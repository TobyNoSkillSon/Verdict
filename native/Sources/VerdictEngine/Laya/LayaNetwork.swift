// Inference port of laya-mlx 0.2.0 model.py (Apache-2.0; Convai Innovations / mizorewww).
import Foundation
import MLX
import MLXNN

enum LayaError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

struct LayaEncoderConfiguration: Decodable {
    let hidden_size: Int
    let num_hidden_layers: Int
    let num_attention_heads: Int
    let intermediate_size: Int
    let vocab_size: Int
    var model_type: String = "modernbert"
    var norm_eps: Float = 1e-5
    var local_attention: Int = 128
    var global_attn_every_n_layers: Int = 3
    var global_rope_theta: Float = 160000
    var local_rope_theta: Float = 10000
    var layer_types: [String]?
    var rope_parameters: [String: RopeParameters]?
    struct RopeParameters: Decodable { let rope_theta: Float; var rope_type: String? }

    init(data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        func integer(_ key: String) throws -> Int {
            guard let result = object[key] as? Int, result > 0 else { throw LayaError.invalid("Missing encoder field \(key)") }
            return result
        }
        hidden_size = try integer("hidden_size")
        num_hidden_layers = try integer("num_hidden_layers")
        num_attention_heads = try integer("num_attention_heads")
        intermediate_size = try integer("intermediate_size")
        vocab_size = try integer("vocab_size")
        model_type = object["model_type"] as? String ?? "modernbert"
        norm_eps = (object["norm_eps"] as? NSNumber)?.floatValue ?? 1e-5
        local_attention = object["local_attention"] as? Int ?? 128
        global_attn_every_n_layers = object["global_attn_every_n_layers"] as? Int ?? 3
        global_rope_theta = (object["global_rope_theta"] as? NSNumber)?.floatValue ?? 160000
        local_rope_theta = (object["local_rope_theta"] as? NSNumber)?.floatValue ?? 10000
        layer_types = object["layer_types"] as? [String]
        if let parameters = object["rope_parameters"] {
            rope_parameters = try JSONDecoder().decode([String: RopeParameters].self, from: JSONSerialization.data(withJSONObject: parameters))
        }
        guard model_type == "modernbert", object["hidden_activation"] as? String ?? "gelu" == "gelu",
              hidden_size % num_attention_heads == 0, (hidden_size / num_attention_heads) % 2 == 0,
              global_attn_every_n_layers > 0 else { throw LayaError.invalid("Unsupported ModernBERT configuration") }
        if let types = layer_types, types.count != num_hidden_layers || types.contains(where: { !["full_attention", "sliding_attention"].contains($0) }) {
            throw LayaError.invalid("Invalid ModernBERT layer_types")
        }
        if rope_parameters?.values.contains(where: { ($0.rope_type ?? "default") != "default" }) == true {
            throw LayaError.invalid("Only default (unscaled) ModernBERT RoPE is supported")
        }
    }

    func kind(_ layer: Int) -> String { layer_types?[layer] ?? (layer % global_attn_every_n_layers == 0 ? "full_attention" : "sliding_attention") }
    func ropeBase(_ kind: String) -> Float { rope_parameters?[kind]?.rope_theta ?? (kind == "full_attention" ? global_rope_theta : local_rope_theta) }
}

/// Frozen, inference-only weights. Serial use is owned by the helper's model service.
/// Uses the exact MLX Linear / QuantizedLinear primitives used by the Python model.
final class LayaNetwork {
    let config: LayaEncoderConfiguration
    let headLayers: Int
    private var arrays: [String: MLXArray] = [:]
    private var linears: [String: Linear] = [:]
    private(set) var residentBytes = 0
    /// Active attention path for the sliding-window layers, reported in /status.
    private(set) var kernelPath = "stock"
    private var graph: LayaGraph!

