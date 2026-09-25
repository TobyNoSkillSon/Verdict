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

    /// From the API's JSON (`{"choice", "probabilities", "confidence", "noul", "score", "calibrated"}`).
    public init(json: JSON) throws {
        guard json.members != nil else { throw VerdictError.unavailable("Unexpected answer from Verdict: an answer is not an object") }
        choice = json["choice"]?.string
        probabilities = json["probabilities"]?.members.map { members in ExactKeyed(members.compactMap { m in m.value.double.map { (m.key, $0) } }) }
        noul = json["noul"]?.double; score = json["score"]?.double; confidence = json["confidence"]?.double
        calibrated = json["calibrated"]?.bool
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
        answers = ExactKeyed(try (json["answers"]?.members ?? []).map { ($0.key, try Answer(json: $0.value)) })
        error = json["error"]?.string
        model = json["model"]?.string
        ms = json["ms"]?.double ?? 0
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

/// A catalog model as GET /v1/models reports it.
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
