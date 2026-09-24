import Foundation

/// Checked, CPU-only tokenizer for the published Laya multilingual BPE shape.
/// The large vocab and merge tables are scanned directly; Foundation only decodes
/// the small metadata object. A shape change declines the fast path.
public final class FastMetaspaceBPE: @unchecked Sendable {
    private struct Added { let id: Int; let scalars: [Unicode.Scalar]; let lstrip: Bool }
    private struct Merge { let rank: Int; let id: Int }
    private let added: [UInt32: [Added]]
    private let vocab: [Data: Int]
    private let merges: [UInt64: Merge]
    private let bosID: Int, eosID: Int
    private let lock = NSLock()
    private var cache: [Data: [Int]] = [:]
    private var fifo: [Data] = []
    private var eviction = 0
    private static func pair(_ a: Int, _ b: Int) -> UInt64 { UInt64(a) << 32 | UInt64(b) }
    private static func keys(_ d: [String: Any], _ names: Set<String>) -> Bool { Set(d.keys) == names }
    private static func object(_ o: Any?) -> [String: Any]? { o as? [String: Any] }
    private static func equal(_ d: [String: Any], _ key: String, _ value: Any) -> Bool {
        guard let o = d[key] else { return false }
        if let b = value as? Bool { return (o as? NSNumber)?.objCType.pointee == 99 && (o as? Bool) == b }
        if let n = value as? Int { return o as? Int == n }
        return o as? String == value as? String
    }
    private static func template(_ rows: [[String: Any]], _ expected: [String]) -> Bool {
        rows.count == expected.count && zip(rows, expected).allSatisfy { row, name in
            let key = name == "A" || name == "B" ? "Sequence" : "SpecialToken"
            guard keys(row, [key]), let obj = object(row[key]) else { return false }
            return keys(obj, ["id", "type_id"]) && equal(obj, "id", name) && equal(obj, "type_id", 0)
        }
    }

