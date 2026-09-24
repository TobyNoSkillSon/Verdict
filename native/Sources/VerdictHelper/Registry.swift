import Foundation
import VerdictEngine

/// Test-only stand-in. Never selected for normal production loads.
struct StubLoader: ModelLoader {
    static func load(id: String, snapshot: URL, bits: Int) throws -> DecisionModel { StubModel(id: id) }
}

private final class StubModel: DecisionModel {
    let id: String
    init(id: String) { self.id = id }
    var contextLimit: Int { 8192 }
    var residentBytes: Int { 0 }
    func tokenCount(_ item: Item, _ questions: [Question]) throws -> Int {
        item.text.split(whereSeparator: \.isWhitespace).count +
        (questions.map { $0.instructions.split(whereSeparator: \.isWhitespace).count }.max() ?? 0) + 8
    }
    func predict(_ items: [Item], _ questions: [Question]) throws -> [ItemResult] {
        try items.map { item in
            let need = try tokenCount(item, questions)
            if need > contextLimit {
                return .error("Item needs about \(need) tokens; \(id) accepts \(contextLimit). Shorten it or split it.")
            }
            var out: [String: Answer] = [:]
            for q in questions {
                var a = Answer()
                switch q.kind {
                case .noul: a.noul = 0.75; a.confidence = 0.75
                case .choice:
                    a.choice = q.criteria.first?.0
                    a.confidence = 0.9
                    a.probabilities = Dictionary(uniqueKeysWithValues: q.criteria.map { ($0.0, 0.1) })
                case .score: a.score = 1; a.confidence = 0.5
                }
                out[q.id] = a
            }
            return .answers(out)
        }
    }
}

let productionLoaders: [String: ModelLoader.Type] = ["laya": LayaLoader.self]

func loader(runtime: String) throws -> ModelLoader.Type {
    if ProcessInfo.processInfo.environment["VERDICT_STUB_MODELS"] == "1" { return StubLoader.self }
    guard let type = productionLoaders[runtime] else {
        throw ServiceError("Native \(runtime) loader is not ready; the Python worker remains the production path")
    }
    return type
}
