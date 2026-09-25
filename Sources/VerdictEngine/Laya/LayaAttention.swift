import Foundation
import MLX

/// Models that can report which attention/kernel path is active (shown in /status as "kernel").
public protocol KernelPathReporting { var kernelPath: String { get } }

/// Sliding-window attention for ModernBERT's local layers (|query - key| <= half, half = 64), computed per
/// block of `half` queries against its three-block key neighbourhood (3 * half keys) instead of the full
/// L x L grid the stock path computes and then masks. Same allowed keys, same fused SDPA kernel; only the
/// reduction tiling differs (float rounding). Pays from a few hundred tokens up: at ~7.5k tokens attention
/// was 59% of the forward (measured on an M5 Max).
///
/// Padding queries (valid = false) attend to every key of their neighbourhood rather than every valid key of
/// the row: their outputs are never read (all layers mask invalid keys, markers point at valid tokens), they
/// only must stay finite, and no row may have all keys masked (a NaN value times a zero weight is NaN).
enum LayaWindowedAttention {
    static let enabled = ProcessInfo.processInfo.environment["VERDICT_LAYA_WINDOW"] != "0"
    /// Rows shorter than this keep the stock dense path (window covers nearly everything; nothing to save).
    static let minimumLength = Int(ProcessInfo.processInfo.environment["VERDICT_LAYA_WINDOW_MIN"] ?? "") ?? 768

    /// Block mask for one forward, shared by all sliding layers: [B * H, nb, w, 3w] (the fused SDPA indexes the
    /// flattened batch*head axis with one stride, so it cannot broadcast over heads). ~B*L*H*3w bytes.
    static func mask(valid: MLXArray, heads h: Int, half w: Int) -> MLXArray {
        let b = valid.dim(0), length = valid.dim(1), nb = (length + w - 1) / w, extra = nb * w - length
        // Validity padded by one block on the left: block i + 1 of `vp` holds positions i*w ..< (i+1)*w.
        let vp = padded(valid, widths: [0, [w, w + extra]], value: MLXArray(false)).reshaped(b, nb + 2, w)
        let keyValid = concatenated([vp[0..., 0..<nb], vp[0..., 1..<(nb + 1)], vp[0..., 2..<(nb + 2)]], axis: 2)
        let queryValid = vp[0..., 1..<(nb + 1)]
        // Query r of block i sits at i*w + r; key j of its neighbourhood at (i - 1)*w + j.
        let r = MLXArray(Int32(0)..<Int32(w)).reshaped(w, 1), j = MLXArray(Int32(0)..<Int32(3 * w)).reshaped(1, 3 * w)
        let inWindow = abs(j - Int32(w) - r) .<= Int32(w)
        let m = logicalOr(logicalAnd(inWindow.reshaped(1, 1, w, 3 * w), keyValid.reshaped(b, nb, 1, 3 * w)),
                          logicalNot(queryValid.reshaped(b, nb, w, 1)))
        return broadcast(m.reshaped(b, 1, nb, w, 3 * w), to: [b, h, nb, w, 3 * w]).reshaped(b * h, nb, w, 3 * w)
    }

    /// q, k, v: [B, H, L, d] (after RoPE); mask from `mask(valid:heads:half:)`. Returns [B, L, H * d].
    /// One padding copy each of q, k, v; the blocks are strided views (the fused kernel takes arbitrary
    /// batch/head/sequence strides), so the overlapping 3w-key neighbourhoods are never materialised.
    static func attend(q: MLXArray, k: MLXArray, v: MLXArray, mask: MLXArray, half w: Int, scale: Float) -> MLXArray {
        let b = q.dim(0), h = q.dim(1), length = q.dim(2), d = q.dim(3)
        let nb = (length + w - 1) / w, extra = nb * w - length, rows = (nb + 2) * w
        let qp = extra == 0 ? q.contiguous() : padded(q, widths: [0, 0, [0, extra], 0])
        let qb = asStrided(qp, [b * h, nb, w, d], strides: [nb * w * d, w * d, d, 1])
        func neighbourhood(_ x: MLXArray) -> MLXArray {   // [B, H, L, d] -> view [B * H, nb, 3w, d]
            asStrided(padded(x, widths: [0, 0, [w, w + extra], 0]), [b * h, nb, 3 * w, d], strides: [rows * d, w * d, d, 1])
        }
        let out = MLXFast.scaledDotProductAttention(queries: qb, keys: neighbourhood(k), values: neighbourhood(v), scale: scale, mask: .array(mask))
        let merged = out.reshaped(b, h, nb, w, d).transposed(0, 2, 3, 1, 4).reshaped(b, nb * w, h * d)
        return extra == 0 ? merged : merged[0..., 0..<length]
    }

    /// Stock path, exactly as the dense graph computes a local layer. Returns [B, L, H * d].
    static func stock(q: MLXArray, k: MLXArray, v: MLXArray, valid: MLXArray, half w: Int, scale: Float) -> MLXArray {
        let b = q.dim(0), length = q.dim(2)
        let positions = MLXArray(0..<length)
        let near = abs(positions.expandedDimensions(axis: 1) - positions.expandedDimensions(axis: 0)) .<= w
        let local = logicalAnd(logicalOr(near.reshaped(1, 1, length, length), logicalNot(valid.reshaped(b, 1, length, 1))), valid.reshaped(b, 1, 1, length))
        let out = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: scale, mask: .array(local))
        return out.transposed(0, 2, 1, 3).reshaped(b, length, -1)
    }

    /// On-device check at load: windowed vs stock on fixed fp16 inputs (two rows, one with padding, a
    /// length that is not a block multiple). Returns the max |difference| on valid queries, or nil if the
    /// windowed output is non-finite or differs by more than a few fp16 ulps.
    static func selfTest(half w: Int, heads: Int, dims d: Int) -> Float? {
        let b = 2, length = 4 * w + 45, count = b * heads * length * d
        func tensor(_ seed: Float) -> MLXArray {
            let values = (0..<count).map { i -> Float in let x = Float(i); return sin(x * 0.7071 + seed) * cos(x * 0.0137 * seed) }
            return MLXArray(values, [b, heads, length, d]).asType(.float16)
        }
        let q = tensor(1.3), k = tensor(2.9), v = tensor(0.61)
        let valid = MLXArray((0..<(b * length)).map { $0 < length || $0 - length < 3 * w + 7 }, [b, length])
        let scale = pow(Float(d), -0.5)
        let windowed = attend(q: q, k: k, v: v, mask: mask(valid: valid, heads: heads, half: w), half: w, scale: scale).asType(.float32)
        let reference = stock(q: q, k: k, v: v, valid: valid, half: w, scale: scale).asType(.float32)
        let finite = isFinite(windowed).all().item(Bool.self)
        let diff = MLX.where(valid.reshaped(b, length, 1), abs(windowed - reference), MLXArray(Float(0))).max().item(Float.self)
        return finite && diff.isFinite && diff <= 4e-3 ? diff : nil
    }
}

