import Foundation
@testable import RepoPrompt
import XCTest

final class CodexCLIProviderThreadPolicyTests: XCTestCase {
    func testProviderForwardsThreadPolicyAndAlwaysStartsFreshThreadMatrix() async throws {
        for startNewCodexThreadsEphemerally in [true, false] {
            let recorder = CodexProviderThreadPolicyRecorder()
            let provider = makeProvider(
                startNewCodexThreadsEphemerally: startNewCodexThreadsEphemerally,
                recorder: recorder
            )

            try await exhaust(provider: provider)

            XCTAssertEqual(recorder.recordedEphemeralPolicies, [startNewCodexThreadsEphemerally])
            XCTAssertEqual(recorder.recordedExistingSessionFlags, [false])
        }
    }

    private func makeProvider(
        startNewCodexThreadsEphemerally: Bool,
        recorder: CodexProviderThreadPolicyRecorder
    ) -> CodexCLIProvider {
        CodexCLIProvider(
            maxRetries: 0,
            appServerReadyHook: {},
            startNewCodexThreadsEphemerally: startNewCodexThreadsEphemerally,
            sessionControllerFactory: { _, _, ephemeral in
                recorder.recordPolicy(ephemeral)
                return CompletedCodexSessionController { existing in
                    recorder.recordExistingSession(existing != nil)
                }
            }
        )
    }

    private func exhaust(provider: CodexCLIProvider) async throws {
        let stream = try await provider.streamMessage(
            AIMessage(systemPrompt: "", userMessage: "hello"),
            model: .codexCliGpt5Medium
        )
        for try await _ in stream {}
        await provider.dispose()
    }
}

private final class CodexProviderThreadPolicyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ephemeralPolicies: [Bool] = []
    private var existingSessionFlags: [Bool] = []

    var recordedEphemeralPolicies: [Bool] {
        lock.withLock { ephemeralPolicies }
    }

    var recordedExistingSessionFlags: [Bool] {
        lock.withLock { existingSessionFlags }
    }

    func recordPolicy(_ value: Bool) {
        lock.withLock {
            ephemeralPolicies.append(value)
        }
    }

    func recordExistingSession(_ value: Bool) {
        lock.withLock {
            existingSessionFlags.append(value)
        }
    }
}

private final class CompletedCodexSessionController: CodexSessionControlling {
    private let onStart: (CodexNativeSessionController.SessionRef?) -> Void
    private(set) var hasActiveThread = false
    let events: AsyncStream<CodexNativeSessionController.Event>

    init(onStart: @escaping (CodexNativeSessionController.SessionRef?) -> Void) {
        self.onStart = onStart
        events = AsyncStream { continuation in
            continuation.yield(.turnCompleted(turnID: "turn", status: .completed))
            continuation.finish()
        }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        try await startOrResume(existing: existing, baseInstructions: baseInstructions, model: nil, reasoningEffort: nil, serviceTier: nil)
    }

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        try await startOrResume(
            existing: existing,
            baseInstructions: baseInstructions,
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: nil
        )
    }

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        onStart(existing)
        hasActiveThread = true
        return CodexNativeSessionController.SessionRef(
            conversationID: "fresh",
            rolloutPath: nil,
            model: model,
            reasoningEffort: reasoningEffort
        )
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        throw CancellationError()
    }

    func setThreadName(_: String, threadID _: String?) async throws {}
    func sendUserMessage(_: String) async throws {}
    func sendUserTurn(text _: String, images _: [AgentImageAttachment]) async throws {}
    func sendUserTurn(text _: String, images _: [AgentImageAttachment], model _: String?, reasoningEffort _: String?) async throws {}
    func sendUserTurn(text _: String, images _: [AgentImageAttachment], model _: String?, reasoningEffort _: String?, serviceTier _: String?) async throws {}
    func compactThread() async throws {}
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func setThreadGoalObjective(_: String) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func setThreadGoalStatus(_: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        throw CancellationError()
    }

    func clearThreadGoal() async throws -> Bool {
        false
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}
