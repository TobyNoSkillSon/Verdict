import Foundation

/// A JSON value that keeps object key order and number literals exactly as written. Item text depends on both: the
/// models read a JSON object item as its rendered text, so `{"b":1,"a":2.0}` must reach them as written, not
/// reordered or with `2.0` turned into `2`.
///
/// Strings and object keys compare by their exact UTF-8 bytes (Swift's `String ==` would equate "é" and "e\u{301}";
/// the API keeps them distinct).
public indirect enum JSON: Sendable, Hashable {
    case null
    case bool(Bool)
    /// The number's literal text (validated JSON number syntax).
    case number(String)
    case string(String)
    case array([JSON])
    case object([Member])

    public struct Member: Sendable, Hashable {
        public var key: String
        public var value: JSON
        public init(_ key: String, _ value: JSON) { self.key = key; self.value = value }
        public static func == (a: Member, b: Member) -> Bool { exactlyEqual(a.key, b.key) && a.value == b.value }
        public func hash(into hasher: inout Hasher) { hashExactly(key, into: &hasher); hasher.combine(value) }
    }

    public static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.number(x), .number(y)): return exactlyEqual(x, y)
        case let (.string(x), .string(y)): return exactlyEqual(x, y)
        case let (.array(x), .array(y)): return x == y
        case let (.object(x), .object(y)): return x == y
        default: return false
        }
    }
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case .bool(let b): hasher.combine(1); hasher.combine(b)
        case .number(let n): hasher.combine(2); hashExactly(n, into: &hasher)
        case .string(let s): hasher.combine(3); hashExactly(s, into: &hasher)
        case .array(let a): hasher.combine(4); hasher.combine(a)
        case .object(let m): hasher.combine(5); hasher.combine(m)
        }
    }

    public init(_ value: Int) { self = .number(String(value)) }
    public init(_ value: Double) { self = .number(value.isFinite ? "\(value)" : "null") }

    /// Member lookup (first member with exactly these key bytes) for objects; nil otherwise.
    public subscript(key: String) -> JSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { exactlyEqual($0.key, key) }?.value
    }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var double: Double? { if case .number(let n) = self { return Double(n) }; return nil }
    public var int: Int? { if case .number(let n) = self { return Int(n) ?? Double(n).flatMap { $0 == $0.rounded() ? Int(exactly: $0) : nil } }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    public var members: [Member]? { if case .object(let m) = self { return m }; return nil }
    public var isNull: Bool { self == .null }

    // MARK: Parsing

    public struct ParseError: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Parses one JSON document (UTF-8). Duplicate keys are kept in order, as written.
    public static func parse(_ data: Data) throws -> JSON {
        var parser = Parser(bytes: Array(data))
        parser.skipSpace()
        let value = try parser.value(depth: 0)
        parser.skipSpace()
        guard parser.index == parser.bytes.count else { throw parser.error("trailing characters") }
        return value
    }
    public static func parse(_ text: String) throws -> JSON { try parse(Data(text.utf8)) }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        func error(_ what: String) -> ParseError { ParseError(message: "invalid JSON: \(what) at byte \(index)") }
        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }
        mutating func literal(_ word: String, _ value: JSON) throws -> JSON {
            let utf8 = Array(word.utf8)
            guard index + utf8.count <= bytes.count, Array(bytes[index..<index + utf8.count]) == utf8 else { throw error("unexpected token") }
            index += utf8.count
            return value
        }
        mutating func value(depth: Int) throws -> JSON {
            guard depth < 512 else { throw error("nesting too deep") }
            guard index < bytes.count else { throw error("unexpected end") }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1; skipSpace()
                var members: [Member] = []
                if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                while true {
                    skipSpace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("expected a key") }
                    let key = try string()
                    skipSpace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("expected ':'") }
                    index += 1; skipSpace()
                    members.append(Member(key, try value(depth: depth + 1)))
                    skipSpace()
                    guard index < bytes.count else { throw error("unexpected end") }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                    throw error("expected ',' or '}'")
                }
            case UInt8(ascii: "["):
                index += 1; skipSpace()
                var values: [JSON] = []
                if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(values) }
                while true {
                    skipSpace()
                    values.append(try value(depth: depth + 1))
                    skipSpace()
                    guard index < bytes.count else { throw error("unexpected end") }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(values) }
                    throw error("expected ',' or ']'")
                }
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): return try literal("true", .bool(true))
            case UInt8(ascii: "f"): return try literal("false", .bool(false))
            case UInt8(ascii: "n"): return try literal("null", .null)
            default: return .number(try number())
            }
        }
        mutating func number() throws -> String {
            let start = index
            func digits() -> Int { let s = index; while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }; return index - s }
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count else { throw error("unexpected end") }
            if bytes[index] == UInt8(ascii: "0") { index += 1 } else if digits() == 0 { throw error("unexpected character") }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") { index += 1; guard digits() > 0 else { throw error("bad number") } }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard digits() > 0 else { throw error("bad number") }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else { throw error("bad \\u escape") }
            index += 4
            return v
        }
        mutating func string() throws -> String {
            index += 1   // opening quote
            var out = [UInt8]()
            while true {
                guard index < bytes.count else { throw error("unterminated string") }
                let b = bytes[index]
                if b == UInt8(ascii: "\"") { index += 1; break }
                if b < 0x20 { throw error("control character in string") }
                if b != UInt8(ascii: "\\") { out.append(b); index += 1; continue }
                index += 1
                guard index < bytes.count else { throw error("unterminated string") }
                let e = bytes[index]; index += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800...0xDBFF).contains(scalar), index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        let save = index
                        index += 2
                        let low = try hex4()
                        if (0xDC00...0xDFFF).contains(low) { scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00) } else { index = save }
                    }
                    // A lone surrogate cannot be UTF-8; it becomes U+FFFD (as Foundation does).
                    out.append(contentsOf: Array(String(Character(Unicode.Scalar(scalar) ?? "\u{FFFD}")).utf8))
                default: throw error("bad escape")
                }
            }
            return String(decoding: out, as: UTF8.self)
        }
    }

    // MARK: Rendering

    /// Compact JSON (`{"a":1}`), non-ASCII kept as UTF-8.
    public var compact: String { var out = ""; write(&out, itemSeparator: ",", keySeparator: ":", indent: nil, level: 0); return out }
    /// Python `json.dumps(value, ensure_ascii=False)` layout: `{"a": 1, "b": [1, 2]}`.
    public var spaced: String { var out = ""; write(&out, itemSeparator: ", ", keySeparator: ": ", indent: nil, level: 0); return out }
    /// Python `json.dumps(value, indent=2, ensure_ascii=False)` layout.
    public var pretty: String { var out = ""; write(&out, itemSeparator: ",", keySeparator: ": ", indent: 2, level: 0); return out }

    public static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    private func write(_ out: inout String, itemSeparator: String, keySeparator: String, indent: Int?, level: Int) {
        func newline(_ level: Int) { if let indent { out += "\n" + String(repeating: " ", count: indent * level) } }
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s): out += Self.quote(s)
        case .array(let values):
            if values.isEmpty { out += "[]"; return }
            out += "["
            for (i, v) in values.enumerated() {
                if i > 0 { out += itemSeparator }
                newline(level + 1)
                v.write(&out, itemSeparator: itemSeparator, keySeparator: keySeparator, indent: indent, level: level + 1)
            }
            newline(level); out += "]"
        case .object(let members):
            if members.isEmpty { out += "{}"; return }
            out += "{"
            for (i, m) in members.enumerated() {
                if i > 0 { out += itemSeparator }
                newline(level + 1)
                out += Self.quote(m.key) + keySeparator
                m.value.write(&out, itemSeparator: itemSeparator, keySeparator: keySeparator, indent: indent, level: level + 1)
            }
            newline(level); out += "}"
        }
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral,
                ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public typealias Key = String
    public typealias Value = JSON
    public typealias ArrayLiteralElement = JSON
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self.init(value) }
    public init(floatLiteral value: Double) { self.init(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    /// Keeps the literal's key order.
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(elements.map { Member($0.0, $0.1) }) }
    public init(nilLiteral: ()) { self = .null }
}

