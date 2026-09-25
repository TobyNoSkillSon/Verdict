// ModernBERT encoder follows the parity-qualified LayaGraph operator path;
// Von adds its own option-marker scorer and (1.2) isolated-option masks/RoPE.
import Foundation
import MLX
import MLXNN

/// GELU(a) * b in one kernel (same formula as MLXNN's gelu; as LayaNetwork's). Captures no arrays, so the
/// thread-local compile cache holds no weights.
private let vonGeGLU: @Sendable (MLXArray, MLXArray) -> MLXArray = compile(shapeless: true) { a, b in a * (1 + erf(a / sqrt(2))) / 2 * b }

final class VonNetwork {
    /// Encoder weights/activations dtype: the original f32 by default (bits 0 or 32; fp16 fails the ≤1% gate vs the SDK
    /// on near-tie items, native/perf/THEORY.md), fp16 at 16 bits and for the 8/4-bit quantized models (activations,
    /// embeddings, norms and quantization scales). VERDICT_VON_DTYPE=fp32|fp16|bf16 overrides (A/B, tolerance curve).
    static func dtype(bits: Int) -> DType {
        switch ProcessInfo.processInfo.environment["VERDICT_VON_DTYPE"] {
        case "fp32": return .float32
        case "fp16": return .float16
        case "bf16": return .bfloat16
        default: return bits == 0 || bits == 32 ? .float32 : .float16
        }
    }
    /// Encoder Linear layers (Wqkv, Wo, Wi, mlp.Wo; in-dims 1024/2624, all multiples of 64) are quantized at 8 or 4 bits,
    /// group 64, as LayaNetwork. Embeddings, norms and the scorer head (1.6 MB, marker rows only, f32) never are.
    static let quantGroup = 64
    /// Keep the residual stream in f32 while the GEMMs run in the (half) weight dtype: VERDICT_VON_RESIDUAL=fp32.
    static let residualF32 = ProcessInfo.processInfo.environment["VERDICT_VON_RESIDUAL"] == "fp32"
    /// Diagnostic/curve knob: encoder layers kept entirely in f32 (weights and compute), e.g. "0-3,27".
    static let f32Layers: Set<Int> = {
        var out = Set<Int>()
        for part in (ProcessInfo.processInfo.environment["VERDICT_VON_F32_LAYERS"] ?? "").split(separator: ",") {
            let bounds = part.split(separator: "-").compactMap { Int($0) }
            if bounds.count == 1 { out.insert(bounds[0]) } else if bounds.count == 2, bounds[0] <= bounds[1] { out.formUnion(bounds[0]...bounds[1]) }
        }
        return out
    }()
    static func layerIndex(_ name: String) -> Int? {
        guard name.hasPrefix("layers.") else { return nil }
        return Int(name.dropFirst(7).prefix { $0 != "." })
    }
    static let fusedGeGLU = ProcessInfo.processInfo.environment["VERDICT_VON_GEGLU"] != "0"
    static let windowEnabled = ProcessInfo.processInfo.environment["VERDICT_VON_WINDOW"] != "0"
    /// Rows shorter than this keep the dense local mask (as Laya: the window covers nearly everything below ~700).
    static let windowMinimum = Int(ProcessInfo.processInfo.environment["VERDICT_VON_WINDOW_MIN"] ?? "") ?? 768

    let config: LayaEncoderConfiguration
    let independent: Bool
    let dtype: DType
    /// 8 or 4 when the encoder Linears are quantized, else 0.
    let quantBits: Int
    private var graph: VonGraph!
    let residentBytes: Int
    /// Active attention path for the sliding-window layers, reported in /status.
    var kernelPath: String { stockForced && windowedValidated ? "stock (windowed attention switched off after an inference failure)" : validatedKernelPath }
    private var validatedKernelPath = "stock"
    /// Windowed attention passed its load-time self-test.
    private(set) var windowedValidated = false
    private var stockForced = false
    /// True while long rows take the windowed path.
    var windowedActive: Bool { windowedValidated && !stockForced }
    /// Stock attention (true) or back to the validated windowed path (false).
    func useStockAttention(_ on: Bool) { stockForced = on; graph.windowed = windowedActive }

