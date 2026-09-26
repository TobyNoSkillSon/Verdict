import Foundation

/// A client for the System One API (TypeSafe Jev): one state, named typed questions, typed answers, with the same
/// call shape as the TypeSafe SDK. It talks to the local Verdict by default (found or launched like `Verdict`), and
/// to any other compatible server when given its base URL and key.
///
///     let client = SystemOneClient()                                  // local Verdict, model "auto"
///     let pr = try await client.systemOne(state: ["title": "Bump lodash to 4.17.21", "files": "package.json, yarn.lock"], questions: [
///         "deps": .noul("Does this pull request only change dependencies?"),
///         "area": .choice("Which part of the codebase does it touch?", labels: ["frontend", "backend", "build"]),
///         "risk": .score("How risky is merging it without review?", levels: ["harmless", "worth a glance", "needs a reviewer"]),
///     ])
///     pr.nouls["deps"]?.noul; pr.choices["area"]?.choice; pr.scores["risk"]?.score
///
///     let hosted = SystemOneClient(baseURL: URL(string: "https://openrouter.ai/api")!, apiKey: key, model: "jev-1.13")
public struct SystemOneClient: Sendable {
    /// nil: the local Verdict (its port is read before every request, so a restarted helper is found again).
    public let baseURL: URL?
    public let apiKey: String
    /// The default model for `systemOne` (per call: `model:`).
    public let model: String
    /// Discovery and launch of the local app (also the batch `judge` extension and management calls).
    public let verdict: Verdict
    /// Retries after 408, 429 and 5xx answers (except Verdict's 507 memory refusal) and connection failures, with
    /// exponential backoff from 0.5 s, as the TypeSafe SDKs do by default.
    public let maxRetries: Int
    private let session: URLSession

    /// `baseURL` nil talks to the local Verdict: no key needed (any key is accepted and ignored), default model
    /// "auto". With a base URL the key comes from `apiKey` or TYPESAFE_API_KEY, and the default model is
    /// TYPESAFE_DEFAULT_MODEL or "jev-latest", as in the TypeSafe SDKs.
    public init(baseURL: URL? = nil, apiKey: String? = nil, model: String? = nil, verdict: Verdict = Verdict(unchecked: true), maxRetries: Int = 2) {
        let env = ProcessInfo.processInfo.environment
        func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
        var base = baseURL
        if let url = base, url.absoluteString.hasSuffix("/") { base = URL(string: String(url.absoluteString.dropLast())) }
        self.baseURL = base
        self.apiKey = nonEmpty(apiKey) ?? (base == nil ? "verdict" : nonEmpty(env["TYPESAFE_API_KEY"]) ?? "")
        self.model = model ?? (base == nil ? "auto" : nonEmpty(env["TYPESAFE_DEFAULT_MODEL"]) ?? "jev-latest")
        self.verdict = verdict
        self.maxRetries = max(0, maxRetries)
        let config = URLSessionConfiguration.ephemeral
        if base == nil { config.connectionProxyDictionary = [:] }   // loopback never goes through a proxy
        config.timeoutIntervalForRequest = base == nil ? 600 : 60   // a first local load downloads its model
        session = URLSession(configuration: config)
    }

    /// The request body the TypeSafe SDKs send: `{"state", "model", "questions"}`, then `extraBody` members (they
    /// replace a same-named field, like the SDK's `extra_body`; Verdict reads `bits`).
    public static func body(state: JSON, questions: Questions, model: String, extraBody: [JSON.Member] = []) throws -> JSON {
        guard !questions.isEmpty else { throw VerdictError.invalidRequest("At least one question is required.") }
        for entry in questions.entries where entry.question.kind == .score && entry.question.labels.isEmpty {
            throw VerdictError.invalidRequest("Score question \"\(entry.id)\" needs one or more levels.")
        }
        var members: [JSON.Member] = [.init("state", state), .init("model", .string(model)), .init("questions", questions.json)]
        for extra in extraBody {
            if let i = members.firstIndex(where: { $0.key.utf8.elementsEqual(extra.key.utf8) }) { members[i] = extra } else { members.append(extra) }
        }
        return .object(members)
    }

