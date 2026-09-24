// Prompt/calibration port of laya-mlx 0.2.0 common.py and agent.py (Apache-2.0).
import Foundation
import MLX

public enum LayaLoader: ModelLoader {
    public static func load(id: String, snapshot: URL, bits: Int) throws -> any DecisionModel {
        try LayaModel(id: id, snapshot: snapshot, bits: bits)
    }
}

public struct LayaPreparedRow: Codable, Sendable {
    public let ids: [Int]
    public let markers: [Int]
    public let qtype: Int
    public init(ids: [Int], markers: [Int], qtype: Int) { self.ids = ids; self.markers = markers; self.qtype = qtype }
}

public final class LayaModel: DecisionModel {
    public let id: String
    public let contextLimit = 8192
    private let bits: Int
    /// 0 and 16 both load plain fp16 Linear weights (LayaNetwork quantizes only 8 and 4), so both take the fp16 path.
    private var fp16: Bool { bits == 0 || bits == 16 }
    public var residentBytes: Int { network.residentBytes }
    private let prompt: LayaPrompt
    private let temperatures: [Double]
    private let temperatureBuckets: [String: Double]
    private let network: LayaNetwork
    /// Question templates and token counts survive across requests: agents repeat the same
    /// questions, and tokenizing a long question (e.g. 20 options) dominated single-item calls.
    /// Keyed by the question's source JSON, which fully determines both values, as exact UTF-8 bytes:
    /// String keys compare by canonical equivalence, but the Multilingual tokenizer (no normalizer)
    /// gives NFC and NFD spellings different token IDs.
    static let sortByLength = ProcessInfo.processInfo.environment["VERDICT_LAYA_ARRIVAL_ORDER"] != "1"
    static let tokenBudget = Int(ProcessInfo.processInfo.environment["VERDICT_LAYA_TOKEN_BUDGET"] ?? "") ?? 8192
    static let padMultiple = Int(ProcessInfo.processInfo.environment["VERDICT_LAYA_PAD_MULTIPLE"] ?? "") ?? 16
    static let parallelBytesFast = Int(ProcessInfo.processInfo.environment["VERDICT_LAYA_PARALLEL_BYTES"] ?? "") ?? Int.max
    static let bucketAll = Int(ProcessInfo.processInfo.environment["VERDICT_LAYA_BUCKET"] ?? "") ?? 8
    static let profile = ProcessInfo.processInfo.environment["VERDICT_PROFILE"] == "1"
    private var questionCache: [Data: (template: LayaPrompt.QuestionTemplate, count: Int)] = [:]

    public init(id: String, snapshot: URL, bits: Int = 0) throws {
        guard ["laya-english", "laya-multilingual", "laya-typed-decisions"].contains(id) else { throw LayaError.invalid("Unknown Laya model '\(id)'") }
        guard [0, 16, 8, 4].contains(bits) else { throw LayaError.invalid("Laya precision must be 16, 8 or 4 bits") }
        self.id = id; self.bits = bits
        let agent = try JSONSerialization.jsonObject(with: Data(contentsOf: snapshot.appendingPathComponent("rl_agent_config.json"))) as? [String: Any] ?? [:]
        guard let headLayers = agent["head_layers"] as? Int, headLayers >= 0, agent["encoder"] != nil else { throw LayaError.invalid("Laya config must specify encoder and head_layers") }
        let rawTemps = agent["temperature"] as? [Double] ?? [1, 1, 1]
        let rawBuckets = agent["temperature_by_options"] as? [String: Double] ?? [:]
        guard rawTemps.count == 3, (rawTemps + Array(rawBuckets.values)).allSatisfy({ $0.isFinite && $0 > 0 }) else { throw LayaError.invalid("Calibration temperatures must be finite and positive") }
        temperatures = rawTemps.map { min(5, max(0.5, $0)) }
        temperatureBuckets = rawBuckets.mapValues { min(5, max(0.5, $0)) }
        prompt = try LayaPrompt(snapshot: snapshot)
        network = try LayaNetwork(snapshot: snapshot, config: LayaEncoderConfiguration(data: Data(contentsOf: snapshot.appendingPathComponent("encoder/config.json"))), headLayers: headLayers, bits: bits)
    }

