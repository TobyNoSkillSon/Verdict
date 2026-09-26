import Foundation

public enum VerdictError: Error, LocalizedError, Sendable, Equatable {
    /// Verdict is not running and could not be started (not installed, or did not answer in time).
    case unavailable(String)
    /// The request was refused before it was sent (bad questions, bad arguments).
    case invalidRequest(String)
    /// The API answered with an error status; `message` is its text verbatim.
    case api(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let m), .invalidRequest(let m): return m
        case .api(_, let m): return m
        }
    }
}

/// One question's answer. `choice` + `probabilities` for a choice, `noul` (P(true)) for a yes/no, `score` (expected
/// level 0…n-1) for a score; `confidence` for all three.
public struct Answer: Sendable, Hashable, Codable {
    public var choice: String?
    /// Label -> probability, in the API's order; labels are compared by their exact bytes.
    public var probabilities: ExactKeyed<Double>?
    public var noul: Double?
    public var score: Double?
    public var confidence: Double?
    /// False when the model's calibration does not cover this question shape.
    public var calibrated: Bool?

    public init(choice: String? = nil, probabilities: ExactKeyed<Double>? = nil, noul: Double? = nil, score: Double? = nil,
                confidence: Double? = nil, calibrated: Bool? = nil) {
        self.choice = choice; self.probabilities = probabilities; self.noul = noul; self.score = score
        self.confidence = confidence; self.calibrated = calibrated
    }
    /// The number to sort or threshold on: the score, else P(true), else the choice's confidence.
    public var value: Double { score ?? noul ?? confidence ?? 0 }

    /// The API's JSON, labels exactly as they are (JSONEncoder would merge normalization-distinct ones).
    public var json: JSON {
        var m: [JSON.Member] = []
        if let choice { m.append(.init("choice", .string(choice))) }
        if let calibrated { m.append(.init("calibrated", .bool(calibrated))) }
        if let confidence { m.append(.init("confidence", JSON(confidence))) }
        if let noul { m.append(.init("noul", JSON(noul))) }
        if let probabilities { m.append(.init("probabilities", .object(probabilities.entries.map { .init($0.key, JSON($0.value)) }))) }
        if let score { m.append(.init("score", JSON(score))) }
        return .object(m)
    }

    /// From the API's JSON (`{"choice", "probabilities", "confidence", "noul", "score", "calibrated"}`). A field that is
    /// present with the wrong type (`"noul": "0.9"`, a null probability) throws rather than reading as absent.
    public init(json: JSON) throws {
        guard json.members != nil else { throw VerdictError.unavailable("Unexpected answer from Verdict: an answer is not an object") }
        func bad(_ field: String, _ type: String) -> VerdictError { .unavailable("Unexpected answer from Verdict: \(field) is not \(type)") }
        func number(_ key: String) throws -> Double? {
            guard let value = json[key] else { return nil }
            guard let n = value.double else { throw bad(key, "a number") }
            return n
        }
        if let value = json["choice"] { guard let c = value.string else { throw bad("choice", "a string") }; choice = c }
        if let value = json["probabilities"] {
            guard let members = value.members else { throw bad("probabilities", "an object") }
            probabilities = ExactKeyed(try members.map { m in
                guard let p = m.value.double else { throw bad("probabilities.\(m.key)", "a number") }
                return (m.key, p)
            })
        }
        noul = try number("noul"); score = try number("score"); confidence = try number("confidence")
        if let value = json["calibrated"] { guard let b = value.bool else { throw bad("calibrated", "true or false") }; calibrated = b }
    }
}

/// Answers for one item, or the reason it was not judged (`error`: over the model's context, a media item, …).
/// The other items of a request are unaffected by one item's error.
public struct Judgement: Sendable, Hashable, Codable {
    /// Question id -> answer, in the API's order; ids are compared by their exact bytes ("é" and "e\u{301}" are two).
    public var answers: ExactKeyed<Answer>
    public var error: String?
    /// The model that judged it (nil for an item refused before routing).
    public var model: String?
    /// Milliseconds per item for its model's group in this request.
    public var ms: Double

