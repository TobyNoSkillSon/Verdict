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

/// One item as the client sent it. Text items are strings; dict items keep their JSON rendering
/// (exactly as Python's json.dumps(item, ensure_ascii=False) produced it) plus any media paths.
public struct Item: Sendable {
    public let text: String
    public let images: [String]
    public let audio: [String]
    public let videos: [String]
    public init(text: String, images: [String] = [], audio: [String] = [], videos: [String] = []) {
        self.text = text; self.images = images; self.audio = audio; self.videos = videos
    }
    public var hasMedia: Bool { !(images.isEmpty && audio.isEmpty && videos.isEmpty) }
}

/// One answer, serialised by the helper with the Python worker's keys and 4-decimal rounding.
public struct Answer: Sendable, Equatable {
    public var choice: String? = nil
    public var probabilities: [String: Double]? = nil   // Choice: label -> p; Score: "0","1",… -> p
    public var confidence: Double? = nil
    public var noul: Double? = nil
    public var score: Double? = nil
    public var calibrated: Bool? = nil                  // nil for calibrated models; false for Gemma
    public init() {}
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
