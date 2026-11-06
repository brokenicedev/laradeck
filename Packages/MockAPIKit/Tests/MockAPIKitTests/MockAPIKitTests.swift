import HTTPKit
import XCTest
@testable import MockAPIKit

final class PathPatternTests: XCTestCase {
    func testParamsAndWildcard() {
        XCTAssertEqual(PathPattern("users/:id").match("/users/42"), ["id": "42"])
        XCTAssertEqual(PathPattern("/users/{id}/posts").match("users/7/posts/"), ["id": "7"])
        XCTAssertNil(PathPattern("users/:id").match("/users"))
        XCTAssertNil(PathPattern("users/:id").match("/users/1/2"))
        XCTAssertEqual(PathPattern("files/*").match("/files/a/b.txt")?["*"], "a/b.txt")
        XCTAssertEqual(PathPattern.join("api/v1/", "/users"), "/api/v1/users")
    }
}

final class EngineTests: XCTestCase {
    func request(_ method: String, _ target: String, headers: [String: String] = [:], body: String = "") -> HTTPRequest {
        var raw = "\(method) \(target) HTTP/1.1\r\n"
        for (k, v) in headers { raw += "\(k): \(v)\r\n" }
        raw += "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case .complete(let r) = HTTPParser.parse(Data(raw.utf8)) else { fatalError("bad request") }
        return r
    }

    func body(_ result: MockEngine.Result) -> String { String(decoding: result.response.body, as: UTF8.self) }

