import Foundation

/// Keys in order, compared by their exact UTF-8 bytes. Swift's `String ==` and `Dictionary` treat canonically
/// equivalent strings ("é" as U+00E9 and "e" + U+0301) as one key; the Verdict API does not, so question ids and
/// choice labels are kept in this instead. Keys are unique by bytes: a repeated key keeps its first value.
///
///     judgement.answers["refund"]?.noul
///     for (id, answer) in judgement.answers { … }
public struct ExactKeyed<Value> {
    public struct Entry {
        public let key: String
        public var value: Value
        public init(_ key: String, _ value: Value) { self.key = key; self.value = value }
    }
    public private(set) var entries: [Entry]

    public init() { entries = [] }
    /// A key repeated with the same bytes keeps its first value (as JSON lookup does).
    public init(_ pairs: [(String, Value)]) {
        entries = []
        for (key, value) in pairs where !entries.contains(where: { exactlyEqual($0.key, key) }) { entries.append(Entry(key, value)) }
    }

    public subscript(key: String) -> Value? {
        get { entries.first { exactlyEqual($0.key, key) }?.value }
        set {
            if let i = entries.firstIndex(where: { exactlyEqual($0.key, key) }) {
                if let newValue { entries[i].value = newValue } else { entries.remove(at: i) }
            } else if let newValue {
                entries.append(Entry(key, newValue))
            }
        }
    }
    public var keys: [String] { entries.map(\.key) }
    public var values: [Value] { entries.map(\.value) }
    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
}

/// Exact string identity (same UTF-8 bytes), the API's rule for ids and labels.
@inline(__always) func exactlyEqual(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
func hashExactly(_ s: String, into hasher: inout Hasher) {
    hasher.combine(s.utf8.count)
    for byte in s.utf8 { hasher.combine(byte) }
}

extension ExactKeyed: Sequence {
    public func makeIterator() -> AnyIterator<(key: String, value: Value)> {
        var i = entries.makeIterator()
        return AnyIterator { i.next().map { (key: $0.key, value: $0.value) } }
    }
}

extension ExactKeyed: ExpressibleByDictionaryLiteral {
    /// Keeps the literal's order and every distinct key, including ones Swift would consider equal.
    public init(dictionaryLiteral elements: (String, Value)...) { self.init(elements) }
}

extension ExactKeyed.Entry: Sendable where Value: Sendable {}
extension ExactKeyed: Sendable where Value: Sendable {}

/// Equal when the same keys (by bytes) map to equal values, in any order (keys are unique, so this is symmetric).
extension ExactKeyed: Equatable where Value: Equatable {
    public static func == (a: ExactKeyed, b: ExactKeyed) -> Bool {
        a.count == b.count && a.entries.allSatisfy { e in b.entries.contains { exactlyEqual($0.key, e.key) && $0.value == e.value } }
    }
}
extension ExactKeyed: Hashable where Value: Hashable {
    public func hash(into hasher: inout Hasher) {
        // Order-independent, like ==.
        var sum = 0
        for e in entries { var h = Hasher(); hashExactly(e.key, into: &h); h.combine(e.value); sum &+= h.finalize() }
        hasher.combine(count); hasher.combine(sum)
    }
}

/// Foundation's JSONDecoder and JSONEncoder fold canonically equivalent keys ("é" / "e\u{301}") into one. Decoding
/// through them therefore sees one key; `Judgement(json:)` (what `Verdict.judge` uses) and `JSON.parse` keep both.
/// Encoding refuses such keys with an EncodingError instead of silently dropping one; `Judgement.json` /
/// `Answer.json` serialize them exactly.
extension ExactKeyed: Codable where Value: Codable {
    private struct Name: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Name.self)
        self.init(try c.allKeys.map { ($0.stringValue, try c.decode(Value.self, forKey: $0)) })
    }
    public func encode(to encoder: Encoder) throws {
        if Set(keys).count < count {   // Set<String> uses Swift's canonical equality: a collision the encoder would fold
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription:
                "keys that differ only by Unicode normalization would be merged by this encoder; use Judgement.json / Answer.json"))
        }
        var c = encoder.container(keyedBy: Name.self)
        for e in entries { try c.encode(e.value, forKey: Name(stringValue: e.key)) }
    }
}
