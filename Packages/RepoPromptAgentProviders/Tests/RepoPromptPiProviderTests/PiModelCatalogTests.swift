import Foundation
@testable import RepoPromptPiProvider
import XCTest

final class PiModelCatalogTests: XCTestCase {
    private func decode(_ line: String) throws -> PiJSONValue {
        try PiRPCWire.decodeLine(Data(line.utf8))
    }

    func testModelDescriptorDecodesCoreFields() throws {
        let json = try decode(
            #"{"id":"claude-sonnet-4-20250514","name":"Claude Sonnet 4","api":"anthropic-messages","provider":"anthropic","baseUrl":"https://api.anthropic.com","reasoning":true,"input":["text","image"],"contextWindow":200000,"maxTokens":16384,"cost":{"input":3.0,"output":15.0,"cacheRead":0.3,"cacheWrite":3.75}}"#
        )
        let model = try XCTUnwrap(PiModelDescriptor(json: json))
        XCTAssertEqual(model.id, "claude-sonnet-4-20250514")
        XCTAssertEqual(model.provider, "anthropic")
        XCTAssertEqual(model.contextWindow, 200_000)
        XCTAssertTrue(model.reasoning)
        XCTAssertEqual(model.inputTypes, ["text", "image"])
        XCTAssertTrue(model.thinkingLevelMap.isEmpty)
    }

    func testThinkingLevelMapTristateWithHoles() throws {
        // Live-probed shape: glm-5.3 exposes low/high/max only; thinking cannot be
        // disabled (`off: null`).
        let json = try decode(
            #"{"id":"glm-5.3","provider":"zai","api":"openai-completions","reasoning":true,"thinkingLevelMap":{"off":null,"minimal":null,"low":"low","medium":null,"high":"high","xhigh":null,"max":"max"}}"#
        )
        let model = try XCTUnwrap(PiModelDescriptor(json: json))
        XCTAssertEqual(model.thinkingLevelMap[.off], .unsupported)
        XCTAssertEqual(model.thinkingLevelMap[.minimal], .unsupported)
        XCTAssertEqual(model.thinkingLevelMap[.low], .supported(providerValue: "low"))
        XCTAssertEqual(model.thinkingLevelMap[.medium], .unsupported)
        XCTAssertEqual(model.thinkingLevelMap[.high], .supported(providerValue: "high"))
        XCTAssertEqual(model.thinkingLevelMap[.xhigh], .unsupported)
        XCTAssertEqual(model.thinkingLevelMap[.max], .supported(providerValue: "max"))
        // `off: null` means thinking cannot be disabled; `minimal`/`medium` are null too.
        XCTAssertEqual(model.effectiveThinkingLevels(), [.low, .high, .max])
    }

    func testAbsentExtendedLevelsDefaultToUnsupported() throws {
        let json = try decode(
            #"{"id":"m","provider":"p","api":"openai-completions","reasoning":true,"thinkingLevelMap":{"low":"low"}}"#
        )
        let model = try XCTUnwrap(PiModelDescriptor(json: json))
        // Absent standard levels (through high) stay supported; xhigh/max do not.
        XCTAssertEqual(
            model.effectiveThinkingLevels(),
            [.off, .minimal, .low, .medium, .high]
        )
    }

    func testNonReasoningModelOnlyExposesOff() throws {
        let json = try decode(#"{"id":"m2","provider":"p","reasoning":false}"#)
        let model = try XCTUnwrap(PiModelDescriptor(json: json))
        XCTAssertEqual(model.effectiveThinkingLevels(), [.off])
    }

    func testDefaultsWhenMetadataIsSparse() throws {
        let json = try decode(#"{"id":"qwen38-27b-exl3-262k"}"#)
        let model = try XCTUnwrap(PiModelDescriptor(json: json))
        XCTAssertEqual(model.contextWindow, 128_000)
        XCTAssertEqual(model.maxTokens, 16384)
        XCTAssertEqual(model.inputTypes, ["text"])
        XCTAssertEqual(model.name, "qwen38-27b-exl3-262k")
    }

    func testSessionStateDecoding() throws {
        let json = try decode(
            #"{"model":{"id":"glm-5.3","provider":"zai","reasoning":true},"thinkingLevel":"off","isStreaming":false,"isCompacting":false,"steeringMode":"one-at-a-time","followUpMode":"one-at-a-time","sessionFile":"/tmp/s.jsonl","sessionId":"01a06f3a-5c10-70fb-8c41-c624f07d7bcd","autoCompactionEnabled":true,"messageCount":0,"pendingMessageCount":0}"#
        )
        let state = try XCTUnwrap(PiSessionState(json: json))
        XCTAssertEqual(state.model?.id, "glm-5.3")
        XCTAssertEqual(state.thinkingLevel, "off")
        XCTAssertEqual(state.sessionId, "01a06f3a-5c10-70fb-8c41-c624f07d7bcd")
        XCTAssertNil(state.sessionName)
        XCTAssertTrue(state.autoCompactionEnabled)
    }

    func testSessionStatsDecodingWithContextUsage() throws {
        let json = try decode(
            #"{"sessionFile":"/path/to/session.jsonl","sessionId":"abc123","userMessages":5,"assistantMessages":5,"toolCalls":12,"toolResults":12,"totalMessages":22,"tokens":{"input":50000,"output":10000,"cacheRead":40000,"cacheWrite":5000,"total":105000},"cost":0.45,"contextUsage":{"tokens":60000,"contextWindow":200000,"percent":30}}"#
        )
        let stats = try XCTUnwrap(PiSessionStats(json: json))
        XCTAssertEqual(stats.totalMessages, 22)
        XCTAssertEqual(stats.usage?.totalTokens, 105_000)
        XCTAssertEqual(stats.cost, 0.45, accuracy: 0.0001)
        XCTAssertEqual(stats.contextUsage?.percent, 30)
        XCTAssertEqual(stats.contextUsage?.contextWindow, 200_000)
        XCTAssertEqual(stats.contextUsage?.tokens, 60000)
    }

    func testSessionStatsToleratesNullContextTokensAfterCompaction() throws {
        let json = try decode(
            #"{"sessionId":"abc","contextUsage":{"tokens":null,"contextWindow":200000,"percent":null}}"#
        )
        let stats = try XCTUnwrap(PiSessionStats(json: json))
        XCTAssertNil(stats.contextUsage?.tokens)
        XCTAssertNil(stats.contextUsage?.percent)
    }

    func testSessionEntryListDecodesCursorPayload() throws {
        let json = try decode(
            #"{"entries":[{"type":"message","id":"def456","parentId":"abc123","message":{"role":"user","content":"Next"}}],"leafId":"def456"}"#
        )
        let entries = try XCTUnwrap(PiSessionEntryList(json: json))
        XCTAssertEqual(entries.leafId, "def456")
        XCTAssertEqual(entries.entries.count, 1)
        XCTAssertEqual(entries.entries.first?["id"]?.stringValue, "def456")
    }
}