    /// Answers every question about `state` (text, or a JSON object/array: one shared state for all questions).
    public func systemOne(state: JSON, questions: Questions, model: String? = nil, extraBody: [JSON.Member] = []) async throws -> SystemOneResult {
        let body = try Self.body(state: state, questions: questions, model: model ?? self.model, extraBody: extraBody)
        let (data, headers) = try await send("POST", "/v1/systemone", body: body)
        return try SystemOneResult(data: data, requestID: headers["x-typesafe-request-id"])
    }
    public func systemOne(state: String, questions: Questions, model: String? = nil, extraBody: [JSON.Member] = []) async throws -> SystemOneResult {
        try await systemOne(state: .string(state), questions: questions, model: model, extraBody: extraBody)
    }

    /// GET /v1/models: every model name the `model` field accepts.
    public func models() async throws -> [ModelMetadata] {
        let (data, _) = try await send("GET", "/v1/models", body: nil)
        let reply: JSON
        do { reply = try JSON.parse(data) } catch { throw VerdictError.unavailable("Unexpected answer: \(error.localizedDescription)") }
        guard let list = reply["models"]?.array else { throw VerdictError.unavailable("Unexpected answer: no models list") }
        return try list.map(ModelMetadata.init(json:))
    }

    /// The base URL requests go to: the given one, or the local Verdict's (launched if needed) — for other clients,
    /// e.g. the TypeSafe SDKs' base_url.
    public func resolvedBaseURL() async throws -> URL {
        if let baseURL { return baseURL }
        return URL(string: "http://127.0.0.1:\(try await verdict.ensureRunning())")!
    }

    private func send(_ method: String, _ path: String, body: JSON?) async throws -> (Data, [String: String]) {
        if baseURL != nil, apiKey.isEmpty { throw VerdictError.invalidRequest("No API key was provided. Pass apiKey or set TYPESAFE_API_KEY.") }
        guard apiKey.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value < 127 }) else {
            throw VerdictError.invalidRequest("The API key may use printable ASCII only, with no spaces.")
        }
        var attempt = 0
        while true {
            let base = try await resolvedBaseURL()
            var request = URLRequest(url: URL(string: base.absoluteString + path)!)
            request.httpMethod = method
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("VerdictKit", forHTTPHeaderField: "User-Agent")
            if attempt > 0 { request.setValue(String(attempt), forHTTPHeaderField: "X-TypeSafe-Retry-Count") }
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(body.compact.utf8)
            }
            let retry: Bool, failure: Error
            do {
                let (data, response) = try await session.data(for: request)
                let http = response as? HTTPURLResponse
                let code = http?.statusCode ?? 0
                var headers: [String: String] = [:]
                for (key, value) in http?.allHeaderFields ?? [:] { headers[String(describing: key).lowercased()] = String(describing: value) }
                if (200..<300).contains(code) { return (data, headers) }
                failure = VerdictError.api(status: code, message: Self.message(data) ?? "HTTP \(code)")
                retry = [408, 429].contains(code) || (500...599).contains(code) && code != 507
            } catch {
                failure = VerdictError.unavailable("\(base.host ?? "server") did not answer: \(error.localizedDescription)")
                retry = true
            }
            guard retry, attempt < maxRetries else { throw failure }
            attempt += 1
            try await Task.sleep(nanoseconds: UInt64(0.5 * pow(2, Double(attempt - 1)) * 1e9))
        }
    }

    /// The error text from TypeSafe's, OpenRouter's and Verdict's error bodies: `error` (string or `{message}`),
    /// `message`, `detail` (string, `{message}`, or FastAPI's list → "field: msg; …").
    static func message(_ data: Data) -> String? {
        guard let body = try? JSON.parse(data) else { return String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : String($0.prefix(200)) } }
        if let e = body["error"]?.string { return e }
        if let e = body["error"]?["message"]?.string { return e }
        if let m = body["message"]?.string { return m }
        if let d = body["detail"]?.string { return d }
        if let d = body["detail"]?["message"]?.string { return d }
        if let list = body["detail"]?.array {
            let parts = list.compactMap { entry -> String? in
                guard let msg = entry["msg"]?.string else { return nil }
                let path = (entry["loc"]?.array ?? []).filter { $0.string != "body" }.map { $0.string ?? $0.compact }.joined(separator: ".")
                return path.isEmpty ? msg : "\(path): \(msg)"
            }
            return parts.isEmpty ? nil : parts.joined(separator: "; ")
        }
        return nil
    }
}