    public func encode(_ text: String, addSpecialTokens: Bool = false) -> [Int] {
        prompt.encode(text, addSpecialTokens: addSpecialTokens)
    }

    private func typeIndex(_ question: Question) -> Int {
        switch question.kind { case .choice: 0; case .score: 1; case .noul: 2 }
    }

    /// Python common.build_sequence, including literal-mask replacement and per-option cap.
    public func prepare(_ item: Item, _ question: Question) throws -> LayaPreparedRow {
        try prompt.prepare(item, question)
    }

    /// Raw logits are exposed for numerical parity fixtures, not through the public HTTP API.
    public func logits(_ rows: [LayaPreparedRow]) throws -> [[Float]] {
        try collect(launch(rows), rows: rows)
    }

    /// Build the chunk's inputs and queue its forward on the GPU without waiting.
    private func launch(_ rows: [LayaPreparedRow]) throws -> MLXArray {
        guard !rows.isEmpty, rows.count <= 64 else { throw LayaError.invalid("Expected 1...64 Laya rows") }
        let length = paddedLength(rows)
        let count = max(2, rows.map { $0.markers.count }.max()!)
        var ids = [Int32](repeating: Int32(prompt.padID), count: rows.count * length)
        var valid = [Bool](repeating: false, count: ids.count)
        var positions = [Int32](repeating: 0, count: rows.count * count)
        var markerMask = [Bool](repeating: false, count: positions.count)
        for (i, row) in rows.enumerated() {
            for (j, token) in row.ids.enumerated() { ids[i * length + j] = Int32(token); valid[i * length + j] = true }
            for (j, marker) in row.markers.enumerated() { positions[i * count + j] = Int32(marker); markerMask[i * count + j] = true }
        }
        let inputs = [MLXArray(ids, [rows.count, length]), MLXArray(valid, [rows.count, length]), MLXArray(positions, [rows.count, count]), MLXArray(markerMask, [rows.count, count]), MLXArray(rows.map { Int32($0.qtype) })]
        return network.launch(inputs)
    }

    /// Sequence length a chunk is padded to. fp16 rounds up to a bucket (VERDICT_LAYA_PAD_MULTIPLE, default 16, for
    /// chunks of <= 8 rows; VERDICT_LAYA_BUCKET, default 8, above); quantized models keep exact lengths.
    /// Still worth it without compile (fewer distinct shapes for MLX's kernel and buffer reuse), measured
    /// 24 Sep: jobs batches 22-23% vs 42-44% helper CPU at the same items/s; single items 4.3 vs 5.1 ms
    /// CPU and 7.5 vs 7.9 ms wall p50.
    private func paddedLength(_ rows: [LayaPreparedRow]) -> Int {
        let length = rows.map { $0.ids.count }.max() ?? 0
        guard fp16 else { return length }
        let step = rows.count <= 8 ? Self.padMultiple : Self.bucketAll
        return step > 1 ? (length + step - 1) / step * step : length
    }

    /// Wait for a launched chunk and split its logits per row.
    private func collect(_ output: MLXArray, rows: [LayaPreparedRow]) throws -> [[Float]] {
        let count = max(2, rows.map { $0.markers.count }.max()!)
        let flat = output.asArray(Float.self)
        guard flat.allSatisfy(\.isFinite) else { throw LayaError.invalid("Non-finite model outputs; retry with dtype='float32'") }
        return rows.indices.map { Array(flat[($0 * count)..<($0 * count + count)]) }
    }

    public func tokenCount(_ item: Item, _ questions: [Question]) throws -> Int {
        // worker.py's backend.encode() defaults to adding tokenizer special tokens.
        encode(item.text, addSpecialTokens: true).count + (questions.map { encode($0.sourceJSON ?? Self.questionJSON($0), addSpecialTokens: true).count }.max() ?? 0) + 8
    }

