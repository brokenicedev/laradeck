import Foundation
import HTTPKit

/// Turns an OpenAPI 3.x or Swagger 2.0 document into a mock server.
///
/// Each operation becomes a route. Each documented response becomes a mock response, one per named example;
/// without examples the body is generated from the schema. The lowest 2xx response is the default.
struct OpenAPIImporter {
    static let methods = ["get", "put", "post", "delete", "options", "head", "patch"]

    let root: JSONValue
    var resolver: RefResolver
    var warnings: [String] = []

    init(root: JSONValue) {
        self.root = root
        resolver = RefResolver(root: root)
    }

    static func canImport(_ root: JSONValue) -> Bool {
        root["openapi"]?.string?.hasPrefix("3") == true || root["swagger"] != nil
    }

    var isSwagger2: Bool { root["swagger"] != nil }

    mutating func makeServer(port: Int) throws -> MockServer {
        guard let paths = root["paths"]?.object else {
            throw MockImportError.invalid("The spec has no `paths`.")
        }
        let title = root["info"]?["title"]?.string ?? "Imported API"
        var server = MockServer(name: title, port: port, prefix: basePath())
        server.notes = root["info"]?["description"]?.string ?? ""

        for (path, rawItem) in paths.pairs {
            guard let item = resolver.deref(rawItem) else {
                warnings.append("Skipped \(path): unresolved path item reference.")
                continue
            }
            for method in Self.methods {
                guard let operation = item[method] else { continue }
                let route = makeRoute(method: method, path: path, operation: operation)
                server.routes.append(route)
            }
        }
        for ref in resolver.externalRefs.sorted() {
            warnings.append("External reference not followed: \(ref)")
        }
        if server.routes.isEmpty { warnings.append("No operations found in `paths`.") }
        return server
    }

    /// `servers[0].url` path (OpenAPI 3) or `basePath` (Swagger 2).
    func basePath() -> String {
        if isSwagger2 { return root["basePath"]?.string.map { $0 == "/" ? "" : $0 } ?? "" }
        guard let first = root["servers"]?[0], var url = first["url"]?.string else { return "" }
        // Fill `{variables}` with their defaults.
        for pair in first["variables"]?.object?.pairs ?? [] {
            url = url.replacingOccurrences(of: "{\(pair.key)}", with: pair.value["default"]?.displayString ?? "")
        }
        if url.hasPrefix("/") { return url == "/" ? "" : url }
        guard let components = URLComponents(string: url) else { return "" }
        return components.path == "/" ? "" : components.path
    }

    mutating func makeRoute(method: String, path: String, operation: JSONValue) -> MockRoute {
        let notes = [operation["summary"]?.string, operation["operationId"]?.string]
            .compactMap { $0 }.first ?? ""
        var route = MockRoute(method: method, path: Self.convertPath(path), notes: notes)

        let produces = (operation["produces"]?.array ?? root["produces"]?.array)?.compactMap(\.string) ?? []
        let responses = operation["responses"]?.object?.pairs ?? []
        let hasNumeric = responses.contains { Int($0.key) != nil || $0.key.uppercased().hasSuffix("XX") }

        for (code, rawResponse) in responses {
            let status: Int
            if let number = Int(code) {
                status = number
            } else if code.uppercased().hasSuffix("XX"), let first = Int(code.prefix(1)) {
                status = first * 100
            } else if code == "default" && !hasNumeric {
                status = 200
            } else {
                continue
            }
            guard let response = resolver.deref(rawResponse) else { continue }
            let headers = responseHeaders(response)
            let label = response["description"]?.string.map { String($0.prefix(60)) } ?? ""
            let bodies = isSwagger2 ? swagger2Bodies(response, produces: produces) : openAPI3Bodies(response)
            if bodies.isEmpty {
                route.responses.append(MockResponse(label: label, status: status, headers: headers, body: "", templating: false))
            }
            for body in bodies {
                var all = headers
                if let type = body.contentType { all.insert(MockHeader(name: "Content-Type", value: type), at: 0) }
                let name = body.exampleName ?? label
                route.responses.append(MockResponse(label: name, status: status, headers: all, body: body.text, templating: false))
            }
        }

        if route.responses.isEmpty {
            route.responses.append(MockResponse(label: "Empty", status: 200, body: ""))
        }
        let defaultIndex = route.responses.enumerated()
            .filter { (200..<300).contains($0.element.status) }
            .min { $0.element.status < $1.element.status }?.offset ?? 0
        route.responses[defaultIndex].isDefault = true
        // Put the default first so the list reads naturally.
        let defaultResponse = route.responses.remove(at: defaultIndex)
        route.responses.insert(defaultResponse, at: 0)
        return route
    }

