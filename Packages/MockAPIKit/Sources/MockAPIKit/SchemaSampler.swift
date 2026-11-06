import Foundation
import HTTPKit

/// Resolves local `$ref`s (`#/components/schemas/Pet`) inside one spec document.
struct RefResolver {
    let root: JSONValue
    private(set) var externalRefs: Set<String> = []

    init(root: JSONValue) {
        self.root = root
    }

    func lookup(_ ref: String) -> JSONValue? {
        guard ref.hasPrefix("#") else { return nil }
        var current: JSONValue? = root
        for raw in ref.dropFirst().split(separator: "/") {
            let key = String(raw).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            let decoded = key.removingPercentEncoding ?? key
            if let index = Int(decoded), let item = current?[index] {
                current = item
            } else {
                current = current?[decoded]
            }
        }
        return current
    }

    /// Follows `$ref` chains on a single node. Remembers refs to other files.
    mutating func deref(_ value: JSONValue?, depth: Int = 0) -> JSONValue? {
        guard let value, depth < 32, let ref = value["$ref"]?.string else { return value }
        guard let target = lookup(ref) else {
            if !ref.hasPrefix("#") { externalRefs.insert(ref) }
            return nil
        }
        return deref(target, depth: depth + 1)
    }
}

/// Builds an example JSON value from an OpenAPI / JSON Schema.
struct SchemaSampler {
    var resolver: RefResolver
    var maxDepth = 8

    init(resolver: RefResolver) {
        self.resolver = resolver
    }

    mutating func sample(_ schema: JSONValue?, name: String? = nil) -> JSONValue {
        sample(schema, name: name, depth: 0, seen: [])
    }

    private mutating func sample(_ schemaIn: JSONValue?, name: String?, depth: Int, seen: Set<String>) -> JSONValue {
        guard let raw = schemaIn else { return .null }
        var seen = seen
        if let ref = raw["$ref"]?.string {
            // Recursive schemas (a Category with children Categories) stop at the second visit.
            if seen.contains(ref) || depth > maxDepth { return .null }
            seen.insert(ref)
        }
        guard let schema = resolver.deref(raw), depth <= maxDepth else { return .null }

        if let example = schema["example"] { return example }
        if let examples = schema["examples"]?.array, let first = examples.first { return first }
        if let value = schema["const"] { return value }
        if let value = schema["default"] { return value }
        if let values = schema["enum"]?.array, let first = values.first { return first }

        if let all = schema["allOf"]?.array {
            var merged: [(String, JSONValue)] = []
            var other: JSONValue?
            for part in all {
                let value = sample(part, name: name, depth: depth + 1, seen: seen)
                if case .object(let object) = value {
                    for pair in object.pairs where !merged.contains(where: { $0.0 == pair.key }) {
                        merged.append((pair.key, pair.value))
                    }
                } else if other == nil, !value.isNull {
                    other = value
                }
            }
            return merged.isEmpty ? (other ?? .object(JSONObject())) : .object(JSONObject(merged))
        }
        for key in ["oneOf", "anyOf"] {
            if let options = schema[key]?.array, let first = options.first {
                return sample(first, name: name, depth: depth + 1, seen: seen)
            }
        }

        var type = schema["type"]?.string
        if type == nil, case .array(let types)? = schema["type"] {
            type = types.compactMap(\.string).first { $0 != "null" }
        }
        if type == nil {
            if schema["properties"] != nil || schema["additionalProperties"] != nil { type = "object" }
            else if schema["items"] != nil { type = "array" }
        }

        switch type {
        case "object":
            var pairs: [(String, JSONValue)] = []
            for pair in schema["properties"]?.object?.pairs ?? [] {
                pairs.append((pair.key, sample(pair.value, name: pair.key, depth: depth + 1, seen: seen)))
            }
            if pairs.isEmpty, let additional = schema["additionalProperties"], additional.object != nil {
                pairs.append(("key", sample(additional, name: "key", depth: depth + 1, seen: seen)))
            }
            return .object(JSONObject(pairs))
        case "array":
            let item = sample(schema["items"], name: name.map(Self.singular), depth: depth + 1, seen: seen)
            let count = max(1, min(schema["minItems"]?.int ?? 2, 3))
            return .array(Array(repeating: item, count: item.isNull ? 0 : count))
        case "integer":
            return .number(Double(Self.number(schema, name: name, integer: true)))
        case "number":
            return .number(Self.number(schema, name: name, integer: false))
        case "boolean":
            return .bool(true)
        case "string":
            return .string(Self.string(schema, name: name))
        case "null":
            return .null
        default:
            return .string(name.map { Self.string(.object(JSONObject()), name: $0) } ?? "string")
        }
    }

