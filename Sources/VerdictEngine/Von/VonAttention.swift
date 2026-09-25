import Foundation
import MLX

/// Sliding-window attention for Von's local layers, reusing LayaWindowedAttention's blocked kernel
/// (64-query blocks against their 3 x 64-key neighbourhood, strided views, one fused SDPA).
///
/// Von 1.1 has ModernBERT's own masks: exactly Laya's path (`LayaWindowedAttention.mask`).
///
/// Von 1.2 (independent options) windows by the order-invariant *position ids*, not the sequence index, and
/// option tokens may only see the prefix and their own option. Prefix tokens (everything before the first
/// marker, the final [SEP] and padding) have position == index, so their allowed keys all lie inside the
/// index neighbourhood: the block mask applies the exact 1.2 rule there. Option tokens restart at the prefix
/// length, so they need prefix keys up to 64 *positions* back, which can be further than 64 indices; those
/// queries (the option region [first marker, last token), typically tens of tokens) are recomputed densely
/// against the keys [first marker - 64, row end) and merged back (`recomputeTail`).
enum VonWindowedAttention {
    /// Exact 1.2 local rule inside each block's neighbourhood: [B * H, nb, w, 3w].
    static func independentBlockMask(valid: MLXArray, positions: MLXArray, options: MLXArray, heads h: Int, half w: Int) -> MLXArray {
        let b = valid.dim(0), length = valid.dim(1), nb = (length + w - 1) / w, extra = nb * w - length
        func blocks(_ x: MLXArray, pad: MLXArray) -> (query: MLXArray, key: MLXArray) {
            let p = padded(x, widths: [0, [w, w + extra]], value: pad).reshaped(b, nb + 2, w)
            let key = concatenated([p[0..., 0..<nb], p[0..., 1..<(nb + 1)], p[0..., 2..<(nb + 2)]], axis: 2)
            return (p[0..., 1..<(nb + 1)].reshaped(b, nb, w, 1), key.reshaped(b, nb, 1, 3 * w))
        }
        let v = blocks(valid, pad: MLXArray(false)), p = blocks(positions, pad: MLXArray(Int32(0))), o = blocks(options, pad: MLXArray(Int32(-1)))
        let queryPrefix = o.query .== Int32(-1), keyPrefix = o.key .== Int32(-1)
        let allowed = logicalOr(logicalAnd(queryPrefix, keyPrefix), logicalAnd(logicalNot(queryPrefix), logicalOr(keyPrefix, o.query .== o.key)))
        let local = abs(p.query - p.key) .<= Int32(w)
        let r = MLXArray(Int32(0)..<Int32(w)).reshaped(w, 1), j = MLXArray(Int32(0)..<Int32(3 * w)).reshaped(1, 3 * w)
        let diagonal = (j .== r + Int32(w)).reshaped(1, 1, w, 3 * w)
        let m = logicalOr(logicalAnd(logicalAnd(allowed, v.key), local), diagonal)
        return broadcast(m.reshaped(b, 1, nb, w, 3 * w), to: [b, h, nb, w, 3 * w]).reshaped(b * h, nb, w, 3 * w)
    }