    public func predict(_ items: [Item], _ questions: [Question]) throws -> [ItemResult] {
        guard !questions.isEmpty else { throw LayaError.invalid("questions must be a nonempty object") }
        let clock = ContinuousClock(), t0 = clock.now
        let prepared = try questions.map(cachedQuestion)
        let questionCount = prepared.map(\.count).max() ?? 0
        let templates = prepared.map(\.template)
        var results = Array(repeating: ItemResult.answers([:]), count: items.count)
        var answers = Array(repeating: [String: Answer](), count: items.count)
        var rows: [LayaPreparedRow] = [], metadata: [(Int, Question)] = []
        let states = encodeStates(items.map(\.text))
        for (i, _) in items.enumerated() {
            let state = states[i]
            let count = state.count + questionCount + 8
            if count > contextLimit {
                results[i] = .error("Item needs about \(count) tokens; \(id) accepts \(contextLimit). Shorten it or split it.")
                continue
            }
            for (question, template) in zip(questions, templates) {
                rows.append(prompt.row(stateIDs: state.ids, template: template))
                metadata.append((i, question))
            }
        }
        let t1 = clock.now
        var gpu = Duration.zero, padded = 0
        // fp16: chunk rows in length order so each 64-row forward pads only to similar lengths.
        // Not always bit-identical to the Python worker's arrival-order chunks: MLX picks matmul tiling
        // from the chunk's total size (e.g. M*N >= 2^20), so a row in a small chunk (a lone tail row) can
        // differ in the 4th decimal (measured 11/1261 random batched items, max 0.0031; arrival order,
        // VERDICT_LAYA_ARRIVAL_ORDER=1, matched 1261/1261). Quantized (8/4-bit) keep arrival order.
        let order = Self.sortByLength && fp16 ? rows.indices.sorted { (rows[$0].ids.count, $0) < (rows[$1].ids.count, $1) } : Array(rows.indices)
        // Double-buffered: queue chunk k+1 on the GPU before waiting for chunk k, so the CPU encodes the
        // next graph while the GPU runs the current one. Same computation, only scheduling changes.
        // At most two chunks are in flight, which bounds activation memory.
        func finish(_ slots: [Int], _ output: MLXArray) throws {
            let chunk = slots.map { rows[$0] }
            let values = try collect(output, rows: chunk)
            for (r, row) in chunk.enumerated() {
                let (index, question) = metadata[slots[r]]
                answers[index][question.id] = answer(values[r], optionCount: row.markers.count, question: question)
            }
        }
        let g = clock.now
        var inflight: ([Int], MLXArray)? = nil
        for slots in chunks(order, rows: rows) {
            let chunk = slots.map { rows[$0] }
            let output = try launch(chunk)
            padded += chunk.count * paddedLength(chunk)
            if let (previous, previousOutput) = inflight { try finish(previous, previousOutput) }
            inflight = (slots, output)
        }
        if let (previous, previousOutput) = inflight { try finish(previous, previousOutput) }
        gpu = clock.now - g
        for i in items.indices { if case .answers = results[i] { results[i] = .answers(answers[i]) } }
        if Self.profile {
            let total = clock.now - t0, real = rows.reduce(0) { $0 + $1.ids.count }
            func ms(_ d: Duration) -> String { String(format: "%.1f", Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000) }
            FileHandle.standardError.write(Data("profile \(id) items=\(items.count) rows=\(rows.count) tokens=\(real) padded=\(padded) prepare=\(ms(t1 - t0))ms forward=\(ms(gpu))ms post=\(ms(total - (t1 - t0) - gpu))ms total=\(ms(total))ms\n".utf8))
        }
        return results
    }

