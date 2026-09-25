// Port of von-sdk 1.1.1 / 1.2.2 OptionMarkerBackend, no Python at runtime.
import Foundation
import Hub
import Tokenizers
import CoreFoundation
import MLX

public enum VonLoader: ModelLoader {
    public static func load(id: String, snapshot: URL, bits: Int) throws -> any DecisionModel {
        try VonModel(id: id, snapshot: snapshot, bits: bits)
    }
}

public struct VonPreparedRow: Sendable {
    public let ids: [Int]
    public let markers: [Int]
    public init(ids: [Int], markers: [Int]) { self.ids = ids; self.markers = markers }
}

public final class VonModel: DecisionModel, KernelPathReporting {
    public let id: String
    public let contextLimit = 8192
    public var residentBytes: Int { network.residentBytes }
    public var kernelPath: String { network.kernelPath }
    private let tokenizer: (any Tokenizer)?
    /// FastByteBPE when Von's tokenizer.json has the validated ModernBERT shape (zero mismatches vs the SDK's
    /// transformers tokenizer on 141k texts, native/perf/tokcheck.py --model von-1.x); swift-transformers otherwise.
    private let fastEncode: ((String, Bool) -> [Int])?
    private let maskID: Int
    private let maskToken: String
    private let sepToken: String
    private let calibration: [String: Double]
    private let temperature: Double
    private let prior: [String: Double]?
    private let network: VonNetwork
    /// Per question, across requests (agents repeat questions): option keys/texts, the validated zero-shot Noul null
    /// row and its logit bias, which depend only on the question. Keyed by the question JSON as exact UTF-8 bytes.
    private struct QuestionInfo { let keys: [String]; let texts: [String]; let nullRow: VonPreparedRow?; var null: Float? }
    private var questionCache: [Data: QuestionInfo] = [:]

    // A/B switches (native/perf/THEORY.md); defaults are the measured best.
    static let env = ProcessInfo.processInfo.environment
    /// 0 and 32 both load the original f32 weights (the native precision).
    public static let precisions: Set<Int> = [0, 32, 16, 8, 4]
    public static let precisionMessage = "Von precision must be 32 (native f32; 0 means the same), 16, 8 or 4 bits"
    static let sortByLength = env["VERDICT_VON_ARRIVAL_ORDER"] != "1"
    static let tokenBudget = Int(env["VERDICT_VON_TOKEN_BUDGET"] ?? "") ?? 8192
    static let rowCap = max(1, Int(env["VERDICT_VON_ROWS"] ?? "") ?? 64)
    /// Length bucket for chunks of > 8 rows. f32 is compute-bound (non-NAX GEMMs): exact lengths, jobs +7.6% vs
    /// 8-token buckets (2 A/B repeats); half precision keeps Laya's 8 (shape reuse).
    static let bucketOverride = Int(env["VERDICT_VON_BUCKET"] ?? "")
    private var bucketAll: Int { Self.bucketOverride ?? (network.dtype == .float32 ? 1 : 8) }
    static let padMultiple = Int(env["VERDICT_VON_PAD_MULTIPLE"] ?? "") ?? 16
    static let exactSingle = Int(env["VERDICT_VON_EXACT_SINGLE"] ?? "") ?? 512
    static let cacheNull = env["VERDICT_VON_NULL_CACHE"] != "0"
    static let doubleBuffer = env["VERDICT_VON_DOUBLE_BUFFER"] != "0"
    static let libraryTokenizer = env["VERDICT_VON_TOKENIZER"] == "library"
    static let profile = env["VERDICT_PROFILE"] == "1"
    static let trace = env["VERDICT_VON_PARITY_TRACE"] == "1"

