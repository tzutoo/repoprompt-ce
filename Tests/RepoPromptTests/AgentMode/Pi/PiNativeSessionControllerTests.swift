import Foundation
@testable import RepoPromptApp
import XCTest

final class PiNativeSessionControllerTests: XCTestCase {
    private var fakePiURL: URL!

    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpce-pi-fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fakePiURL = directory.appendingPathComponent("pi")
        try fakeScript.write(to: fakePiURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePiURL.path)
    }

    override func tearDownWithError() throws {
        if let fakePiURL {
            try? FileManager.default.removeItem(at: fakePiURL.deletingLastPathComponent())
        }
    }

    /// Minimal pi RPC double: get_state returns a fixed session identity, prompt
    /// emits the agent_start → text delta → agent_settled sequence, and every
    /// other command responds with success.
    private var fakeScript: String {
        #"""
        #!/bin/bash
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
          type=$(printf '%s' "$line" | sed -n 's/.*"type":"\([^"]*\)".*/\1/p')
          case "$type" in
            get_state)
              printf '{"id":"%s","type":"response","command":"get_state","success":true,"data":{"sessionId":"fake-session-1","thinkingLevel":"off","isStreaming":false,"messageCount":0}}\n' "$id"
              ;;
            prompt)
              printf '{"id":"%s","type":"response","command":"prompt","success":true}\n' "$id"
              printf '{"type":"agent_start"}\n'
              printf '{"type":"message_update","usage":{"input":10,"output":2,"totalTokens":12,"cost":{"input":0.01,"output":0.02,"cacheRead":0,"cacheWrite":0,"total":0.03}},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"CE_PI_FAKE_OK"}}\n'
              printf '{"type":"agent_settled"}\n'
              ;;
            get_session_stats)
              printf '{"id":"%s","type":"response","command":"get_session_stats","success":true,"data":{"tokens":{"input":10,"output":2,"total":12,"cost":{"total":0.03}},"cost":0.03,"contextUsage":{"tokens":1200,"contextWindow":200000,"percent":0.6}}}\n' "$id"
              ;;
            get_available_models)
              printf '{"id":"%s","type":"response","command":"get_available_models","success":true,"data":{"models":[{"id":"glm-5.3","name":"GLM 5.3","provider":"zai","reasoning":true,"contextWindow":200000,"input":["text"],"thinkingLevelMap":{"off":"off","minimal":null,"low":"low","medium":null,"high":"high","xhigh":null,"max":null}}]}}\n' "$id"
              ;;
            set_model)
              printf '{"id":"%s","type":"response","command":"set_model","success":true,"data":{"id":"glm-5.3","name":"GLM 5.3","provider":"zai","reasoning":true,"contextWindow":200000,"input":["text"],"thinkingLevelMap":{"off":"off","minimal":null,"low":"low","medium":null,"high":"high","xhigh":null,"max":null}}}\n' "$id"
              ;;
            get_available_thinking_levels)
              printf '{"id":"%s","type":"response","command":"get_available_thinking_levels","success":true,"data":{"levels":["off","low","high"]}}\n' "$id"
              ;;
            get_commands)
              printf '{"id":"%s","type":"response","command":"get_commands","success":true,"data":{"commands":[{"name":"skill:pdf-tools","description":"Extract PDFs","source":"skill"},{"name":"mcp","source":"extension"}]}}\n' "$id"
              ;;
            compact)
              printf '{"id":"%s","type":"response","command":"compact","success":true,"data":{"summary":"ok","usage":{"input":1,"output":1,"cost":{"total":0.01}}}}\n' "$id"
              ;;
            *)
              printf '{"id":"%s","type":"response","command":"%s","success":true}\n' "$id" "$type"
              ;;
          esac
        done
        """#
    }

    private func makeController(
        mcpServers: [String: PiProviderRuntimeBridge.MCPServerConfiguration] = [:]
    ) -> PiNativeSessionController {
        PiNativeSessionController(
            options: .init(
                executableURL: fakePiURL,
                mcpServers: mcpServers,
                suppressDeterminismFlags: true,
                stateRequestTimeout: 10,
                commandTimeout: 10
            )
        )
    }

    private func collectedEvents(
        from controller: PiNativeSessionController,
        until predicate: @escaping (NativeAgentRuntimeEvent) -> Bool,
        timeout: TimeInterval = 10
    ) async -> [NativeAgentRuntimeEvent] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[NativeAgentRuntimeEvent], Never>) in
            let task = Task {
                var events: [NativeAgentRuntimeEvent] = []
                for await event in await controller.events {
                    events.append(event)
                    if predicate(event) {
                        continuation.resume(returning: events)
                        return
                    }
                }
                continuation.resume(returning: events)
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                task.cancel()
            }
        }
    }

    func testStartOrResumeEmitsRuntimeInitWithSessionIdentity() async throws {
        let controller = makeController()
        await controller.ensureEventsStreamReady()
        let reference = try await controller.startOrResume(existingSessionID: nil, model: nil, effortLevel: nil, systemPromptOverride: nil)
        XCTAssertEqual(reference.sessionID, "fake-session-1")
        let events = await collectedEvents(from: controller, until: {
            if case .runtimeInit = $0 { return true }
            return false
        })
        guard case let .runtimeInit(status) = events.last else {
            return XCTFail("Expected runtimeInit event, got: \(events)")
        }
        XCTAssertEqual(status.sessionID, "fake-session-1")
        XCTAssertNil(status.initializeResponse)
        let active = await controller.hasActiveSession
        XCTAssertTrue(active)
        await controller.shutdown()
    }

    func testSendUserMessageStreamsContentAndCompletesTurnOnAgentSettled() async throws {
        let controller = makeController()
        await controller.ensureEventsStreamReady()
        _ = try await controller.startOrResume(existingSessionID: nil, model: nil, effortLevel: nil, systemPromptOverride: nil)
        let turnID = try await controller.sendUserMessage("Reply with CE_PI_FAKE_OK")
        let events = await collectedEvents(from: controller, until: {
            if case let .turnCompleted(turnID, _) = $0 { return turnID == turnID }
            return false
        })
        var sawContent = false
        var stopResult: AIStreamResult?
        var turnStatus: NativeAgentRuntimeTurnStatus?
        for event in events {
            switch event {
            case let .stream(result):
                if result.type == "content", result.text == "CE_PI_FAKE_OK" {
                    sawContent = true
                }
                if result.type == "message_stop" {
                    stopResult = result
                }
            case let .turnCompleted(completedTurnID, status):
                if completedTurnID == turnID {
                    turnStatus = status
                }
            default:
                break
            }
        }
        XCTAssertTrue(sawContent, "Expected streamed content delta; events: \(events)")
        XCTAssertEqual(turnStatus, .completed)
        let stop = try XCTUnwrap(stopResult)
        XCTAssertEqual(stop.providerSessionID, "fake-session-1")
        XCTAssertEqual(stop.promptTokens, 10)
        XCTAssertEqual(stop.completionTokens, 2)
        XCTAssertEqual(stop.cost ?? 0, 0.03, accuracy: 0.0001)
        XCTAssertEqual(stop.contextUsedTokens, 1200)
        XCTAssertEqual(stop.modelContextWindow, 200_000)
        let turnInFlight = await controller.hasTurnInFlight
        XCTAssertFalse(turnInFlight)
        await controller.shutdown()
    }

    func testEphemeralMCPConfigurationLifecycle() async throws {
        let controller = PiNativeSessionController(
            options: .init(
                executableURL: fakePiURL,
                mcpServers: [
                    "RepoPromptCE": PiProviderRuntimeBridge.MCPServerConfiguration(
                        command: "/usr/local/bin/repoprompt-ce-cli",
                        arguments: ["--backend", "app"]
                    )
                ],
                suppressDeterminismFlags: true,
                stateRequestTimeout: 10,
                commandTimeout: 10
            )
        )
        await controller.ensureEventsStreamReady()
        let tempDirectory = FileManager.default.temporaryDirectory
        let preexisting = try Set(
            FileManager.default.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("rpce-pi-mcp-") && $0.pathExtension == "ts" }
                .map(\.path)
        )
        _ = try await controller.startOrResume(existingSessionID: nil, model: nil, effortLevel: nil, systemPromptOverride: nil)
        // Observe only files this controller created so concurrent live smokes or
        // leftover sessions cannot fail the assertion.
        let created = try FileManager.default.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("rpce-pi-mcp-") && $0.pathExtension == "ts" }
            .filter { !preexisting.contains($0.path) }
        XCTAssertEqual(created.count, 1, "Expected exactly one ephemeral pi MCP injector from this controller")
        let createdPath = try XCTUnwrap(created.first?.path)
        let source = try String(contentsOfFile: createdPath, encoding: .utf8)
        XCTAssertTrue(source.contains("registerMcpServer"))
        await controller.shutdown()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: createdPath),
            "Ephemeral injector \(createdPath) should be removed on shutdown"
        )
    }

    func testCompactSessionSynthesizesCompletedTurn() async throws {
        let controller = makeController()
        await controller.ensureEventsStreamReady()
        _ = try await controller.startOrResume(existingSessionID: nil, model: nil, effortLevel: nil, systemPromptOverride: nil)
        let turnID = try await controller.compactSession()
        let events = await collectedEvents(from: controller, until: {
            if case let .turnCompleted(completed, _) = $0 { return completed == turnID }
            return false
        })
        var turnStatus: NativeAgentRuntimeTurnStatus?
        var stopResult: AIStreamResult?
        for event in events {
            switch event {
            case let .stream(result) where result.type == "message_stop":
                stopResult = result
            case let .turnCompleted(completed, status) where completed == turnID:
                turnStatus = status
            default:
                break
            }
        }
        XCTAssertEqual(turnStatus, .completed)
        XCTAssertEqual(try XCTUnwrap(stopResult).stopReason, "compact")
        await controller.shutdown()
    }

    func testConfirmExtensionUIRequestEmitsApprovalAndAcceptsDecision() async throws {
        let directory = fakePiURL.deletingLastPathComponent()
        let gatedURL = directory.appendingPathComponent("pi-gate")
        let gatedScript = #"""
        #!/bin/bash
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
          type=$(printf '%s' "$line" | sed -n 's/.*"type":"\([^"]*\)".*/\1/p')
          case "$type" in
            get_state)
              printf '{"id":"%s","type":"response","command":"get_state","success":true,"data":{"sessionId":"fake-session-1"}}\n' "$id"
              printf '{"type":"extension_ui_request","id":"gate-1","method":"confirm","title":"Allow pi bash?","message":"pi wants to run a shell command."}\n'
              ;;
            *)
              printf '{"id":"%s","type":"response","command":"%s","success":true}\n' "$id" "$type"
              ;;
          esac
        done
        """#
        try gatedScript.write(to: gatedURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gatedURL.path)
        defer { try? FileManager.default.removeItem(at: gatedURL) }

        let controller = PiNativeSessionController(
            options: .init(
                executableURL: gatedURL,
                suppressDeterminismFlags: true,
                stateRequestTimeout: 10,
                commandTimeout: 10
            )
        )
        await controller.ensureEventsStreamReady()
        let eventsTask = Task {
            await self.collectedEvents(from: controller, until: {
                if case .approvalRequest = $0 { return true }
                return false
            })
        }
        _ = try await controller.startOrResume(existingSessionID: nil, model: nil, effortLevel: nil, systemPromptOverride: nil)
        let events = await eventsTask.value
        var request: AgentApprovalRequest?
        for event in events {
            if case let .approvalRequest(approval) = event {
                request = approval
            }
        }
        let approval = try XCTUnwrap(request)
        XCTAssertEqual(approval.requestID, .piExtensionUI("gate-1"))
        XCTAssertEqual(approval.kind, .commandExecution)
        await controller.respondToPermissionRequest(id: "gate-1", decision: .accept)
        await controller.respondToPermissionRequest(id: "gate-2", decision: .decline)
        await controller.respondToPermissionRequest(id: "gate-3", decision: .cancel)
        await controller.shutdown()
    }

    func testSetModelUpsertsThinkingLevelsAndGetCommandsCachesSlashList() async throws {
        PiModelRegistry.clear()
        defer { PiModelRegistry.clear() }
        PiModelRegistry.update(records: [
            PiModelRegistry.ModelRecord(
                id: "glm-5.3",
                name: "GLM 5.3",
                provider: "zai",
                reasoning: true,
                contextWindow: 200_000,
                thinkingLevels: ["off", "minimal", "low", "medium", "high"]
            )
        ])
        let controller = makeController()
        await controller.ensureEventsStreamReady()
        _ = try await controller.startOrResume(existingSessionID: nil, model: nil, effortLevel: nil, systemPromptOverride: nil)
        try await controller.applyModelAndEffort(model: "zai/glm-5.3", effortLevel: .high)
        XCTAssertEqual(
            PiModelRegistry.reasoningEffortOptions(forRaw: "zai/glm-5.3").map(\.rawValue),
            ["none", "low", "high"]
        )
        let commands = await controller.discoveredSlashCommands()
        XCTAssertEqual(commands.map(\.name), ["skill:pdf-tools", "mcp"])
        XCTAssertEqual(commands.first?.source, "skill")
        await controller.shutdown()
    }

    func testApplyThinkingLevelOffSucceeds() async throws {
        let controller = makeController()
        await controller.ensureEventsStreamReady()
        _ = try await controller.startOrResume(existingSessionID: nil, model: nil, effortLevel: nil, systemPromptOverride: nil)
        try await controller.applyThinkingLevel("off")
        try await controller.applyThinkingLevel("minimal")
        await controller.shutdown()
    }

    func testProcessExitFailsPendingTurn() async throws {
        let directory = fakePiURL.deletingLastPathComponent()
        let exitingURL = directory.appendingPathComponent("pi-exit")
        try "#!/bin/bash\nexit 7\n".write(to: exitingURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exitingURL.path)
        defer { try? FileManager.default.removeItem(at: exitingURL) }

        let controller = PiNativeSessionController(
            options: .init(
                executableURL: exitingURL,
                suppressDeterminismFlags: true,
                stateRequestTimeout: 5,
                commandTimeout: 5
            )
        )
        await controller.ensureEventsStreamReady()
        do {
            _ = try await controller.startOrResume(existingSessionID: nil, model: nil, effortLevel: nil, systemPromptOverride: nil)
            XCTFail("Expected initialization failure when the process exits immediately")
        } catch {
            // Expected: get_state round trip fails via EOF or timeout.
        }
        await controller.shutdown()
    }
}