    init(snapshot: URL, config: LayaEncoderConfiguration, headLayers: Int, bits: Int) throws {
        self.config = config; self.headLayers = headLayers
        let raw = try MLX.loadArrays(url: snapshot.appendingPathComponent("model.safetensors"))
        var weights: [String: MLXArray] = [:]
        for (original, array) in raw {
            var key = original.replacingOccurrences(of: ".in_proj_weight", with: ".in_proj.weight")
                .replacingOccurrences(of: ".in_proj_bias", with: ".in_proj.bias")
            for prefix in ["scorer", "act_head"] where key.hasPrefix(prefix + ".") && !key.hasPrefix(prefix + ".layers.") {
                key = prefix + ".layers." + key.dropFirst(prefix.count + 1)
            }
            guard weights[key] == nil else { throw LayaError.invalid("Duplicate checkpoint parameter \(key)") }
            weights[key] = array.asType(.float16)
        }
        // Only actual Linear layers are quantized; never embeddings or LayerNorm.
        var linearNames = ["scorer.layers.1", "scorer.layers.3", "act_head.layers.0", "act_head.layers.2"]
        for i in 0..<config.num_hidden_layers {
            linearNames += ["attn.Wqkv", "attn.Wo", "mlp.Wi", "mlp.Wo"].map { "encoder.layers.\(i)." + $0 }
        }
        for i in 0..<headLayers {
            linearNames += ["self_attn.in_proj", "self_attn.out_proj", "linear1", "linear2"].map { "head.layers.\(i)." + $0 }
        }
        for name in linearNames {
            guard let weight = weights.removeValue(forKey: name + ".weight"), weight.ndim == 2 else {
                throw LayaError.invalid("Missing or invalid Linear weight \(name)")
            }
            let bias = weights.removeValue(forKey: name + ".bias")
            if (bits == 4 || bits == 8) && weight.dim(-1) % 64 == 0 {
                linears[name] = QuantizedLinear(weight: weight, bias: bias, groupSize: 64, bits: bits)
            } else { linears[name] = Linear(weight: weight, bias: bias) }
        }
        arrays = weights
        var needed = ["encoder.embeddings.tok_embeddings.weight", "encoder.embeddings.norm.weight", "encoder.final_norm.weight", "type_emb.weight", "scorer.layers.0.weight"]
        for i in 0..<config.num_hidden_layers {
            needed.append("encoder.layers.\(i).mlp_norm.weight")
            if i > 0 { needed.append("encoder.layers.\(i).attn_norm.weight") }
        }
        for i in 0..<headLayers { needed += ["head.layers.\(i).norm1.weight", "head.layers.\(i).norm2.weight"] }
        for key in needed where arrays[key] == nil { throw LayaError.invalid("Missing checkpoint parameter \(key)") }
        var all = Array(arrays.values)
        for linear in linears.values { all += linear.parameters().flattened().map(\.1) }
        eval(all)
        residentBytes = all.reduce(0) { $0 + $1.nbytes }
        // No MLX compile (same finding as VonNetwork): MLX's compile cache is thread_local and keyed by the
        // closure's address, while requests run on arbitrary GCD threads. Traced graphs, which hold every
        // weight, then outlive /unload and precision switches (~0.8 GB leaked per English reload), and
        // per-shape traces grow the footprint. The plain graph gives identical outputs at the same speed.
        var windowed = false
        if LayaWindowedAttention.enabled {
            let heads = config.num_attention_heads
            if let diff = LayaWindowedAttention.selfTest(half: config.local_attention / 2, heads: heads, dims: config.hidden_size / heads) {
                windowed = true
                kernelPath = String(format: "windowed-attention (L>=%d, self-test max diff %.1e)", LayaWindowedAttention.minimumLength, diff)
            } else { kernelPath = "stock (windowed-attention self-test failed)" }
            Memory.clearCache()   // self-test buffers; not weights
        }
        graph = LayaGraph(config: config, headLayers: headLayers, arrays: arrays, linears: linears, windowed: windowed)
    }

    /// Queue the forward on the GPU without blocking; the caller reads the result later.
    func launch(_ inputs: [MLXArray]) -> MLXArray {
        let result = graph.forward(inputs)
        asyncEval(result)
        return result
    }

    func forward(_ inputs: [MLXArray]) -> MLXArray {
        let result = graph.forward(inputs)
        eval(result)
        return result
    }
}

