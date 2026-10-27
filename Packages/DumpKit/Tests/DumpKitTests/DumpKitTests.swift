import XCTest
@testable import DumpKit

final class JSONTests: XCTestCase {
    func testKeepsKeyOrderAndRoundTrips() throws {
        let text = #"{"z":1,"a":[true,null,"x\né😀"],"m":{"b":2.5,"a":-3}}"#
        let v = try JSONValue.parse(text)
        XCTAssertEqual(v.object?.keys, ["z", "a", "m"])
        XCTAssertEqual(v["m"]?.object?.keys, ["b", "a"])
        XCTAssertEqual(v["a"]?[2]?.string, "x\né😀")
        XCTAssertEqual(try JSONValue.parse(v.serialized()), v)
        XCTAssertEqual(v["m"]?["a"]?.displayString, "-3")
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try JSONValue.parse("{\"a\":}"))
        XCTAssertThrowsError(try JSONValue.parse("[1,2] x"))
    }
}

final class HTTPTests: XCTestCase {
    func testContentLength() {
        let raw = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"
        guard case .complete(let r) = HTTPParser.parse(Data(raw.utf8)) else { return XCTFail() }
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "hello")
    }

    func testIncompleteWithExpectContinue() {
        let raw = "POST / HTTP/1.1\r\nContent-Length: 50\r\nExpect: 100-continue\r\n\r\nabc"
        guard case .incomplete(let expects) = HTTPParser.parse(Data(raw.utf8)) else { return XCTFail() }
        XCTAssertTrue(expects)
    }

    func testChunkedAndQuery() {
        let raw = "POST /locks/ab%20c?hostname=my+host&project_name=p HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n"
        guard case .complete(let r) = HTTPParser.parse(Data(raw.utf8)) else { return XCTFail() }
        XCTAssertEqual(r.path, "/locks/ab c")
        XCTAssertEqual(r.query["hostname"], "my host")
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "abcde")
    }
}

@MainActor
final class StoreTests: XCTestCase {
    func request(_ uuid: String, _ payloads: [JSONValue], project: String = "demo") -> JSONValue {
        ["uuid": .string(uuid), "payloads": .array(payloads), "meta": ["project_name": .string(project)]]
    }

    func payload(_ type: String, _ content: JSONValue) -> JSONValue {
        ["type": .string(type), "content": content, "origin": ["file": "/app/a.php", "line_number": 7, "hostname": "box"]]
    }

    func testLogThenColorLabelSizeHideRemove() {
        let store = DumpStore()
        store.ingest(request("u1", [payload("log", ["values": ["hello", 42]])]))
        store.ingest(request("u1", [payload("color", ["color": "red"])]))
        store.ingest(request("u1", [payload("label", ["label": "mine"])]))
        store.ingest(request("u1", [payload("size", ["size": "lg"])]))
        let e = store.currentScreen.entries[0]
        XCTAssertEqual(e.color, "red")
        XCTAssertEqual(e.label, "mine")
        XCTAssertEqual(e.size, "lg")
        XCTAssertEqual(e.origin.line, 7)
        XCTAssertEqual(e.projectName, "demo")
        store.ingest(request("u1", [payload("hide", [:])]))
        XCTAssertTrue(store.currentScreen.entries[0].collapsed)
        store.ingest(request("u1", [payload("remove", [:])]))
        XCTAssertTrue(store.currentScreen.entries.isEmpty)
    }

    func testActionWithoutMatchingLogIsIgnored() {
        let store = DumpStore()
        store.ingest(request("nope", [payload("color", ["color": "green"])]))
        XCTAssertTrue(store.currentScreen.entries.isEmpty)
    }

    func testNewScreenAndClearAll() {
        let store = DumpStore()
        store.ingest(request("a", [payload("log", ["values": ["1"]])]))
        store.ingest(request("b", [payload("new_screen", ["name": "Second"])]))
        XCTAssertEqual(store.screens.count, 2)
        XCTAssertEqual(store.currentScreen.name, "Second")
        store.ingest(request("c", [payload("log", ["values": ["2"]])]))
        store.ingest(request("d", [payload("clear_all", [:])]))
        XCTAssertTrue(store.currentScreen.entries.isEmpty)
        XCTAssertEqual(store.archived.count, 1)
    }

