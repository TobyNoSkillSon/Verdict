import Foundation

/// Preserve insertion order when reconstructing Python's json.dumps(..., ensure_ascii=False).
/// Foundation's [String: Any] parsing loses object key order, which changes tokenizer IDs.
indirect enum OrderedJSON {
    case object([(String, OrderedJSON)])
    case array([OrderedJSON])
    case string(String)
    case scalar(String)

    subscript(_ key: String) -> OrderedJSON? {
        if case .object(let fields) = self { return fields.first { $0.0.utf8.elementsEqual(key.utf8) }?.1 }
        return nil
    }
    var arrayValues: [OrderedJSON]? { if case .array(let values) = self { return values }; return nil }
    var fields: [(String, OrderedJSON)]? { if case .object(let entries) = self { return entries }; return nil }
    var text: String? { if case .string(let value) = self { return value }; return nil }
    var isNull: Bool { if case .scalar("null") = self { return true }; return false }
    func render() -> String {
        switch self {
        case .string(let value):
            var out = "\""
            for scalar in value.unicodeScalars {
                switch scalar.value {
                case 34: out += "\\\""
                case 92: out += "\\\\"
                case 8: out += "\\b"
                case 12: out += "\\f"
                case 10: out += "\\n"
                case 13: out += "\\r"
                case 9: out += "\\t"
                case 0..<32: out += String(format: "\\u%04x", scalar.value)
                default: out.unicodeScalars.append(scalar)
                }
            }
            return out + "\""
        case .scalar(let value):
            if value == "-0" { return "0" }
            if value.contains(".") || value.contains("e") || value.contains("E") {
                if let number = Double(value) {
                    if number == .infinity { return "Infinity" }
                    if number == -.infinity { return "-Infinity" }
                    let printed = String(number)
                    // Swift occasionally chooses scientific form below 1e16; Python
                    // repr uses fixed notation for decimal exponents -4...15.
                    if let marker = printed.firstIndex(of: "e"),
                       let exponent = Int(printed[printed.index(after: marker)...]),
                       (-4...15).contains(exponent) {
                        let mantissa = String(printed[..<marker])
                        let negative = mantissa.hasPrefix("-")
                        let unsigned = negative ? String(mantissa.dropFirst()) : mantissa
                        let before = unsigned.prefix(while: { $0 != "." }).count + exponent
                        let digits = unsigned.filter { $0 != "." }
                        let fixed: String
                        if before <= 0 { fixed = "0." + String(repeating: "0", count: -before) + digits }
                        else if before >= digits.count { fixed = digits + String(repeating: "0", count: before - digits.count) + ".0" }
                        else {
                            let split = digits.index(digits.startIndex, offsetBy: before)
                            fixed = String(digits[..<split]) + "." + String(digits[split...])
                        }
                        return (negative ? "-" : "") + fixed
                    }
                    return printed
                }
            }
            return value
        case .array(let values): return "[" + values.map { $0.render() }.joined(separator: ", ") + "]"
        case .object(let pairs): return "{" + pairs.map { OrderedJSON.string($0.0).render() + ": " + $0.1.render() }.joined(separator: ", ") + "}"
        }
    }
}

struct OrderedJSONParser {
    private let bytes: [UInt8]
    private var cursor = 0
    init(_ data: Data) { bytes = Array(data) }
    mutating func parse() throws -> OrderedJSON {
        let result = try value(); space()
        guard cursor == bytes.count else { throw ServiceError("Invalid JSON trailing data") }
        return result
    }
    private mutating func space() { while cursor < bytes.count && [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 } }
    private mutating func take(_ byte: UInt8) throws {
        space(); guard cursor < bytes.count && bytes[cursor] == byte else { throw ServiceError("Invalid JSON") }; cursor += 1
    }
    private mutating func quoted() throws -> String {
        space(); let begin = cursor; try take(34)
        var escaped = false
        while cursor < bytes.count {
            let b = bytes[cursor]; cursor += 1
            if escaped { escaped = false; continue }
            if b == 92 { escaped = true; continue }
            if b == 34 {
                return try JSONDecoder().decode(String.self, from: Data(bytes[begin..<cursor]))
            }
        }
        throw ServiceError("Unterminated JSON string")
    }
    private mutating func value() throws -> OrderedJSON {
        space(); guard cursor < bytes.count else { throw ServiceError("Invalid JSON") }
        switch bytes[cursor] {
        case 34: return .string(try quoted())
        case 123:
            cursor += 1; space()
            if cursor < bytes.count && bytes[cursor] == 125 { cursor += 1; return .object([]) }
            var entries: [(String, OrderedJSON)] = []
            while true {
                let key = try quoted(); try take(58)
                let element = try value()
                // Swift String equality treats canonically equivalent Unicode as equal;
                // Python dict keys do not. Compare UTF-8 sequences instead.
                if let old = entries.firstIndex(where: { $0.0.utf8.elementsEqual(key.utf8) }) { entries[old].1 = element }
                else { entries.append((key, element)) }
                space()
                guard cursor < bytes.count else { throw ServiceError("Invalid JSON object") }
                if bytes[cursor] == 125 { cursor += 1; return .object(entries) }
                try take(44)
            }
        case 91:
            cursor += 1; space()
            if cursor < bytes.count && bytes[cursor] == 93 { cursor += 1; return .array([]) }
            var elements: [OrderedJSON] = []
            while true {
                elements.append(try value()); space()
                guard cursor < bytes.count else { throw ServiceError("Invalid JSON array") }
                if bytes[cursor] == 93 { cursor += 1; return .array(elements) }
                try take(44)
            }
        default:
            let start = cursor
            while cursor < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[cursor]) { cursor += 1 }
            guard cursor > start else { throw ServiceError("Invalid JSON scalar") }
            return .scalar(String(decoding: bytes[start..<cursor], as: UTF8.self))
        }
    }
}

/// Response bodies: keys sorted, numbers in their shortest round-trip form (0.8828, not JSONSerialization's
/// 0.88280000000000003), non-ASCII as UTF-8, `/` unescaped. Keys that differ only by Unicode normalization stay
/// two keys (NSString keys, compared as written).
enum ResponseJSON {
    static func data(_ value: Any) -> Data { var out = ""; write(value, &out); return Data(out.utf8) }
    private static func string(_ s: String, _ out: inout String) { out += OrderedJSON.string(s).render() }
    private static func write(_ value: Any, _ out: inout String) {
        switch value {
        case is NSNull: out += "null"
        case let s as String: string(s, &out)
        case let n as NSDecimalNumber: out += n.stringValue
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { out += n.boolValue ? "true" : "false" }
            else if CFNumberIsFloatType(n) { let d = n.doubleValue; out += d.isFinite ? "\(d)" : "null" }
            else { out += n.stringValue }
        case let d as NSDictionary:
            let keys = d.allKeys.map { "\($0)" }.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            out += "{"
            for (i, key) in keys.enumerated() {
                if i > 0 { out += "," }
                string(key, &out); out += ":"
                write(d[key as NSString] ?? NSNull(), &out)
            }
            out += "}"
        case let a as NSArray:
            out += "["
            for (i, v) in a.enumerated() { if i > 0 { out += "," }; write(v, &out) }
            out += "]"
        default: string(String(describing: value), &out)
        }
    }
}
