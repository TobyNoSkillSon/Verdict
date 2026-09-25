import Foundation

/// The contract between the helper (routing, HTTP, lifecycle) and each model family.
/// Mirrors Resources/worker.py: same field names, same rounding, same per-item errors.
/// Owned by the coordinator; change by agreement (see native/PLAN.md).

/// One typed question. `criteria` is ordered: Choice labels with descriptions, or Score levels.
public enum QuestionKind: String, Codable, Sendable { case choice, score, noul }

public struct Question: Sendable {
    public let id: String
    public let kind: QuestionKind
    public let instructions: String
    /// Choice: [(label, description)] in request order. Score: [(level, level)] in order. Noul: empty.
    public let criteria: [(String, String)]
    /// The question exactly as Python's json.dumps(question_dict, ensure_ascii=False) renders it
    /// (original key order, list-vs-dict criteria, nulls). The helper fills it; models use it for
    /// token counting where the Python worker counts the rendered question. nil = derive from fields.
    public let sourceJSON: String?
    public init(id: String, kind: QuestionKind, instructions: String, criteria: [(String, String)], sourceJSON: String? = nil) {
        self.id = id; self.kind = kind; self.instructions = instructions; self.criteria = criteria; self.sourceJSON = sourceJSON
    }
}

/// The JSON type the client sent an item as. A string that merely looks like JSON stays `.text`.
public enum ItemKind: Sendable { case text, object, value }

/// One item as the client sent it. Text items are strings; dict items keep their JSON rendering
/// (exactly as Python's json.dumps(item, ensure_ascii=False) produced it) plus any media paths.
/// `kind` records the original type: `text` holds the JSON rendering for `.object` (a dict) and
/// `.value` (a list, number, bool or null), the string itself for `.text`.
public struct Item: Sendable {
    public let text: String
    public let kind: ItemKind
    public let images: [String]
    public let audio: [String]
    public let videos: [String]
    public init(text: String, kind: ItemKind = .text, images: [String] = [], audio: [String] = [], videos: [String] = []) {
        self.text = text; self.kind = kind; self.images = images; self.audio = audio; self.videos = videos
    }
    public var hasMedia: Bool { !(images.isEmpty && audio.isEmpty && videos.isEmpty) }
}

/// One answer, serialised by the helper with the Python worker's keys and 4-decimal rounding.
public struct Answer: Sendable, Equatable {
    public var choice: String? = nil
    public var probabilities: Probabilities? = nil       // Choice: label -> p; Score: "0","1",… -> p
    public var confidence: Double? = nil
    public var noul: Double? = nil
    public var score: Double? = nil
    public var calibrated: Bool? = nil                  // nil for calibrated models; false for Gemma
    public init() {}
}

/// Label -> probability in option order. Labels are distinct as exact UTF-8 bytes, like the client's JSON object
/// keys: Swift `String` equality is canonical equivalence ("é" == "e\u{301}"), so a `[String: Double]` would
/// merge (or, built with `uniqueKeysWithValues`, trap on) two labels the client sent as different keys.
public struct Probabilities: Sendable, Equatable, Sequence, CustomStringConvertible {
    public let labels: [String]
    public let values: [Double]
    public init(labels: [String], values: [Double]) {
        let n = Swift.min(labels.count, values.count)
        self.labels = Array(labels.prefix(n)); self.values = Array(values.prefix(n))
    }
    /// Byte-exact lookup.
    public subscript(_ label: String) -> Double? {
        labels.firstIndex { $0.utf8.elementsEqual(label.utf8) }.map { values[$0] }
    }
    public subscript(_ label: String, default fallback: Double) -> Double { self[label] ?? fallback }
    public func makeIterator() -> IndexingIterator<[(key: String, value: Double)]> {
        zip(labels, values).map { (key: $0.0, value: $0.1) }.makeIterator()
    }
    public var count: Int { labels.count }
    public var description: String { "[" + zip(labels, values).map { "\($0.0): \($0.1)" }.joined(separator: ", ") + "]" }
    public static func == (a: Probabilities, b: Probabilities) -> Bool {
        a.values == b.values && a.labels.count == b.labels.count && zip(a.labels, b.labels).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }
    /// Byte-exact uniqueness of request labels (what a JSON object / Python dict would keep apart).
    public static func distinct(_ labels: [String]) -> Bool { Set(labels.map { Data($0.utf8) }).count == labels.count }
}

public enum ItemResult: Sendable {
    case answers([String: Answer])      // keyed by Question.id
    case error(String)                  // per-item failure; the batch continues
}

public protocol DecisionModel: AnyObject {
    /// Catalog id, e.g. "laya-english".
    var id: String { get }
    /// Tokens this item needs with these questions; the helper refuses items over `contextLimit`.
    func tokenCount(_ item: Item, _ questions: [Question]) throws -> Int
    var contextLimit: Int { get }
    /// Answer every question for every item. Batch across items internally (up to 64 rows per pass).
    func predict(_ items: [Item], _ questions: [Question]) throws -> [ItemResult]
    /// Bytes of weights resident, for status.json memory reporting.
    var residentBytes: Int { get }
}

/// Loads a model family from a local snapshot directory (Hugging Face cache layout).
/// `bits` is 0 (fp16), 8 or 4 — Laya quantises on load; Gemma accepts only 4.
public protocol ModelLoader {
    static func load(id: String, snapshot: URL, bits: Int) throws -> DecisionModel
}
