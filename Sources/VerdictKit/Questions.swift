import Foundation

/// A typed question, in the TypeSafe/Laya wire format (`{"type": …, "instructions": …, "criteria": …}`).
///
///     .noul("Does the customer ask for money back?")
///     .choice("Which team should handle this?", ["billing": "charges, refunds", "tech": "bugs, outages", "other": "none of these"])
///     .score("How urgent is this?", levels: ["routine", "this week", "blocking today"])
public struct Question: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable { case choice, score, noul }

    /// Choice options and Noul `true`/`false` descriptions: labels with descriptions (`nil` = JSON null, the bare
    /// label), or bare labels (a JSON list: each label is its own description). Score levels are always a list.
    public enum Criteria: Sendable, Hashable {
        case none
        case labels([String])
        case described([Criterion])
    }
    public struct Criterion: Sendable, Hashable {
        public var label: String
        public var description: String?
        public init(_ label: String, _ description: String?) { self.label = label; self.description = description }
    }

    public var kind: Kind
    public var instructions: String
    public var criteria: Criteria

    public init(kind: Kind, instructions: String, criteria: Criteria = .none) {
        self.kind = kind; self.instructions = instructions; self.criteria = criteria
    }

    /// One of several named options, in order. Include an escape option (`other`, `unclear`).
    public static func choice(_ instructions: String, _ options: KeyValuePairs<String, String>) -> Question {
        Question(kind: .choice, instructions: instructions, criteria: .described(options.map { Criterion($0.key, $0.value) }))
    }
    /// Options that are their own descriptions.
    public static func choice(_ instructions: String, labels: [String]) -> Question {
        Question(kind: .choice, instructions: instructions, criteria: .described(labels.map { Criterion($0, $0) }))
    }
    /// An ordered rubric, lowest level first; the answer is the expected level 0…n-1.
    public static func score(_ instructions: String, levels: [String]) -> Question {
        Question(kind: .score, instructions: instructions, criteria: .labels(levels))
    }
    /// A yes/no proposition; the answer is P(true).
    public static func noul(_ instructions: String) -> Question { Question(kind: .noul, instructions: instructions) }
    /// A yes/no proposition with descriptions of what counts as `true` and `false`.
    public static func noul(_ instructions: String, criteria: KeyValuePairs<String, String>) -> Question {
        Question(kind: .noul, instructions: instructions, criteria: .described(criteria.map { Criterion($0.key, $0.value) }))
    }

    /// Choice labels or score levels, in order.
    public var labels: [String] {
        switch criteria {
        case .none: return []
        case .labels(let l): return l
        case .described(let c): return c.map(\.label)
        }
    }

    /// The wire format.
    public var json: JSON {
        var members: [JSON.Member] = [.init("type", .string(kind.rawValue)), .init("instructions", .string(instructions))]
        switch criteria {
        case .none: break
        case .labels(let labels): members.append(.init("criteria", .array(labels.map(JSON.string))))
        case .described(let list): members.append(.init("criteria", .object(list.map { .init($0.label, $0.description.map(JSON.string) ?? .null) })))
        }
        return .object(members)
    }

    /// From the wire format (a questions file). Unknown types are refused with the helper's message.
    public init(json: JSON) throws {
        guard json.members != nil else { throw VerdictError.invalidRequest("a question must be an object") }
        let type = json["type"]?.string ?? json["type"]?.compact ?? ""
        guard let kind = Kind(rawValue: type) else { throw VerdictError.invalidRequest("Unknown question type '\(type)'") }
        self.kind = kind
        instructions = json["instructions"]?.string ?? ""
        switch json["criteria"] {
        case .array(let values)?: criteria = .labels(values.map { $0.string ?? $0.compact })
        case .object(let members)?: criteria = .described(members.map { Criterion($0.key, $0.value.isNull ? nil : ($0.value.string ?? $0.value.compact)) })
        default: criteria = .none
        }
    }

    public init(from decoder: Decoder) throws { try self.init(json: try JSON(from: decoder)) }
    public func encode(to encoder: Encoder) throws { try json.encode(to: encoder) }
}