private final class LayaGraph {
    let config: LayaEncoderConfiguration
    let headLayers: Int
    let arrays: [String: MLXArray]
    let linears: [String: Linear]
    let windowed: Bool
    init(config: LayaEncoderConfiguration, headLayers: Int, arrays: [String: MLXArray], linears: [String: Linear], windowed: Bool) {
        self.config = config; self.headLayers = headLayers; self.arrays = arrays; self.linears = linears; self.windowed = windowed
    }
    func norm(_ x: MLXArray, _ name: String, eps: Float = 1e-5) -> MLXArray {
        MLXFast.layerNorm(x, weight: arrays[name + ".weight"], bias: arrays[name + ".bias"], eps: eps)
    }
    func linear(_ x: MLXArray, _ name: String) -> MLXArray { linears[name]!(x) }
    /// `window`: the block mask (LayaWindowedAttention.mask) when this sliding layer takes the windowed path.
    func attention(_ x: MLXArray, name: String, heads: Int, mask: MLXArray?, ropeBase: Float? = nil, window: MLXArray? = nil) -> MLXArray {
        let b = x.dim(0), length = x.dim(1), dims = x.dim(2), d = dims / heads
        let qkv = linear(x, name + (ropeBase == nil ? ".in_proj" : ".Wqkv")).reshaped(b, length, 3, heads, d)
        var q = qkv[0..., 0..., 0, 0..., 0...].transposed(0, 2, 1, 3)
        var k = qkv[0..., 0..., 1, 0..., 0...].transposed(0, 2, 1, 3)
        let v = qkv[0..., 0..., 2, 0..., 0...].transposed(0, 2, 1, 3)
        if let base = ropeBase {
            q = MLXFast.RoPE(q, dimensions: d, traditional: false, base: base, scale: 1, offset: 0)
            k = MLXFast.RoPE(k, dimensions: d, traditional: false, base: base, scale: 1, offset: 0)
        }
        if let blockMask = window {
            let attended = LayaWindowedAttention.attend(q: q, k: k, v: v, mask: blockMask, half: config.local_attention / 2, scale: pow(Float(d), -0.5))
            return linear(attended, name + ".Wo")
        }
        let attended = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: pow(Float(d), -0.5), mask: .array(mask!))
        return linear(attended.transposed(0, 2, 1, 3).reshaped(b, length, dims), name + (ropeBase == nil ? ".out_proj" : ".Wo"))
    }
    func forward(_ inputs: [MLXArray]) -> MLXArray {
        let ids = inputs[0], valid = inputs[1], markers = inputs[2], markerMask = inputs[3], qtype = inputs[4]
        let b = ids.dim(0), length = ids.dim(1)
        let full = valid.reshaped(b, 1, 1, length)
        let windowed = self.windowed && length >= LayaWindowedAttention.minimumLength
        var local: MLXArray? = nil, blockMask: MLXArray? = nil
        if windowed {
            blockMask = LayaWindowedAttention.mask(valid: valid, heads: config.num_attention_heads, half: config.local_attention / 2)
        } else {
            let positions = MLXArray(0..<length)
            let localDistances = abs(positions.expandedDimensions(axis: 1) - positions.expandedDimensions(axis: 0)) .<= (config.local_attention / 2)
            local = logicalAnd(logicalOr(localDistances.reshaped(1, 1, length, length), logicalNot(valid.reshaped(b, 1, length, 1))), full)
        }
        var x = arrays["encoder.embeddings.tok_embeddings.weight"]![ids]
        x = norm(x, "encoder.embeddings.norm", eps: config.norm_eps)
        for i in 0..<config.num_hidden_layers {
            let prefix = "encoder.layers.\(i)", kind = config.kind(i)
            let normalized = i == 0 ? x : norm(x, prefix + ".attn_norm", eps: config.norm_eps)
            let global = kind == "full_attention"
            x = x + attention(normalized, name: prefix + ".attn", heads: config.num_attention_heads, mask: global ? full : local,
                              ropeBase: config.ropeBase(kind), window: global ? nil : blockMask)
            let mlp = linear(norm(x, prefix + ".mlp_norm", eps: config.norm_eps), prefix + ".mlp.Wi")
            let halves = split(mlp, parts: 2, axis: -1)
            x = x + linear(gelu(halves[0]) * halves[1], prefix + ".mlp.Wo")
        }
        x = norm(x, "encoder.final_norm", eps: config.norm_eps)
        x = x + arrays["type_emb.weight"]![qtype].expandedDimensions(axis: 1)
        for i in 0..<headLayers {
            let prefix = "head.layers.\(i)"
            x = x + attention(norm(x, prefix + ".norm1"), name: prefix + ".self_attn", heads: max(1, config.hidden_size / 64), mask: full)
            x = x + linear(relu(linear(norm(x, prefix + ".norm2"), prefix + ".linear1")), prefix + ".linear2")
        }
        let gathered = x[MLXArray(0..<b).expandedDimensions(axis: 1), maximum(markers, 0)]
        let logits = linear(gelu(linear(norm(gathered, "scorer.layers.0"), "scorer.layers.1")), "scorer.layers.3").squeezed(axis: -1).asType(.float32)
        // act_head is loaded/quantized to preserve residency, but its outputs are discarded by worker.py.
        return MLX.where(markerMask, logits, MLXArray(Float(-1e4)))
    }
}
