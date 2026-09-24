// ModernBERT encoder follows the parity-qualified LayaGraph operator path;
// Von adds its own option-marker scorer and (1.2) isolated-option masks/RoPE.
import Foundation
import MLX
import MLXNN

final class VonNetwork {
    let config: LayaEncoderConfiguration
    let independent: Bool
    private let arrays: [String: MLXArray]
    private let linears: [String: Linear]
    private var forwardGraph: (([MLXArray]) -> [MLXArray])!
    let residentBytes: Int

    init(snapshot: URL, id: String) throws {
        config = try LayaEncoderConfiguration(data: Data(contentsOf: snapshot.appendingPathComponent("config.json")))
        let zip = try VonZip(snapshot.appendingPathComponent("option_marker.pt"))
        try VonWeights.validate(zip, config: config)
        independent = id == "von-1.2"
        var weights = try VonWeights.arrays(zip, config: config)
        let expected = Set((VonWeights.encoderNames(config) + VonWeights.head).map(\.0))
        guard Set(weights.keys) == expected else { throw VonError.invalid("Von checkpoint is not the trained 178-key model") }
        let dtype: DType = .float32
        var linearNames = ["scorer.dense", "scorer.out_proj"]
        for i in 0..<config.num_hidden_layers {
            linearNames += ["attn.Wqkv", "attn.Wo", "mlp.Wi", "mlp.Wo"].map { "layers.\(i)." + $0 }
        }
        var layers: [String: Linear] = [:]
        for name in linearNames {
            guard let w = weights.removeValue(forKey: name + ".weight"), w.ndim == 2 else { throw VonError.invalid("Missing Von linear \(name)") }
            let b = weights.removeValue(forKey: name + ".bias")?.asType(dtype)
            let weight = w.asType(dtype)
            layers[name] = Linear(weight: weight, bias: b)
        }
        // Match Python's float32 checkpoint. VonModel refuses precision overrides
        // until an independent quantized parity gate has qualified each mode.
        arrays = weights.mapValues { $0.asType(dtype) }
        linears = layers
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
        let graph = VonGraph(config: config, independent: independent, arrays: arrays, linears: linears)
        // MLX's compiled closure/cache retained ~1.58 GB of this model's
        // allocations after deinit. The ordinary graph has identical fixture
        // outputs and releases the weights immediately on /unload.
        forwardGraph = { (inputs: [MLXArray]) in [graph.forward(inputs)] }
    }

    func forward(_ ids: [Int32], _ lengths: [Int], _ markers: [[Int]]) throws -> [[Float]] {
        let b = lengths.count, length = lengths.max()!, count = markers.map(\.count).max()!
        var tokens = [Int32](repeating: ids.last ?? 0, count: b * length)
        var valid = [Bool](repeating: false, count: b * length)
        var positions = [Int32](repeating: 0, count: b * length)
        var optionIDs = [Int32](repeating: -1, count: b * length)
        var indices = [Int32](repeating: 0, count: b * count)
        var start = 0
        for row in 0..<b {
            let n = lengths[row]
            for j in 0..<n { tokens[row * length + j] = ids[start+j]; valid[row * length + j] = true; positions[row*length+j] = Int32(j) }
            start += n
            for (j, marker) in markers[row].enumerated() {
                let end = j+1 < markers[row].count ? markers[row][j+1] : n-1
                indices[row*count+j] = Int32(marker)
                for k in marker..<end {
                    optionIDs[row*length+k] = Int32(j)
                    positions[row*length+k] = Int32(markers[row][0]+k-marker)
                }
            }
            if n < length { for j in n..<length { positions[row*length+j] = Int32(j) } }
        }
        let inputs = [MLXArray(tokens,[b,length]), MLXArray(valid,[b,length]), MLXArray(positions,[b,length]), MLXArray(optionIDs,[b,length]), MLXArray(indices,[b,count])]
        let output = forwardGraph(inputs)[0]
        eval(output)
        let flat = output.asArray(Float.self)
        return markers.indices.map { i in Array(flat[i*count..<(i*count+markers[i].count)]) }
    }
}