    public init(answers: ExactKeyed<Answer> = [:], error: String? = nil, model: String? = nil, ms: Double = 0) {
        self.answers = answers; self.error = error; self.model = model; self.ms = ms
    }
    /// From the API's JSON, keeping every id exactly as sent (what `Verdict.judge` uses).
    public init(json: JSON) throws {
        guard json.members != nil else { throw VerdictError.unavailable("Unexpected answer from Verdict: a result is not an object") }
        func bad(_ field: String, _ type: String) -> VerdictError { .unavailable("Unexpected answer from Verdict: \(field) is not \(type)") }
        func optionalString(_ key: String) throws -> String? {
            guard let value = json[key], !value.isNull else { return nil }
            guard let s = value.string else { throw bad(key, "a string") }
            return s
        }
        if let value = json["answers"], !value.isNull {
            guard let members = value.members else { throw bad("answers", "an object") }
            answers = ExactKeyed(try members.map { ($0.key, try Answer(json: $0.value)) })
        } else { answers = [:] }
        error = try optionalString("error")
        model = try optionalString("model")
        if let value = json["ms"], !value.isNull { guard let n = value.double else { throw bad("ms", "a number") }; ms = n } else { ms = 0 }
    }
    /// The API's JSON, ids exactly as they are (JSONEncoder would merge normalization-distinct ones).
    public var json: JSON {
        var m: [JSON.Member] = [.init("answers", .object(answers.entries.map { .init($0.key, $0.value.json) }))]
        if let error { m.append(.init("error", .string(error))) }
        m.append(.init("model", model.map(JSON.string) ?? .null))
        m.append(.init("ms", JSON(ms)))
        return .object(m)
    }
    enum CodingKeys: String, CodingKey { case answers, error, model, ms }
    /// Decodable for convenience; note that JSONDecoder folds canonically equivalent ids into one before this runs.
    /// `Judgement(json: try JSON.parse(data))` keeps them.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        answers = try c.decodeIfPresent(ExactKeyed<Answer>.self, forKey: .answers) ?? [:]
        error = try c.decodeIfPresent(String.self, forKey: .error)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        ms = try c.decodeIfPresent(Double.self, forKey: .ms) ?? 0
    }
    public subscript(question: String) -> Answer? { answers[question] }
    public var ok: Bool { error == nil }
}

// MARK: Status

public struct Status: Sendable, Codable, Equatable {
    public var api: Int?
    /// The app version (Info.plist CFBundleShortVersionString), e.g. "0.3.0".
    public var version: String?
    /// The MLX runtime: core version and pinned mlx-swift revision, e.g. "0.32.0 (mlx-swift 9019419)".
    public var mlx: String?
    public var port: Int?
    public var pid: Int?
    public var models: [String: LoadedModel]
    public var calls: Int?
    public var items: Int?
    public var last_ms: Double?
    public var loading: String?
    public var downloading: Bool?
    public var error: String?
    public var gpu: GPU?
    public var memory: Memory?
    public var manual_idle_minutes: Int?
    public var on_demand_idle_minutes: Int?
    public var allow_swap: Bool?
    public var evictions: [Eviction]?
    public var refused: Refusal?
    public var installed: [String: Installed]?

    public struct LoadedModel: Sendable, Codable, Equatable {
        public var bits: Int?
        public var context: Int?
        public var engine: String?
        public var engine_reason: String?
        public var residency: String?
        public var load_s: Double?
        public var last_used: Double?
        public var memory_estimate_mb: Double?
        public var optimizations: Optimizations?
        /// The attention path and its load-time self-test, e.g. "windowed-attention (L>=768, self-test max diff 1.2e-06)"
        /// or "stock (windowed-attention self-test failed)".
        public var kernel: String?
    }
    public struct Optimizations: Sendable, Codable, Equatable {
        public var tokenizer: String?
        public var attention: String?
        public var matmul: String?
        public var optimized: Bool?
    }
    public struct GPU: Sendable, Codable, Equatable {
        public var chip: String?
        public var architecture: String?
        public var macos: String?
        public var neural_accelerators: Bool?
    }
    public struct Memory: Sendable, Codable, Equatable {
        public var rss_mb: Double?
        public var mlx_active_mb: Double?
        public var mlx_cache_mb: Double?
        public var available_mb: Double?
    }
    public struct Eviction: Sendable, Codable, Equatable {
        public var model: String
        public var residency: String?
        public var reason: String
        public var at: Double?
    }
    public struct Refusal: Sendable, Codable, Equatable {
        public var model: String?
        public var message: String
        public var at: Double?
    }
    public struct Installed: Sendable, Codable, Equatable {
        public var bytes: Int64?
    }
}