    // JSON string reader: the unescaped UTF-8 common case needs no JSON object allocation.
    private struct Scanner {
        let bytes: [UInt8]
        var i: Int = 0
        mutating func space() { while i < bytes.count && [10, 13, 32, 9].contains(bytes[i]) { i += 1 } }
        mutating func take(_ c: UInt8) -> Bool { space(); guard i < bytes.count && bytes[i] == c else { return false }; i += 1; return true }
        mutating func string() -> String? {
            guard take(34) else { return nil }
            let start = i
            var escaped = false
            while i < bytes.count {
                let c = bytes[i]
                if c == 34 {
                    let end = i; i += 1
                    if !escaped { return String(decoding: bytes[start..<end], as: UTF8.self) }
                    return try? JSONDecoder().decode(String.self, from: Data(bytes[(start-1)..<i]))
                }
                if c == 92 { escaped = true; i += 2 } else { i += 1 }
            }
            return nil
        }
        mutating func number() -> Int? {
            space(); let start = i
            while i < bytes.count && bytes[i] >= 48 && bytes[i] <= 57 { i += 1 }
            guard start < i else { return nil }
            return Int(String(decoding: bytes[start..<i], as: UTF8.self))
        }
        // Skip a JSON container, respecting quoted strings and escapes.
        mutating func container(_ open: UInt8, _ close: UInt8) -> Range<Int>? {
            space(); let start = i
            guard i < bytes.count && bytes[i] == open else { return nil }
            var depth = 0, quoted = false
            while i < bytes.count {
                let c = bytes[i]; i += 1
                if quoted { if c == 92 { i += 1 } else if c == 34 { quoted = false }; continue }
                if c == 34 { quoted = true } else if c == open { depth += 1 }
                else if c == close { depth -= 1; if depth == 0 { return start..<i } }
            }
            return nil
        }
    }
    public init?(data: Data) {
        var scanner = Scanner(bytes: Array(data))
        // Only the two exact top-level table fields may be stripped. Reinsert
        // empty containers for Foundation's small metadata validation.
        guard let vr = Self.fieldRange("vocab", in: scanner.bytes, open: 123, close: 125),
              let mr = Self.fieldRange("merges", in: scanner.bytes, open: 91, close: 93), vr.upperBound < mr.lowerBound else { return nil }
        let small = Data(scanner.bytes[..<vr.lowerBound] + [123, 125] + scanner.bytes[vr.upperBound..<mr.lowerBound] + [91, 93] + scanner.bytes[mr.upperBound...])
        guard let root = (try? JSONSerialization.jsonObject(with: small)) as? [String: Any],
              Self.keys(root, ["version", "truncation", "padding", "normalizer", "pre_tokenizer", "post_processor", "decoder", "model", "added_tokens"]),
              Self.equal(root, "version", "1.0"), root["truncation"] is NSNull, root["padding"] is NSNull,
              let normal = Self.object(root["normalizer"]), Self.keys(normal, ["type", "pattern", "content"]),
              Self.equal(normal, "type", "Replace"), Self.equal(normal, "content", "▁"),
              let pattern = Self.object(normal["pattern"]), Self.keys(pattern, ["String"]), Self.equal(pattern, "String", " "),
              let pre = Self.object(root["pre_tokenizer"]), Self.keys(pre, ["type", "replacement", "prepend_scheme", "split"]),
              Self.equal(pre, "type", "Metaspace"), Self.equal(pre, "replacement", "▁"),
              Self.equal(pre, "prepend_scheme", "always"), Self.equal(pre, "split", true),
              let decoder = Self.object(root["decoder"]), Self.keys(decoder, ["type", "decoders"]), Self.equal(decoder, "type", "Sequence"),
              let decoders = decoder["decoders"] as? [[String: Any]], decoders.count == 3,
              Self.keys(decoders[0], ["type", "pattern", "content"]), Self.equal(decoders[0], "type", "Replace"),
              Self.equal(decoders[0], "content", " "), let decPattern = Self.object(decoders[0]["pattern"]),
              Self.keys(decPattern, ["String"]), Self.equal(decPattern, "String", "▁"),
              Self.keys(decoders[1], ["type"]), Self.equal(decoders[1], "type", "ByteFallback"),
              Self.keys(decoders[2], ["type"]), Self.equal(decoders[2], "type", "Fuse"),
              let post = Self.object(root["post_processor"]), Self.keys(post, ["type", "single", "pair", "special_tokens"]),
              Self.equal(post, "type", "TemplateProcessing"),
              let single = post["single"] as? [[String: Any]], Self.template(single, ["<bos>", "A", "<eos>"]),
              let pair = post["pair"] as? [[String: Any]], Self.template(pair, ["<bos>", "A", "<eos>", "B", "<eos>"]),
              let specials = Self.object(post["special_tokens"]), Self.keys(specials, ["<bos>", "<eos>"]),
              let model = Self.object(root["model"]),
              Self.keys(model, ["type", "dropout", "unk_token", "continuing_subword_prefix", "end_of_word_suffix", "fuse_unk", "byte_fallback", "ignore_merges", "vocab", "merges"]),
              Self.equal(model, "type", "BPE"), model["dropout"] is NSNull,
              model["continuing_subword_prefix"] is NSNull, model["end_of_word_suffix"] is NSNull,
              Self.equal(model, "unk_token", "<unk>"), Self.equal(model, "fuse_unk", true),
              Self.equal(model, "byte_fallback", true), Self.equal(model, "ignore_merges", false),
              let rows = root["added_tokens"] as? [[String: Any]], rows.count == 249 else { return nil }
        for (token, id) in [("<bos>", 2), ("<eos>", 1)] {
            guard let entry = Self.object(specials[token]), Self.keys(entry, ["id", "ids", "tokens"]),
                  Self.equal(entry, "id", token), entry["ids"] as? [Int] == [id], entry["tokens"] as? [String] == [token] else { return nil }
        }
        var mapped = [UInt32: [Added]](), seen = Set<Int>()
        let specialIDs: Set<Int> = [0, 1, 2, 3, 4, 106, 107]
        let namedSpecials = [0: "<pad>", 1: "<eos>", 2: "<bos>", 3: "<unk>",
                             4: "<mask>", 106: "<start_of_turn>", 107: "<end_of_turn>"]
        for row in rows {
            guard Self.keys(row, ["id", "content", "single_word", "lstrip", "rstrip", "normalized", "special"]),
                  let id = row["id"] as? Int, (0..<256000).contains(id), !seen.contains(id),
                  let content = row["content"] as? String, !content.isEmpty,
                  (namedSpecials[id] == nil || namedSpecials[id] == content),
                  Self.equal(row, "single_word", false), Self.equal(row, "rstrip", false),
                  Self.equal(row, "normalized", false), Self.equal(row, "special", specialIDs.contains(id)),
                  Self.equal(row, "lstrip", id == 4) else { return nil }
            seen.insert(id)
            let scalars = Array(content.unicodeScalars)
            mapped[scalars[0].value, default: []].append(Added(id: id, scalars: scalars, lstrip: id == 4))
        }
        guard seen.count == 249, (0...105).allSatisfy(seen.contains), seen.contains(255999) else { return nil }
        for k in mapped.keys { mapped[k]!.sort { $0.scalars.count > $1.scalars.count } }
        scanner.i = vr.lowerBound
        guard scanner.take(123) else { return nil }
        var vocab = [Data: Int](minimumCapacity: 256000)
        while true {
            scanner.space(); if scanner.take(125) { break }
            guard let word = scanner.string(), scanner.take(58), let id = scanner.number(),
                  (0..<256000).contains(id), vocab.updateValue(id, forKey: Data(word.utf8)) == nil else { return nil }
            if !scanner.take(44) { guard scanner.take(125) else { return nil }; break }
        }
        guard scanner.i == vr.upperBound, vocab.count == 256000,
              Set(vocab.values).count == 256000,
              rows.allSatisfy({ vocab[Data(($0["content"] as! String).utf8)] == $0["id"] as? Int }),
              vocab[Data("<unk>".utf8)] == 3, vocab[Data("▁".utf8)] != nil,
              (0..<256).allSatisfy({ $0 == 9 || vocab[Data(String(format: "<0x%02X>", $0).utf8)] != nil }) else { return nil }
        scanner.i = mr.lowerBound
        guard scanner.take(91) else { return nil }
        var merges = [UInt64: Merge](minimumCapacity: 580604)
        for rank in 0..<580604 {
            guard scanner.take(91), let a = scanner.string(), scanner.take(44), let b = scanner.string(), scanner.take(93),
                  let ai = vocab[Data(a.utf8)], let bi = vocab[Data(b.utf8)], let id = vocab[Data((a+b).utf8)],
                  merges.updateValue(Merge(rank: rank, id: id), forKey: Self.pair(ai, bi)) == nil else { return nil }
            if rank < 580603 { guard scanner.take(44) else { return nil } }
        }
        guard scanner.take(93), scanner.i == mr.upperBound else { return nil }
        guard let bosID = vocab[Data("<bos>".utf8)], let eosID = vocab[Data("<eos>".utf8)] else { return nil }
        self.added = mapped; self.vocab = vocab; self.merges = merges
        self.bosID = bosID; self.eosID = eosID
    }
    public func tokenID(_ token: String) -> Int? { vocab[Data(token.utf8)] }
    private static func fieldRange(_ key: String, in bytes: [UInt8], open: UInt8, close: UInt8) -> Range<Int>? {
        let needle = Array("\"\(key)\"".utf8)
        guard let found = bytes.indices.first(where: { i in i + needle.count < bytes.count && bytes[i..<(i+needle.count)].elementsEqual(needle) }) else { return nil }
        var scanner = Scanner(bytes: bytes, i: found + needle.count)
        guard scanner.take(58) else { return nil }
        return scanner.container(open, close)
    }
    private func bpe(_ word: String) -> [Int] {
        let key = Data(word.utf8)
        lock.lock(); let hit = cache[key]; lock.unlock()
        if let hit { return hit }
        var ids: [Int] = []
        for c in word.unicodeScalars {
            if let id = vocab[Data(String(c).utf8)] { ids.append(id) }
            else {
                for byte in String(c).utf8 { ids.append(vocab[Data(String(format: "<0x%02X>", byte).utf8)] ?? 3) }
            }
        }
        while ids.count > 1 {
            var best = Int.max, at = -1, merged = -1
            for i in 0..<(ids.count-1) {
                if let m = merges[Self.pair(ids[i], ids[i+1])], m.rank < best { best = m.rank; at = i; merged = m.id }
            }
            if at == -1 { break }
            ids[at] = merged; ids.remove(at: at+1)
        }
        lock.lock()
        if cache[key] == nil {
            if fifo.count == 4096 { cache.removeValue(forKey: fifo[eviction]); fifo[eviction] = key; eviction = (eviction+1)%4096 }
            else { fifo.append(key) }
            cache[key] = ids
        }
        lock.unlock()
        return ids
    }
    private func ordinary(_ text: String, into result: inout [Int]) {
        guard !text.isEmpty else { return }
        // Foundation's string replacement works on composed grapheme ranges;
        // a space followed by a lone combining mark can be one grapheme.
        var scalars = text.unicodeScalars.map { $0.value == 32 ? Unicode.Scalar(0x2581)! : $0 }
        if scalars.first != "▁" { scalars.insert("▁", at: 0) }
        var start = 0
        for i in 1..<scalars.count where scalars[i] == "▁" {
            result += bpe(String(String.UnicodeScalarView(scalars[start..<i])))
            start = i
        }
        result += bpe(String(String.UnicodeScalarView(scalars[start...])))
    }
    // Rust's AddedToken lstrip stops at LF (even in a whitespace run).
    private static func stripWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value != 10 && scalar.properties.isWhitespace
    }
    public func encode(_ text: String, addSpecialTokens: Bool = false) -> [Int] {
        let s = Array(text.unicodeScalars)
        var output = addSpecialTokens ? [bosID] : [Int]()
        var i = 0, plain = 0
        while i < s.count {
            let match = added[s[i].value]?.first { a in
                i + a.scalars.count <= s.count && s[i..<(i+a.scalars.count)].elementsEqual(a.scalars)
            }
            if let match {
                var left = i
                if match.lstrip { while left > plain && Self.stripWhitespace(s[left-1]) { left -= 1 } }
                if left > plain { ordinary(String(String.UnicodeScalarView(s[plain..<left])), into: &output) }
                output.append(match.id)
                i += match.scalars.count; plain = i
            } else { i += 1 }
        }
        if plain < s.count { ordinary(String(String.UnicodeScalarView(s[plain...])), into: &output) }
        if addSpecialTokens { output.append(eosID) }
        return output
    }
}