private final class VonGraph {
    let config: LayaEncoderConfiguration
    let independent: Bool
    let arrays: [String: MLXArray]
    let linears: [String: Linear]
    init(config: LayaEncoderConfiguration, independent: Bool, arrays: [String: MLXArray], linears: [String: Linear]) {
        self.config = config; self.independent = independent; self.arrays = arrays; self.linears = linears
    }
    func norm(_ x: MLXArray, _ name: String) -> MLXArray {
        MLXFast.layerNorm(x, weight: arrays[name + ".weight"], bias: arrays[name + ".bias"], eps: config.norm_eps)
    }
    func linear(_ x: MLXArray, _ name: String) -> MLXArray { linears[name]!(x) }
    func rotate(_ x: MLXArray, pos: MLXArray, base: Float) -> MLXArray {
        let d = x.dim(-1)
        let freqs = (MLXArray(0..<(d/2)).asType(.float32) * MLXArray(Float(2)/Float(d)))
        let inverse = exp(-freqs * log(MLXArray(base)))
        let angles = pos.asType(.float32).expandedDimensions(axis: -1) * inverse
        let cosine = concatenated([cos(angles),cos(angles)],axis: -1).expandedDimensions(axis: 1)
        let sine = concatenated([sin(angles),sin(angles)],axis: -1).expandedDimensions(axis: 1)
        let half = split(x, parts: 2, axis: -1)
        let swapped = concatenated([-half[1],half[0]],axis: -1)
        return x * cosine + swapped * sine
    }
    func attention(_ x: MLXArray, _ name: String, mask: MLXArray, pos: MLXArray, base: Float) -> MLXArray {
        let b = x.dim(0), n = x.dim(1), h = config.num_attention_heads, d = config.hidden_size/h
        let qkv = linear(x,name+".Wqkv").reshaped(b,n,3,h,d)
        var q = qkv[0...,0...,0,0...,0...].transposed(0,2,1,3)
        var k = qkv[0...,0...,1,0...,0...].transposed(0,2,1,3)
        let v = qkv[0...,0...,2,0...,0...].transposed(0,2,1,3)
        if independent {
            q = rotate(q,pos:pos,base:base); k = rotate(k,pos:pos,base:base)
        } else {
            q = MLXFast.RoPE(q,dimensions:d,traditional:false,base:base,scale:1,offset:0)
            k = MLXFast.RoPE(k,dimensions:d,traditional:false,base:base,scale:1,offset:0)
        }
        let attended = MLXFast.scaledDotProductAttention(queries:q, keys:k, values:v,scale:pow(Float(d),-0.5),mask:.array(mask))
        return linear(attended.transposed(0,2,1,3).reshaped(b,n,config.hidden_size),name+".Wo")
    }
    func forward(_ inputs: [MLXArray]) -> MLXArray {
        let ids = inputs[0], valid = inputs[1], pos = inputs[2], opts = inputs[3], markers = inputs[4]
        let b = ids.dim(0), n = ids.dim(1)
        let full: MLXArray, local: MLXArray
        if independent {
            let oi = opts.expandedDimensions(axis: 2), oj = opts.expandedDimensions(axis: 1)
            let prefix = (oi .== -1), keyPrefix = (oj .== -1)
            let allowed = logicalOr(logicalAnd(prefix,keyPrefix),logicalAnd(logicalNot(prefix),logicalOr(keyPrefix,oi .== oj)))
            let padOK = valid.expandedDimensions(axis: 1)
            let eye = MLXArray(0..<n)
            let diagonal = eye.expandedDimensions(axis: 0) .== eye.expandedDimensions(axis: 1)
            let attend = logicalOr(logicalAnd(allowed,padOK),diagonal.reshaped(1,n,n))
            full = attend.expandedDimensions(axis: 1)
            let diff = abs(pos.expandedDimensions(axis: 2) - pos.expandedDimensions(axis: 1))
            local = logicalOr(logicalAnd(attend,diff .<= (config.local_attention/2)),diagonal.reshaped(1,n,n)).expandedDimensions(axis: 1)
        } else {
            full = valid.reshaped(b,1,1,n)
            let p = MLXArray(0..<n)
            let distance = abs(p.expandedDimensions(axis: 1)-p.expandedDimensions(axis: 0)) .<= (config.local_attention/2)
            local = logicalAnd(logicalOr(distance.reshaped(1,1,n,n),logicalNot(valid.reshaped(b,1,n,1))),full)
        }
        var x = arrays["embeddings.tok_embeddings.weight"]![ids]
        x = norm(x,"embeddings.norm")
        for i in 0..<config.num_hidden_layers {
            let prefix = "layers.\(i)",kind = config.kind(i)
            let y = i == 0 ? x : norm(x,prefix+".attn_norm")
            x = x + attention(y,prefix+".attn",mask:kind == "full_attention" ? full : local,pos:pos,base:config.ropeBase(kind))
            let mlp = linear(norm(x,prefix+".mlp_norm"),prefix+".mlp.Wi")
            let halves = split(mlp,parts:2,axis:-1)
            x = x + linear(gelu(halves[0])*halves[1],prefix+".mlp.Wo")
        }
        x = norm(x,"final_norm")
        let picked = x[MLXArray(0..<b).expandedDimensions(axis:1),markers]
        let h = linear(norm(picked,"scorer.input_norm"),"scorer.dense")
        let score = linear(norm(gelu(h),"scorer.norm"),"scorer.out_proj")
        return score.squeezed(axis:-1).asType(.float32)
    }
}
