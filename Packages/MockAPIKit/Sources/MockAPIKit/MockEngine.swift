import Foundation
import HTTPKit

/// Answers requests for one mock server and remembers per-route state (sequential counters).
public actor MockEngine {
    public private(set) var server: MockServer
    private var compiled: [(route: MockRoute, pattern: PathPattern)] = []
    private var counters: [UUID: Int] = [:]
    /// Lets tests skip the configured delays.
    private let applyLatency: Bool

    public init(server: MockServer, applyLatency: Bool = true) {
        self.server = server
        self.applyLatency = applyLatency
        compiled = Self.compile(server)
    }

    public func update(_ server: MockServer) {
        self.server = server
        compiled = Self.compile(server)
        let ids = Set(server.routes.map(\.id))
        counters = counters.filter { ids.contains($0.key) }
    }

    private static func compile(_ server: MockServer) -> [(route: MockRoute, pattern: PathPattern)] {
        server.routes
            .filter(\.enabled)
            .map { ($0, PathPattern(PathPattern.join(server.prefix, $0.path))) }
    }

    public struct Result: Sendable {
        public var response: HTTPResponse
        public var log: MockLogEntry
    }

    public func handle(_ request: HTTPRequest) async -> Result {
        let started = Date()
        let resolved = resolve(request)
        let delay = server.latencyMs + (resolved.response?.latencyMs ?? 0)
        if applyLatency && delay > 0 {
            try? await Task.sleep(for: .milliseconds(delay))
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let log = MockLogEntry(
            date: started,
            method: request.method,
            path: request.path,
            rawQuery: request.rawQuery,
            requestHeaders: request.headers,
            requestBody: Self.preview(request.body),
            status: resolved.http.status,
            responseHeaders: resolved.http.headers.map { MockHeader(name: $0.0, value: $0.1) },
            responseBody: Self.preview(resolved.http.body),
            routeId: resolved.route?.id,
            responseId: resolved.response?.id,
            responseLabel: resolved.response?.displayName,
            durationMs: elapsed
        )
        return Result(response: resolved.http, log: log)
    }

    struct Resolved {
        var http: HTTPResponse
        var route: MockRoute?
        var response: MockResponse?
    }

    func resolve(_ request: HTTPRequest) -> Resolved {
        let method = request.method.uppercased()
        let isHead = method == "HEAD"

        // Candidates whose path matches, most specific first, then in declared order.
        let pathMatches = compiled.enumerated().compactMap { index, entry -> (Int, MockRoute, PathPattern, [String: String])? in
            guard let params = entry.pattern.match(request.path) else { return nil }
            return (index, entry.route, entry.pattern, params)
        }
        .sorted { lhs, rhs in
            if lhs.2.specificity != rhs.2.specificity { return lhs.2.specificity > rhs.2.specificity }
            return lhs.0 < rhs.0
        }

        func accepts(_ route: MockRoute, _ m: String) -> Bool { route.method == "ANY" || route.method == m }
        let match = pathMatches.first { accepts($0.1, method) }
            ?? (isHead ? pathMatches.first { accepts($0.1, "GET") } : nil)

        guard let (_, route, _, params) = match else {
            if method == "OPTIONS" && server.cors {
                return Resolved(http: HTTPResponse(status: 204, headers: [("Access-Control-Max-Age", "86400")]))
            }
            if !pathMatches.isEmpty {
                let allowed = Set(pathMatches.map(\.1.method)).sorted().joined(separator: ", ")
                return Resolved(http: Self.error(405, "No mock for \(method) \(request.path)", extra: [("Allow", allowed)]))
            }
            return Resolved(http: Self.error(404, "No mock route matches \(method) \(request.path)"))
        }

        let context = RequestContext(request: request, params: params)
        guard let response = select(route, context: context, request: request) else {
            return Resolved(http: Self.error(500, "Route \(route.method) \(route.path) has no responses"), route: route)
        }

        var http = build(response, context: context)
        if isHead { http.body = Data() }
        return Resolved(http: http, route: route, response: response)
    }

    /// Picks the response for a request. `x-mock-response-name` / `x-mock-response-code` (as in Postman) force one.
    func select(_ route: MockRoute, context: RequestContext, request: HTTPRequest) -> MockResponse? {
        guard !route.responses.isEmpty else { return nil }
        if let name = request.headers["x-mock-response-name"],
           let forced = route.responses.first(where: { $0.label.caseInsensitiveCompare(name) == .orderedSame }) {
            return forced
        }
        if let code = request.headers["x-mock-response-code"].flatMap(Int.init),
           let forced = route.responses.first(where: { $0.status == code }) {
            return forced
        }
        switch route.responseMode {
        case .rules:
            return route.responses.first { RuleEvaluator.matches($0, in: context) } ?? route.defaultResponse
        case .sequential:
            let index = counters[route.id, default: 0]
            counters[route.id] = index + 1
            return route.responses[index % route.responses.count]
        case .random:
            return route.responses.randomElement()
        }
    }

    func build(_ response: MockResponse, context: RequestContext) -> HTTPResponse {
        let renderer = TemplateRenderer(context: context)
        let render: (String) -> String = { response.templating ? renderer.render($0) : $0 }

        var headers: [(String, String)] = []
        var seen = Set<String>()
        // Route headers first, then server-wide ones that the route didn't set.
        for header in response.headers + server.headers where !header.name.isEmpty {
            let key = header.name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            headers.append((header.name, render(header.value)))
        }
        let body = render(response.body)
        if !seen.contains("content-type") && !body.isEmpty {
            headers.append(("Content-Type", Self.guessContentType(body)))
        }
        return HTTPResponse(status: response.status, headers: headers, body: Data(body.utf8))
    }

    static func guessContentType(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return "application/json; charset=utf-8" }
        if trimmed.hasPrefix("<") { return trimmed.lowercased().hasPrefix("<?xml") ? "application/xml; charset=utf-8" : "text/html; charset=utf-8" }
        return "text/plain; charset=utf-8"
    }

    static func error(_ status: Int, _ message: String, extra: [(String, String)] = []) -> HTTPResponse {
        var response = HTTPResponse.json(.object(JSONObject([("error", .string(message))])), status: status)
        response.headers.append(contentsOf: extra)
        return response
    }

    /// Bodies kept in the log are capped so a big upload doesn't fill memory.
    static func preview(_ data: Data, limit: Int = 64 * 1024) -> String {
        guard data.count > limit else { return String(decoding: data, as: UTF8.self) }
        return String(decoding: data.prefix(limit), as: UTF8.self) + "\n… (\(data.count) bytes)"
    }
}