extension Status.LoadedModel {
    /// The app's engine label: "Optimized · <chip>" on Verdict's optimized path (fast tokenizer + windowed attention,
    /// self-tested at load), else "MLX" (the stock path, or only one of the two active; `engine_reason` says why).
    public func engineLabel(chip: String?) -> String {
        let optimized = engine.map { $0 == "optimized" }
            ?? (optimizations?.tokenizer == "fast" && optimizations?.attention == "windowed")
        guard optimized else { return "MLX" }
        if let chip, !chip.isEmpty { return "Optimized \u{00B7} \(chip)" }
        return "Optimized"
    }
}

// MARK: Models

/// A catalog model as GET /v1/models reports it (Verdict's fields of a model entry; `name` is the human name, the API's
/// `display_name` — the API's own `name` is the id, TypeSafe's model name).
public struct Model: Sendable, Codable, Equatable {
    public var id: String
    public var name: String
    public var family: String?
    public var inputs: [String]
    public var params: String?
    public var context: Int?
    public var languages: String?
    public var license: String?
    /// "hot" (loaded), "downloaded", "available" (downloads on first use) or "hosted" (not loadable).
    public var state: String
    public var loadable: Bool
    /// Bits: the selected precision (what a load uses), the recommended default, the loaded one; nil for hosted.
    public var precision: Precision?
    /// Figures at the selected precision.
    public var benchmark: Benchmark?
    /// Figures per measured precision ("16", "8", …), with deltas against the recommended precision.
    public var benchmarks: [String: Benchmark]
    public var links: [String: String]
    public var recommendation: String?
    /// YYYY-MM-DD.
    public var release_date: String?

    enum CodingKeys: String, CodingKey {
        case id, name = "display_name", family, inputs, params, context, languages, license, state, loadable, precision, benchmark,
             benchmarks, links, recommendation, release_date
    }
    private enum LegacyKeys: String, CodingKey { case name }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        // Helpers before the System One API sent the human name as `name`.
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? decoder.container(keyedBy: LegacyKeys.self).decode(String.self, forKey: .name)
        family = try c.decodeIfPresent(String.self, forKey: .family)
        inputs = try c.decode([String].self, forKey: .inputs)
        params = try c.decodeIfPresent(String.self, forKey: .params)
        context = try c.decodeIfPresent(Int.self, forKey: .context)
        languages = try c.decodeIfPresent(String.self, forKey: .languages)
        license = try c.decodeIfPresent(String.self, forKey: .license)
        state = try c.decode(String.self, forKey: .state)
        loadable = try c.decode(Bool.self, forKey: .loadable)
        precision = try c.decodeIfPresent(Precision.self, forKey: .precision)
        benchmark = try c.decodeIfPresent(Benchmark.self, forKey: .benchmark)
        benchmarks = try c.decode([String: Benchmark].self, forKey: .benchmarks)
        links = try c.decode([String: String].self, forKey: .links)
        recommendation = try c.decodeIfPresent(String.self, forKey: .recommendation)
        release_date = try c.decodeIfPresent(String.self, forKey: .release_date)
    }

    public struct Precision: Sendable, Codable, Equatable {
        public var selected: Int
        public var `default`: Int
        public var loaded: Int?
        public var options: [Int]
    }
    public struct Benchmark: Sendable, Codable, Equatable {
        public var accuracy: Double?
        public var accuracy_en: Double?
        public var accuracy_ml: Double?
        public var ece: Double?
        /// Single-item p50 wall time.
        public var ms: Double?
        public var items_per_s: Double?
        /// Net energy per 1,000 judgements (batched).
        public var j_per_1k: Double?
        public var memory_mb: Double?
        public var sets: [String: Double]?
        public var n_tasks: Int?
        public var n: Int?
        public var source: String?
        public var date: String?
        public var hardware: String?
        public var note: String?
        /// Against the recommended precision: "accuracy" ("−0.4 pt"), "ece", "speed" ("35% faster"), "energy".
        public var deltas: [String: String]?
    }
}
