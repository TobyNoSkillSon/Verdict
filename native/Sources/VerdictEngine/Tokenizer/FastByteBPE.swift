import Foundation

/// Narrow, checked implementation of the Laya English/typed checkpoint tokenizer.
/// Unsupported tokenizer.json revisions return nil, leaving the general Tokenizers path in use.
public final class FastByteBPE: @unchecked Sendable {
    private struct Added {
        let id: Int
        let scalars: [Unicode.Scalar]
        let lstrip: Bool
    }
    private struct Merge { let rank: Int; let id: Int }
    private let added: [UInt32: [Added]]
    private let byteIDs: [Int]
    private let merges: [UInt64: Merge]
    private let cls: Int, sep: Int
    private let lock = NSLock()
    private var cache: [String: [Int]] = [:]
    private var fifo: [String] = []
    private var eviction = 0
    private let cacheLimit = 4096

    private static func dict(_ a: Any?) -> [String: Any]? { a as? [String: Any] }
    private static func keys(_ d: [String: Any], _ names: Set<String>) -> Bool { Set(d.keys) == names }
    private static func equal(_ d: [String: Any], _ field: String, _ value: Any) -> Bool {
        guard let a = d[field] else { return false }
        if value is NSNull { return a is NSNull }
        if let b = value as? Bool { return (a as? NSNumber)?.objCType.pointee == 99 && (a as? Bool) == b }
        if let n = value as? Int { return (a as? Int) == n }
        return (a as? String) == (value as? String)
    }
    private static func pair(_ a: Int, _ b: Int) -> UInt64 { UInt64(a) << 32 | UInt64(b) }

