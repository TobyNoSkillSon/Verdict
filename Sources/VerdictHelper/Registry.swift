import Foundation
import VerdictEngine

/// Test-only stand-in. Never selected for normal production loads. VERDICT_TEST_LOAD_FAULT=<id>@<bits> makes that
/// load throw (a failed reload after the old precision was unloaded).
struct StubLoader: ModelLoader {
    static func load(id: String, snapshot: URL, bits: Int) throws -> DecisionModel {
        if ProcessInfo.processInfo.environment["VERDICT_TEST_LOAD_FAULT"] == "\(id)@\(bits)" { throw ServiceError("test load fault") }
        return StubModel(id: id)
    }
}

/// Reports an optimized path (fast tokenizer, windowed attention) so the helper's engine reporting and stock fallback
/// can be tested without weights; VERDICT_TEST_OPTIMIZED_FAULT makes that path fail like the real models'.
private final class StubModel: DecisionModel, TokenizerPathReporting, KernelPathReporting, InferencePathSwitching, CatalogContextAdopting {
    let id: String
    init(id: String) { self.id = id }
    private var stock = false
    var tokenizerPath: String { stock ? "library" : "fast" }
    var kernelPath: String { stock ? "stock (windowed attention switched off after an inference failure)" : "windowed-attention (stub)" }
    var optimizedPathActive: Bool { !stock }
    func useStockPath(_ stock: Bool) throws { self.stock = stock }
    private(set) var contextLimit = 8192
    func adoptContext(_ tokens: Int) { contextLimit = tokens }
    var residentBytes: Int { 0 }
    func tokenCount(_ item: Item, _ questions: [Question]) throws -> Int {
        item.text.split(whereSeparator: \.isWhitespace).count +
        (questions.map { $0.instructions.split(whereSeparator: \.isWhitespace).count }.max() ?? 0) + 8
    }
    func predict(_ items: [Item], _ questions: [Question]) throws -> [ItemResult] {
        try OptimizedPathFault.check(optimized: optimizedPathActive)
        let poison = OptimizedPathFault.poisons(optimized: optimizedPathActive)
        return try items.map { item in
            let need = try tokenCount(item, questions)
            if need > contextLimit {
                return .error("Item needs about \(need) tokens; \(id) accepts \(contextLimit). Shorten it or split it.")
            }
            var out = Answers()
            for q in questions {
                var a = Answer()
                switch q.kind {
                case .noul: a.noul = poison ? .nan : 0.75; a.confidence = 0.75
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

extension StubModel {
    /// VERDICT_TEST_BATCH_DEPENDENT=1 imitates the real models' batch arithmetic: a noul answered in a pass shared by
    /// several requests is 0.74, alone 0.75 (tests of merging and the `merge: false` opt-out). VERDICT_TEST_PASS_MS
    /// makes each pass take that long, so concurrent requests queue and merge as they do behind a real GPU pass.
    func predict(groups: [RequestGroup]) throws -> [GroupResult] {
        let env = ProcessInfo.processInfo.environment
        if let ms = Double(env["VERDICT_TEST_PASS_MS"] ?? ""), ms > 0 { usleep(useconds_t(ms * 1000)) }
        let shared = groups.count > 1 && env["VERDICT_TEST_BATCH_DEPENDENT"] == "1"
        return try groups.map { group in
            var results = try predict(group.items, group.questions)
            if shared {
                results = results.map { result in
                    guard case .answers(var answers) = result else { return result }
                    for (id, answer) in answers where answer.noul != nil { var a = answer; a.noul = 0.74; answers[id] = a }
                    return .answers(answers)
                }
            }
            let tokens = try zip(group.items, results).map { item, result -> Int in
                if case .answers = result { return try tokenCount(item, group.questions) * group.questions.count }
                return 0
            }
            return GroupResult(results: results, inputTokens: tokens)
        }
    }
}

/// Test stubs have no config of their own: they take the catalog's context (von-1.1 2048, the rest 8192).
protocol CatalogContextAdopting: AnyObject { func adoptContext(_ tokens: Int) }

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