    func testLocks() {
        let store = DumpStore()
        store.ingest(request("l", [payload("create_lock", ["name": "abc"])]))
        XCTAssertEqual(store.lockResponse("abc"), ["active": true, "stop_execution": false])
        store.resolveLock("abc", stop: true)
        XCTAssertEqual(store.lockResponse("abc"), ["active": false, "stop_execution": true])
        XCTAssertEqual(store.lockResponse("unknown"), ["active": false, "stop_execution": false])
    }

    func testRouter() throws {
        let store = DumpStore()
        let router = DumpRouter(store: store)
        let body = request("r", [payload("log", ["values": ["x"]])]).serialized()
        let resp = router.handle(HTTPRequest(method: "POST", path: "/", body: Data(body.utf8)))
        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(store.currentScreen.entries.count, 1)
        // PHP client requires a 404 here to treat the app as available.
        XCTAssertEqual(router.handle(HTTPRequest(method: "GET", path: "/_availability_check")).status, 404)
        let lock = router.handle(HTTPRequest(method: "GET", path: "/locks/zzz"))
        XCTAssertEqual(try JSONValue.parse(lock.body)["active"], false)
    }

    func testHistoryLimitAndPause() {
        let store = DumpStore()
        store.historyLimit = 3
        for i in 0..<5 { store.ingest(request("u\(i)", [payload("log", ["values": .array([.number(Double(i))])])])) }
        XCTAssertEqual(store.currentScreen.entries.map { $0.groupUuid }, ["u2", "u3", "u4"])
        store.isPaused = true
        store.ingest(request("p", [payload("log", ["values": ["x"]])]))
        XCTAssertEqual(store.currentScreen.entries.count, 3)
    }

    func testSnapshotRestore() {
        let store = DumpStore()
        store.ingest(request("a", [payload("table", ["values": ["k2": "v", "k1": 1], "label": "Table"])]))
        let other = DumpStore()
        other.restore(from: try! JSONValue.parse(store.snapshot().serialized()))
        XCTAssertEqual(other.currentScreen.entries.first?.content["values"]?.object?.keys, ["k2", "k1"])
    }
}

final class DumpTests: XCTestCase {
    let html = """
    <script> Sfdump = window.Sfdump || (function (doc) { return 1 })(document) </script><pre class=sf-dump id=sf-dump-1 data-indent-pad="  "><span class=sf-dump-note>array:2</span> [<samp data-depth=1 class=sf-dump-expanded>
      "<span class=sf-dump-key>a</span>" => <span class=sf-dump-num>1</span>
      "<span class=sf-dump-key>b</span>" => "<span class=sf-dump-str title="3 characters">f&amp;o</span>"
    </samp>]
    </pre><script>Sfdump("sf-dump-1")</script>
    """

    func testParsesTreeAndSkipsScripts() {
        let nodes = SfDump.parse(html)
        let text = SfDump.plainText(nodes)
        XCTAssertFalse(text.contains("Sfdump"))
        XCTAssertTrue(text.contains("array:2 ["))
        XCTAssertTrue(text.contains("\"b\" => \"f&o\""))
        let blocks = nodes.compactMap { n -> Int? in if case .block(_, let d, _, _) = n { return d }; return nil }
        XCTAssertEqual(blocks, [1])
    }

    func testSearchTextStripsHTML() {
        let e = DumpEntry(groupUuid: "x", type: "log", content: ["values": .array([.string(html)])])
        XCTAssertTrue(e.searchText.contains("f&o"))
        XCTAssertFalse(e.searchText.contains("sf-dump"))
    }

    func testSQLInterpolation() {
        XCTAssertEqual(SQL.interpolate("select * from u where a = ? and b = '?' and c = ?", bindings: ["x'y", 3]),
                       "select * from u where a = 'x''y' and b = '?' and c = 3")
    }
}

@MainActor
final class DsPayloadTests: XCTestCase {
    func ld(_ id: String, _ type: String, _ body: JSONValue, label: String = "dump", screen: String = "home") -> JSONValue {
        ["id": .string(id), "type": .string(type), .init(stringLiteral: type): body,
         "application_path": "/Users/me/shop",
         "ide_handle": ["real_path": "app/Http/Controller.php", "project_path": "/Users/me/shop", "line": "42", "separator": "/"],
         "with_label": ["label": .string(label)], "to_screen": ["screen_name": .string(screen)]]
    }

