import Foundation
@testable import RepoPromptPiProvider
import XCTest

final class PiRPCFramingTests: XCTestCase {
    func testAccumulatorSplitsOnlyOnLFAndHandlesChunkBoundaries() {
        var accumulator = PiRPCLineAccumulator()
        XCTAssertEqual(accumulator.append(Data("{\"a\":".utf8)), [])
        XCTAssertEqual(accumulator.append(Data("\"1\"}\n{\"b\":".utf8)).count, 1)
        XCTAssertEqual(accumulator.append(Data("\"2\"}\n".utf8)).count, 1)
        XCTAssertFalse(accumulator.hasPartialLine)
    }

    func testAccumulatorStripsTrailingCRAndIgnoresBlankLines() throws {
        var accumulator = PiRPCLineAccumulator()
        let lines = accumulator.append(Data("{\"x\":1}\r\n\r\n{\"y\":2}\n".utf8))
        XCTAssertEqual(lines.count, 2)
        let first = try PiRPCWire.decodeLine(lines[0])
        XCTAssertEqual(first["x"]?.intValue, 1)
    }

    func testUnicodeLineSeparatorsRemainInsidePayload() throws {
        // U+2028/U+2029 are valid inside JSON strings and must never act as delimiters.
        let payload = "{\"type\":\"prompt\",\"message\":\"line one\u{2028}separator\"}" + "\n"
        var accumulator = PiRPCLineAccumulator()
        let lines = accumulator.append(Data(payload.utf8))
        XCTAssertEqual(lines.count, 1)
        let value = try PiRPCWire.decodeLine(lines[0])
        XCTAssertEqual(value["message"]?.stringValue?.contains("\u{2028}"), true)
    }

    func testFinishFlushesUnterminatedRemainder() {
        var accumulator = PiRPCLineAccumulator()
        _ = accumulator.append(Data("{\"a\":1}\n{\"b\":2".utf8))
        let remainder = accumulator.finish()
        XCTAssertEqual(String(data: remainder ?? Data(), encoding: .utf8), "{\"b\":2")
        XCTAssertNil(accumulator.finish())
    }

    func testDecodeLineRejectsInvalidJSON() {
        XCTAssertThrowsError(try PiRPCWire.decodeLine(Data("not json\n".utf8))) { error in
            guard case let PiProviderError.framing(detail) = error else {
                return XCTFail("Expected framing error")
            }
            XCTAssertTrue(detail.contains("not valid JSON"))
        }
    }

    func testRequestEncodingIsSingleLineLFTerminated() throws {
        let data = try PiRPCWire.encodeRequestLine(.prompt(message: "hello\nworld"), id: "req-1")
        XCTAssertEqual(data.last, 0x0A)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.dropLast().contains("\n"))
        let decoded = try JSONDecoder().decode(PiJSONValue.self, from: data)
        XCTAssertEqual(decoded["id"]?.stringValue, "req-1")
        XCTAssertEqual(decoded["type"]?.stringValue, "prompt")
        XCTAssertEqual(decoded["message"]?.stringValue, "hello\nworld")
    }
}
