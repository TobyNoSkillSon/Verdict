// Checkpoint-specific, CPU-only prompt preparation. No model weights/GPU initialization.
import Foundation
import Tokenizers
import Hub

public final class LayaPrompt {
    struct QuestionTemplate {
        let prefix: [Int]
        let markers: [Int]
        let qtype: Int
    }

    private let tokenizer: any Tokenizer
    private let fastTokenizer: FastByteBPE?
    private let clsID: Int, sepID: Int, maskID: Int
    let padID: Int
    private let maskToken: String
    private let headMaxLength: Int
    private let singleSpecialTokenCount: Int
    public let contextLimit = 8192

    public init(snapshot: URL) throws {
        let agent = try JSONSerialization.jsonObject(with: Data(contentsOf: snapshot.appendingPathComponent("rl_agent_config.json"))) as? [String: Any] ?? [:]
        headMaxLength = agent["head_max_len"] as? Int ?? 192
        guard headMaxLength > 4, headMaxLength < contextLimit else { throw LayaError.invalid("Invalid head_max_len") }
        let dir = snapshot.appendingPathComponent("tokenizer")
        let configData = try Data(contentsOf: dir.appendingPathComponent("tokenizer_config.json"))
        let tokenData = try Data(contentsOf: dir.appendingPathComponent("tokenizer.json"))
        let decoder = JSONDecoder()
        let loaded = try AutoTokenizer.from(tokenizerConfig: decoder.decode(Config.self, from: configData), tokenizerData: decoder.decode(Config.self, from: tokenData))
        tokenizer = loaded
        fastTokenizer = FastByteBPE(data: tokenData)
        // Both shipped checkpoint post-processors add exactly [CLS, SEP] (or
        // <bos, eos>) to a single sequence. Check at load rather than assuming
        // that future tokenizer revisions preserve this shortcut.
        singleSpecialTokenCount = loaded.encode(text: "", addSpecialTokens: true).count
            - loaded.encode(text: "", addSpecialTokens: false).count
        guard singleSpecialTokenCount == 2 else { throw LayaError.invalid("Unsupported Laya tokenizer post-processor") }
        let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any] ?? [:]
        func special(_ name: String) throws -> (String, Int) {
            let value = config[name] as? String ?? (config[name] as? [String: Any])?["content"] as? String
            guard let text = value, let id = loaded.convertTokenToId(text) else { throw LayaError.invalid("Tokenizer is missing a valid \(name)") }
            return (text, id)
        }
        (_, clsID) = try special("cls_token"); (_, sepID) = try special("sep_token")
        (_, padID) = try special("pad_token"); (maskToken, maskID) = try special("mask_token")
    }
    public func encode(_ text: String, addSpecialTokens: Bool = false) -> [Int] {
        fastTokenizer?.encode(text, addSpecialTokens: addSpecialTokens)
            ?? tokenizer.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    /// Encode the state once for all of its question rows. Context counting
    /// uses the original text; only sequence construction removes a literal
    /// mask token. That rare case needs a separate count to preserve Python.
    public func encodeState(_ text: String) -> (ids: [Int], count: Int) {
        if text.contains(maskToken) {
            return (encode(text.replacingOccurrences(of: maskToken, with: " ")),
                    encode(text, addSpecialTokens: true).count)
        }
        let ids = encode(text)
        return (ids, ids.count + singleSpecialTokenCount)
    }
    private func options(_ question: Question) throws -> [String] {
        switch question.kind {
        case .choice:
            guard !question.criteria.isEmpty else { throw LayaError.invalid("Choice criteria must be a nonempty dictionary or list") }
            guard Set(question.criteria.map(\.0)).count == question.criteria.count else { throw LayaError.invalid("Choice labels must be unique") }
            return question.criteria.map { $0.1.isEmpty ? $0.0 : "\($0.0): \($0.1)" }
        case .score:
            guard !question.criteria.isEmpty else { throw LayaError.invalid("Score criteria must be a nonempty list") }
            return question.criteria.enumerated().map { "level \($0.offset): \($0.element.1)" }
        case .noul:
            let a = question.criteria.first { $0.0 == "false" }?.1 ?? "", b = question.criteria.first { $0.0 == "true" }?.1 ?? ""
            return ["false: " + (a.isEmpty ? "no, the statement does not hold" : a), "true: " + (b.isEmpty ? "yes, the statement holds" : b)]
        }
    }
    func template(_ question: Question) throws -> QuestionTemplate {
        let renderedOptions = try options(question)
        func clean(_ text: String) -> String { text.replacingOccurrences(of: maskToken, with: " ") }
        var head = encode("\(question.kind.rawValue) question: \(clean(question.instructions))")
        var optionIDs = renderedOptions.map { [maskID] + Array(encode(" " + clean($0)).prefix(48)) }
        var budget = headMaxLength - optionIDs.reduce(0) { $0 + $1.count }
        if budget < 16 {
            let per = max(4, (headMaxLength - 16) / max(1, optionIDs.count))
            optionIDs = optionIDs.map { Array($0.prefix(per)) }
            budget = headMaxLength - optionIDs.reduce(0) { $0 + $1.count }
        }
        head = Array(head.prefix(max(8, budget)))
        var prefix = [clsID] + head + [sepID], markers: [Int] = []
        for option in optionIDs { markers.append(prefix.count); prefix += option }
        prefix.append(sepID)
        markers = markers.filter { $0 < contextLimit }
        guard markers.count == renderedOptions.count else { throw LayaError.invalid("Question '\(question.id)' has too many options for the token budget") }
        let qtype: Int = switch question.kind { case .choice: 0; case .score: 1; case .noul: 2 }
        return QuestionTemplate(prefix: prefix, markers: markers, qtype: qtype)
    }
    func row(stateIDs: [Int], template: QuestionTemplate) -> LayaPreparedRow {
        let room = max(0, contextLimit - template.prefix.count - 1)
        var ids = template.prefix
        ids += stateIDs.prefix(room)
        ids.append(sepID)
        return LayaPreparedRow(ids: Array(ids.prefix(contextLimit)), markers: template.markers, qtype: template.qtype)
    }
    public func prepare(_ item: Item, _ question: Question) throws -> LayaPreparedRow {
        let q = try template(question)
        return row(stateIDs: encodeState(item.text).ids, template: q)
    }
}