    public init(id: String, snapshot: URL, bits: Int = 0) throws {
        guard ["von-1.1","von-1.2"].contains(id) else { throw VonError.invalid("Unknown Von model '\(id)'") }
        // 0: the original f32 weights (passes the ≤1% gate vs the SDK). 16: fp16 weights/activations, ~3x faster and
        // half the memory, max |dp| 0.08 on near-tie items (outside the gate; opt-in like Laya's 8/4-bit). 8/4: encoder
        // Linears quantized (group 64) with fp16 activations: less memory, lossy by design (drift: native/perf/THEORY.md).
        guard Self.precisions.contains(bits) else { throw VonError.invalid(Self.precisionMessage) }
        self.id = id
        let configData = try Data(contentsOf: snapshot.appendingPathComponent("tokenizer_config.json"))
        let tokenData = try Data(contentsOf: snapshot.appendingPathComponent("tokenizer.json"))
        let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any] ?? [:]
        guard let mask = config["mask_token"] as? String, let sep = config["sep_token"] as? String else { throw VonError.invalid("Von tokenizer is missing MASK/SEP") }
        if !Self.libraryTokenizer, mask.utf8.elementsEqual("[MASK]".utf8), sep.utf8.elementsEqual("[SEP]".utf8),
           let fast = FastByteBPE(data: tokenData, ignoringTruncationAndPadding: true), let id = fast.tokenID(mask) {
            tokenizer = nil
            fastEncode = { fast.encode($0, addSpecialTokens: $1) }
            maskID = id
        } else {
            let decoder = JSONDecoder()
            let loaded = try AutoTokenizer.from(tokenizerConfig: decoder.decode(Config.self, from: configData), tokenizerData: decoder.decode(Config.self, from: tokenData))
            guard let id = loaded.convertTokenToId(mask) else { throw VonError.invalid("Von tokenizer is missing MASK/SEP") }
            tokenizer = loaded; fastEncode = nil; maskID = id
        }
        maskToken = mask; sepToken = sep
        let cdata = try JSONSerialization.jsonObject(with: Data(contentsOf: snapshot.appendingPathComponent("marker_calibration.json"))) as? [String: Any] ?? [:]
        guard let t = cdata["temperature"] as? Double, t > 0, t.isFinite,
              let map = cdata["calibration_map"] as? [String: Double],
              ["bias","entropy","log_tokens","n_options","lo","hi"].allSatisfy({ map[$0]?.isFinite == true }) else {
            throw VonError.invalid("Invalid Von calibration")
        }
        temperature = t; calibration = map
        prior = cdata["noul_zero_shot_prior"] as? [String: Double]
        guard (cdata["independent_options"] as? Bool ?? false) == (id == "von-1.2") else { throw VonError.invalid("Von independent-options flag disagrees with catalog version") }
        network = try VonNetwork(snapshot: snapshot, id: id, bits: bits)
    }
    var hasFastTokenizer: Bool { fastEncode != nil }
    public func encode(_ text: String, addSpecialTokens: Bool = true) -> [Int] {
        fastEncode?(text, addSpecialTokens) ?? tokenizer!.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    private func state(_ item: Item) -> String {
        // SDK _format_state: a str is used as is (even when it looks like JSON); a dict enumerates its
        // insertion-order top-level fields as `key: str(value)` lines (the helper preserves an ordered JSON
        // rendering); anything else is str(state).
        switch item.kind {
        case .text: return item.text
        case .object:
            guard let pairs = VonJSON.topLevel(item.text) else { return item.text }
            return pairs.map { "\($0.0): \(VonJSON.pythonValue($0.1))" }.joined(separator: "\n")
        case .value: return VonJSON.pythonValue(item.text)
        }
    }
    private func descriptions(_ question: Question) -> ([String],[String]) {
        switch question.kind {
        case .choice:
            return (question.criteria.map(\.0), question.criteria.map { ($0.1.isEmpty ? $0.0 : $0.1).trimmingCharacters(in: .whitespacesAndNewlines) })
        case .score:
            return (question.criteria.indices.map(String.init), question.criteria.map { $0.1.trimmingCharacters(in: .whitespacesAndNewlines) })
        case .noul:
            let pos = question.criteria.first { $0.0 == "true" }?.1 ?? ""
            let neg = question.criteria.first { $0.0 == "false" }?.1 ?? ""
            return (["true","false"],[pos.isEmpty ? "Yes, condition holds true." : pos, neg.isEmpty ? "No, condition is false." : neg])
        }
    }
    private func pack(_ state: String, _ instructions: String, _ options: [String]) -> String {
        let prefix = instructions.isEmpty ? state.trimmingCharacters(in: .whitespacesAndNewlines) : (instructions + " " + state).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(prefix) \(sepToken) \(options.map { "\(maskToken) \($0.trimmingCharacters(in: .whitespacesAndNewlines))" }.joined(separator: " "))"
    }
    public func prepare(_ item: Item, _ question: Question) throws -> VonPreparedRow {
        let texts = try validated(question).1, prepared = row(pack(state(item), question.instructions, texts))
        guard prepared.markers.count == texts.count else { throw VonError.invalid(markerMessage) }
        return prepared
    }
    private func row(_ packed: String) -> VonPreparedRow {
        let ids = encode(packed)
        return VonPreparedRow(ids: ids, markers: ids.indices.filter { ids[$0] == maskID })
    }
    /// The SDK packs a literal mask token in user text as one more marker (it then scores K + extra markers and
    /// zips the first K probabilities with the labels: an invalid distribution). Von refuses it instead.
    private var markerMessage: String {
        "Item contains the literal mask token '\(maskToken)', which Von reserves for option markers; remove or replace it."
    }
    /// Request-level checks before any tokenization or GPU work: nonempty options and labels distinct as exact
    /// bytes (as JSON object keys are; list criteria may repeat a label). Returns option keys and texts.
    private func validated(_ question: Question) throws -> ([String], [String]) {
        switch question.kind {
        case .choice:
            guard !question.criteria.isEmpty else { throw VonError.invalid("Choice criteria must be a nonempty dictionary or list") }
            guard Probabilities.distinct(question.criteria.map(\.0)) else { throw VonError.invalid("Choice labels must be unique") }
        case .score:
            guard !question.criteria.isEmpty else { throw VonError.invalid("Score criteria must be a nonempty list") }
        case .noul: break
        }
        return descriptions(question)
    }
    /// Raw logits for prepared rows (parity tests), as one chunk.
    public func logits(_ rows: [VonPreparedRow]) throws -> [[Float]] {
        guard !rows.isEmpty, rows.count <= Self.rowCap else { throw VonError.invalid("Expected 1...\(Self.rowCap) Von rows") }
        guard let long = rows.map(\.ids.count).max(), long <= contextLimit else {
            throw VonError.invalid("Row needs \(rows.map(\.ids.count).max() ?? 0) tokens; Von accepts \(contextLimit).")
        }
        guard rows.allSatisfy({ !$0.markers.isEmpty }) else { throw VonError.invalid("Von rows need option markers") }
        let values = network.collect(network.launch(rows.map(\.ids), rows.map(\.markers), length: paddedLength(rows)), markers: rows.map(\.markers))
        if Self.trace { log(rows, values) }
        return values
    }
    private func log(_ rows: [VonPreparedRow], _ values: [[Float]]) {
        // Explicit local test hook only: never log private inputs in normal use.
        for (row,logits) in zip(rows,values) {
            let record: [String: Any] = ["ids":row.ids,"markers":row.markers,"logits":logits,
                                         "batch_size":rows.count,"sequence_length":rows.map { $0.ids.count }.max()!]
            if let data = try? JSONSerialization.data(withJSONObject: record,options:[.fragmentsAllowed]),
               let text = String(data:data,encoding:.utf8) {
                fputs("VON_PARITY_TRACE \(text)\n",stderr)
            }
        }
    }
    /// Sequence length a chunk is padded to: 16-token buckets for chunks of <= 8 rows, 8 above (fewer distinct
    /// shapes for MLX's kernel/buffer reuse); a long row alone keeps its exact length (no padding, no key mask).
    /// Arrival order (VERDICT_VON_ARRIVAL_ORDER=1) keeps the previous exact lengths.
    private func paddedLength(_ rows: [VonPreparedRow]) -> Int {
        let length = rows.map { $0.ids.count }.max() ?? 0
        guard Self.sortByLength, !(rows.count == 1 && length >= Self.exactSingle) else { return length }
        let step = rows.count <= 8 ? Self.padMultiple : bucketAll
        return step > 1 ? (length + step - 1) / step * step : length
    }
    public func tokenCount(_ item: Item, _ questions: [Question]) throws -> Int {
        let s = state(item)
        return questions.map { encode(pack(s, $0.instructions, descriptions($0).1)).count }.max() ?? 0
    }
    private func rounded(_ value: Double, digits: Double = 10000) -> Double { (value * digits).rounded(.toNearestOrEven) / digits }
    private func answer(_ logits: [Float], stateTokens tokens: Int, question: Question, keys: [String], null: Float?) -> Answer {
        var values = logits
        if let null { values[0] -= null }
        let k = values.count
        let maxLogit = values.max()!
        let baseline = values.map { expf($0 - maxLogit) }
        let baselineSum = baseline.reduce(Float(0),+)
        let raw = baseline.map { $0 / baselineSum }
        // Explicit Swift.min/max and typed steps: MLX's array overloads of min/max/log make this untypeable.
        let rawEntropy: Float = -raw.reduce(Float(0)) { $0 + $1 * logf(Swift.max(1e-12, $1)) }
        let entropy: Double = k < 2 ? 0 : Double(rawEntropy) / Foundation.log(Double(k))
        let c = calibration
        let linear: Double = c["bias"]! + c["entropy"]! * entropy + c["log_tokens"]! * Foundation.log10(Double(tokens)) / 4 + c["n_options"]! * Double(k) / 8
        let temp: Double = Swift.min(c["hi"]!, Swift.max(c["lo"]!, linear))
        let divisor = Float(Swift.max(temp, 1e-4))
        let scaled = values.map { $0 / divisor }
        let biggest = scaled.max()!, exponent = scaled.map { expf($0 - biggest) }, total = exponent.reduce(Float(0), +)
        let p: [Double] = exponent.map { Double($0 / total) }
        let sorted = p.sorted(by: >)
        let top: Double = sorted[0], second: Double = sorted.count > 1 ? sorted[1] : 0
        let confidence: Double = id == "von-1.1" ? top - second : (k <= 1 ? 1 : (Double(k) * top - 1) / Double(k - 1))
        let bounded: Double = Swift.max(0, Swift.min(1, confidence))
        var a = Answer()
        switch question.kind {
        case .noul:
            a.noul = rounded(Swift.min(1, Swift.max(0, p[0])))
            a.confidence = rounded(Swift.max(p[0], 1 - p[0]))
        case .choice:
            a.choice = keys[values.firstIndex(of: values.max()!)!]
            a.probabilities = Probabilities(labels: keys, values: p.map { rounded($0) })
            a.confidence = rounded(bounded, digits: 1000)
        case .score:
            a.probabilities = Probabilities(labels: keys, values: p.map { rounded($0) })
            a.score = rounded(p.enumerated().reduce(Double(0)) { $0 + Double($1.offset) * $1.element }, digits: 100)
            a.confidence = rounded(bounded, digits: 1000)
        }
        return a
    }
    private func questionKey(_ question: Question) -> Data { Data((question.sourceJSON ?? LayaModel.questionJSON(question)).utf8) }
    /// Validated question info; tokenizer work only, never a forward pass (the null pass is `nullBias`).
    private func cachedQuestion(_ question: Question) throws -> QuestionInfo {
        let key = questionKey(question)
        if let hit = questionCache[key] { return hit }
        let (keys, texts) = try validated(question)
        // The question without any item: its markers must be exactly the options' (a literal mask token in the
        // instructions or an option would add one), and it is the zero-shot Noul null row.
        let bare = row(pack("", question.instructions, texts))
        guard bare.markers.count == texts.count else {
            throw VonError.invalid("Question '\(question.id)' contains the literal mask token '\(maskToken)', which Von reserves for option markers; remove or replace it.")
        }
        let info = QuestionInfo(keys: keys, texts: texts, nullRow: needsNull(question) ? bare : nil, null: nil)
        if Self.cacheNull { remember(key, info) }
        return info
    }
    private func remember(_ key: Data, _ info: QuestionInfo) {
        if questionCache[key] == nil && questionCache.count >= 512 { questionCache.removeAll(keepingCapacity: true) }
        questionCache[key] = info
    }
    /// Zero-shot Noul: the SDK's null pass (empty state) for this question, one row alone. Run only once some item
    /// of the request fits the context, and never for an over-context null row.
    private func nullBias(_ question: Question, _ info: QuestionInfo) throws -> Float? {
        guard let nullRow = info.nullRow else { return nil }
        if let null = info.null { return null }
        guard nullRow.ids.count <= contextLimit else {
            throw VonError.invalid("Question '\(question.id)' needs about \(nullRow.ids.count) tokens; Von accepts \(contextLimit).")
        }
        let lg = try logits([nullRow])[0]
        let bias = lg[0] - lg[1]
        let null = prior.map { Float($0["a"] ?? 0)*bias + Float($0["b"] ?? 0) } ?? 0.7*bias
        if Self.cacheNull { var cached = info; cached.null = null; remember(questionKey(question), cached) }
        return null
    }
    private func needsNull(_ q: Question) -> Bool { q.kind == .noul && q.criteria.allSatisfy { $0.1.isEmpty } }

    public func predict(_ items: [Item], _ questions: [Question]) throws -> [ItemResult] {
        guard !questions.isEmpty else { throw VonError.invalid("Questions must be nonempty") }
        let clock = ContinuousClock(), t0 = clock.now
        var results = [[String: Answer]](repeating: [:],count: items.count)
        var errors: [Int:String] = [:]
        var rows: [VonPreparedRow] = [], meta: [(item: Int, question: Int)] = []
        // Validation and tokenization first: no forward pass (not even the cached null pass) runs before every
        // row is known to fit the context and carry exactly its options' markers.
        var infos = try questions.map(cachedQuestion)
        let states = items.map(state)
        var stateTokens = [Int](repeating: 1, count: items.count)
        for (i,s) in states.enumerated() {
            let prepared = zip(questions, infos).map { row(pack(s, $0.instructions, $1.texts)) }
            let count = prepared.map { $0.ids.count }.max() ?? 0
            if count > contextLimit { errors[i] = "Item needs about \(count) tokens; Von accepts \(contextLimit)."; continue }
            if zip(prepared, infos).contains(where: { $0.markers.count != $1.texts.count }) { errors[i] = markerMessage; continue }
            // Calibration input: the state's own token count, once per item (was once per row).
            stateTokens[i] = max(1, encode(s, addSpecialTokens: false).count)
            for (q,r) in prepared.enumerated() { rows.append(r); meta.append((i,q)) }
        }
        let tn = clock.now
        if !rows.isEmpty {
            for q in infos.indices { infos[q].null = try nullBias(questions[q], infos[q]) }
        }
        let t1 = clock.now
        // Rows in length order, chunks of <= 64 rows under the token budget (as Laya fp16): less padding and bounded
        // activation memory; results are scattered back by `meta`, so answers stay in input order.
        let order = Self.sortByLength ? rows.indices.sorted { (rows[$0].ids.count, $0) < (rows[$1].ids.count, $1) } : Array(rows.indices)
        var chunks: [[Int]] = [], current: [Int] = []
        for slot in order {
            let length = rows[slot].ids.count
            let over = Self.sortByLength && (current.count + 1) * max(length, current.map { rows[$0].ids.count }.max() ?? 0) > Self.tokenBudget
            if !current.isEmpty && (current.count == Self.rowCap || over) { chunks.append(current); current = [] }
            current.append(slot)
        }
        if !current.isEmpty { chunks.append(current) }
        var padded = 0
        func finish(_ slots: [Int], _ output: MLXArray) {
            let chunk = slots.map { rows[$0] }
            let values = network.collect(output, markers: chunk.map(\.markers))
            if Self.trace { log(chunk, values) }
            for (r,lg) in values.enumerated() {
                let (i,q) = meta[slots[r]]
                // Validated above; never map a different number of logits onto the labels.
                guard lg.count == infos[q].keys.count else { errors[i] = markerMessage; continue }
                results[i][questions[q].id] = answer(lg, stateTokens: stateTokens[i], question: questions[q], keys: infos[q].keys, null: infos[q].null)
            }
        }
        // Double-buffered: queue chunk k+1 before reading chunk k (at most two chunks in flight).
        var inflight: ([Int], MLXArray)? = nil
        for slots in chunks {
            let chunk = slots.map { rows[$0] }
            let length = paddedLength(chunk)
            padded += chunk.count * length
            let output = network.launch(chunk.map(\.ids), chunk.map(\.markers), length: length)
            if let (previous, previousOutput) = inflight { finish(previous, previousOutput) }
            inflight = Self.doubleBuffer ? (slots, output) : nil
            if !Self.doubleBuffer { finish(slots, output) }
        }
        if let (previous, previousOutput) = inflight { finish(previous, previousOutput) }
        if Self.profile {
            let t2 = clock.now, real = rows.reduce(0) { $0 + $1.ids.count }
            func ms(_ d: Duration) -> String { String(format: "%.1f", Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000) }
            FileHandle.standardError.write(Data("profile \(id) items=\(items.count) rows=\(rows.count) chunks=\(chunks.count) tokens=\(real) padded=\(padded) prepare=\(ms(tn - t0))ms null=\(ms(t1 - tn))ms forward+post=\(ms(t2 - t1))ms\n".utf8))
        }
        return items.indices.map { errors[$0].map(ItemResult.error) ?? .answers(results[$0]) }
    }
}