    func testDumpColorLabelScreen() throws {
        let store = DumpStore()
        let router = DumpRouter(store: store)
        let id = "4f9a4c4e-8d7b-4b8a-9b0e-2d7c2f7b1a11"
        let resp = router.handle(HTTPRequest(method: "POST", path: "/api/dumps",
                                             body: Data(ld(id, "dump", ["dump": "hello", "variable_name": "$x"]).serialized().utf8)))
        XCTAssertEqual(try JSONValue.parse(resp.body)["id"]?.string, id)
        let e = store.currentScreen.entries[0]
        XCTAssertEqual(e.content["values"]?[0]?.string, "hello")
        XCTAssertEqual(e.label, "$x")
        XCTAssertEqual(e.origin.file, "/Users/me/shop/app/Http/Controller.php")
        XCTAssertEqual(e.origin.line, 42)
        XCTAssertEqual(e.projectName, "shop")

        store.ingestDsPayload(ld(id, "color", ["color": "black"]))
        store.ingestDsPayload(ld(id, "label", [:], label: "mine"))
        XCTAssertEqual(store.currentScreen.entries[0].color, "gray")
        XCTAssertEqual(store.currentScreen.entries[0].label, "mine")

        store.ingestDsPayload(ld(id, "screen", [:], screen: "users"))
        XCTAssertTrue(store.currentScreen.entries.isEmpty)
        XCTAssertEqual(store.screens.first { $0.name == "users" }?.entries.count, 1)
        store.ingestDsPayload(ld("other", "dump", ["dump": "x", "variable_name": "arg0"]))
        XCTAssertEqual(store.currentScreen.entries.count, 1)
        XCTAssertNil(store.currentScreen.entries[0].label)
    }

    func testTablesJsonAndClear() {
        let store = DumpStore()
        store.ingestDsPayload(ld("a", "table_v2", ["values": ["k": .array(["<pre class=sf-dump>1</pre>", "id"])]]))
        XCTAssertEqual(store.currentScreen.entries[0].content["values"]?["k"]?.string, "<pre class=sf-dump>1</pre>")
        store.ingestDsPayload(ld("b", "table", ["fields": ["id"], "values": [["id": "1"]], "label": "Users"]))
        XCTAssertEqual(store.currentScreen.entries[1].type, DumpStore.dsTableType)
        store.ingestDsPayload(ld("c", "json", ["string": "{\"a\":1}"]))
        XCTAssertEqual(store.currentScreen.entries[2].type, "json_string")
        store.ingestDsPayload(ld("d", "clear", [:]))
        XCTAssertTrue(store.currentScreen.entries.isEmpty)
    }

    func testValidateContains() {
        let store = DumpStore()
        store.ingestDsPayload(ld("v", "dump", ["dump": "Hello World"]))
        store.ingestDsPayload(ld("v", "validate", ["type": "contains", "content": "world", "is_case_sensitive": false, "is_whole_word": true]))
        XCTAssertTrue(store.currentScreen.entries[1].content["content"]?.string?.hasPrefix("✓") == true)
    }
}

@MainActor
final class DumpRoutingTests: XCTestCase {
    func testRequestsRouteByHint() throws {
        let a = DumpStore(), b = DumpStore()
        let router = DumpRouter(
            storeFor: { $0.files.contains { $0.hasPrefix("/work/a/") } ? a : b },
            allStores: { [a, b] }
        )
        let body: JSONValue = [
            "uuid": "1",
            "payloads": [["type": "log", "content": ["values": ["x"]], "origin": ["file": "/work/a/app/X.php", "line_number": 3]]],
            "meta": [:],
        ]
        _ = router.handle(HTTPRequest(method: "POST", path: "/", headers: [:], body: Data(body.serialized().utf8)))
        XCTAssertEqual(a.currentScreen.entries.count, 1)
        XCTAssertEqual(b.currentScreen.entries.count, 0)

        let other: JSONValue = ["uuid": "2", "payloads": [["type": "log", "content": ["values": ["y"]], "origin": ["file": "/elsewhere/Y.php"]]]]
        _ = router.handle(HTTPRequest(method: "POST", path: "/", headers: [:], body: Data(other.serialized().utf8)))
        XCTAssertEqual(b.currentScreen.entries.count, 1)
    }
}
