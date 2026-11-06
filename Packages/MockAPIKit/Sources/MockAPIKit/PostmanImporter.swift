import Foundation
import HTTPKit

/// Turns a Postman Collection (v2.0 / v2.1) into a mock server.
///
/// Like Postman's own mock servers, every saved example of a request becomes a response.
/// When examples differ by query string, rules are added so each example answers its own query.
struct PostmanImporter {
    let root: JSONValue
    var warnings: [String] = []
    /// Collection variables, used to expand `{{baseUrl}}`.
    let variables: [String: String]

    init(root: JSONValue) {
        self.root = root
        var vars: [String: String] = [:]
        for variable in root["variable"]?.array ?? [] {
            if let key = variable["key"]?.string { vars[key] = variable["value"]?.displayString ?? "" }
        }
        variables = vars
    }

    static func canImport(_ root: JSONValue) -> Bool {
        if root["info"]?["schema"]?.string?.contains("getpostman.com") == true { return true }
        if root["info"]?["_postman_id"] != nil { return true }
        return root["info"] != nil && root["item"]?.array != nil
    }

    mutating func makeServer(port: Int) throws -> MockServer {
        guard let items = root["item"]?.array else { throw MockImportError.invalid("The collection has no requests.") }
        var server = MockServer(name: root["info"]?["name"]?.string ?? "Postman collection", port: port)
        server.notes = root["info"]?["description"]?.displayString ?? ""
        var routes: [MockRoute] = []
        walk(items, folder: [], into: &routes)
        server.routes = routes
        if routes.isEmpty { warnings.append("No requests found in the collection.") }
        return server
    }

    private mutating func walk(_ items: [JSONValue], folder: [String], into routes: inout [MockRoute]) {
        for item in items {
            let name = item["name"]?.string ?? ""
            if let children = item["item"]?.array {
                walk(children, folder: folder + [name], into: &routes)
            } else if let request = item["request"] {
                add(item: item, request: request, name: (folder + [name]).filter { !$0.isEmpty }.joined(separator: " / "), into: &routes)
            }
        }
    }

    private mutating func add(item: JSONValue, request: JSONValue, name: String, into routes: inout [MockRoute]) {
        let method = (request["method"]?.string ?? "GET").uppercased()
        let path = Self.convertPath(path(of: request["url"]))

        var responses: [MockResponse] = []
        let examples = item["response"]?.array ?? []
        let queries = examples.map { example -> [String: String] in
            query(of: example["originalRequest"]?["url"])
        }
        // Query keys whose value changes between examples: they tell examples apart.
        let distinguishing = Set(queries.flatMap(\.keys)).filter { key in
            Set(queries.map { $0[key] ?? "" }).count > 1
        }

        for (index, example) in examples.enumerated() {
            let status = example["code"]?.int ?? 200
            var headers: [MockHeader] = []
            for header in example["header"]?.array ?? [] where header["disabled"]?.bool != true {
                guard let key = header["key"]?.string, !Self.skippedHeaders.contains(key.lowercased()) else { continue }
                headers.append(MockHeader(name: key, value: header["value"]?.displayString ?? ""))
            }
            let body = example["body"]?.displayString ?? ""
            if !headers.contains(where: { $0.name.lowercased() == "content-type" }) {
                let language = example["_postman_previewlanguage"]?.string
                if language == "json" || (try? JSONValue.parse(body)) != nil && !body.isEmpty {
                    headers.insert(MockHeader(name: "Content-Type", value: "application/json"), at: 0)
                }
            }
            let rules = distinguishing.sorted().compactMap { key -> MockRule? in
                guard let value = queries[index][key] else { return nil }
                return MockRule(target: .query, key: key, op: .equals, value: value)
            }
            responses.append(MockResponse(
                label: example["name"]?.string ?? "",
                status: status,
                headers: headers,
                body: Self.prettify(body),
                templating: false,
                rules: rules
            ))
        }

        if responses.isEmpty {
            warnings.append("\(method) /\(path) has no saved examples: answering 200 with an empty JSON object.")
            responses.append(MockResponse(label: "Placeholder", status: 200,
                                          headers: [MockHeader(name: "Content-Type", value: "application/json")],
                                          body: "{}"))
        }

        let defaultIndex = responses.firstIndex { (200..<300).contains($0.status) } ?? 0
        responses[defaultIndex].isDefault = true

        // Postman collections often repeat a request; merge them into one route.
        if let existing = routes.firstIndex(where: { $0.method == method && $0.path == path }) {
            for var response in responses {
                response.isDefault = false
                routes[existing].responses.append(response)
            }
            return
        }
        routes.append(MockRoute(method: method, path: path, notes: name, responses: responses))
    }