    public init?(data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Self.keys(root, ["version", "truncation", "padding", "normalizer", "pre_tokenizer", "post_processor", "decoder", "model", "added_tokens"]),
              Self.equal(root, "version", "1.0"), root["truncation"] is NSNull, root["padding"] is NSNull,
              let norm = Self.dict(root["normalizer"]), Self.keys(norm, ["type"]), Self.equal(norm, "type", "NFC"),
              let pre = Self.dict(root["pre_tokenizer"]), Self.byteLevel(pre),
              let decoder = Self.dict(root["decoder"]), Self.byteLevel(decoder),
              let post = Self.dict(root["post_processor"]), Self.keys(post, ["type", "single", "pair", "special_tokens"]),
              Self.equal(post, "type", "TemplateProcessing"),
              let single = post["single"] as? [[String: Any]], single.count == 3,
              Self.template(single, ["[CLS]", "A", "[SEP]"]),
              let pair = post["pair"] as? [[String: Any]], pair.count == 5,
              Self.template(pair, ["[CLS]", "A", "[SEP]", "B", "[SEP]"]),
              let specials = Self.dict(post["special_tokens"]),
              Self.keys(specials, ["[CLS]", "[SEP]", "[PAD]", "[MASK]", "[UNK]"]),
              let model = Self.dict(root["model"]),
              Self.keys(model, ["type", "dropout", "unk_token", "continuing_subword_prefix", "end_of_word_suffix", "fuse_unk", "byte_fallback", "ignore_merges", "vocab", "merges"]),
              Self.equal(model, "type", "BPE"),
              model["dropout"] is NSNull, model["unk_token"] is NSNull,
              model["continuing_subword_prefix"] is NSNull, model["end_of_word_suffix"] is NSNull,
              Self.equal(model, "fuse_unk", false), Self.equal(model, "byte_fallback", false), Self.equal(model, "ignore_merges", false),
              let vocab = model["vocab"] as? [String: Int], vocab.count == 50280,
              let mergeRows = model["merges"] as? [[String]], mergeRows.count == 50009,
              let addedRows = root["added_tokens"] as? [[String: Any]], addedRows.count == 116
        else { return nil }
        for (name, id) in [("[CLS]", 50281), ("[SEP]", 50282), ("[PAD]", 50283), ("[MASK]", 50284), ("[UNK]", 50280)] {
            guard let s = Self.dict(specials[name]), Self.keys(s, ["id", "ids", "tokens"]),
                  Self.equal(s, "id", name), (s["ids"] as? [Int]) == [id], (s["tokens"] as? [String]) == [name]
            else { return nil }
        }
        var mapped = [UInt32: [Added]]()
        var seen = Set<Int>()
        for row in addedRows {
            guard Self.keys(row, ["id", "content", "single_word", "lstrip", "rstrip", "normalized", "special"]),
                  let id = row["id"] as? Int, let content = row["content"] as? String,
                  !content.isEmpty, content.unicodeScalars.allSatisfy({ $0.value < 128 }), !seen.contains(id),
                  (id >= 50280 ? vocab[content] == nil : vocab[content] == id),
                  Self.equal(row, "single_word", false), Self.equal(row, "rstrip", false),
                  let lstrip = row["lstrip"] as? Bool, let normalized = row["normalized"] as? Bool,
                  let special = row["special"] as? Bool,
                  lstrip == (content == "[MASK]"), normalized == !special,
                  (!special || ["<|padding|>", "<|endoftext|>", "[UNK]", "[CLS]", "[SEP]", "[PAD]", "[MASK]"].contains(content))
            else { return nil }
            seen.insert(id)
            let seq = Array(content.unicodeScalars)
            mapped[seq[0].value, default: []].append(Added(id: id, scalars: seq, lstrip: lstrip))
        }
        guard seen.contains(50281), seen.contains(50282), seen.contains(50284),
              Set(vocab.values).count == vocab.count, vocab.values.allSatisfy({ $0 >= 0 && $0 < 50280 || seen.contains($0) })
        else { return nil }
        for k in mapped.keys { mapped[k]!.sort { $0.scalars.count > $1.scalars.count } }
        var byteChars = [String](repeating: "", count: 256)
        var next = 256
        for b in 0..<256 {
            if (33...126).contains(b) || (161...172).contains(b) || (174...255).contains(b) {
                byteChars[b] = String(Unicode.Scalar(b)!)
            } else { byteChars[b] = String(Unicode.Scalar(next)!); next += 1 }
        }
        let byteIDs = byteChars.map { vocab[$0] ?? -1 }
        guard byteIDs.enumerated().allSatisfy({ b, id in id >= 0 || b == 0xc0 || b == 0xc1 || b >= 0xf5 }) else { return nil }
        var rankMap = [UInt64: Merge](minimumCapacity: mergeRows.count)
        for (rank, row) in mergeRows.enumerated() {
            guard row.count == 2, let a = vocab[row[0]], let b = vocab[row[1]],
                  let combined = vocab[row[0] + row[1]], rankMap[Self.pair(a, b)] == nil
            else { return nil }
            rankMap[Self.pair(a, b)] = Merge(rank: rank, id: combined)
        }
        self.added = mapped; self.byteIDs = byteIDs; self.merges = rankMap
        cls = 50281; sep = 50282
    }
    private static func byteLevel(_ d: [String: Any]) -> Bool {
        keys(d, ["type", "add_prefix_space", "trim_offsets", "use_regex"]) && equal(d, "type", "ByteLevel") &&
        equal(d, "add_prefix_space", false) && equal(d, "trim_offsets", true) && equal(d, "use_regex", true)
    }
    private static func template(_ rows: [[String: Any]], _ sequence: [String]) -> Bool {
        zip(rows, sequence).allSatisfy { row, value in
            let key = value == "A" || value == "B" ? "Sequence" : "SpecialToken"
            guard keys(row, [key]), let token = dict(row[key]) else { return false }
            return keys(token, ["id", "type_id"]) && equal(token, "id", value) && equal(token, "type_id", 0)
        }
    }
    private static func kind(_ c: Unicode.Scalar) -> Int {
        switch c.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return 1
        case .decimalNumber, .letterNumber, .otherNumber: return 2
        default: return c.properties.isWhitespace ? 0 : 3
        }
    }
    private func bpe(_ word: String) -> [Int] {
        lock.lock(); let cached = cache[word]; lock.unlock()
        if let cached { return cached }
        var ids = word.utf8.map { byteIDs[Int($0)] }
        while ids.count > 1 {
            var best = Int.max, at = -1, merged = -1
            for i in 0..<(ids.count - 1) {
                if let m = merges[Self.pair(ids[i], ids[i+1])], m.rank < best {
                    best = m.rank; at = i; merged = m.id
                }
            }
            if at < 0 { break }
            ids[at] = merged; ids.remove(at: at + 1)
        }
        lock.lock()
        if cache[word] == nil {
            if fifo.count >= cacheLimit {
                cache.removeValue(forKey: fifo[eviction]); fifo[eviction] = word
                eviction = (eviction + 1) % cacheLimit
            } else { fifo.append(word) }
            cache[word] = ids
        }
        lock.unlock()
        return ids
    }
    private func ordinary(_ text: String, into output: inout [Int]) {
        let s = Array(text.precomposedStringWithCanonicalMapping.unicodeScalars)
        var i = 0
        while i < s.count {
            let start = i
            // GPT-2 contractions are ASCII apostrophe and lowercase only.
            if s[i] == "'" {
                for suffix in ["s", "t", "re", "ve", "m", "ll", "d"] {
                    let a = Array(suffix.unicodeScalars)
                    if i + 1 + a.count <= s.count && s[(i+1)..<(i+1+a.count)].elementsEqual(a) {
                        i += 1 + a.count; break
                    }
                }
            }
            if i == start {
                var j = i
                if s[j] == " " && j + 1 < s.count && Self.kind(s[j+1]) != 0 { j += 1 }
                if j < s.count && Self.kind(s[j]) != 0 {
                    let k = Self.kind(s[j]); i = j + 1
                    while i < s.count && Self.kind(s[i]) == k { i += 1 }
                } else {
                    i += 1
                    while i < s.count && Self.kind(s[i]) == 0 { i += 1 }
                    // \s+(?!\S) consumes all trailing whitespace, or all but one
                    // whitespace before a non-whitespace character.
                    if i < s.count && i - start > 1 { i -= 1 }
                }
            }
            output.append(contentsOf: bpe(String(String.UnicodeScalarView(s[start..<i]))))
        }
    }
    public func encode(_ text: String, addSpecialTokens: Bool = false) -> [Int] {
        let s = Array(text.unicodeScalars)
        var output: [Int] = []
        if addSpecialTokens { output.append(cls) }
        var i = 0, plain = 0
        while i < s.count {
            // Detect a lstrip special before matching an earlier whitespace
            // added token in the same run.
            if s[i].properties.isWhitespace {
                var end = i + 1
                while end < s.count && s[end].properties.isWhitespace { end += 1 }
                if end < s.count, let tokens = added[s[end].value],
                   tokens.contains(where: { $0.lstrip && end + $0.scalars.count <= s.count &&
                       s[end..<(end+$0.scalars.count)].elementsEqual($0.scalars) }) {
                    i = end
                    continue
                }
            }
            var matched: Added?
            if let candidates = added[s[i].value] {
                matched = candidates.first { a in
                    i + a.scalars.count <= s.count && s[i..<(i+a.scalars.count)].elementsEqual(a.scalars)
                }
            }
            if let match = matched {
                var left = i
                if match.lstrip { while left > plain && s[left-1].properties.isWhitespace { left -= 1 } }
                if left > plain { ordinary(String(String.UnicodeScalarView(s[plain..<left])), into: &output) }
                output.append(match.id)
                i += match.scalars.count; plain = i
            } else { i += 1 }
        }
        if plain < s.count { ordinary(String(String.UnicodeScalarView(s[plain..<s.count])), into: &output) }
        if addSpecialTokens { output.append(sep) }
        return output
    }
}