    struct Body {
        var contentType: String?
        var exampleName: String?
        var text: String
    }

    mutating func openAPI3Bodies(_ response: JSONValue) -> [Body] {
        guard let content = response["content"]?.object, !content.isEmpty else { return [] }
        let preferred = content.pairs.first { Self.isJSON($0.key) } ?? content.pairs[0]
        let (type, media) = (preferred.key, preferred.value)

        if let examples = media["examples"]?.object, !examples.isEmpty {
            var bodies: [Body] = []
            for (name, rawExample) in examples.pairs {
                guard let example = resolver.deref(rawExample) else { continue }
                if let value = example["value"] {
                    bodies.append(Body(contentType: type, exampleName: example["summary"]?.string ?? name, text: Self.text(value, type: type)))
                } else if let external = example["externalValue"]?.string {
                    warnings.append("External example not loaded: \(external)")
                }
            }
            if !bodies.isEmpty { return bodies }
        }
        if let example = media["example"] {
            return [Body(contentType: type, exampleName: nil, text: Self.text(example, type: type))]
        }
        if let schema = media["schema"] {
            var sampler = SchemaSampler(resolver: resolver)
            let value = sampler.sample(schema)
            resolver = sampler.resolver
            return [Body(contentType: type, exampleName: nil, text: Self.text(value, type: type))]
        }
        return [Body(contentType: type, exampleName: nil, text: "")]
    }

    mutating func swagger2Bodies(_ response: JSONValue, produces: [String]) -> [Body] {
        if let examples = response["examples"]?.object, !examples.isEmpty {
            let preferred = examples.pairs.first { Self.isJSON($0.key) } ?? examples.pairs[0]
            return [Body(contentType: preferred.key, exampleName: nil, text: Self.text(preferred.value, type: preferred.key))]
        }
        guard let schema = response["schema"] else { return [] }
        let type = produces.first(where: Self.isJSON) ?? produces.first ?? "application/json"
        var sampler = SchemaSampler(resolver: resolver)
        let value = sampler.sample(schema)
        resolver = sampler.resolver
        return [Body(contentType: type, exampleName: nil, text: Self.text(value, type: type))]
    }

    mutating func responseHeaders(_ response: JSONValue) -> [MockHeader] {
        var headers: [MockHeader] = []
        for (name, raw) in response["headers"]?.object?.pairs ?? [] {
            guard name.lowercased() != "content-type", let header = resolver.deref(raw) else { continue }
            let value: JSONValue
            if let example = header["example"] {
                value = example
            } else if let first = header["examples"]?.object?.pairs.first, let example = resolver.deref(first.value)?["value"] {
                value = example
            } else {
                var sampler = SchemaSampler(resolver: resolver)
                // Swagger 2 puts the type on the header itself.
                value = sampler.sample(header["schema"] ?? header, name: name)
                resolver = sampler.resolver
            }
            headers.append(MockHeader(name: name, value: value.displayString))
        }
        return headers
    }

    static func isJSON(_ contentType: String) -> Bool {
        let lower = contentType.lowercased()
        return lower.contains("/json") || lower.contains("+json")
    }

    static func text(_ value: JSONValue, type: String) -> String {
        if case .string(let s) = value, !isJSON(type) { return s }
        return value.serialized(pretty: true)
    }

    /// `/pets/{petId}` → `pets/:petId`.
    static func convertPath(_ path: String) -> String {
        PathPattern.split(path).map { segment in
            guard segment.contains("{") else { return segment }
            if segment.hasPrefix("{") && segment.hasSuffix("}") { return ":" + segment.dropFirst().dropLast() }
            // Mixed segments like `{id}.json` keep only the param.
            let name = segment.split(whereSeparator: { $0 == "{" || $0 == "}" }).dropFirst(segment.hasPrefix("{") ? 0 : 1).first
            return ":" + (name.map(String.init) ?? "param")
        }.joined(separator: "/")
    }
}