    /// Gather indices and mask for the option-region queries of one forward (shared by all sliding layers).
    struct Tail {
        let queryIndex: MLXArray   // [B, 1, T, 1]
        let keyIndex: MLXArray     // [B, 1, W, 1]
        let mask: MLXArray         // [B, 1, T, W]
        let slot: MLXArray         // [B, L, 1]: tail slot of each position (clamped)
        let inTail: MLXArray       // [B, L, 1]
        /// `tails`: [B, 2] = (first marker, index of the last content token). T = longest option region,
        /// W = longest key span (row length - max(first marker - half, 0)). nil when no row has an option region.
        init?(valid: MLXArray, positions: MLXArray, options: MLXArray, tails: MLXArray, queries t: Int, keys kw: Int, half w: Int) {
            guard t > 0, kw > 0 else { return nil }
            let b = valid.dim(0), length = valid.dim(1)
            let first = tails[0..., 0..<1], last = tails[0..., 1..<2]
            let rawQuery = first + MLXArray(Int32(0)..<Int32(t)).reshaped(1, t)
            let queryIn = rawQuery .< last
            let q = minimum(rawQuery, Int32(length - 1))
            let rawKey = maximum(first - Int32(w), Int32(0)) + MLXArray(Int32(0)..<Int32(kw)).reshaped(1, kw)
            let keyIn = rawKey .<= last
            let k = minimum(rawKey, Int32(length - 1))
            let oq = takeAlong(options, q, axis: 1).reshaped(b, t, 1), ok = takeAlong(options, k, axis: 1).reshaped(b, 1, kw)
            let pq = takeAlong(positions, q, axis: 1).reshaped(b, t, 1), pk = takeAlong(positions, k, axis: 1).reshaped(b, 1, kw)
            let kv = logicalAnd(takeAlong(valid, k, axis: 1), keyIn).reshaped(b, 1, kw)
            let queryPrefix = oq .== Int32(-1), keyPrefix = ok .== Int32(-1)
            let allowed = logicalOr(logicalAnd(queryPrefix, keyPrefix), logicalAnd(logicalNot(queryPrefix), logicalOr(keyPrefix, oq .== ok)))
            let diagonal = q.reshaped(b, t, 1) .== k.reshaped(b, 1, kw)
            var m = logicalOr(logicalAnd(logicalAnd(allowed, kv), abs(pq - pk) .<= Int32(w)), diagonal)
            m = logicalOr(m, logicalNot(queryIn).reshaped(b, t, 1))   // unused query slots: any finite result
            mask = m.reshaped(b, 1, t, kw)
            queryIndex = q.reshaped(b, 1, t, 1); keyIndex = k.reshaped(b, 1, kw, 1)
            let p = MLXArray(Int32(0)..<Int32(length)).reshaped(1, length)
            inTail = logicalAnd(p .>= first, p .< last).reshaped(b, length, 1)
            slot = clip(p - first, min: Int32(0), max: Int32(t - 1)).reshaped(b, length, 1)
        }
    }

    /// Replace the option-region rows of the windowed output [B, L, H * d] with dense attention over their keys.
    static func recomputeTail(_ out: MLXArray, q: MLXArray, k: MLXArray, v: MLXArray, tail: Tail, scale: Float) -> MLXArray {
        let b = q.dim(0), t = tail.queryIndex.dim(2)
        let qt = takeAlong(q, tail.queryIndex, axis: 2), kt = takeAlong(k, tail.keyIndex, axis: 2), vt = takeAlong(v, tail.keyIndex, axis: 2)
        let attended = MLXFast.scaledDotProductAttention(queries: qt, keys: kt, values: vt, scale: scale, mask: .array(tail.mask))
            .transposed(0, 2, 1, 3).reshaped(b, t, -1)
        return MLX.where(tail.inTail, takeAlong(attended, tail.slot, axis: 1), out)
    }

