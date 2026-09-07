import Foundation
@testable import RepoPromptPiProvider
import XCTest

final class PiRPCCommandTests: XCTestCase {
    private func encode(_ command: PiRPCCommand, id: String? = nil) throws -> PiJSONValue {
        let data = try PiRPCWire.encodeRequestLine(command, id: id)
        return try PiRPCWire.decodeLine(data)
    }

    func testPromptWithStreamingBehaviorAndImages() throws {
        let command = PiRPCCommand.prompt(
            message: "New instruction",
            images: [PiImageAttachment(data: "aGk=", mimeType: "image/png")],
            streamingBehavior: .steer
        )
        let json = try encode(command, id: "req-1")
        XCTAssertEqual(json["id"]?.stringValue, "req-1")
        XCTAssertEqual(json["type"]?.stringValue, "prompt")
        XCTAssertEqual(json["message"]?.stringValue, "New instruction")
        XCTAssertEqual(json["streamingBehavior"]?.stringValue, "steer")
        let image = try XCTUnwrap(json["images"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(image["type"]?.stringValue, "image")
        XCTAssertEqual(image["data"]?.stringValue, "aGk=")
        XCTAssertEqual(image["mimeType"]?.stringValue, "image/png")
    }

    func testOmittedOptionalFieldsAreAbsent() throws {
        let json = try encode(.prompt(message: "Hello"))
        XCTAssertNil(json["streamingBehavior"])
        XCTAssertNil(json["images"])
        XCTAssertNil(json["id"])
    }

    func testFollowUpUsesUnderscoreWireName() throws {
        let json = try encode(.followUp(message: "later"))
        XCTAssertEqual(json["type"]?.stringValue, "follow_up")
    }

    func testClearQueueAndAbort() throws {
        XCTAssertEqual(try encode(.clearQueue)["type"]?.stringValue, "clear_queue")
        XCTAssertEqual(try encode(.abort)["type"]?.stringValue, "abort")
    }

    func testGetEntriesCarriesCursor() throws {
        XCTAssertEqual(try encode(.getEntries())["type"]?.stringValue, "get_entries")
        let json = try encode(.getEntries(since: "abc123"))
        XCTAssertEqual(json["since"]?.stringValue, "abc123")
    }

    func testSetModelAndThinkingLevel() throws {
        let model = try encode(.setModel(provider: "anthropic", modelId: "claude-sonnet-4-20250514"))
        XCTAssertEqual(model["type"]?.stringValue, "set_model")
        XCTAssertEqual(model["provider"]?.stringValue, "anthropic")
        XCTAssertEqual(model["modelId"]?.stringValue, "claude-sonnet-4-20250514")
        let thinking = try encode(.setThinkingLevel(level: "high"))
        XCTAssertEqual(thinking["type"]?.stringValue, "set_thinking_level")
        XCTAssertEqual(thinking["level"]?.stringValue, "high")
    }

    func testQueueDeliveryModeWireValues() throws {
        XCTAssertEqual(try encode(.setSteeringMode(mode: .oneAtATime))["mode"]?.stringValue, "one-at-a-time")
        XCTAssertEqual(try encode(.setFollowUpMode(mode: .all))["mode"]?.stringValue, "all")
    }

    func testSessionLifecycleCommands() throws {
        XCTAssertEqual(try encode(.newSession(parentSession: "/tmp/parent.jsonl"))["parentSession"]?.stringValue, "/tmp/parent.jsonl")
        XCTAssertEqual(try encode(.switchSession(sessionPath: "/tmp/s.jsonl"))["type"]?.stringValue, "switch_session")
        XCTAssertEqual(try encode(.fork(entryId: "abc123"))["entryId"]?.stringValue, "abc123")
        XCTAssertEqual(try encode(.clone)["type"]?.stringValue, "clone")
        XCTAssertEqual(try encode(.setSessionName(name: "release audit"))["name"]?.stringValue, "release audit")
    }

    func testCompactCarriesCustomInstructionsOnlyWhenPresent() throws {
        XCTAssertNil(try encode(.compact())["customInstructions"])
        XCTAssertEqual(
            try encode(.compact(customInstructions: "Focus on code changes"))["customInstructions"]?.stringValue,
            "Focus on code changes"
        )
    }

    func testGetCommandsAndBash() throws {
        XCTAssertEqual(try encode(.getCommands)["type"]?.stringValue, "get_commands")
        let bash = try encode(.bash(command: "ls -la"), id: "req-1")
        XCTAssertEqual(bash["id"]?.stringValue, "req-1")
        XCTAssertEqual(bash["command"]?.stringValue, "ls -la")
    }

    func testExtensionUIDialogResponses() throws {
        let value = try encode(.extensionUIResponseValue(id: "uuid-1", value: "Allow"))
        XCTAssertEqual(value["type"]?.stringValue, "extension_ui_response")
        XCTAssertEqual(value["id"]?.stringValue, "uuid-1")
        XCTAssertEqual(value["value"]?.stringValue, "Allow")

        let confirmed = try encode(.extensionUIResponseConfirmed(id: "uuid-2", confirmed: true))
        XCTAssertEqual(confirmed["confirmed"]?.boolValue, true)

        let cancelled = try encode(.extensionUIResponseCancelled(id: "uuid-3"))
        XCTAssertEqual(cancelled["cancelled"]?.boolValue, true)
    }
}
