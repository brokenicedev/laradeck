import XCTest
@testable import laradeck

@MainActor
final class TerminalByteBufferTests: XCTestCase {
    func testNormalizeForTerminalInsertsCarriageReturnBeforeLineFeed() {
        let input = Data("line one\nline two\r\n".utf8)
        let normalized = TerminalByteBuffer.normalizeForTerminal(input)
        XCTAssertEqual(String(decoding: normalized, as: UTF8.self), "line one\r\nline two\r\n")
    }

    func testAppendResetsWhenExceedingMaxBytes() {
        let buffer = TerminalByteBuffer(maxBytes: 8)
        buffer.append(Data("12345".utf8))
        let generationBeforeOverflow = buffer.terminalGeneration
        buffer.append(Data("67890".utf8))

        XCTAssertEqual(buffer.terminalData, Data("67890".utf8))
        XCTAssertEqual(buffer.terminalGeneration, generationBeforeOverflow + 1)
    }

    func testClearIncrementsGeneration() {
        let buffer = TerminalByteBuffer(maxBytes: 1024)
        buffer.appendText("hello")
        let generation = buffer.terminalGeneration
        buffer.clear()
        XCTAssertTrue(buffer.terminalData.isEmpty)
        XCTAssertEqual(buffer.terminalGeneration, generation + 1)
    }
}