// MARK: Results

/// A yes/no answer: P(yes).
public struct NoulAnswer: Sendable, Hashable { public var noul: Double }
/// The most probable option, its confidence and every option's probability (labels by exact bytes).
public struct ChoiceAnswer: Sendable, Hashable {
    public var choice: String
    public var confidence: Double
    public var probabilities: ExactKeyed<Double>
}
/// The expected level (0…n-1, fractional), its confidence, and per level its probability and description.
public struct ScoreAnswer: Sendable, Hashable {
    public var score: Double
    public var confidence: Double
    public var legend: [Int: JSON]
    public var probabilities: [Int: Double]
}
/// One answer, by its question's type.
public enum SystemOneAnswer: Sendable, Hashable {
    case noul(NoulAnswer), choice(ChoiceAnswer), score(ScoreAnswer)
}

/// POST /v1/systemone's answer. `nouls`, `choices` and `scores` hold the answers of that type by question name, like
/// the Python SDK's `result.nouls["billing"].noul`. Answer types this version does not know are skipped (they stay
/// in `raw`).
public struct SystemOneResult: Sendable {
    /// The model that answered (for `auto`, the one it chose).
    public var model: String
    public var answers: ExactKeyed<SystemOneAnswer>
    public var inputTokens: Int?
    public var outputTokens: Int?
    /// The `x-typesafe-request-id` header.
    public var requestID: String?
    /// The whole response body.
    public var raw: JSON

    public var nouls: ExactKeyed<NoulAnswer> { ExactKeyed(answers.compactMap { if case .noul(let a) = $0.value { return ($0.key, a) }; return nil }) }
    public var choices: ExactKeyed<ChoiceAnswer> { ExactKeyed(answers.compactMap { if case .choice(let a) = $0.value { return ($0.key, a) }; return nil }) }
    public var scores: ExactKeyed<ScoreAnswer> { ExactKeyed(answers.compactMap { if case .score(let a) = $0.value { return ($0.key, a) }; return nil }) }

