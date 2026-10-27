import Foundation

/// A JSON object that keeps keys in the order they arrived.
/// Clients send tables and model attributes as objects, and their order matters on screen.
public struct JSONObject: Hashable {
    public private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    public init() {}

    public init(_ pairs: [(String, JSONValue)]) {
        for (key, value) in pairs { self[key] = value }
    }

    public subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage[key] == nil { keys.append(key) }
                storage[key] = newValue
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var pairs: [(key: String, value: JSONValue)] { keys.map { ($0, storage[$0]!) } }
    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }
}

public indirect enum JSONValue: Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let array) = self, array.indices.contains(index) { return array[index] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    public var int: Int? { double.map { Int($0) } }
    public var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        default: return nil
        }
    }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var object: JSONObject? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    /// Text form of a value: strings without quotes, everything else as compact JSON.
    public var displayString: String {
        switch self {
        case .string(let s): return s
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return JSONValue.format(n)
        default: return serialized()
        }
    }

    static func format(_ n: Double) -> String {
        if n.isFinite, n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        return String(n)
    }
}

// MARK: - Parsing

public struct JSONParseError: Error, CustomStringConvertible {
    public let offset: Int
    public let reason: String
    public var description: String { "JSON parse error at \(offset): \(reason)" }
}

extension JSONValue {
    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = Parser(bytes: [UInt8](data))
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw parser.error("trailing characters") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        func error(_ reason: String) -> JSONParseError { JSONParseError(offset: index, reason: reason) }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
        }

        mutating func parseValue(depth: Int) throws -> JSONValue {
            guard depth < 512 else { throw error("nesting too deep") }
            guard index < bytes.count else { throw error("unexpected end") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return try parseNumber()
            }
        }

        mutating func expect(_ word: String) throws {
            let w = Array(word.utf8)
            guard index + w.count <= bytes.count, Array(bytes[index..<index + w.count]) == w else {
                throw error("expected \(word)")
            }
            index += w.count
        }

        mutating func parseObject(depth: Int) throws -> JSONValue {
            index += 1
            var object = JSONObject()
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("expected key") }
                let key = try parseString()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("expected :") }
                index += 1
                skipWhitespace()
                object[key] = try parseValue(depth: depth + 1)
                skipWhitespace()
                guard index < bytes.count else { throw error("unterminated object") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
                throw error("expected , or }")
            }
        }

        mutating func parseArray(depth: Int) throws -> JSONValue {
            index += 1
            var array: [JSONValue] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(array) }
            while true {
                skipWhitespace()
                array.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw error("unterminated array") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(array) }
                throw error("expected , or ]")
            }
        }

        mutating func parseHex4() throws -> UInt32 {
            guard index + 4 <= bytes.count,
                  let s = String(bytes: bytes[index..<index + 4], encoding: .ascii),
                  let v = UInt32(s, radix: 16) else { throw error("bad \\u escape") }
            index += 4
            return v
        }

        mutating func parseString() throws -> String {
            index += 1
            var out = [UInt8]()
            while index < bytes.count {
                let b = bytes[index]
                if b == UInt8(ascii: "\"") {
                    index += 1
                    return String(decoding: out, as: UTF8.self)
                }
                if b == UInt8(ascii: "\\") {
                    index += 1
                    guard index < bytes.count else { break }
                    let e = bytes[index]
                    index += 1
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
                        var code = try parseHex4()
                        if (0xD800...0xDBFF).contains(code), index + 6 <= bytes.count,
                           bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                            index += 2
                            let low = try parseHex4()
                            if (0xDC00...0xDFFF).contains(low) {
                                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                            }
                        }
                        let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                        out.append(contentsOf: Array(String(Character(scalar)).utf8))
                    default: throw error("bad escape")
                    }
                    continue
                }
                out.append(b)
                index += 1
            }
            throw error("unterminated string")
        }

        mutating func parseNumber() throws -> JSONValue {
            let start = index
            while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
            guard index > start,
                  let s = String(bytes: bytes[start..<index], encoding: .ascii),
                  let n = Double(s) else { throw error("bad number") }
            return .number(n)
        }
    }
}

// MARK: - Serializing

extension JSONValue {
    public func serialized(pretty: Bool = false) -> String {
        var out = ""
        write(to: &out, pretty: pretty, indent: 0)
        return out
    }

    private func write(to out: inout String, pretty: Bool, indent: Int) {
        let pad = pretty ? String(repeating: "    ", count: indent + 1) : ""
        let closePad = pretty ? String(repeating: "    ", count: indent) : ""
        let nl = pretty ? "\n" : ""
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n.isFinite ? JSONValue.format(n) : "null"
        case .string(let s): JSONValue.writeString(s, to: &out)
        case .array(let a):
            if a.isEmpty { out += "[]"; return }
            out += "[" + nl
            for (i, v) in a.enumerated() {
                out += pad
                v.write(to: &out, pretty: pretty, indent: indent + 1)
                if i < a.count - 1 { out += "," }
                out += nl
            }
            out += closePad + "]"
        case .object(let o):
            if o.isEmpty { out += "{}"; return }
            out += "{" + nl
            for (i, pair) in o.pairs.enumerated() {
                out += pad
                JSONValue.writeString(pair.key, to: &out)
                out += pretty ? ": " : ":"
                pair.value.write(to: &out, pretty: pretty, indent: indent + 1)
                if i < o.count - 1 { out += "," }
                out += nl
            }
            out += closePad + "}"
        }
    }

    private static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(JSONObject(elements)) }
    public init(nilLiteral: ()) { self = .null }
}
