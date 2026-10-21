import XCTest
@testable import laradeck

final class EnvFileCodecTests: XCTestCase {
    func testParseSkipsCommentsAndBlankLines() {
        let input = """
        # comment
        APP_NAME=Laradeck

        APP_ENV=local
        """
        let variables = EnvFileCodec.parse(input)
        XCTAssertEqual(variables.map(\.key), ["APP_NAME", "APP_ENV"])
        XCTAssertEqual(variables[0].value, "Laradeck")
    }

    func testParseStripsDoubleQuotes() {
        let variables = EnvFileCodec.parse("APP_NAME=\"My App\"\n")
        XCTAssertEqual(variables.count, 1)
        XCTAssertEqual(variables[0].value, "My App")
    }

    func testSerializeQuotesValuesWithSpaces() {
        let output = EnvFileCodec.serialize([
            EnvVariable(key: "APP_NAME", value: "My App"),
            EnvVariable(key: "APP_ENV", value: "local"),
        ])
        XCTAssertTrue(output.contains("APP_NAME=\"My App\""))
        XCTAssertTrue(output.contains("APP_ENV=local\n"))
    }

    func testSerializeQuotesEmptyValues() {
        let output = EnvFileCodec.serialize([EnvVariable(key: "EMPTY", value: "")])
        XCTAssertEqual(output, "EMPTY=\"\"\n")
    }

    func testRoundTripPreservesQuotes() {
        let input = """
        APP_NAME="Laravel"
        DB_PASSWORD='secret'
        APP_ENV=local
        MAIL_FROM_NAME="${APP_NAME}"
        """
        let output = EnvFileCodec.serialize(EnvFileCodec.parse(input))
        XCTAssertEqual(output, input + "\n")
    }

    func testParseQuotedValueIgnoresTrailingComment() {
        let variables = EnvFileCodec.parse("APP_NAME=\"My App\" # comment\n")
        XCTAssertEqual(variables[0].value, "My App")
        XCTAssertEqual(variables[0].quote, .double)
    }

    func testParseUnquotedValueStripsInlineComment() {
        let variables = EnvFileCodec.parse("APP_ENV=local # comment\n")
        XCTAssertEqual(variables[0].value, "local")
    }

    func testMergeKeepsIncomingQuotes() {
        let local = EnvFileCodec.parse("APP_NAME=Old\n")
        let incoming = EnvFileCodec.parse("APP_NAME=\"New\"\nDB_PASSWORD='p#ss'\n")
        let merged = EnvMergeDiff.apply(EnvMergeDiff.rows(local: local, incoming: incoming))
        XCTAssertEqual(EnvFileCodec.serialize(merged), "APP_NAME=\"New\"\nDB_PASSWORD='p#ss'\n")
    }

    func testMergeToleratesDuplicateKeys() {
        let incoming = EnvFileCodec.parse("A=1\nA=2\n")
        let rows = EnvMergeDiff.rows(local: [], incoming: incoming)
        XCTAssertEqual(rows.first?.incomingValue, "2")
    }

    func testIsSensitiveDetectsKnownMarkers() {
        XCTAssertTrue(EnvFileCodec.isSensitive("DB_PASSWORD"))
        XCTAssertTrue(EnvFileCodec.isSensitive("mailgun_secret"))
        XCTAssertFalse(EnvFileCodec.isSensitive("APP_NAME"))
    }
}
