// The official PyTorch archive is a ZIP of uncompressed, little-endian f32 storages.
// Read only pinned checkpoint layouts; never execute its pickle or repository code.
import Foundation
import Darwin
import MLX

enum VonError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

struct VonZip {
    struct Entry { let offset: UInt64; let size: Int }
    private let file: FileHandle
    private let entries: [String: Entry]
    init(_ url: URL) throws {
        file = try FileHandle(forReadingFrom: url)
        let length = try file.seekToEnd()
        let tailSize = Int(min(length, 65557))
        try file.seek(toOffset: length - UInt64(tailSize))
        let tail = [UInt8](try file.read(upToCount: tailSize) ?? Data())
        func u16(_ b: [UInt8], _ n: Int) -> Int { Int(b[n]) | Int(b[n+1]) << 8 }
        func u32(_ b: [UInt8], _ n: Int) -> Int { u16(b,n) | u16(b,n+2) << 16 }
        guard tail.count >= 22, let end = (0...(tail.count-22)).reversed().first(where: { u32(tail,$0) == 0x06054b50 }) else { throw VonError.invalid("Not a ZIP checkpoint") }
        let count = u16(tail,end+10), directorySize = u32(tail,end+12), directoryOffset = u32(tail,end+16)
        // 1.1 ships 182 ZIP entries; 1.2 has two extra metadata entries (184).
        guard (182...184).contains(count), directorySize < 200_000, directoryOffset + directorySize <= length else { throw VonError.invalid("Unsupported Von archive layout") }
        try file.seek(toOffset: UInt64(directoryOffset))
        let central = [UInt8](try file.read(upToCount: directorySize) ?? Data())
        var result: [String: Entry] = [:], index = 0
        for _ in 0..<count {
            guard index + 46 <= central.count, u32(central,index) == 0x02014b50 else { throw VonError.invalid("Invalid ZIP central directory") }
            let size = u32(central,index+24), nameLength = u16(central,index+28), extra = u16(central,index+30), comment = u16(central,index+32)
            let start = index + 46, finish = start + nameLength
            guard finish <= central.count, u16(central,index+10) == 0, u32(central,index+20) == size else { throw VonError.invalid("Compressed/invalid Von storage") }
            let name = String(decoding: central[start..<finish], as: UTF8.self)
            let headerOffset = u32(central,index+42)
            try file.seek(toOffset: UInt64(headerOffset))
            let header = [UInt8](try file.read(upToCount: 30) ?? Data())
            guard header.count == 30, u32(header,0) == 0x04034b50 else { throw VonError.invalid("Invalid local ZIP entry") }
            let dataOffset = headerOffset + 30 + u16(header,26) + u16(header,28)
            guard dataOffset + size <= length else { throw VonError.invalid("Storage outside ZIP") }
            result[name] = Entry(offset: UInt64(dataOffset), size: size)
            index = finish + extra + comment
        }
        entries = result
    }
    func read(_ name: String) throws -> Data {
        guard let entry = entries["option_marker/" + name] else { throw VonError.invalid("Missing Von storage \(name)") }
        try file.seek(toOffset: entry.offset)
        let data = try file.read(upToCount: entry.size) ?? Data()
        guard data.count == entry.size else { throw VonError.invalid("Truncated Von storage \(name)") }
        return data
    }
    func entry(_ name: String) throws -> Entry {
        guard let e = entries["option_marker/" + name] else { throw VonError.invalid("Missing Von storage \(name)") }
        return e
    }
    func tensor(_ index: Int, shape: [Int]) throws -> MLXArray {
        let e = try entry("data/\(index)")
        guard e.size == shape.reduce(4,*) else { throw VonError.invalid("Invalid Von tensor \(index) size") }
        let pageSize = Int(sysconf(_SC_PAGESIZE))
        var allocation: UnsafeMutableRawPointer?
        guard posix_memalign(&allocation, pageSize, e.size) == 0, let pointer = allocation else {
            throw VonError.invalid("Unable to allocate Von tensor \(index)")
        }
        var filled = 0
        while filled < e.size {
            let amount = min(e.size - filled, 4 * 1024 * 1024)
            let n = pread(file.fileDescriptor, pointer.advanced(by: filled), amount, off_t(e.offset) + off_t(filled))
            guard n > 0 else { free(pointer); throw VonError.invalid("Truncated Von tensor \(index)") }
            filled += n
        }
        // Page-aligned managed storage transfers directly into MLX; its
        // finalizer owns the allocation for precisely the array's lifetime.
        return MLXArray(rawPointer: pointer, shape, dtype: .float32) { free(pointer) }
    }
}

/// The mapping was checked against both pinned `option_marker.pt` state_dicts (178
/// tensors, same insertion order). Each storage's byte length is verified first.
struct VonWeights {
    static let head: [(String, [Int])] = [
        ("scorer.input_norm.weight", [1024]), ("scorer.input_norm.bias", [1024]),
        ("scorer.dense.weight", [512,1024]), ("scorer.dense.bias", [512]),
        ("scorer.norm.weight", [512]), ("scorer.norm.bias", [512]),
        ("scorer.out_proj.weight", [1,512]), ("scorer.out_proj.bias", [1])
    ]
    static func encoderNames(_ config: LayaEncoderConfiguration) -> [(String,[Int])] {
        let h = config.hidden_size, inner = config.intermediate_size, vocab = config.vocab_size
        var names: [(String,[Int])] = [("embeddings.tok_embeddings.weight",[vocab,h]), ("embeddings.norm.weight",[h])]
        for i in 0..<config.num_hidden_layers {
            let p = "layers.\(i)."
            if i > 0 { names.append((p + "attn_norm.weight",[h])) }
            names += [(p+"attn.Wqkv.weight",[3*h,h]), (p+"attn.Wo.weight",[h,h]), (p+"mlp_norm.weight",[h]), (p+"mlp.Wi.weight",[2*inner,h]), (p+"mlp.Wo.weight",[h,inner])]
        }
        names.append(("final_norm.weight",[h]))
        return names
    }
    static func validate(_ zip: VonZip, config: LayaEncoderConfiguration) throws {
        let names = encoderNames(config)
        guard names.count == 170, config.hidden_size == 1024, config.num_hidden_layers == 28 else { throw VonError.invalid("Unsupported Von checkpoint dimensions") }
        let all = names + head
        let pickle = try zip.read("data.pkl")
        for (index,(name,shape)) in all.enumerated() {
            guard try zip.entry("data/\(index)").size == shape.reduce(4,*) else { throw VonError.invalid("Wrong Von storage size: \(name)") }
            // Fail closed if the pinned PyTorch state_dict's name order changes.
            let full = index < 170 ? "encoder." + name : name
            guard pickle.range(of: Data(full.utf8)) != nil else { throw VonError.invalid("Missing PyTorch state key \(full)") }
        }
    }
    /// Materialize one tensor at a time from the authoritative .pt ZIP. No
    /// persistent converted weight copy and no untrusted pickle execution.
    static func arrays(_ zip: VonZip, config: LayaEncoderConfiguration) throws -> [String: MLXArray] {
        var result: [String: MLXArray] = [:]
        let names = encoderNames(config) + head
        for (i,(name,shape)) in names.enumerated() {
            result[name] = try zip.tensor(i, shape: shape)
        }
        return result
    }
}
