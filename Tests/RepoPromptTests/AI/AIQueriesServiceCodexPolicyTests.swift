@testable import RepoPrompt
import XCTest

final class AIQueriesServiceCodexPolicyTests: XCTestCase {
    func testCodexEphemeralThreadPolicyMatrix() {
        let rows: [(label: String, model: AIModel, queryOrigin: AIQueryOrigin, expected: Bool)] = [
            ("Oracle Codex", .codexCliGpt5Medium, .oracle, true),
            ("ordinary Codex chat", .codexCliGpt5Medium, .standardChat, false),
            ("Oracle non-Codex", .claude4Sonnet, .oracle, false)
        ]

        for row in rows {
            XCTAssertEqual(
                AIQueriesService.shouldStartNewCodexThreadsEphemerally(
                    for: row.model,
                    queryOrigin: row.queryOrigin
                ),
                row.expected,
                row.label
            )
        }
    }
}
