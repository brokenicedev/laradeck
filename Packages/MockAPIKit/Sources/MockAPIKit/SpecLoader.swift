import Foundation
import HTTPKit
import Yams

public enum MockImportError: LocalizedError, Equatable {
    case unreadable(String)
    case unknownFormat
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let reason): return "The file can't be read: \(reason)"
        case .unknownFormat: return "This isn't an OpenAPI/Swagger spec, a Postman collection or a Laradeck mock export."
        case .invalid(let reason): return reason
        }
    }
}

/// Parses JSON or YAML into `JSONValue`, keeping key order.
public enum SpecLoader {
    public static func parse(_ data: Data) throws -> JSONValue {
        if let json = try? JSONValue.parse(data) { return json }
        guard let text = String(data: data, encoding: .utf8) else {
            throw MockImportError.unreadable("not UTF-8 text")
        }
        do {
            guard let node = try Yams.compose(yaml: text) else { throw MockImportError.unreadable("empty document") }
            return convert(node)
        } catch let error as MockImportError {
            throw error
        } catch {
            throw MockImportError.unreadable("\(error)")
        }
    }

    static func convert(_ node: Node) -> JSONValue {
        switch node {
        case .mapping(let mapping):
            var pairs: [(String, JSONValue)] = []
            for (key, value) in mapping {
                pairs.append((key.string ?? key.any.map { "\($0)" } ?? "", convert(value)))
            }
            return .object(JSONObject(pairs))
        case .sequence(let sequence):
            return .array(sequence.map(convert))
        case .scalar(let scalar):
            switch Tag.Name(rawValue: node.tag.rawValue) {
            case .null: return .null
            case .bool: return node.bool.map(JSONValue.bool) ?? .string(scalar.string)
            case .int: return node.int.map { .number(Double($0)) } ?? .string(scalar.string)
            case .float: return node.float.map(JSONValue.number) ?? .string(scalar.string)
            default: return .string(scalar.string)
            }
        case .alias:
            return .null
        }
    }
}

private extension Node {
    var any: Any? { scalar?.string }
}