    init(snapshot: URL, id: String, bits: Int) throws {
        config = try LayaEncoderConfiguration(data: Data(contentsOf: snapshot.appendingPathComponent("config.json")))
        let zip = try VonZip(snapshot.appendingPathComponent("option_marker.pt"))
        try VonWeights.validate(zip, config: config)
        independent = id == "von-1.2"
        dtype = Self.dtype(bits: bits)
        quantBits = bits == 8 || bits == 4 ? bits : 0
        // One f32 storage at a time: converted (or quantized) and evaluated before the next is read, so load peaks at
        // the converted model plus one f32 tensor (the f32 buffer is freed as soon as its conversion evaluates).
        // The scorer head (1.6 MB) and the final norm stay f32: they run on marker rows only.
        var weights: [String: MLXArray] = [:]
        var quantized: [String: (MLXArray, MLXArray, MLXArray?)] = [:]
        let names = VonWeights.encoderNames(config) + VonWeights.head
        let encoderLinear = [".attn.Wqkv.weight", ".attn.Wo.weight", ".mlp.Wi.weight", ".mlp.Wo.weight"]
        for (i, (name, shape)) in names.enumerated() {
            let raw = try zip.tensor(i, shape: shape)
            let f32Layer = Self.layerIndex(name).map { Self.f32Layers.contains($0) } == true
            if quantBits > 0, !f32Layer, encoderLinear.contains(where: name.hasSuffix), shape[1] % Self.quantGroup == 0 {
                // Quantized from the original f32 weights; scales/biases then take the activation dtype.
                let (w, s, b) = MLX.quantized(raw, groupSize: Self.quantGroup, bits: quantBits)
                let entry = (w, s.asType(dtype), b?.asType(dtype))
                eval([entry.0, entry.1] + (entry.2.map { [$0] } ?? []))
                quantized[String(name.dropLast(7))] = entry   // key without ".weight"
                continue
            }
            let keep = dtype == .float32 || name.hasPrefix("scorer.") || name.hasPrefix("final_norm.") || f32Layer
            let value = keep ? raw : raw.asType(dtype)
            eval(value)
            weights[name] = value
        }
        let expected = Set(names.map(\.0))
        guard Set(weights.keys).union(quantized.keys.map { $0 + ".weight" }) == expected else { throw VonError.invalid("Von checkpoint is not the trained 178-key model") }
        var linearNames = ["scorer.dense", "scorer.out_proj"]
        for i in 0..<config.num_hidden_layers {
            linearNames += ["attn.Wqkv", "attn.Wo", "mlp.Wi", "mlp.Wo"].map { "layers.\(i)." + $0 }
        }
        var linears: [String: Linear] = [:]
        for name in linearNames {
            if let (w, s, b) = quantized.removeValue(forKey: name) {
                linears[name] = QuantizedLinear(weight: w, bias: weights.removeValue(forKey: name + ".bias"), scales: s, biases: b,
                                                groupSize: Self.quantGroup, bits: quantBits)
                continue
            }
            guard let w = weights.removeValue(forKey: name + ".weight"), w.ndim == 2 else { throw VonError.invalid("Missing Von linear \(name)") }
            linears[name] = Linear(weight: w, bias: weights.removeValue(forKey: name + ".bias"))
        }
        guard quantized.isEmpty else { throw VonError.invalid("Unexpected quantized Von tensors") }
        let arrays = weights
        var all = Array(arrays.values)
        for layer in linears.values { all += layer.parameters().flattened().map(\.1) }
        eval(all)
        residentBytes = all.reduce(0) { $0 + $1.nbytes }
        // Previous revisions stored a duplicate local safetensors conversion.
        // Only remove our own regular cache file after all ZIP weights evaluate.
        let legacy = snapshot.appendingPathComponent("von-encoder.safetensors")
        if let values = try? legacy.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
           values.isRegularFile == true && values.isSymbolicLink != true {
            try FileManager.default.removeItem(at: legacy)
        }
        var windowed = false
        if Self.windowEnabled {
            let heads = config.num_attention_heads
            if let diff = VonWindowedAttention.selfTest(half: config.local_attention / 2, heads: heads, dims: config.hidden_size / heads, independent: independent, dtype: dtype) {
                windowed = true
                validatedKernelPath = String(format: "windowed-attention%@ (L>=%d, self-test max diff %.1e)", independent ? " + option tail" : "", Self.windowMinimum, diff)
            } else { validatedKernelPath = "stock (windowed-attention self-test failed)" }
        }
        windowedValidated = windowed
        // MLX's compiled closure/cache retained ~1.58 GB of this model's
        // allocations after deinit. The ordinary graph has identical fixture
        // outputs and releases the weights immediately on /unload.
        graph = VonGraph(config: config, independent: independent, arrays: arrays, linears: linears, dtype: dtype, windowed: windowed)
        Memory.clearCache()   // conversion and self-test buffers; not weights
    }