    static let skippedHeaders: Set<String> = ["content-length", "connection", "date", "transfer-encoding", "content-encoding", "keep-alive"]

    /// Path part of a Postman URL (string or object), with variables expanded where they hold a base URL.
    func path(of url: JSONValue?) -> String {
        guard let url else { return "" }
        if let parts = url["path"]?.array {
            let segments = parts.map { $0.string ?? $0["value"]?.displayString ?? "" }
            // The host may be `{{baseUrl}}` holding a path too, e.g. https://api.test/v1.
            let hostPath = (url["host"]?.array?.compactMap(\.string).joined(separator: ".")).map(pathOfHost) ?? ""
            return ([hostPath] + segments).filter { !$0.isEmpty }.joined(separator: "/")
        }
        let raw = url.string ?? url["raw"]?.string ?? ""
        return pathOfRaw(raw)
    }

    private func pathOfHost(_ host: String) -> String {
        let expanded = expand(host)
        guard expanded.contains("/") else { return "" }
        return pathOfRaw(expanded)
    }

    func pathOfRaw(_ raw: String) -> String {
        var text = expand(raw)
        if let q = text.firstIndex(where: { $0 == "?" || $0 == "#" }) { text = String(text[..<q]) }
        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
            text = text.firstIndex(of: "/").map { String(text[$0...]) } ?? ""
        } else if let first = text.split(separator: "/").first, first.contains("{{") || first.contains(".") || first.contains(":") && !first.hasPrefix(":") {
            // `{{host}}/users` or `api.test/users`: drop the host part.
            text = text.firstIndex(of: "/").map { String(text[$0...]) } ?? ""
        }
        return PathPattern.split(text).joined(separator: "/")
    }

    /// Replaces `{{var}}` with collection variables that hold a value.
    func expand(_ text: String) -> String {
        var result = text
        for (key, value) in variables where !value.isEmpty {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }

    func query(of url: JSONValue?) -> [String: String] {
        guard let url else { return [:] }
        var result: [String: String] = [:]
        if let items = url["query"]?.array {
            for item in items where item["disabled"]?.bool != true {
                if let key = item["key"]?.string { result[key] = item["value"]?.displayString ?? "" }
            }
            return result
        }
        let raw = url.string ?? url["raw"]?.string ?? ""
        guard let q = raw.firstIndex(of: "?") else { return [:] }
        for pair in raw[raw.index(after: q)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            result[String(kv[0])] = kv.count > 1 ? String(kv[1]) : ""
        }
        return result
    }

    /// `users/{{userId}}` → `users/:userId`; `:id` is kept.
    static func convertPath(_ path: String) -> String {
        PathPattern.split(path).map { segment in
            if segment.hasPrefix("{{") && segment.hasSuffix("}}") {
                return ":" + segment.dropFirst(2).dropLast(2)
            }
            return segment
        }.joined(separator: "/")
    }

    static func prettify(_ body: String) -> String {
        guard let json = try? JSONValue.parse(body) else { return body }
        return json.serialized(pretty: true)
    }
}
