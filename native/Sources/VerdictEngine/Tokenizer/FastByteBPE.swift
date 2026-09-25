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
    private let tokenIDs: [Data: Int]
    private let byteIDs: [Int]
    private let merges: [UInt64: Merge]
    private let cls: Int, sep: Int
    private let lock = NSLock()
    private var cache: [Data: [Int]] = [:]
    private var fifo: [Data] = []
    private var eviction = 0
    /// Longer words are rare and would pin arbitrary amounts of memory in the 4,096-entry cache.
    private static let maxCachedWordBytes = 64
    private let cacheLimit = 4096

    private static func dict(_ a: Any?) -> [String: Any]? { a as? [String: Any] }
    private static func keys(_ d: [String: Any], _ names: Set<String>) -> Bool {
        Set(d.keys.map { Data($0.utf8) }) == Set(names.map { Data($0.utf8) })
    }
    private static func equal(_ d: [String: Any], _ field: String, _ value: Any) -> Bool {
        guard let a = d[field] else { return false }
        if value is NSNull { return a is NSNull }
        if let b = value as? Bool { return (a as? NSNumber)?.objCType.pointee == 99 && (a as? Bool) == b }
        if let n = value as? Int { return (a as? Int) == n }
        guard let left = a as? String, let right = value as? String else { return false }
        return left.utf8.elementsEqual(right.utf8)
    }
    private static func pair(_ a: Int, _ b: Int) -> UInt64 { UInt64(a) << 32 | UInt64(b) }

    /// `ignoringTruncationAndPadding`: accept a tokenizer.json whose `truncation`/`padding` are set (Von's). They are
    /// call-time options in HF: transformers disables both unless the caller asks (Von SDK: 1.1's max_length 512 still
    /// encodes 10,003 tokens), and this encoder never truncates or pads.
    public init?(data: Data, ignoringTruncationAndPadding: Bool = false) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Self.keys(root, ["version", "truncation", "padding", "normalizer", "pre_tokenizer", "post_processor", "decoder", "model", "added_tokens"]),
              Self.equal(root, "version", "1.0"), ignoringTruncationAndPadding || (root["truncation"] is NSNull && root["padding"] is NSNull),
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
              let rawVocab = model["vocab"] as? [String: Int], rawVocab.count == 50280,
              let mergeRows = model["merges"] as? [[String]], mergeRows.count == 50009,
              let addedRows = root["added_tokens"] as? [[String: Any]], addedRows.count == 116
        else { return nil }
        // Foundation's String keys compare by canonical equivalence; materialize
        // exact UTF-8 keys before any vocab/merge lookup. The shape count above
        // rejects a JSON table whose distinct keys were folded during parsing.
        var vocab = [Data: Int](minimumCapacity: rawVocab.count)
        for (word, id) in rawVocab {
            guard vocab.updateValue(id, forKey: Data(word.utf8)) == nil else { return nil }
        }
        for (name, id) in [("[CLS]", 50281), ("[SEP]", 50282), ("[PAD]", 50283), ("[MASK]", 50284), ("[UNK]", 50280)] {
            guard let s = Self.dict(specials[name]), Self.keys(s, ["id", "ids", "tokens"]),
                  Self.equal(s, "id", name), (s["ids"] as? [Int]) == [id],
                  let tokens = s["tokens"] as? [String], tokens.count == 1, tokens[0].utf8.elementsEqual(name.utf8)
            else { return nil }
        }
        var mapped = [UInt32: [Added]]()
        var seen = Set<Int>()
        var tokenIDs = [Data: Int](minimumCapacity: addedRows.count)
        for row in addedRows {
            guard Self.keys(row, ["id", "content", "single_word", "lstrip", "rstrip", "normalized", "special"]),
                  let id = row["id"] as? Int, let content = row["content"] as? String,
                  !content.isEmpty, content.unicodeScalars.allSatisfy({ $0.value < 128 }), !seen.contains(id),
                  (id >= 50280 ? vocab[Data(content.utf8)] == nil : vocab[Data(content.utf8)] == id),
                  Self.equal(row, "single_word", false), Self.equal(row, "rstrip", false),
                  let lstrip = row["lstrip"] as? Bool, let normalized = row["normalized"] as? Bool,
                  let special = row["special"] as? Bool,
                  lstrip == content.utf8.elementsEqual("[MASK]".utf8), normalized == !special,
                  (!special || ["<|padding|>", "<|endoftext|>", "[UNK]", "[CLS]", "[SEP]", "[PAD]", "[MASK]"].contains(content))
            else { return nil }
            guard tokenIDs.updateValue(id, forKey: Data(content.utf8)) == nil else { return nil }
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
        let byteIDs = byteChars.map { vocab[Data($0.utf8)] ?? -1 }
        guard byteIDs.enumerated().allSatisfy({ b, id in id >= 0 || b == 0xc0 || b == 0xc1 || b >= 0xf5 }) else { return nil }
        var rankMap = [UInt64: Merge](minimumCapacity: mergeRows.count)
        for (rank, row) in mergeRows.enumerated() {
            guard row.count == 2, let a = vocab[Data(row[0].utf8)], let b = vocab[Data(row[1].utf8)],
                  let combined = vocab[Data(row[0].utf8) + Data(row[1].utf8)], rankMap[Self.pair(a, b)] == nil
            else { return nil }
            rankMap[Self.pair(a, b)] = Merge(rank: rank, id: combined)
        }
        guard let clsID = tokenIDs[Data("[CLS]".utf8)], let sepID = tokenIDs[Data("[SEP]".utf8)] else { return nil }
        self.added = mapped; self.tokenIDs = tokenIDs; self.byteIDs = byteIDs; self.merges = rankMap
        cls = clsID; sep = sepID
    }
    /// HF tokenizers `Word::merge_all`: pop the lowest (rank, position) pair from a min-heap over a
    /// doubly linked symbol list; skip entries made stale by earlier merges. O(n log n) per word.
    private func mergeAll(_ ids: inout [Int]) {
        let n = ids.count
        var prev = [Int](0..<n).map { $0 - 1 }, next = [Int](1...n).map { $0 == n ? -1 : $0 }, alive = [Bool](repeating: true, count: n)
        var heap: [(rank: Int, pos: Int, id: Int)] = []
        heap.reserveCapacity(n)
        func less(_ a: (rank: Int, pos: Int, id: Int), _ b: (rank: Int, pos: Int, id: Int)) -> Bool { a.rank != b.rank ? a.rank < b.rank : a.pos < b.pos }
        func push(_ e: (rank: Int, pos: Int, id: Int)) {
            heap.append(e); var i = heap.count - 1
            while i > 0 { let p = (i - 1) / 2; if less(heap[i], heap[p]) { heap.swapAt(i, p); i = p } else { break } }
        }
        func pop() -> (rank: Int, pos: Int, id: Int) {
            let top = heap[0]; let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last; var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1; var m = i
                    if l < heap.count && less(heap[l], heap[m]) { m = l }
                    if r < heap.count && less(heap[r], heap[m]) { m = r }
                    if m == i { break }; heap.swapAt(i, m); i = m
                }
            }
            return top
        }
        for i in 0..<(n - 1) { if let m = merges[Self.pair(ids[i], ids[i + 1])] { push((m.rank, i, m.id)) } }
        while !heap.isEmpty {
            let top = pop()
            guard alive[top.pos], next[top.pos] >= 0 else { continue }
            let right = next[top.pos]
            guard let m = merges[Self.pair(ids[top.pos], ids[right])], m.id == top.id else { continue }
            ids[top.pos] = m.id; alive[right] = false
            next[top.pos] = next[right]; if next[right] >= 0 { prev[next[right]] = top.pos }
            if prev[top.pos] >= 0, let p = merges[Self.pair(ids[prev[top.pos]], ids[top.pos])] { push((p.rank, prev[top.pos], p.id)) }
            if next[top.pos] >= 0, let q = merges[Self.pair(ids[top.pos], ids[next[top.pos]])] { push((q.rank, top.pos, q.id)) }
        }
        var out: [Int] = []; out.reserveCapacity(n)
        var i = 0; while i >= 0 { out.append(ids[i]); i = next[i] }
        ids = out
    }

    public func tokenID(_ token: String) -> Int? { tokenIDs[Data(token.utf8)] }
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
        let key = Data(word.utf8), cacheable = key.count <= Self.maxCachedWordBytes
        lock.lock(); let cached = cacheable ? cache[key] : nil; lock.unlock()
        if let cached { return cached }
        var ids = word.utf8.map { byteIDs[Int($0)] }
        // Short words: rescan for the lowest-rank pair (fast for typical words). Long runs without
        // spaces (DNA, Thai, CJK under the English tokenizer, ASCII art) use the O(n log n) heap merge.
        if ids.count > 24 { mergeAll(&ids) } else {
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
        }
        guard cacheable else { return ids }
        lock.lock()
        if cache[key] == nil {
            if fifo.count >= cacheLimit {
                cache.removeValue(forKey: fifo[eviction]); fifo[eviction] = key
                eviction = (eviction + 1) % cacheLimit
            } else { fifo.append(key) }
            cache[key] = ids
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
