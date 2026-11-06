import Foundation
import HTTPKit

/// A compiled route path: literal segments, `:name` / `{name}` params and a trailing `*`.
public struct PathPattern: Hashable, Sendable {
    enum Segment: Hashable, Sendable {
        case literal(String)
        case param(String)
        case wildcard
    }

    let segments: [Segment]

    public init(_ path: String) {
        segments = PathPattern.split(path).map { part in
            if part == "*" { return .wildcard }
            if part.hasPrefix(":") && part.count > 1 { return .param(String(part.dropFirst())) }
            if part.hasPrefix("{") && part.hasSuffix("}") && part.count > 2 {
                return .param(String(part.dropFirst().dropLast()))
            }
            return .literal(part)
        }
    }

    static func split(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Joins a prefix and a path into one normalized `/a/b` path.
    public static func join(_ parts: String...) -> String {
        "/" + parts.flatMap(split).joined(separator: "/")
    }

    /// Path params when the path matches, nil otherwise.
    public func match(_ path: String) -> [String: String]? {
        let parts = PathPattern.split(path)
        var params: [String: String] = [:]
        for (index, segment) in segments.enumerated() {
            switch segment {
            case .wildcard:
                params["*"] = parts.dropFirst(index).joined(separator: "/")
                return params
            case .literal(let text):
                guard index < parts.count, parts[index] == text else { return nil }
            case .param(let name):
                guard index < parts.count else { return nil }
                params[name] = parts[index]
            }
        }
        return parts.count == segments.count ? params : nil
    }

    /// Higher for more literal paths, so `users/me` beats `users/:id`.
    var specificity: Int {
        segments.reduce(0) { total, segment in
            switch segment {
            case .literal: return total * 3 + 2
            case .param: return total * 3 + 1
            case .wildcard: return total * 3
            }
        }
    }

    var hasWildcard: Bool { segments.contains(.wildcard) }
}

/// Everything rules and templates can read from a request.
public struct RequestContext: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var params: [String: String]
    public var bodyText: String
    public var cookies: [String: String]
    /// The body parsed as JSON or as a form, when possible.
    public var bodyJSON: JSONValue?

    public init(request: HTTPRequest, params: [String: String] = [:]) {
        method = request.method
        path = request.path
        query = request.query
        headers = request.headers
        self.params = params
        bodyText = String(decoding: request.body, as: UTF8.self)
        cookies = RequestContext.parseCookies(request.headers["cookie"] ?? "")
        bodyJSON = RequestContext.parseBody(bodyText, contentType: request.headers["content-type"] ?? "")
    }

    static func parseCookies(_ header: String) -> [String: String] {
        var cookies: [String: String] = [:]
        for pair in header.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let name = kv.first?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            cookies[name] = kv.count > 1 ? kv[1].trimmingCharacters(in: .whitespaces) : ""
        }
        return cookies
    }

    static func parseBody(_ text: String, contentType: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let json = try? JSONValue.parse(trimmed) { return json }
        if contentType.contains("x-www-form-urlencoded") {
            var pairs: [(String, JSONValue)] = []
            for pair in trimmed.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let decode: (Substring) -> String = {
                    let s = $0.replacingOccurrences(of: "+", with: " ")
                    return s.removingPercentEncoding ?? s
                }
                pairs.append((decode(kv[0]), .string(kv.count > 1 ? decode(kv[1]) : "")))
            }
            return .object(JSONObject(pairs))
        }
        return nil
    }

    /// A dot path into the parsed body: `user.roles.0`. Empty returns the whole body.
    public func bodyValue(at keyPath: String) -> JSONValue? {
        guard !keyPath.isEmpty else { return bodyJSON ?? (bodyText.isEmpty ? nil : .string(bodyText)) }
        var current = bodyJSON
        for key in keyPath.split(separator: ".").map(String.init) {
            guard let value = current else { return nil }
            if let index = Int(key), let item = value[index] {
                current = item
            } else {
                current = value[key]
            }
        }
        return current
    }

    /// The text a rule compares, or nil when the value is missing.
    func value(for target: RuleTarget, key: String) -> String? {
        switch target {
        case .query: return key.isEmpty ? (query.isEmpty ? nil : query.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "&")) : query[key]
        case .header: return headers[key.lowercased()]
        case .cookie: return cookies[key]
        case .params: return params[key]
        case .path: return path
        case .method: return method
        case .body: return bodyValue(at: key).map(RequestContext.text)
        }
    }

    /// Plain text for strings, JSON for everything else.
    static func text(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return s
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number: return value.serialized()
        default: return value.serialized()
        }
    }
}

enum RuleEvaluator {
    static func matches(_ rule: MockRule, in context: RequestContext) -> Bool {
        let actual = context.value(for: rule.target, key: rule.key)
        let result: Bool
        switch rule.op {
        case .exists:
            result = actual != nil
        case .equals:
            if let actual {
                if actual == rule.value {
                    result = true
                } else if rule.target == .body, case .array(let items)? = context.bodyValue(at: rule.key) {
                    // An array body value matches when one of its items equals the rule value.
                    result = items.contains { RequestContext.text($0) == rule.value }
                } else {
                    result = false
                }
            } else {
                result = false
            }
        case .contains:
            result = actual?.localizedCaseInsensitiveContains(rule.value) ?? false
        case .regex:
            if let actual, let regex = try? NSRegularExpression(pattern: rule.value) {
                result = regex.firstMatch(in: actual, range: NSRange(actual.startIndex..., in: actual)) != nil
            } else {
                result = false
            }
        }
        return rule.invert ? !result : result
    }

    static func matches(_ response: MockResponse, in context: RequestContext) -> Bool {
        guard !response.rules.isEmpty else { return false }
        switch response.rulesOperator {
        case .and: return response.rules.allSatisfy { matches($0, in: context) }
        case .or: return response.rules.contains { matches($0, in: context) }
        }
    }
}