    /// Tokenize item texts across CPU cores. Same tokenizer function, same tokens; the
    /// tokenizer (swift-transformers PreTrainedTokenizer) is Sendable with read-only state.
    /// Serial below ~8 items or ~4 KB of text, where thread hand-off costs more than it saves.
    private func encodeStates(_ texts: [String]) -> [(ids: [Int], count: Int)] {
        let prompt = self.prompt, bytes = texts.reduce(0) { $0 + $1.utf8.count }
        // The fast tokenizer encodes ~5 MB/s per core: go parallel only when a serial pass would take
        // several milliseconds; below that, thread hand-off and word-cache locking cost more CPU than they save.
        let threshold = prompt.hasFastTokenizer ? Self.parallelBytesFast : 4096   // fast: serial measured best (35% vs 50% CPU, same speed)
        if texts.count < 8 || bytes < threshold { return texts.map { prompt.encodeState($0) } }
        var out = [(ids: [Int], count: Int)](repeating: ([], 0), count: texts.count)
        out.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: texts.count) { i in base[i] = prompt.encodeState(texts[i]) }
        }
        return out
    }

    /// Chunks of at most 64 rows. At fp16 (length-sorted) a chunk also closes when its padded size would
    /// exceed the token budget, so a request of long items cannot allocate gigabytes of activations at once.
    /// Quantized models keep plain 64-row chunks in arrival order (their results depend on chunk shape).
    private func chunks(_ order: [Int], rows: [LayaPreparedRow]) -> [[Int]] {
        guard fp16, Self.sortByLength else { return stride(from: 0, to: order.count, by: 64).map { Array(order[$0..<min($0 + 64, order.count)]) } }
        var out: [[Int]] = [], current: [Int] = []
        for slot in order {
            let length = rows[slot].ids.count   // ascending, so this row sets the padded length
            if !current.isEmpty && (current.count == 64 || (current.count + 1) * length > Self.tokenBudget) { out.append(current); current = [] }
            current.append(slot)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private func cachedQuestion(_ question: Question) throws -> (template: LayaPrompt.QuestionTemplate, count: Int) {
        let json = question.sourceJSON ?? Self.questionJSON(question), key = Data(json.utf8)
        if let hit = questionCache[key] { return hit }
        let value = (template: try prompt.template(question), count: encode(json, addSpecialTokens: true).count)
        if questionCache.count >= 512 { questionCache.removeAll(keepingCapacity: true) }
        questionCache[key] = value
        return value
    }

    private func answer(_ logits: [Float], optionCount k: Int, question: Question) -> Answer {
        let bucket = k <= 2 ? "2" : k <= 5 ? "3-5" : k <= 10 ? "6-10" : "11+"
        let temperature = Float(temperatureBuckets[question.kind.rawValue + ":" + bucket] ?? temperatures[typeIndex(question)])
        let z = logits.prefix(k).map { $0 / temperature }, maxZ = z.max()!
        let exponents = z.map { exp($0 - maxZ) }, total = exponents.reduce(Float(0), +)
        let p = exponents.map { $0 / total }
        let entropy = -p.reduce(Float(0)) { $0 + $1 * log(min(1, max(1e-12, $1))) }
        // NumPy's weak scalar promotion keeps this expression in float32.
        let confidence: Float = k < 2 ? 1 : min(1, max(0, 1 - entropy / Float(log(Double(k)))))
        func rounded(_ value: Double) -> Double { (value * 10000).rounded(.toNearestOrEven) / 10000 }
        var result = Answer(); result.confidence = rounded(Double(confidence))
        switch question.kind {
        case .noul:
            result.noul = rounded(Double(p[1])); result.confidence = rounded(max(Double(p[1]), 1 - Double(p[1])))
        case .choice:
            let winner = p.firstIndex(of: p.max()!)!
            result.choice = question.criteria[winner].0
            result.probabilities = Dictionary(uniqueKeysWithValues: zip(question.criteria, p).map { ($0.0.0, rounded(Double($0.1))) })
        case .score:
            result.score = rounded(p.enumerated().reduce(0) { $0 + Double($1.offset) * Double($1.element) })
            result.probabilities = Dictionary(uniqueKeysWithValues: p.enumerated().map { (String($0.offset), rounded(Double($0.element))) })
        }
        return result
    }

    // Ordered Python json.dumps(... ensure_ascii=False) for ordinary client Question shapes.
    // The service should retain raw question JSON for arbitrary criteria shapes / key order.
    static func questionJSON(_ question: Question) -> String {
        func quote(_ s: String) -> String {
            let bytes = try! JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            return String(decoding: bytes, as: UTF8.self)
        }
        var fields = ["\"type\": " + quote(question.kind.rawValue), "\"instructions\": " + quote(question.instructions)]
        switch question.kind {
        case .choice:
            fields.append("\"criteria\": {" + question.criteria.map { quote($0.0) + ": " + quote($0.1) }.joined(separator: ", ") + "}")
        case .score:
            fields.append("\"criteria\": [" + question.criteria.map { quote($0.1) }.joined(separator: ", ") + "]")
        case .noul:
            if !question.criteria.isEmpty { fields.append("\"criteria\": {" + question.criteria.map { quote($0.0) + ": " + quote($0.1) }.joined(separator: ", ") + "}") }
        }
        return "{" + fields.joined(separator: ", ") + "}"
    }
}
