import Foundation
@testable import RepoPromptPiProvider
import XCTest

final class PiRPCEventTests: XCTestCase {
    private func decodeEvent(_ line: String) throws -> PiRPCEvent {
        try PiRPCEvent(line: Data(line.utf8))
    }

    func testResponseDecodingSuccessAndFailure() throws {
        let success = try PiRPCResponse(json: PiRPCWire.decodeLine(
            Data(#"{"id":"req-1","type":"response","command":"prompt","success":true}"#.utf8)
        ))
        XCTAssertNotNil(success)
        XCTAssertEqual(success?.id, "req-1")
        XCTAssertEqual(success?.command, "prompt")
        XCTAssertEqual(success?.success, true)
        XCTAssertNil(success?.errorMessage)
        XCTAssertNil(success?.data)

        let failure = try PiRPCResponse(json: PiRPCWire.decodeLine(
            Data(#"{"type":"response","command":"set_model","success":false,"error":"Model not found: invalid/model"}"#.utf8)
        ))
        XCTAssertEqual(failure?.success, false)
        XCTAssertEqual(failure?.errorMessage, "Model not found: invalid/model")
    }

    func testNonResponseJSONIsNotAResponse() throws {
        let event = try PiRPCWire.decodeLine(Data(#"{"type":"agent_start"}"#.utf8))
        XCTAssertNil(PiRPCResponse(json: event))
    }

    func testMessageUpdateTextDelta() throws {
        let event = try decodeEvent(
            #"{"type":"message_update","usage":{"input":100,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":101,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"Hello "}}"#
        )
        guard case let .messageUpdate(usage, delta) = event else {
            return XCTFail("Expected messageUpdate")
        }
        XCTAssertEqual(usage?.totalTokens, 101)
        guard case let .textDelta(contentIndex, deltaText) = delta else {
            return XCTFail("Expected textDelta")
        }
        XCTAssertEqual(contentIndex, 0)
        XCTAssertEqual(deltaText, "Hello ")
    }

    func testMessageUpdateToolCallStart() throws {
        let event = try decodeEvent(
            #"{"type":"message_update","usage":null,"assistantMessageEvent":{"type":"toolcall_start","contentIndex":1,"id":"call_abc123","toolName":"write"}}"#
        )
        guard case let .messageUpdate(_, delta) = event else {
            return XCTFail("Expected messageUpdate")
        }
        guard case let .toolCallStart(contentIndex, id, toolName) = delta else {
            return XCTFail("Expected toolCallStart")
        }
        XCTAssertEqual(contentIndex, 1)
        XCTAssertEqual(id, "call_abc123")
        XCTAssertEqual(toolName, "write")
    }

    func testToolExecutionLifecycle() throws {
        let start = try decodeEvent(
            #"{"type":"tool_execution_start","toolCallId":"call_abc123","toolName":"bash","args":{"command":"ls -la"}}"#
        )
        guard case let .toolExecutionStart(toolCallId, toolName, arguments) = start else {
            return XCTFail("Expected toolExecutionStart")
        }
        XCTAssertEqual(toolCallId, "call_abc123")
        XCTAssertEqual(toolName, "bash")
        XCTAssertEqual(arguments["command"]?.stringValue, "ls -la")

        let end = try decodeEvent(
            #"{"type":"tool_execution_end","toolCallId":"call_abc123","toolName":"bash","result":{"content":[{"type":"text","text":"total 48\n"}],"details":{}},"isError":false}"#
        )
        guard case let .toolExecutionEnd(_, _, result, isError) = end else {
            return XCTFail("Expected toolExecutionEnd")
        }
        XCTAssertEqual(isError, false)
        XCTAssertEqual(result?["content"]?.arrayValue?.first?["text"]?.stringValue, "total 48\n")
    }

    func testQueueUpdate() throws {
        let event = try decodeEvent(
            #"{"type":"queue_update","steering":["Focus on error handling"],"followUp":["Summarize when finished"]}"#
        )
        guard case let .queueUpdate(steering, followUp) = event else {
            return XCTFail("Expected queueUpdate")
        }
        XCTAssertEqual(steering, ["Focus on error handling"])
        XCTAssertEqual(followUp, ["Summarize when finished"])
    }

    func testAgentEndCarriesMessagesAndRetryFlag() throws {
        let event = try decodeEvent(
            #"{"type":"agent_end","messages":[{"role":"user","content":"Hi"}],"willRetry":true}"#
        )
        guard case let .agentEnd(messages, willRetry) = event else {
            return XCTFail("Expected agentEnd")
        }
        XCTAssertEqual(willRetry, true)
        guard case let .user(content)? = messages.first, case let .text(text) = content else {
            return XCTFail("Expected user message with text content")
        }
        XCTAssertEqual(text, "Hi")
    }

    func testCompactionEndAbortedHasNoSummary() throws {
        let event = try decodeEvent(#"{"type":"compaction_end","reason":"manual","result":null,"aborted":true,"willRetry":false}"#)
        guard case let .compactionEnd(reason, summary, aborted, willRetry, errorMessage) = event else {
            return XCTFail("Expected compactionEnd")
        }
        XCTAssertEqual(reason, "manual")
        XCTAssertNil(summary)
        XCTAssertEqual(aborted, true)
        XCTAssertEqual(willRetry, false)
        XCTAssertNil(errorMessage)
    }

    func testCompactionEndSuccessExtractsSummary() throws {
        let event = try decodeEvent(
            #"{"type":"compaction_end","reason":"threshold","result":{"summary":"Summary of conversation...","firstKeptEntryId":"abc123","tokensBefore":150000,"estimatedTokensAfter":32000},"aborted":false,"willRetry":false}"#
        )
        guard case let .compactionEnd(_, summary, _, _, _) = event else {
            return XCTFail("Expected compactionEnd")
        }
        XCTAssertEqual(summary, "Summary of conversation...")
    }

    func testExtensionUIRequestSelectDialogWithTimeout() throws {
        let event = try decodeEvent(
            #"{"type":"extension_ui_request","id":"uuid-1","method":"select","title":"Allow dangerous command?","options":["Allow","Block"],"timeout":10000}"#
        )
        guard case let .extensionUIRequest(request) = event else {
            return XCTFail("Expected extensionUIRequest")
        }
        XCTAssertEqual(request.id, "uuid-1")
        XCTAssertEqual(request.method, .select)
        XCTAssertEqual(request.title, "Allow dangerous command?")
        XCTAssertEqual(request.options, ["Allow", "Block"])
        XCTAssertEqual(request.timeoutMilliseconds, 10000)
        XCTAssertTrue(request.isDialog)
    }

    func testExtensionUIRequestNotifyIsFireAndForget() throws {
        let event = try decodeEvent(
            #"{"type":"extension_ui_request","id":"uuid-5","method":"notify","message":"Command blocked by user","notifyType":"warning"}"#
        )
        guard case let .extensionUIRequest(request) = event else {
            return XCTFail("Expected extensionUIRequest")
        }
        XCTAssertEqual(request.method, .notify)
        XCTAssertEqual(request.notifyType, "warning")
        XCTAssertFalse(request.isDialog)
    }

    func testUnknownEventsDoNotFailTheStream() throws {
        let event = try decodeEvent(#"{"type":"future_event","payload":{"nested":true}}"#)
        guard case let .unknown(type, raw) = event else {
            return XCTFail("Expected unknown")
        }
        XCTAssertEqual(type, "future_event")
        XCTAssertEqual(raw["payload"]?["nested"]?.boolValue, true)
    }

    func testAssistantMessageDecodingWithThinkingAndToolCall() throws {
        let event = try decodeEvent(
            #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Hello! How can I help?"},{"type":"thinking","thinking":"User is greeting me..."},{"type":"toolCall","id":"call_123","name":"bash","arguments":{"command":"ls"}}],"api":"anthropic-messages","provider":"anthropic","model":"claude-sonnet-4-20250514","usage":{"input":100,"output":50,"cacheRead":0,"cacheWrite":0,"totalTokens":150},"stopReason":"toolUse","timestamp":1733234567890}}"#
        )
        guard case let .messageEnd(message) = event else {
            return XCTFail("Expected messageEnd")
        }
        guard case let .assistant(blocks, provider, model, usage, stopReason, errorMessage) = message else {
            return XCTFail("Expected assistant message")
        }
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(provider, "anthropic")
        XCTAssertEqual(model, "claude-sonnet-4-20250514")
        XCTAssertEqual(usage?.totalTokens, 150)
        XCTAssertEqual(stopReason, "toolUse")
        XCTAssertNil(errorMessage)
        guard case let .toolCall(id, name, arguments) = blocks[2] else {
            return XCTFail("Expected toolCall block")
        }
        XCTAssertEqual(id, "call_123")
        XCTAssertEqual(name, "bash")
        XCTAssertEqual(arguments["command"]?.stringValue, "ls")
    }

    func testDiscoveredCommandParseKeepsSkillsAndSkipsNameless() throws {
        let json = try PiRPCWire.decodeLine(
            Data(#"{"commands":[{"name":"skill:pdf-tools","description":"Extract PDFs","source":"skill"},{"name":"mcp","source":"extension"},{"description":"no name"}]}"#.utf8)
        )
        let commands = PiDiscoveredCommand.parse(json)
        XCTAssertEqual(commands.map(\.name), ["skill:pdf-tools", "mcp"])
        XCTAssertEqual(commands.first?.description, "Extract PDFs")
        XCTAssertEqual(commands.first?.source, "skill")
        XCTAssertEqual(commands.last?.source, "extension")
        XCTAssertNil(commands.last?.description)
    }
}
