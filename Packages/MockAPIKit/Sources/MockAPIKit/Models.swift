import Foundation

/// One mock API: a port, some global settings and a list of routes.
public struct MockServer: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var port: Int
    /// Start this server when Laradeck launches.
    public var autoStart: Bool
    /// Path prefix shared by every route, e.g. `api/v1`.
    public var prefix: String
    /// Delay added to every response, in milliseconds.
    public var latencyMs: Int
    public var cors: Bool
    /// Headers added to every response (route headers win).
    public var headers: [MockHeader]
    public var routes: [MockRoute]
    /// Optional link to a Laradeck project.
    public var projectId: UUID?
    public var notes: String
    /// Where this server was imported from (file name), if any.
    public var source: String?

    public init(
        id: UUID = UUID(), name: String, port: Int, autoStart: Bool = false, prefix: String = "",
        latencyMs: Int = 0, cors: Bool = true, headers: [MockHeader] = [], routes: [MockRoute] = [],
        projectId: UUID? = nil, notes: String = "", source: String? = nil
    ) {
        self.id = id
        self.name = name
        self.port = port
        self.autoStart = autoStart
        self.prefix = prefix
        self.latencyMs = latencyMs
        self.cors = cors
        self.headers = headers
        self.routes = routes
        self.projectId = projectId
        self.notes = notes
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Mock API"
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 3001
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        latencyMs = try c.decodeIfPresent(Int.self, forKey: .latencyMs) ?? 0
        cors = try c.decodeIfPresent(Bool.self, forKey: .cors) ?? true
        headers = try c.decodeIfPresent([MockHeader].self, forKey: .headers) ?? []
        routes = try c.decodeIfPresent([MockRoute].self, forKey: .routes) ?? []
        projectId = try c.decodeIfPresent(UUID.self, forKey: .projectId)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }
}

public struct MockHeader: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var value: String

    public init(id: UUID = UUID(), name: String, value: String) {
        self.id = id
        self.name = name
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
    }
}

public enum ResponseMode: String, Codable, CaseIterable, Sendable {
    /// First response whose rules match, otherwise the default one.
    case rules
    /// Responses in turn, one per request.
    case sequential
    case random
}

public enum RulesOperator: String, Codable, CaseIterable, Sendable {
    case and
    case or
}

public struct MockRoute: Codable, Hashable, Identifiable, Sendable {
    public static let methods = ["ANY", "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    public var id: UUID
    public var enabled: Bool
    /// Upper-cased HTTP method, or `ANY`.
    public var method: String
    /// Path below the server prefix, e.g. `users/:id`. Also accepts `{id}` and a trailing `*`.
    public var path: String
    public var notes: String
    public var responseMode: ResponseMode
    public var responses: [MockResponse]

    public init(
        id: UUID = UUID(), enabled: Bool = true, method: String, path: String, notes: String = "",
        responseMode: ResponseMode = .rules, responses: [MockResponse] = []
    ) {
        self.id = id
        self.enabled = enabled
        self.method = method.uppercased()
        self.path = path
        self.notes = notes
        self.responseMode = responseMode
        self.responses = responses
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        method = (try c.decodeIfPresent(String.self, forKey: .method) ?? "GET").uppercased()
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        responseMode = try c.decodeIfPresent(ResponseMode.self, forKey: .responseMode) ?? .rules
        responses = try c.decodeIfPresent([MockResponse].self, forKey: .responses) ?? []
    }

    /// The response used when no rule matches.
    public var defaultResponse: MockResponse? {
        responses.first(where: \.isDefault) ?? responses.first
    }
}

public struct MockResponse: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var status: Int
    public var headers: [MockHeader]
    public var body: String
    /// Render `{{…}}` tags in the body and header values.
    public var templating: Bool
    public var latencyMs: Int
    public var rules: [MockRule]
    public var rulesOperator: RulesOperator
    public var isDefault: Bool

    public init(
        id: UUID = UUID(), label: String = "", status: Int = 200, headers: [MockHeader] = [], body: String = "",
        templating: Bool = true, latencyMs: Int = 0, rules: [MockRule] = [], rulesOperator: RulesOperator = .and,
        isDefault: Bool = false
    ) {
        self.id = id
        self.label = label
        self.status = status
        self.headers = headers
        self.body = body
        self.templating = templating
        self.latencyMs = latencyMs
        self.rules = rules
        self.rulesOperator = rulesOperator
        self.isDefault = isDefault
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        status = try c.decodeIfPresent(Int.self, forKey: .status) ?? 200
        headers = try c.decodeIfPresent([MockHeader].self, forKey: .headers) ?? []
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        templating = try c.decodeIfPresent(Bool.self, forKey: .templating) ?? true
        latencyMs = try c.decodeIfPresent(Int.self, forKey: .latencyMs) ?? 0
        rules = try c.decodeIfPresent([MockRule].self, forKey: .rules) ?? []
        rulesOperator = try c.decodeIfPresent(RulesOperator.self, forKey: .rulesOperator) ?? .and
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }

    /// Short name for lists: the label, or the status code.
    public var displayName: String {
        label.isEmpty ? "\(status)" : "\(status) · \(label)"
    }
}

public enum RuleTarget: String, Codable, CaseIterable, Sendable {
    case query, header, body, params, cookie, path, method
}

public enum RuleOperator: String, Codable, CaseIterable, Sendable {
    case equals, contains, regex, exists
}

/// A condition on the request, e.g. "query `status` equals `sold`".
public struct MockRule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var target: RuleTarget
    /// Query/header/cookie/param name, or a dot path into a JSON body (`user.roles.0`). Empty means the whole value.
    public var key: String
    public var op: RuleOperator
    public var value: String
    public var invert: Bool

    public init(id: UUID = UUID(), target: RuleTarget, key: String = "", op: RuleOperator = .equals, value: String = "", invert: Bool = false) {
        self.id = id
        self.target = target
        self.key = key
        self.op = op
        self.value = value
        self.invert = invert
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        target = try c.decodeIfPresent(RuleTarget.self, forKey: .target) ?? .query
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        op = try c.decodeIfPresent(RuleOperator.self, forKey: .op) ?? .equals
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
    }
}

/// One request seen by a mock server, for the log.
public struct MockLogEntry: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var date: Date
    public var method: String
    public var path: String
    public var rawQuery: String
    public var requestHeaders: [String: String]
    public var requestBody: String
    public var status: Int
    public var responseHeaders: [MockHeader]
    public var responseBody: String
    public var routeId: UUID?
    public var responseId: UUID?
    public var responseLabel: String?
    public var durationMs: Int

    public var matched: Bool { routeId != nil }
    public var fullPath: String { rawQuery.isEmpty ? path : "\(path)?\(rawQuery)" }
}