    func server() -> MockServer {
        MockServer(name: "Test", port: 1, prefix: "api", headers: [MockHeader(name: "X-Server", value: "mock")], routes: [
            MockRoute(method: "GET", path: "users/:id", responses: [
                MockResponse(label: "Found", status: 200, body: #"{"id": {{params.id}}, "q": "{{query.q}}"}"#, isDefault: true),
                MockResponse(label: "Admin", status: 200, body: "admin",
                             rules: [MockRule(target: .header, key: "X-Role", op: .equals, value: "admin")]),
                MockResponse(label: "Missing", status: 404, body: "nope",
                             rules: [MockRule(target: .params, key: "id", op: .regex, value: "^9+$")]),
            ]),
            MockRoute(method: "GET", path: "users/me", responses: [MockResponse(body: "me")]),
            MockRoute(method: "POST", path: "users", responses: [
                MockResponse(status: 201, body: #"{"name": "{{body.user.name}}"}"#, isDefault: true),
                MockResponse(status: 422, body: "invalid", rules: [
                    MockRule(target: .body, key: "user.name", op: .exists, invert: true),
                ]),
            ]),
            MockRoute(method: "GET", path: "seq", responseMode: .sequential, responses: [
                MockResponse(body: "one"), MockResponse(body: "two"),
            ]),
        ])
    }

    func testTemplatingAndDefault() async {
        let engine = MockEngine(server: server(), applyLatency: false)
        let result = await engine.handle(request("GET", "/api/users/5?q=hi"))
        XCTAssertEqual(result.response.status, 200)
        XCTAssertEqual(body(result), #"{"id": 5, "q": "hi"}"#)
        XCTAssertTrue(result.response.headers.contains { $0.0 == "X-Server" && $0.1 == "mock" })
        XCTAssertTrue(result.response.headers.contains { $0.0 == "Content-Type" && $0.1.hasPrefix("application/json") })
        XCTAssertEqual(result.log.responseLabel, "200 · Found")
    }

    func testRulesPickResponses() async {
        let engine = MockEngine(server: server(), applyLatency: false)
        let admin = await engine.handle(request("GET", "/api/users/5", headers: ["X-Role": "admin"]))
        XCTAssertEqual(body(admin), "admin")
        let missing = await engine.handle(request("GET", "/api/users/999"))
        XCTAssertEqual(missing.response.status, 404)
    }

    func testLiteralBeatsParam() async {
        let engine = MockEngine(server: server(), applyLatency: false)
        let result = await engine.handle(request("GET", "/api/users/me"))
        XCTAssertEqual(body(result), "me")
    }

    func testBodyRulesAndTemplates() async {
        let engine = MockEngine(server: server(), applyLatency: false)
        let created = await engine.handle(request("POST", "/api/users", headers: ["Content-Type": "application/json"], body: #"{"user":{"name":"Ada"}}"#))
        XCTAssertEqual(created.response.status, 201)
        XCTAssertEqual(body(created), #"{"name": "Ada"}"#)
        let invalid = await engine.handle(request("POST", "/api/users", body: #"{"user":{}}"#))
        XCTAssertEqual(invalid.response.status, 422)
    }

    func testSequentialAndForcedResponse() async {
        let engine = MockEngine(server: server(), applyLatency: false)
        let first = await engine.handle(request("GET", "/api/seq"))
        let second = await engine.handle(request("GET", "/api/seq"))
        let third = await engine.handle(request("GET", "/api/seq"))
        XCTAssertEqual([body(first), body(second), body(third)], ["one", "two", "one"])
        let forced = await engine.handle(request("GET", "/api/users/1", headers: ["x-mock-response-code": "404"]))
        XCTAssertEqual(forced.response.status, 404)
    }

    func testNotFoundMethodNotAllowedAndPreflight() async {
        let engine = MockEngine(server: server(), applyLatency: false)
        let notFound = await engine.handle(request("GET", "/nothing"))
        XCTAssertEqual(notFound.response.status, 404)
        XCTAssertNil(notFound.log.routeId)
        let wrongMethod = await engine.handle(request("DELETE", "/api/users"))
        XCTAssertEqual(wrongMethod.response.status, 405)
        let preflight = await engine.handle(request("OPTIONS", "/api/users"))
        XCTAssertEqual(preflight.response.status, 204)
        let head = await engine.handle(request("HEAD", "/api/users/me"))
        XCTAssertEqual(head.response.status, 200)
        XCTAssertTrue(head.response.body.isEmpty)
    }
}

final class TemplateTests: XCTestCase {
    func testHelpers() {
        let renderer = TemplateRenderer(context: nil)
        XCTAssertEqual(renderer.render("{{unknown.tag}}"), "{{unknown.tag}}")
        XCTAssertEqual(renderer.render("{{uuid}}").count, 36)
        let n = Int(renderer.render("{{int 5 5}}"))
        XCTAssertEqual(n, 5)
        XCTAssertEqual(renderer.render("[{{#repeat 3}}{{@index}}{{/repeat}}]"), "[0,1,2]")
        XCTAssertEqual(renderer.render("{{pick 'a b'}}"), "a b")
        XCTAssertTrue(renderer.render("{{faker.email}}").contains("@"))
        XCTAssertEqual(renderer.render("{{now 'yyyy'}}").count, 4)
        // Missing request data renders as empty, not as the tag, once a request exists.
        let context = RequestContext(request: HTTPRequest(method: "GET", path: "/"))
        XCTAssertEqual(TemplateRenderer(context: context).render("[{{query.x}}]"), "[]")
    }
}

final class ImportTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
        return try Data(contentsOf: url)
    }

    func testOpenAPI3YAML() async throws {
        let result = try MockImporter.importData(fixture("petstore-openapi3.yaml"), fileName: "petstore.yaml", port: 4010)
        XCTAssertEqual(result.format, .openAPI3)
        let server = result.server
        XCTAssertEqual(server.name, "Petstore")
        XCTAssertEqual(server.prefix, "/api/v1")
        XCTAssertEqual(server.port, 4010)
        XCTAssertEqual(server.routes.map { "\($0.method) \($0.path)" },
                       ["GET pets", "POST pets", "GET pets/:petId", "DELETE pets/:petId"])

        let list = server.routes[0]
        XCTAssertEqual(list.responses.map(\.status), [200])  // `default` is skipped when numeric codes exist
        XCTAssertTrue(list.responses[0].headers.contains { $0.name == "X-Total-Count" && $0.value == "2" })
        let pets = try JSONValue.parse(list.responses[0].body)
        XCTAssertEqual(pets[0]?["name"]?.string, "Fido")
        XCTAssertEqual(pets[0]?["tag"]?.string, "dog")
        XCTAssertEqual(pets[0]?["owner_email"]?.string, "jane.doe@example.com")
        XCTAssertNotNil(pets[0]?["category"]?["parent"])  // recursion stops instead of looping

        let create = server.routes[1]
        XCTAssertEqual(create.responses.map(\.label), ["A dog", "cat", "Validation error"])
        XCTAssertTrue(create.responses[0].isDefault)
        XCTAssertEqual(create.responses.map(\.status), [201, 201, 422])

        // The imported server answers end to end.
        let engine = MockEngine(server: server, applyLatency: false)
        let response = await engine.handle(HTTPRequest(method: "GET", path: "/api/v1/pets/3"))
        XCTAssertEqual(response.response.status, 200)
        XCTAssertEqual(try JSONValue.parse(response.response.body)["name"]?.string, "Fido")
    }

    func testSwagger2() throws {
        let result = try MockImporter.importData(fixture("petstore-swagger2.json"))
        XCTAssertEqual(result.format, .swagger2)
        XCTAssertEqual(result.server.prefix, "/v2")
        let pet = result.server.routes[0]
        XCTAssertEqual(pet.path, "pet/:petId")
        XCTAssertEqual(pet.responses.map(\.status), [200, 400])
        XCTAssertEqual(try JSONValue.parse(pet.responses[0].body)["photoUrls"]?.array?.count, 2)
        let inventory = try JSONValue.parse(result.server.routes[1].responses[0].body)
        XCTAssertEqual(inventory["available"]?.int, 7)
    }

    func testPostman() async throws {
        let result = try MockImporter.importData(fixture("users.postman_collection.json"))
        XCTAssertEqual(result.format, .postman)
        let server = result.server
        XCTAssertEqual(server.name, "Users API")
        XCTAssertEqual(server.routes.map { "\($0.method) \($0.path)" },
                       ["GET v1/users", "GET v1/users/:id", "POST oauth/token"])
        XCTAssertEqual(result.warnings.count, 1)  // Login has no examples

        let list = server.routes[0]
        XCTAssertEqual(list.responses.map(\.label), ["Page 1", "Page 2"])
        XCTAssertEqual(list.responses[1].rules.first?.key, "page")
        XCTAssertFalse(list.responses[0].headers.contains { $0.name == "Content-Length" })
        XCTAssertEqual(list.responses[1].headers.first?.value, "application/json")

        let user = server.routes[1]
        XCTAssertEqual(user.defaultResponse?.label, "Found")

        let engine = MockEngine(server: server, applyLatency: false)
        let page2 = await engine.handle(HTTPRequest(method: "GET", path: "/v1/users", query: ["page": "2"]))
        XCTAssertEqual(try JSONValue.parse(page2.response.body)["page"]?.int, 2)
        let byName = await engine.handle(HTTPRequest(method: "GET", path: "/v1/users/1", headers: ["x-mock-response-name": "not found"]))
        XCTAssertEqual(byName.response.status, 404)
    }

    func testLaradeckRoundTrip() throws {
        let original = EngineTests().server()
        let data = try MockImporter.export(original)
        let result = try MockImporter.importData(data)
        XCTAssertEqual(result.format, .laradeck)
        XCTAssertNotEqual(result.server.id, original.id)
        XCTAssertEqual(result.server.routes, original.routes)
    }

    func testUnknownFormat() {
        XCTAssertThrowsError(try MockImporter.importData(Data(#"{"hello":"world"}"#.utf8))) { error in
            XCTAssertEqual(error as? MockImportError, .unknownFormat)
        }
    }
}

final class LiveServerTests: XCTestCase {
    /// Runs a real listener when MOCKAPI_LIVE_PORT is set, so it can be poked with curl from outside.
    func testLiveServer() async throws {
        guard let portText = ProcessInfo.processInfo.environment["MOCKAPI_LIVE_PORT"], let port = UInt16(portText) else {
            throw XCTSkip("Set MOCKAPI_LIVE_PORT to run")
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/petstore-openapi3.yaml", withExtension: nil))
        var server = try MockImporter.importFile(at: url, port: Int(port)).server
        server.routes[0].responses.append(MockResponse(label: "Sold", status: 200, body: #"[{"status":"{{query.status}}"}]"#,
                                                        rules: [MockRule(target: .query, key: "status", op: .equals, value: "sold")]))
        server.latencyMs = 0
        let engine = MockEngine(server: server)
        let listener = HTTPServer(label: "test.mock") { request in await engine.handle(request).response }
        listener.start(port: port)
        try await Task.sleep(for: .seconds(Double(ProcessInfo.processInfo.environment["MOCKAPI_LIVE_SECONDS"] ?? "8") ?? 8))
        listener.stop()
    }
}
