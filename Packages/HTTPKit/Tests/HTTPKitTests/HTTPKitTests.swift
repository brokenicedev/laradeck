import XCTest
@testable import HTTPKit

final class HTTPKitTests: XCTestCase {
    func testParsesRawQuery() {
        let raw = "GET /pets?status=sold&tag=a%20b HTTP/1.1\r\nHost: x\r\n\r\n"
        guard case .complete(let r) = HTTPParser.parse(Data(raw.utf8)) else { return XCTFail() }
        XCTAssertEqual(r.path, "/pets")
        XCTAssertEqual(r.rawQuery, "status=sold&tag=a%20b")
        XCTAssertEqual(r.query["tag"], "a b")
    }

    func testCorsIsOptionalAndNotDuplicated() {
        let response = HTTPResponse(status: 201, headers: [("Access-Control-Allow-Origin", "https://app.test")])
        let withCors = String(decoding: response.serialized(), as: UTF8.self)
        XCTAssertTrue(withCors.hasPrefix("HTTP/1.1 201 Created\r\n"))
        XCTAssertEqual(withCors.components(separatedBy: "Access-Control-Allow-Origin").count, 2)
        let without = String(decoding: HTTPResponse(status: 422).serialized(cors: false), as: UTF8.self)
        XCTAssertTrue(without.hasPrefix("HTTP/1.1 422 Unprocessable Content\r\n"))
        XCTAssertFalse(without.contains("Access-Control"))
    }
}