    /// Build a chunk's inputs and queue its forward on the GPU without waiting. `length` >= every row's length
    /// (bucket padding). Returns [B, maxMarkers] f32 logits (unread).
    func launch(_ ids: [[Int]], _ markers: [[Int]], length: Int) -> MLXArray {
        let b = ids.count, count = markers.map(\.count).max()!
        var tokens = [Int32](repeating: 0, count: b * length)
        var valid = [Bool](repeating: false, count: b * length)
        var positions = [Int32](repeating: 0, count: b * length)
        var optionIDs = [Int32](repeating: -1, count: b * length)
        var indices = [Int32](repeating: 0, count: b * count)
        var tails = [Int32](repeating: 0, count: b * 2)
        for row in 0..<b {
            let n = ids[row].count, base = row * length
            for j in 0..<length { positions[base + j] = Int32(j) }
            for (j, t) in ids[row].enumerated() { tokens[base + j] = Int32(t); valid[base + j] = true }
            if n < length { for j in n..<length { tokens[base + j] = Int32(ids[row].last ?? 0) } }
            let m = markers[row]
            for (j, marker) in m.enumerated() {
                let end = j + 1 < m.count ? m[j + 1] : n - 1
                indices[row * count + j] = Int32(marker)
                for k in marker..<max(marker, end) {
                    optionIDs[base + k] = Int32(j)
                    positions[base + k] = Int32(m[0] + k - marker)
                }
            }
            // Option region [first marker, last content token) — the queries the 1.2 windowed path recomputes.
            tails[row * 2] = Int32(m.first ?? n); tails[row * 2 + 1] = Int32(n - 1)
        }
        let unpadded = ids.allSatisfy { $0.count == length }
        let inputs = VonGraph.Inputs(ids: MLXArray(tokens, [b, length]), valid: MLXArray(valid, [b, length]),
                                     positions: MLXArray(positions, [b, length]), options: MLXArray(optionIDs, [b, length]),
                                     markers: MLXArray(indices, [b, count]), tails: MLXArray(tails, [b, 2]),
                                     unpadded: unpadded, tailLength: zip(ids, markers).map { max(0, $0.count - 1 - ($1.first ?? $0.count)) }.max() ?? 0,
                                     tailKeys: zip(ids, markers).map { $0.count - max(0, ($1.first ?? $0.count) - config.local_attention / 2) }.max() ?? 0)
        let output = graph.forward(inputs)
        asyncEval(output)
        return output
    }

    /// Wait for a launched chunk and split its logits per row.
    func collect(_ output: MLXArray, markers: [[Int]]) -> [[Float]] {
        let count = markers.map(\.count).max()!
        let flat = output.asArray(Float.self)
        return markers.indices.map { i in Array(flat[i * count..<(i * count + markers[i].count)]) }
    }
}

