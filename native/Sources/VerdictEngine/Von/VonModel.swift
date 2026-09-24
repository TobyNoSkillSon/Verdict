// Port of von-sdk 1.1.1 / 1.2.2 OptionMarkerBackend, no Python at runtime.
import Foundation
import Hub
import Tokenizers
import CoreFoundation

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

public final class VonModel: DecisionModel {
    public let id: String
    public let contextLimit = 8192
    public var residentBytes: Int { network.residentBytes }
    private let tokenizer: any Tokenizer
    private let maskID: Int
    private let maskToken: String
    private let sepToken: String
    private let calibration: [String: Double]
    private let temperature: Double
    private let prior: [String: Double]?
    private let network: VonNetwork

    public init(id: String, snapshot: URL, bits: Int = 0) throws {
        guard ["von-1.1","von-1.2"].contains(id) else { throw VonError.invalid("Unknown Von model '\(id)'") }
        guard bits == 0 else { throw VonError.invalid("Von precision overrides await SDK parity qualification; the default uses original float32 weights") }
        self.id = id
        let decoder = JSONDecoder()
        let configData = try Data(contentsOf: snapshot.appendingPathComponent("tokenizer_config.json"))
        let tokenData = try Data(contentsOf: snapshot.appendingPathComponent("tokenizer.json"))
        tokenizer = try AutoTokenizer.from(tokenizerConfig: decoder.decode(Config.self, from: configData), tokenizerData: decoder.decode(Config.self, from: tokenData))
        let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any] ?? [:]
        guard let mask = config["mask_token"] as? String, let sep = config["sep_token"] as? String,
              let maskID = tokenizer.convertTokenToId(mask) else { throw VonError.invalid("Von tokenizer is missing MASK/SEP") }
        maskToken = mask; sepToken = sep; self.maskID = maskID
        let cdata = try JSONSerialization.jsonObject(with: Data(contentsOf: snapshot.appendingPathComponent("marker_calibration.json"))) as? [String: Any] ?? [:]
        guard let t = cdata["temperature"] as? Double, t > 0, t.isFinite,
              let map = cdata["calibration_map"] as? [String: Double],
              ["bias","entropy","log_tokens","n_options","lo","hi"].allSatisfy({ map[$0]?.isFinite == true }) else {
            throw VonError.invalid("Invalid Von calibration")
        }
        temperature = t; calibration = map
        prior = cdata["noul_zero_shot_prior"] as? [String: Double]
        guard (cdata["independent_options"] as? Bool ?? false) == (id == "von-1.2") else { throw VonError.invalid("Von independent-options flag disagrees with catalog version") }
        network = try VonNetwork(snapshot: snapshot, id: id)
    }
    public func encode(_ text: String, addSpecialTokens: Bool = true) -> [Int] {
        tokenizer.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    private func state(_ item: Item) -> String {
        // The helper preserves an ordered JSON rendering. SDK _format_state for
        // dict items enumerates insertion-order top-level fields as key: value.
        guard item.text.first == "{", let pairs = VonJSON.topLevel(item.text) else { return item.text }
        return pairs.map { "\($0.0): \(VonJSON.pythonValue($0.1))" }.joined(separator: "\n")
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
    private func packed(_ state: String, _ question: Question) -> String {
        pack(state, question.instructions, descriptions(question).1)
    }
    private func pack(_ state: String, _ instructions: String, _ options: [String]) -> String {
        let prefix = instructions.isEmpty ? state.trimmingCharacters(in: .whitespacesAndNewlines) : (instructions + " " + state).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(prefix) \(sepToken) \(options.map { "\(maskToken) \($0.trimmingCharacters(in: .whitespacesAndNewlines))" }.joined(separator: " "))"
    }
    public func prepare(_ item: Item, _ question: Question) throws -> VonPreparedRow {
        try row(packed(state(item), question))
    }
    private func row(_ packed: String) throws -> VonPreparedRow {
        let ids = encode(packed)
        let markers = ids.indices.filter { ids[$0] == maskID }
        guard !markers.isEmpty else { throw VonError.invalid("Von question needs option markers") }
        return VonPreparedRow(ids: ids, markers: markers)
    }
    public func logits(_ rows: [VonPreparedRow]) throws -> [[Float]] {
        guard !rows.isEmpty, rows.count <= 64 else { throw VonError.invalid("Expected 1...64 Von rows") }
        let values = try network.forward(rows.flatMap { $0.ids.map(Int32.init) }, rows.map { $0.ids.count }, rows.map(\.markers))
        if ProcessInfo.processInfo.environment["VERDICT_VON_PARITY_TRACE"] == "1" {
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
        return values
    }
    public func tokenCount(_ item: Item, _ questions: [Question]) throws -> Int {
        let s = state(item)
        return questions.map { encode(packed(s,$0)).count }.max() ?? 0
    }
    private func rounded(_ value: Double, digits: Double = 10000) -> Double { (value * digits).rounded(.toNearestOrEven) / digits }
    private func answer(_ logits: [Float], state: String, question: Question, null: Float?) -> Answer {
        var values = logits
        if let null { values[0] -= null }
        let k = values.count
        let maxLogit = values.max()!
        let baseline = values.map { expf($0 - maxLogit) }
        let baselineSum = baseline.reduce(Float(0),+)
        let raw = baseline.map { $0 / baselineSum }
        let entropy = k < 2 ? 0 : Double(-raw.reduce(Float(0)) { $0 + $1 * logf(max(1e-12,$1)) }) / log(Double(k))
        let tokens = max(1,encode(state,addSpecialTokens:false).count)
        let temp = min(calibration["hi"]!,max(calibration["lo"]!,calibration["bias"]! + calibration["entropy"]!*entropy + calibration["log_tokens"]!*log10(Double(tokens))/4 + calibration["n_options"]!*Double(k)/8))
        let scaled = values.map { $0 / Float(max(temp,1e-4)) }
        let biggest = scaled.max()!, exponent = scaled.map { expf($0-biggest) }, total = exponent.reduce(Float(0),+)
        let p = exponent.map { Double($0 / total) }
        let keys = descriptions(question).0
        let sorted = p.sorted(by: >)
        let confidence = id == "von-1.1" ? sorted[0] - (sorted.count > 1 ? sorted[1] : 0) :
            (k <= 1 ? 1 : (Double(k)*sorted[0]-1)/Double(k-1))
        var a = Answer()
        switch question.kind {
        case .noul:
            a.noul = rounded(min(1,max(0,p[0])))
            a.confidence = rounded(max(p[0],1-p[0]))
        case .choice:
            a.choice = keys[values.firstIndex(of: values.max()!)!]
            a.probabilities = Dictionary(uniqueKeysWithValues: zip(keys,p).map { ($0.0,rounded($0.1)) })
            a.confidence = rounded(max(0,min(1,confidence)),digits:1000)
        case .score:
            a.probabilities = Dictionary(uniqueKeysWithValues: zip(keys,p).map { ($0.0,rounded($0.1)) })
            a.score = rounded(p.enumerated().reduce(0) { $0 + Double($1.offset)*$1.element },digits:100)
            a.confidence = rounded(max(0,min(1,confidence)),digits:1000)
        }
        return a
    }
    public func predict(_ items: [Item], _ questions: [Question]) throws -> [ItemResult] {
        guard !questions.isEmpty else { throw VonError.invalid("Questions must be nonempty") }
        var results = [[String: Answer]](repeating: [:],count: items.count)
        var errors: [Int:String] = [:]
        var rows: [VonPreparedRow] = [], meta: [(Int,Question)] = []
        let states = items.map(state)
        for (i,s) in states.enumerated() {
            let prepared = try questions.map { try row(packed(s,$0)) }
            let count = prepared.map { $0.ids.count }.max() ?? 0
            if count > contextLimit { errors[i] = "Item needs about \(count) tokens; Von accepts \(contextLimit)."; continue }
            for (q,r) in zip(questions,prepared) { rows.append(r); meta.append((i,q)) }
        }
        var nulls: [String:Float] = [:]
        for q in questions where q.kind == .noul && q.criteria.allSatisfy({ $0.1.isEmpty }) {
            let null = try row(pack("",q.instructions,descriptions(q).1))
            let lg = try logits([null])[0]
            let bias = lg[0] - lg[1]
            nulls[q.id] = prior.map { Float($0["a"] ?? 0)*bias + Float($0["b"] ?? 0) } ?? 0.7*bias
        }
        for start in stride(from:0,to:rows.count,by:64) {
            let end = min(rows.count,start+64)
            let values = try logits(Array(rows[start..<end]))
            for (r,lg) in values.enumerated() {
                let (i,q) = meta[start+r]
                results[i][q.id] = answer(lg,state:states[i],question:q,null:nulls[q.id])
            }
        }
        return items.indices.map { errors[$0].map(ItemResult.error) ?? .answers(results[$0]) }
    }
}

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
    static func pythonValue(_ json: String) -> String {
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