    /// Parses and checks a response body: a missing or wrong-typed field throws (naming it), as the SDKs' response
    /// validation does.
    public init(data: Data, requestID: String? = nil) throws {
        let body: JSON
        do { body = try JSON.parse(data) } catch { throw Self.invalid("", "the body is not JSON") }
        try self.init(json: body, requestID: requestID)
    }
    public init(json body: JSON, requestID: String? = nil) throws {
        raw = body; self.requestID = requestID
        guard body.members != nil else { throw Self.invalid("", "not an object") }
        guard let model = body["model"]?.string else { throw Self.invalid("model", "missing or not a string") }
        self.model = model
        guard let usage = body["usage"], usage.members != nil else { throw Self.invalid("usage", "missing or not an object") }
        func count(_ key: String) throws -> Int? {
            guard let value = usage[key], !value.isNull else { return nil }
            guard let n = value.int else { throw Self.invalid("usage.\(key)", "not an integer") }
            return n
        }
        inputTokens = try count("input_tokens"); outputTokens = try count("output_tokens")
        guard let members = body["answers"]?.members else { throw Self.invalid("answers", "missing or not an object") }
        var parsed: [(String, SystemOneAnswer)] = []
        for m in members {
            let path = "answers.\(m.key)"
            guard m.value.members != nil, let type = m.value["type"]?.string else { throw Self.invalid("\(path).type", "missing or not a string") }
            func number(_ key: String) throws -> Double {
                guard let v = m.value[key]?.double else { throw Self.invalid("\(path).\(key)", "missing or not a number") }
                return v
            }
            func probabilities() throws -> [(String, Double)] {
                guard let ps = m.value["probabilities"]?.members else { throw Self.invalid("\(path).probabilities", "missing or not an object") }
                return try ps.map { p in
                    guard let v = p.value.double else { throw Self.invalid("\(path).probabilities.\(p.key)", "not a number") }
                    return (p.key, v)
                }
            }
            func levels<T>(_ pairs: [(String, T)], _ field: String) throws -> [Int: T] {
                var out: [Int: T] = [:]
                for (key, value) in pairs {
                    guard let level = Int(key) else { throw Self.invalid("\(path).\(field).\(key)", "not a score level") }
                    out[level] = value
                }
                return out
            }
            switch type {
            case "noul": parsed.append((m.key, .noul(NoulAnswer(noul: try number("noul")))))
            case "choice":
                guard let choice = m.value["choice"]?.string else { throw Self.invalid("\(path).choice", "missing or not a string") }
                parsed.append((m.key, .choice(ChoiceAnswer(choice: choice, confidence: try number("confidence"), probabilities: ExactKeyed(try probabilities())))))
            case "score":
                guard let legend = m.value["legend"]?.members else { throw Self.invalid("\(path).legend", "missing or not an object") }
                parsed.append((m.key, .score(ScoreAnswer(score: try number("score"), confidence: try number("confidence"),
                                                         legend: try levels(legend.map { ($0.key, $0.value) }, "legend"),
                                                         probabilities: try levels(try probabilities(), "probabilities")))))
            default: continue
            }
        }
        answers = ExactKeyed(parsed)
    }
    private static func invalid(_ field: String, _ why: String) -> VerdictError {
        .unavailable("Invalid response data at '\(field)': \(why)")
    }
}

/// A model name the `model` field accepts (GET /v1/models).
public struct ModelMetadata: Sendable, Hashable {
    public var name: String
    public var description: String
    /// YYYY-MM-DD.
    public var releaseDate: String
    init(json: JSON) throws {
        guard let name = json["name"]?.string, let description = json["description"]?.string, let date = json["release_date"]?.string else {
            throw VerdictError.unavailable("Invalid response data at 'models': each model needs name, description and release_date")
        }
        self.name = name; self.description = description; releaseDate = date
    }
}

// MARK: Verdict's batch extension

extension SystemOneClient {
    /// Verdict's batch extension (POST /v1/judge, local Verdict only): every question for every item, each item its own
    /// state, in batches of `batch` items. Faster than one `systemOne` call per item when you have the items together.
    public func judge(items: [Item], questions: Questions, model: String? = nil, bits: Int? = nil, batch: Int = 256) async throws -> [Judgement] {
        guard baseURL == nil else { throw VerdictError.invalidRequest("judge is Verdict's batch extension; it needs the local Verdict (baseURL nil)") }
        return try await verdict.judge(items, questions, model: model ?? self.model, bits: bits, batch: batch)
    }
    public func judge(items: [String], questions: Questions, model: String? = nil, bits: Int? = nil, batch: Int = 256) async throws -> [Judgement] {
        try await judge(items: items.map { Item($0) }, questions: questions, model: model, bits: bits, batch: batch)
    }
    /// Untyped JSON in and out, for tools that pass questions files through.
    public func judgeJSON(_ items: [JSON], questions: JSON, model: String? = nil, bits: Int? = nil, batch: Int = 256) async throws -> [JSON] {
        guard baseURL == nil else { throw VerdictError.invalidRequest("judge is Verdict's batch extension; it needs the local Verdict (baseURL nil)") }
        return try await verdict.judgeJSON(items, questions: questions, model: model ?? self.model, bits: bits, batch: batch)
    }
}