private final class VonGraph {
    struct Inputs {
        let ids, valid, positions, options, markers, tails: MLXArray
        let unpadded: Bool
        let tailLength: Int, tailKeys: Int
    }
    let config: LayaEncoderConfiguration
    let independent: Bool
    let arrays: [String: MLXArray]
    let linears: [String: Linear]
    let dtype: DType
    var windowed: Bool
    let half: Int
    init(config: LayaEncoderConfiguration, independent: Bool, arrays: [String: MLXArray], linears: [String: Linear], dtype: DType, windowed: Bool) {
        self.config = config; self.independent = independent; self.arrays = arrays; self.linears = linears
        self.dtype = dtype; self.windowed = windowed; half = config.local_attention / 2
    }
    func norm(_ x: MLXArray, _ name: String) -> MLXArray {
        MLXFast.layerNorm(x, weight: arrays[name + ".weight"], bias: arrays[name + ".bias"], eps: config.norm_eps)
    }
    func linear(_ x: MLXArray, _ name: String) -> MLXArray { linears[name]!(x) }
    /// cos/sin tables for per-token positions [B, 1, L, d], computed once per forward per RoPE base (f32 angles,
    /// cast to the activation dtype as transformers does).
    func rotary(_ pos: MLXArray, base: Float, dims d: Int) -> (MLXArray, MLXArray) {
        let freqs = MLXArray(0..<(d / 2)).asType(.float32) * MLXArray(Float(2) / Float(d))
        let inverse = exp(-freqs * log(MLXArray(base)))
        let angles = pos.asType(.float32).expandedDimensions(axis: -1) * inverse
        let c = cos(angles), s = sin(angles)
        return (concatenated([c, c], axis: -1).expandedDimensions(axis: 1).asType(dtype),
                concatenated([s, s], axis: -1).expandedDimensions(axis: 1).asType(dtype))
    }
    func rotate(_ x: MLXArray, _ table: (MLXArray, MLXArray)) -> MLXArray {
        let halves = split(x, parts: 2, axis: -1)
        let (c, sn) = x.dtype == table.0.dtype ? table : (table.0.asType(x.dtype), table.1.asType(x.dtype))
        return x * c + concatenated([-halves[1], halves[0]], axis: -1) * sn
    }
    struct Masks {
        var full: MLXArray?            // nil: no mask (unpadded 1.1 chunk)
        var local: MLXArray?           // dense local mask (short rows or stock path)
        var block: MLXArray?           // windowed block mask
        var tail: VonWindowedAttention.Tail?   // 1.2: option-region recompute
    }
    func attention(_ x: MLXArray, _ name: String, global: Bool, masks: Masks, rope: (MLXArray, MLXArray)?, base: Float) -> MLXArray {
        let b = x.dim(0), n = x.dim(1), h = config.num_attention_heads, d = config.hidden_size / h
        let qkv = linear(x, name + ".Wqkv").reshaped(b, n, 3, h, d)
        var q = qkv[0..., 0..., 0, 0..., 0...].transposed(0, 2, 1, 3)
        var k = qkv[0..., 0..., 1, 0..., 0...].transposed(0, 2, 1, 3)
        let v = qkv[0..., 0..., 2, 0..., 0...].transposed(0, 2, 1, 3)
        if let rope {
            q = rotate(q, rope); k = rotate(k, rope)
        } else {
            q = MLXFast.RoPE(q, dimensions: d, traditional: false, base: base, scale: 1, offset: 0)
            k = MLXFast.RoPE(k, dimensions: d, traditional: false, base: base, scale: 1, offset: 0)
        }
        let scale = pow(Float(d), -0.5)
        if !global, let block = masks.block {
            var out = LayaWindowedAttention.attend(q: q, k: k, v: v, mask: block, half: half, scale: scale)
            if let tail = masks.tail { out = VonWindowedAttention.recomputeTail(out, q: q, k: k, v: v, tail: tail, scale: scale) }
            return linear(out, name + ".Wo")
        }
        let mask = global ? masks.full : masks.local
        let attended = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: scale, mask: mask.map { .array($0) } ?? .none)
        return linear(attended.transposed(0, 2, 1, 3).reshaped(b, n, config.hidden_size), name + ".Wo")
    }
    func forward(_ inputs: Inputs) -> MLXArray {
        let ids = inputs.ids, valid = inputs.valid, pos = inputs.positions, opts = inputs.options
        let b = ids.dim(0), n = ids.dim(1)
        let useWindow = windowed && n >= VonNetwork.windowMinimum
        var masks = Masks()
        if independent {
            let oi = opts.expandedDimensions(axis: 2), oj = opts.expandedDimensions(axis: 1)
            let prefix = (oi .== -1), keyPrefix = (oj .== -1)
            let allowed = logicalOr(logicalAnd(prefix, keyPrefix), logicalAnd(logicalNot(prefix), logicalOr(keyPrefix, oi .== oj)))
            let padOK = valid.expandedDimensions(axis: 1)
            let eye = MLXArray(0..<n)
            let diagonal = (eye.expandedDimensions(axis: 0) .== eye.expandedDimensions(axis: 1)).reshaped(1, n, n)
            let attend = logicalOr(logicalAnd(allowed, padOK), diagonal)
            masks.full = attend.expandedDimensions(axis: 1)
            if useWindow {
                masks.block = VonWindowedAttention.independentBlockMask(valid: valid, positions: pos, options: opts, heads: config.num_attention_heads, half: half)
                masks.tail = VonWindowedAttention.Tail(valid: valid, positions: pos, options: opts, tails: inputs.tails,
                                                       queries: inputs.tailLength, keys: inputs.tailKeys, half: half)
            } else {
                let diff = abs(pos.expandedDimensions(axis: 2) - pos.expandedDimensions(axis: 1))
                masks.local = logicalOr(logicalAnd(attend, diff .<= half), diagonal).expandedDimensions(axis: 1)
            }
        } else {
            let keyMask = valid.reshaped(b, 1, 1, n)
            masks.full = inputs.unpadded ? nil : keyMask
            if useWindow {
                masks.block = LayaWindowedAttention.mask(valid: valid, heads: config.num_attention_heads, half: half)
            } else {
                let p = MLXArray(0..<n)
                let distance = abs(p.expandedDimensions(axis: 1) - p.expandedDimensions(axis: 0)) .<= half
                masks.local = logicalAnd(logicalOr(distance.reshaped(1, 1, n, n), logicalNot(valid.reshaped(b, 1, n, 1))), keyMask)
            }
        }
        let d = config.hidden_size / config.num_attention_heads
        var tables: [Float: (MLXArray, MLXArray)] = [:]
        if independent {
            for kind in ["full_attention", "sliding_attention"] {
                let base = config.ropeBase(kind)
                if tables[base] == nil { tables[base] = rotary(pos, base: base, dims: d) }
            }
        }
        var x = arrays["embeddings.tok_embeddings.weight"]![ids]
        x = norm(x, "embeddings.norm")
        let wide = VonNetwork.residualF32 && dtype != .float32
        if wide { x = x.asType(.float32) }
        for i in 0..<config.num_hidden_layers {
            let layerType: DType = VonNetwork.f32Layers.contains(i) ? .float32 : dtype
            func narrow(_ y: MLXArray) -> MLXArray { y.dtype == layerType ? y : y.asType(layerType) }
            if !wide && x.dtype != dtype { x = x.asType(dtype) }
            let prefix = "layers.\(i)", kind = config.kind(i), base = config.ropeBase(kind)
            let y = narrow(i == 0 ? x : norm(x, prefix + ".attn_norm"))
            x = x + attention(y, prefix + ".attn", global: kind == "full_attention", masks: masks, rope: tables[base], base: base)
            let mlp = linear(narrow(norm(x, prefix + ".mlp_norm")), prefix + ".mlp.Wi")
            let halves = split(mlp, parts: 2, axis: -1)
            x = x + linear(VonNetwork.fusedGeGLU ? vonGeGLU(halves[0], halves[1]) : gelu(halves[0]) * halves[1], prefix + ".mlp.Wo")
            if wide && x.dtype != .float32 { x = x.asType(.float32) }
        }
        // LayerNorm is per token: gather the marker rows first, then the final norm and scorer in f32.
        let picked = x[MLXArray(0..<b).expandedDimensions(axis: 1), inputs.markers].asType(.float32)
        let normed = norm(picked, "final_norm")
        let hidden = linear(norm(normed, "scorer.input_norm"), "scorer.dense")
        let score = linear(norm(gelu(hidden), "scorer.norm"), "scorer.out_proj")
        return score.squeezed(axis: -1).asType(.float32)
    }
}