extension VonModel: TokenizerPathReporting { public var tokenizerPath: String { hasFastTokenizer ? "fast" : "library" } }

/// Bounded, order-preserving JSON text handling for SDK's dict-state rendering.
private enum VonJSON {
    static func topLevel(_ text: String) -> [(String,String)]? {
        let b = Array(text.utf8)
        guard b.first == 123, b.last == 125 else { return nil }
        var i = 1, pairs: [(String,String)] = []
        func white() { while i < b.count && [UInt8(32),10,13,9].contains(b[i]) { i += 1 } }
        func string() -> String? {
            guard i < b.count, b[i] == 34 else { return nil }
            let start = i; i += 1
            while i < b.count {
                if b[i] == 92 { i += 2; continue }
                if b[i] == 34 { i += 1; break }
                i += 1
            }
            guard i <= b.count, let value = try? JSONSerialization.jsonObject(with: Data(b[start..<i]),options:[.fragmentsAllowed]) as? String else { return nil }
            return value
        }
        white()
        while i < b.count-1 {
            guard let key = string() else { return nil }; white()
            guard i < b.count,b[i] == 58 else { return nil }; i += 1;white()
            let start = i;var depth = 0, quoted = false, escaped = false
            while i < b.count {
                let c = b[i]
                if quoted {
                    if escaped { escaped = false } else if c == 92 { escaped = true } else if c == 34 { quoted = false }
                } else {
                    if c == 34 { quoted = true }
                    if c == 91 || c == 123 { depth += 1 }
                    if c == 93 || c == 125 { if depth == 0 { break };depth -= 1 }
                    if c == 44 && depth == 0 { break }
                }
                i += 1
            }
            pairs.append((key,String(decoding:b[start..<i],as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)))
            white(); if i < b.count,b[i] == 44 { i += 1;white() }
        }
        return pairs
    }
    /// A JSON number literal as Python's repr prints it. The helper renders items with Python's json.dumps, whose
    /// number literals are float/int repr ("117188.0", "1e+100"); re-parsing through NSNumber dropped ".0".
    static func numberLiteral(_ json: String) -> String? {
        switch json {
        case "NaN": return "nan"
        case "Infinity": return "inf"
        case "-Infinity": return "-inf"
        default:
            guard let c = json.utf8.first, c == 45 || (48...57).contains(c),
                  json.utf8.allSatisfy({ (48...57).contains($0) || [45, 43, 46, 101, 69].contains($0) }) else { return nil }
            return json
        }
    }
    static func pythonValue(_ json: String) -> String {
        if let number = numberLiteral(json) { return number }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8),options:[.fragmentsAllowed]) else { return json }
        if let s = obj as? String { return s }
        if obj is NSNull { return "None" }
        if let number = obj as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "True" : "False" }
            return number.description
        }
        if obj is [Any] { return pythonReprJSON(json) }
        if let fields = topLevel(json) {
            return "{" + fields.map { "\(pythonRepr($0.0)): \(pythonReprJSON($0.1))" }.joined(separator:", ") + "}"
        }
        return json
    }
    private static func pythonReprJSON(_ json: String) -> String {
        if let number = numberLiteral(json) { return number }
        if let values = arrayItems(json) { return "[" + values.map(pythonReprJSON).joined(separator:", ") + "]" }
        if let fields = topLevel(json) {
            return "{" + fields.map { "\(pythonRepr($0.0)): \(pythonReprJSON($0.1))" }.joined(separator:", ") + "}"
        }
        if let obj = try? JSONSerialization.jsonObject(with:Data(json.utf8),options:[.fragmentsAllowed]) {
            return pythonRepr(obj)
        }
        return json
    }
    private static func arrayItems(_ text: String) -> [String]? {
        let b = Array(text.utf8)
        guard b.first == 91, b.last == 93 else { return nil }
        var values: [String] = [], start = 1, depth = 0, quoted = false, escaped = false
        for i in 1..<(b.count-1) {
            let c = b[i]
            if quoted {
                if escaped { escaped = false } else if c == 92 { escaped = true } else if c == 34 { quoted = false }
            } else {
                if c == 34 { quoted = true }
                if c == 91 || c == 123 { depth += 1 }
                if c == 93 || c == 125 { depth -= 1 }
                if c == 44 && depth == 0 {
                    values.append(String(decoding:b[start..<i],as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines))
                    start = i+1
                }
            }
        }
        let last = String(decoding:b[start..<(b.count-1)],as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        if !last.isEmpty { values.append(last) }
        return values
    }
    private static func pythonRepr(_ obj: Any) -> String {
        if let s = obj as? String {
            let quote = s.contains("'") && !s.contains("\"") ? "\"" : "'"
            let escaped = s.replacingOccurrences(of:"\\",with:"\\\\")
                .replacingOccurrences(of:quote,with:"\\"+quote)
                .replacingOccurrences(of:"\n",with:"\\n")
                .replacingOccurrences(of:"\r",with:"\\r")
                .replacingOccurrences(of:"\t",with:"\\t")
            return quote+escaped+quote
        }
        if obj is NSNull { return "None" }
        if let n = obj as? NSNumber { return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "True" : "False") : n.description }
        if let a = obj as? [Any] { return "["+a.map(pythonRepr).joined(separator:", ")+"]" }
        if let fields = topLevel(String(describing:obj)) { return "{" + fields.map { "\(pythonRepr($0.0)): \(pythonReprJSON($0.1))" }.joined(separator:", ") + "}" }
        return String(describing:obj)
    }
}
