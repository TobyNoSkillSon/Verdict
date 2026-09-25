import Foundation
import VerdictEngine

// POST /v1/systemone: TypeSafe's System One API (https://api.typesafe.ai/openapi.json) on local models. One request
// is one state and its named questions; the response is `{"model", "answers", "usage"}`. Request validation
// failures are 422 with FastAPI's `{"detail": [{"loc", "msg", "type", …}]}`; other failures use TypeSafe's
// `{"detail": {"error_type", "message"}}`. Concurrent requests for the same model and precision are merged into one
// GPU pass (SystemOneBatcher).

/// One pydantic-style validation error.
struct ValidationIssue {
    let loc: [Any]          // "body", field names (String) and array indices (Int)
    let msg: String
    let type: String
    var input: OrderedJSON? = nil
    var ctx: [String: Any]? = nil
    var object: [String: Any] {
        var out: [String: Any] = ["loc": loc, "msg": msg, "type": type]
        if let input { out["input"] = RawJSON(text: input.render()) }
        if let ctx { out["ctx"] = ctx }
        return out
    }
}

/// A validated request, ready to run.
struct SystemOneCall {
    /// Resolved model id ("auto" already resolved).
    let model: String
    /// Explicit precision (the `bits` extension), validated for `model`; nil = the model's selected precision.
    let bits: Int?
    let item: Item
    let questions: [Question]
    /// Score questions' criteria as sent, by question index (the answer's `legend`).
    let legends: [Int: [OrderedJSON]]
    var key: String { "\(model)@\(bits.map(String.init) ?? "-")" }
}

/// A validated request, or why not.
enum Validated {
    case success(SystemOneCall)
    case failure([ValidationIssue])
}

enum SystemOne {
    static let questionTypes = ["noul", "choice", "score"]
    static let expectedTags = "'noul', 'choice', 'score'"

    /// FastAPI's 422 body.
    static func unprocessable(_ issues: [ValidationIssue]) -> (Int, [String: Any]) {
        (422, ["detail": issues.map(\.object)])
    }
    /// TypeSafe's error body for everything that is not request validation.
    static func failure(_ status: Int, _ type: String, _ message: String) -> (Int, [String: Any]) {
        (status, ["detail": ["error_type": type, "message": message]])
    }