    /// Stock dense local attention for the self-test, as VonGraph computes it without windowing. [B, L, H * d].
    static func stock(q: MLXArray, k: MLXArray, v: MLXArray, valid: MLXArray, positions: MLXArray, options: MLXArray,
                      independent: Bool, half w: Int, scale: Float) -> MLXArray {
        let b = q.dim(0), n = q.dim(2)
        let local: MLXArray
        if independent {
            let oi = options.expandedDimensions(axis: 2), oj = options.expandedDimensions(axis: 1)
            let prefix = (oi .== -1), keyPrefix = (oj .== -1)
            let allowed = logicalOr(logicalAnd(prefix, keyPrefix), logicalAnd(logicalNot(prefix), logicalOr(keyPrefix, oi .== oj)))
            let eye = MLXArray(0..<n)
            let diagonal = (eye.expandedDimensions(axis: 0) .== eye.expandedDimensions(axis: 1)).reshaped(1, n, n)
            let attend = logicalOr(logicalAnd(allowed, valid.expandedDimensions(axis: 1)), diagonal)
            let diff = abs(positions.expandedDimensions(axis: 2) - positions.expandedDimensions(axis: 1))
            local = logicalOr(logicalAnd(attend, diff .<= w), diagonal).expandedDimensions(axis: 1)
        } else {
            let p = MLXArray(0..<n)
            let distance = abs(p.expandedDimensions(axis: 1) - p.expandedDimensions(axis: 0)) .<= w
            local = logicalAnd(logicalOr(distance.reshaped(1, 1, n, n), logicalNot(valid.reshaped(b, 1, n, 1))), valid.reshaped(b, 1, 1, n))
        }
        return MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: scale, mask: .array(local))
            .transposed(0, 2, 1, 3).reshaped(b, n, -1)
    }

    /// On-device check at load: windowed (+ option tail for 1.2) vs stock on fixed inputs in the model dtype — two rows, one
    /// padded, lengths not a block multiple, 1.2 rows with options whose tokens sit > 64 indices past the prefix.
    /// Returns max |difference| on valid queries, or nil if non-finite or more than a few fp16 ulps.
    static func selfTest(half w: Int, heads: Int, dims d: Int, independent: Bool, dtype: DType) -> Float? {
        let b = 2, length = 4 * w + 45, count = b * heads * length * d
        func tensor(_ seed: Float) -> MLXArray {
            let values = (0..<count).map { i -> Float in let x = Float(i); return sin(x * 0.7071 + seed) * cos(x * 0.0137 * seed) }
            return MLXArray(values, [b, heads, length, d]).asType(dtype)
        }
        let q = tensor(1.3), k = tensor(2.9), v = tensor(0.61)
        let lengths = [length, 3 * w + 7]
        // Row 0: prefix 150 tokens, options of 30/60/60 tokens (> 64 indices past the prefix), final token.
        // Row 1: prefix 120, options of 40/49, final token, then padding.
        let spans = [[150, 180, 240], [120, 160]]
        var valid = [Bool](), pos = [Int32](), opts = [Int32](), tails = [Int32]()
        for row in 0..<b {
            let n = lengths[row], m = spans[row]
            for j in 0..<length {
                valid.append(j < n)
                var option = Int32(-1), p = Int32(j)
                if independent, j < n - 1, j >= m[0] {
                    let o = m.lastIndex { $0 <= j }!
                    option = Int32(o); p = Int32(m[0] + j - m[o])
                }
                opts.append(option); pos.append(p)
            }
            tails += [Int32(m[0]), Int32(n - 1)]
        }
        let validA = MLXArray(valid, [b, length]), posA = MLXArray(pos, [b, length]), optsA = MLXArray(opts, [b, length])
        let scale = pow(Float(d), -0.5)
        var windowed: MLXArray
        if independent {
            let mask = independentBlockMask(valid: validA, positions: posA, options: optsA, heads: heads, half: w)
            windowed = LayaWindowedAttention.attend(q: q, k: k, v: v, mask: mask, half: w, scale: scale)
            let t = zip(lengths, spans).map { $0 - 1 - $1[0] }.max()!, kw = zip(lengths, spans).map { $0 - max(0, $1[0] - w) }.max()!
            guard let tail = Tail(valid: validA, positions: posA, options: optsA, tails: MLXArray(tails, [b, 2]), queries: t, keys: kw, half: w) else { return nil }
            windowed = recomputeTail(windowed, q: q, k: k, v: v, tail: tail, scale: scale)
        } else {
            windowed = LayaWindowedAttention.attend(q: q, k: k, v: v, mask: LayaWindowedAttention.mask(valid: validA, heads: heads, half: w), half: w, scale: scale)
        }
        let reference = stock(q: q, k: k, v: v, valid: validA, positions: posA, options: optsA, independent: independent, half: w, scale: scale).asType(.float32)
        let got = windowed.asType(.float32)
        let finite = isFinite(got).all().item(Bool.self)
        let diff = MLX.where(validA.reshaped(b, length, 1), abs(got - reference), MLXArray(Float(0))).max().item(Float.self)
        // A few ulps of the compute dtype: blocked and dense SDPA only differ in reduction tiling.
        return finite && diff.isFinite && diff <= (dtype == .float32 ? 1e-5 : 4e-3) ? diff : nil
    }
}
