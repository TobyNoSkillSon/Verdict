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
            var out = Answers()
            for q in questions {
                var a = Answer()
                switch q.kind {
                case .noul: a.noul = 0.75; a.confidence = 0.75
                case .choice:
                    a.choice = q.criteria.first?.0
                    a.confidence = 0.9
                    a.probabilities = Probabilities(labels: q.criteria.map(\.0), values: q.criteria.map { _ in 0.1 })
                case .score: a.score = 1; a.confidence = 0.5
                }
                out[q.id] = a
            }
            return .answers(out)
        }
    }
}

let productionLoaders: [String: ModelLoader.Type] = ["laya": LayaLoader.self, "von": VonLoader.self]

// MLX enables TF32 GEMM by default. Von ships f32 PyTorch weights, and TF32
// changes its first QKV projection by ~2e-4; 28 layers amplify that into
// ~0.001 probability drift. Configure before *any* model's first matmul because
// MLX caches this process-wide flag on first access (Laya may load before Von).
private let preciseMatmulConfigured: Void = { setenv("MLX_ENABLE_TF32", "0", 1) }()

func loader(runtime: String) throws -> ModelLoader.Type {
    _ = preciseMatmulConfigured
    if ProcessInfo.processInfo.environment["VERDICT_STUB_MODELS"] == "1" { return StubLoader.self }
    guard let type = productionLoaders[runtime] else {
        throw ServiceError("No native loader for runtime '\(runtime)'; Verdict runs only models with a native helper loader")
    }
    return type
}