    /// `x-typesafe-request-id`, TypeSafe's format (`req_` + 32 hex digits).
    static func requestID() -> String {
        "req_" + (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private static func isJSONContent(_ value: OrderedJSON) -> Bool {
        switch value { case .string, .object, .array: return true; case .scalar: return false }
    }
    private static func isJSONContentOrNull(_ value: OrderedJSON) -> Bool { isJSONContent(value) || value.isNull }
    /// Text the models read for a structured value: the string itself, else its JSON rendering (key order kept).
    static func text(_ value: OrderedJSON?) -> String {
        guard let value, !value.isNull else { return "" }
        return value.text ?? value.render()
    }

    /// Validates a /v1/systemone body. `catalog` resolves model ids; `precisions` checks the `bits` extension.
    static func validate(_ data: Data, catalog: Catalog) -> Validated {
        // Strict syntax first (the order-keeping parser is lenient about scalars).
        do { _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch {
            return .failure([ValidationIssue(loc: ["body", 0], msg: "JSON decode error", type: "json_invalid",
                                             ctx: ["error": (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? "Invalid JSON"])])
        }
        var parser = OrderedJSONParser(data)
        guard let body = try? parser.parse() else {
            return .failure([ValidationIssue(loc: ["body", 0], msg: "JSON decode error", type: "json_invalid", ctx: ["error": "Invalid JSON"])])
        }
        guard body.fields != nil else {
            return .failure([ValidationIssue(loc: ["body"], msg: "Input should be a valid dictionary or object to extract fields from",
                                             type: "model_attributes_type", input: body)])
        }
        var issues: [ValidationIssue] = []
        func missing(_ field: String) { issues.append(ValidationIssue(loc: ["body", field], msg: "Field required", type: "missing", input: body)) }

        // state
        let state = body["state"]
        if let state {
            if !isJSONContent(state) {
                issues.append(ValidationIssue(loc: ["body", "state"], msg: "Input should be a valid string, object or array", type: "value_error", input: state))
            } else if let fields = state.fields, fields.contains(where: { ["image", "images", "audio", "video", "videos"].contains($0.0) }) {
                issues.append(ValidationIssue(loc: ["body", "state"], msg: "Verdict judges text; image, audio and video state is not supported.", type: "value_error"))
            }
        } else { missing("state") }

        // model
        var model: String?
        if let raw = body["model"] {
            if let name = raw.text { model = name }
            else { issues.append(ValidationIssue(loc: ["body", "model"], msg: "Input should be a valid string", type: "string_type", input: raw)) }
        } else { missing("model") }

        // questions
        var questions: [Question] = [], legends: [Int: [OrderedJSON]] = [:]
        if let raw = body["questions"] {
            if let fields = raw.fields {
                if fields.isEmpty {
                    issues.append(ValidationIssue(loc: ["body", "questions"], msg: "Dictionary should have at least 1 item after validation, not 0",
                                                  type: "too_short", input: raw, ctx: ["field_type": "Dictionary", "min_length": 1, "actual_length": 0]))
                }
                for (id, q) in fields {
                    let before = issues.count
                    if let question = self.question(id, q, &issues) {
                        if issues.count == before {
                            if question.kind == .score, let levels = q["criteria"]?.arrayValues { legends[questions.count] = levels }
                            questions.append(question)
                        }
                    }
                }
            } else {
                issues.append(ValidationIssue(loc: ["body", "questions"], msg: "Input should be a valid dictionary", type: "dict_type", input: raw))
            }
        } else { missing("questions") }

        // model id (after state, so "auto" can look at it) and the bits extension
        var resolved: String?
        if let model {
            let local = catalog.entries.filter { !$0.repository.isEmpty }.map(\.id)
            if model == "auto" {
                if let state, isJSONContent(state) { resolved = english(text(state)) ? "laya-english" : "laya-multilingual" }
            } else if local.contains(model) {
                resolved = model
            } else {
                let hosted = catalog.entries.contains { $0.id == model } || model.lowercased().contains("jev")
                let msg = hosted
                    ? "Value error, '\(model)' is TypeSafe's hosted model and does not run in Verdict; use one of: auto, \(local.joined(separator: ", "))"
                    : "Value error, unknown model '\(model)'; Verdict serves: auto, \(local.joined(separator: ", ")) (GET /v1/models)"
                issues.append(ValidationIssue(loc: ["body", "model"], msg: msg, type: "value_error", input: .string(model)))
            }
        }
        var bits: Int?
        if let raw = body["bits"], !raw.isNull {
            if case .scalar(let literal) = raw, let value = Double(literal), value.isFinite, value == value.rounded(), let whole = Int(exactly: value) {
                if let resolved, let spec = try? catalog.spec(resolved), let rule = Service.precisions[spec.runtime], !rule.0.contains(whole) {
                    issues.append(ValidationIssue(loc: ["body", "bits"], msg: "Value error, \(resolved): \(rule.1)", type: "value_error", input: raw))
                } else { bits = whole }
            } else {
                issues.append(ValidationIssue(loc: ["body", "bits"], msg: "Input should be a valid integer", type: "int_type", input: raw))
            }
        }
        guard issues.isEmpty, let resolved, let state else { return .failure(issues) }
        let item: Item
        switch state {
        case .string(let text): item = Item(text: text, kind: .text)
        case .object: item = Item(text: state.render(), kind: .object)
        default: item = Item(text: state.render(), kind: .value)
        }
        return .success(SystemOneCall(model: resolved, bits: bits, item: item, questions: questions, legends: legends))
    }

    /// One question, OpenAPI `Question` (discriminated by `type`). Appends issues; returns the engine question.
    private static func question(_ id: String, _ q: OrderedJSON, _ issues: inout [ValidationIssue]) -> Question? {
        let base: [Any] = ["body", "questions", id]
        guard q.fields != nil else {
            issues.append(ValidationIssue(loc: base, msg: "Input should be a valid dictionary or object to extract fields from", type: "model_attributes_type", input: q))
            return nil
        }
        guard let tag = q["type"] else {
            issues.append(ValidationIssue(loc: base, msg: "Unable to extract tag using discriminator 'type'", type: "union_tag_not_found",
                                          input: q, ctx: ["discriminator": "'type'"]))
            return nil
        }
        guard let name = tag.text, let kind = QuestionKind(rawValue: name) else {
            let shown = tag.text ?? tag.render()
            issues.append(ValidationIssue(loc: base, msg: "Input tag '\(shown)' found using 'type' does not match any of the expected tags: \(expectedTags)",
                                          type: "union_tag_invalid", input: q, ctx: ["discriminator": "'type'", "tag": shown, "expected_tags": expectedTags]))
            return nil
        }
        let loc = base + [name]
        if let instructions = q["instructions"], !isJSONContentOrNull(instructions) {
            issues.append(ValidationIssue(loc: loc + ["instructions"], msg: "Input should be a valid string, object, array or null", type: "value_error", input: instructions))
        }
        var criteria: [(String, String)] = []
        let raw = q["criteria"]
        switch kind {
        case .choice:
            guard let raw else { issues.append(ValidationIssue(loc: loc + ["criteria"], msg: "Field required", type: "missing", input: q)); return nil }
            guard let options = raw.fields else {
                issues.append(ValidationIssue(loc: loc + ["criteria"], msg: "Input should be a valid dictionary", type: "dict_type", input: raw)); return nil
            }
            if options.isEmpty {
                issues.append(ValidationIssue(loc: loc + ["criteria"], msg: "Value error, a choice needs at least one option", type: "value_error", input: raw))
            }
            for (label, description) in options where !isJSONContentOrNull(description) {
                issues.append(ValidationIssue(loc: loc + ["criteria", label], msg: "Input should be a valid string, object, array or null", type: "value_error", input: description))
            }
            // null = the bare label (the Von SDK and Laya's reference both use the label then).
            criteria = options.map { ($0.0, text($0.1)) }
        case .score:
            guard let raw else { issues.append(ValidationIssue(loc: loc + ["criteria"], msg: "Field required", type: "missing", input: q)); return nil }
            guard let levels = raw.arrayValues else {
                issues.append(ValidationIssue(loc: loc + ["criteria"], msg: "Input should be a valid list", type: "list_type", input: raw)); return nil
            }
            if levels.isEmpty {
                issues.append(ValidationIssue(loc: loc + ["criteria"], msg: "List should have at least 1 item after validation, not 0", type: "too_short",
                                              input: raw, ctx: ["field_type": "List", "min_length": 1, "actual_length": 0]))
            }
            for (index, level) in levels.enumerated() where !isJSONContent(level) {
                issues.append(ValidationIssue(loc: loc + ["criteria", index], msg: "Input should be a valid string, object or array", type: "value_error", input: level))
            }
            criteria = levels.map { (text($0), text($0)) }
        case .noul:
            if let raw, !raw.isNull {
                guard let fields = raw.fields else {
                    issues.append(ValidationIssue(loc: loc + ["criteria"], msg: "Input should be a valid dictionary or object to extract fields from", type: "model_attributes_type", input: raw))
                    return nil
                }
                for key in ["true", "false"] {
                    if let value = raw[key], !isJSONContentOrNull(value) {
                        issues.append(ValidationIssue(loc: loc + ["criteria", key], msg: "Input should be a valid string, object, array or null", type: "value_error", input: value))
                    }
                }
                criteria = fields.filter { ["true", "false"].contains($0.0) }.map { ($0.0, text($0.1)) }
            }
        }
        return Question(id: id, kind: kind, instructions: text(q["instructions"]), criteria: criteria, sourceJSON: q.render())
    }

    /// `auto`: letters ≥ 99.5% ASCII → English.
    static func english(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return letters.isEmpty || Double(letters.filter { $0.value < 128 }.count) / Double(letters.count) > 0.995
    }

    /// The answer object for one question: noul `{type, noul}`; choice `{type, choice, confidence, probabilities}`;
    /// score `{type, score, confidence, legend, probabilities}`.
    static func answer(_ a: Answer, _ question: Question, legend: [OrderedJSON]?) -> [String: Any] {
        var out: [String: Any] = ["type": question.kind.rawValue]
        func probabilities(_ p: Probabilities?) -> NSMutableDictionary {
            // NSString keys compare literally: byte-distinct labels ("é" / "e\u{301}") stay two JSON keys.
            let labelled = NSMutableDictionary()
            for (label, value) in p ?? Probabilities(labels: [], values: []) { labelled[NSString(string: label)] = value }
            return labelled
        }
        switch question.kind {
        case .noul:
            out["noul"] = a.noul ?? 0
        case .choice:
            out["choice"] = a.choice ?? ""
            out["confidence"] = a.confidence ?? 0
            out["probabilities"] = probabilities(a.probabilities)
        case .score:
            out["score"] = a.score ?? 0
            out["confidence"] = a.confidence ?? 0
            out["probabilities"] = probabilities(a.probabilities)
            let levels = NSMutableDictionary()
            for (index, level) in (legend ?? []).enumerated() { levels[NSString(string: String(index))] = RawJSON(text: level.render()) }
            out["legend"] = levels
        }
        return out
    }
}

/// Merges concurrent /v1/systemone requests into GPU batches. Requests queue while a batch runs; when it finishes, the
/// oldest waiting request's model and precision are served next, together with every other waiting request for the
/// same model and precision (up to `maxRows` question rows). A request arriving at an idle batcher starts a batch at
/// once; after a merged batch the next one waits briefly for the clients' follow-up requests (`window`). Replies go
/// out on their own queue so response encoding overlaps the next batch.
final class SystemOneBatcher {
    struct Pending {
        let call: SystemOneCall
        let reply: ((Int, [String: Any])) -> Void
    }
    private let lock = NSLock()
    private var pending: [Pending] = []
    private var running = false
    private let queue = DispatchQueue(label: "verdict.systemone", qos: .userInitiated)
    private let replies = DispatchQueue(label: "verdict.systemone.replies", qos: .userInitiated, attributes: .concurrent)
    private let execute: ([SystemOneCall]) -> [(Int, [String: Any])]
    /// VERDICT_BATCH_WINDOW_MS: after a merged batch, wait up to this long for its clients' next requests (default 2).
    let window: Double
    /// VERDICT_BATCH_MAX_ROWS: question rows per merged batch (default 4096).
    let maxRows: Int
    /// VERDICT_BATCH=0 runs every request alone (A/B and diagnosis).
    let merging: Bool

    init(execute: @escaping ([SystemOneCall]) -> [(Int, [String: Any])]) {
        let env = ProcessInfo.processInfo.environment
        window = max(0, Double(env["VERDICT_BATCH_WINDOW_MS"] ?? "") ?? 2) / 1000
        maxRows = max(1, Int(env["VERDICT_BATCH_MAX_ROWS"] ?? "") ?? 4096)
        merging = env["VERDICT_BATCH"] != "0"
        self.execute = execute
    }

    func submit(_ call: SystemOneCall, reply: @escaping ((Int, [String: Any])) -> Void) {
        lock.lock()
        pending.append(Pending(call: call, reply: reply))
        let start = !running
        if start { running = true }
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    /// Requests in the batch just served; > 1 means clients are sending concurrently.
    private var lastBatch = 0

    private func drain() {
        while true {
            lock.lock()
            // Concurrent clients answer the replies of the last batch with new requests over the next moments: while
            // fewer than that many are back, wait up to `window` so the next batch is not a lone early arrival.
            // A client sending one request at a time (lastBatch 1) never waits.
            if merging && window > 0 && lastBatch > 1 && pending.count < lastBatch {
                lock.unlock()
                let deadline = DispatchTime.now() + window
                repeat { usleep(100) } while DispatchTime.now() < deadline && count() < lastBatch
                lock.lock()
            }
            guard let first = pending.first else { running = false; lastBatch = 0; lock.unlock(); return }
            var take: [Pending] = [], rest: [Pending] = [], rows = 0
            let key = first.call.key
            for p in pending {
                let cost = p.call.questions.count
                if merging ? (p.call.key == key && (take.isEmpty || rows + cost <= maxRows)) : take.isEmpty {
                    take.append(p); rows += cost
                } else { rest.append(p) }
            }
            pending = rest
            lastBatch = take.count
            lock.unlock()
            let results = execute(take.map(\.call))
            for (p, result) in zip(take, results) { replies.async { p.reply(result) } }
        }
    }
    private func count() -> Int { lock.lock(); defer { lock.unlock() }; return pending.count }
}