    static func singular(_ name: String) -> String {
        name.hasSuffix("s") && name.count > 1 ? String(name.dropLast()) : name
    }

    static func number(_ schema: JSONValue, name: String?, integer: Bool) -> Double {
        let lower = schema["minimum"]?.double ?? schema["exclusiveMinimum"]?.double
        let upper = schema["maximum"]?.double ?? schema["exclusiveMaximum"]?.double
        let key = (name ?? "").lowercased()
        var value: Double
        if key == "id" || key.hasSuffix("_id") || key.hasSuffix("id") { value = 1 }
        else if key.contains("price") || key.contains("amount") || key.contains("total") { value = 19.99 }
        else if key.contains("age") { value = 32 }
        else if key.contains("year") { value = 2026 }
        else if key.contains("count") || key.contains("quantity") || key.contains("total") { value = 3 }
        else { value = integer ? 1 : 1.5 }
        if let lower, value < lower { value = lower }
        if let upper, value > upper { value = upper }
        return integer ? value.rounded() : value
    }

    static func string(_ schema: JSONValue, name: String?) -> String {
        switch schema["format"]?.string {
        case "date-time": return "2026-01-15T10:30:00Z"
        case "date": return "2026-01-15"
        case "time": return "10:30:00"
        case "email": return "jane.doe@example.com"
        case "uuid": return "3fa85f64-5717-4562-b3fc-2c963f66afa6"
        case "uri", "url": return "https://example.com"
        case "hostname": return "example.com"
        case "ipv4": return "192.168.1.10"
        case "ipv6": return "2001:db8::1"
        case "byte": return "U3dhZ2dlciByb2Nrcw=="
        case "binary": return ""
        case "password": return "secret"
        case "phone": return "+39 333 123 4567"
        default: break
        }
        let key = (name ?? "").lowercased().replacingOccurrences(of: "_", with: "")
        let byName: [(String, String)] = [
            ("email", "jane.doe@example.com"), ("firstname", "Jane"), ("lastname", "Doe"),
            ("username", "janedoe"), ("fullname", "Jane Doe"), ("phone", "+39 333 123 4567"),
            ("city", "Milan"), ("country", "Italy"), ("street", "Via Roma 1"), ("address", "Via Roma 1, Milan"),
            ("zip", "20121"), ("postcode", "20121"), ("url", "https://example.com"), ("website", "https://example.com"),
            ("avatar", "https://i.pravatar.cc/150"), ("image", "https://picsum.photos/640/480"),
            ("token", "eyJhbGciOiJIUzI1NiJ9.mock.token"), ("password", "secret"), ("uuid", "3fa85f64-5717-4562-b3fc-2c963f66afa6"),
            ("createdat", "2026-01-15T10:30:00Z"), ("updatedat", "2026-01-15T10:30:00Z"), ("date", "2026-01-15"),
            ("status", "active"), ("currency", "EUR"), ("color", "#3b82f6"), ("slug", "example-slug"),
            ("title", "Example title"), ("description", "A short description."), ("company", "Acme Inc"),
            ("name", "Example"), ("id", "1"), ("code", "ABC123"), ("message", "OK"),
        ]
        for (fragment, value) in byName where key.contains(fragment) { return value }
        if let min = schema["minLength"]?.int, min > 6 { return String(repeating: "x", count: min) }
        return "string"
    }
}
