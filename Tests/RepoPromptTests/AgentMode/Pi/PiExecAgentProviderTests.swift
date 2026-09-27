import Foundation
@testable import RepoPromptApp
import XCTest

final class PiExecAgentProviderTests: XCTestCase {
    func testFactoryReturnsPiExecProvider() {
        let provider = AgentRuntimeProviderService.shared.makeProvider(
            for: .piAgent,
            modelString: "default",
            runType: .discover,
            workspacePath: "/tmp"
        )
        XCTAssertTrue(provider is PiExecAgentProvider)
    }

    func testJSONEventMappingStreamsContentAndCompletion() {
        var sessionID: String?
        let sessionLine = Data(#"{"type":"session","id":"headless-session-1"}"#.utf8)
        let deltaLine = Data(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"hello"}}"#.utf8)
        let settledLine = Data(#"{"type":"agent_settled"}"#.utf8)

        let sessionEvents = PiExecAgentProvider.test_parseJSONLLine(sessionLine, sessionID: &sessionID)
        XCTAssertTrue(sessionEvents.isEmpty)
        XCTAssertEqual(sessionID, "headless-session-1")

        let deltaEvents = PiExecAgentProvider.test_parseJSONLLine(deltaLine, sessionID: &sessionID)
        XCTAssertEqual(deltaEvents.count, 1)
        XCTAssertEqual(deltaEvents.first?.type, "content")
        XCTAssertEqual(deltaEvents.first?.text, "hello")

        let settledEvents = PiExecAgentProvider.test_parseJSONLLine(settledLine, sessionID: &sessionID)
        XCTAssertEqual(settledEvents.count, 1)
        XCTAssertEqual(settledEvents.first?.type, "message_stop")
        XCTAssertEqual(settledEvents.first?.providerSessionID, "headless-session-1")
    }
}