extension JSON: Codable {
    private struct CodingName: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    public init(from decoder: Decoder) throws {
        if let object = try? decoder.container(keyedBy: CodingName.self) {
            self = .object(try object.allKeys.map { Member($0.stringValue, try object.decode(JSON.self, forKey: $0)) })
            return
        }
        if var array = try? decoder.unkeyedContainer() {
            var values: [JSON] = []
            while !array.isAtEnd { values.append(try array.decode(JSON.self)) }
            self = .array(values); return
        }
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { self = .null }
        else if let b = try? single.decode(Bool.self) { self = .bool(b) }
        else if let i = try? single.decode(Int.self) { self = .number(String(i)) }
        else if let d = try? single.decode(Double.self) { self.init(d) }
        else { self = .string(try single.decode(String.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .object(let members):
            var c = encoder.container(keyedBy: CodingName.self)
            for m in members { try c.encode(m.value, forKey: CodingName(stringValue: m.key)) }
        case .array(let values):
            var c = encoder.unkeyedContainer()
            for v in values { try c.encode(v) }
        case .null: var c = encoder.singleValueContainer(); try c.encodeNil()
        case .bool(let b): var c = encoder.singleValueContainer(); try c.encode(b)
        case .string(let s): var c = encoder.singleValueContainer(); try c.encode(s)
        case .number(let n):
            var c = encoder.singleValueContainer()
            if let i = Int(n) { try c.encode(i) } else { try c.encode(Double(n) ?? 0) }
        }
    }
}