/// Questions by id, in order. Every question is answered for every item in one pass.
///
///     let questions: Questions = ["refund": .noul("Does the writer ask for money back?"),
///                                 "dept": .choice("Which team?", ["billing": "charges", "other": "anything else"])]
public struct Questions: Sendable, Hashable, Codable, ExpressibleByDictionaryLiteral {
    public typealias Key = String
    public typealias Value = Question
    public struct Entry: Sendable, Hashable {
        public var id: String
        public var question: Question
    }
    public private(set) var entries: [Entry]

    /// Keeps the literal's order.
    public init(dictionaryLiteral elements: (String, Question)...) { entries = elements.map { Entry(id: $0.0, question: $0.1) } }
    public init(_ entries: [(String, Question)]) { self.entries = entries.map { Entry(id: $0.0, question: $0.1) } }
    /// A dictionary has no order: ids are sorted.
    public init(_ dictionary: [String: Question]) { entries = dictionary.sorted { $0.key < $1.key }.map { Entry(id: $0.key, question: $0.value) } }
    /// From a questions file: `{"id": {"type": …, "instructions": …, "criteria": …}, …}`.
    public init(json: JSON) throws {
        guard let members = json.members, !members.isEmpty else { throw VerdictError.invalidRequest("questions must be a nonempty object") }
        entries = try members.map { Entry(id: $0.key, question: try Question(json: $0.value)) }
    }

    public subscript(id: String) -> Question? { entries.first { $0.id == id }?.question }
    public var ids: [String] { entries.map(\.id) }
    public var isEmpty: Bool { entries.isEmpty }
    public var json: JSON { .object(entries.map { .init($0.id, $0.question.json) }) }

    public init(from decoder: Decoder) throws { try self.init(json: try JSON(from: decoder)) }
    public func encode(to encoder: Encoder) throws { try json.encode(to: encoder) }

    /// Question shapes that usually judge badly: counting and dates, "and/or" in one yes/no, choices without an escape
    /// option or with more than 20 options, bare-degree score levels. One warning per problem; never refuses.
    public func lint() -> [String] {
        let escapes = ["other", "none", "unclear", "unknown", "neither", "n/a", "not applicable", "something else"]
        let bare: Set<String> = ["low", "medium", "high", "small", "large", "weak", "strong", "bad", "good", "ok", "poor"]
        func matches(_ pattern: String, _ text: String) -> Bool {
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        var out: [String] = []
        for entry in entries {
            let q = entry.question, name = entry.id
            if matches(#"\b(how many|count|number of|total|sum|date|what year|when did)\b"#, q.instructions) {
                out.append("\(name): the model does not count or do dates well — ask one yes/no per item and sum in code")
            }
            if q.kind == .noul && matches(#"\b(and|or)\b"#, q.instructions) {
                out.append("\(name): \"and/or\" in a yes/no question mixes judgements — split it into two questions")
            }
            if q.kind == .choice {
                let labels = q.labels.map { $0.lowercased() }
                if labels.count > 20 { out.append("\(name): \(labels.count) options; accuracy drops past ~20 — use a two-stage choice") }
                if !labels.contains(where: { label in escapes.contains { label.contains($0) } }) {
                    out.append("\(name): no escape option (other / unclear / none) — the model is forced to pick one of \(labels)")
                }
            }
            if q.kind == .score {
                let levels = q.labels.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
                if levels.allSatisfy({ bare.contains($0) }) {
                    out.append("\(name): score levels are bare degrees (\(levels)); describe each as a checkable situation")
                }
            }
        }
        return out
    }
}

/// One item to judge: text, or a JSON value (name the fields: `{"subject": …, "body": …}`). Laya reads an object as
/// its JSON text, Von as `key: value` lines; a string stays a string even when it looks like JSON.
public struct Item: Sendable, Hashable, ExpressibleByStringLiteral, ExpressibleByDictionaryLiteral {
    public typealias Key = String
    public typealias Value = JSON
    public var json: JSON
    public init(_ text: String) { json = .string(text) }
    public init(json: JSON) { self.json = json }
    public init(stringLiteral value: String) { json = .string(value) }
    /// Keeps the literal's key order.
    public init(dictionaryLiteral elements: (String, JSON)...) { json = .object(elements.map { JSON.Member($0.0, $0.1) }) }
}
