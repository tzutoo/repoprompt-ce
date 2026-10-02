import Foundation
import RepoPromptFoundation
import RepoPromptProcess

/// Headless pi provider for Context Builder discovery and other one-shot runs.
///
/// Launches `pi --mode json` with the same deterministic MCP injection profile as the
/// interactive controller: pinned pi-mcp-adapter, ephemeral `--mcp-config`, mcp-only
/// tools by default, and expected-PID registration against `pi-mcp-RepoPromptCE`.
final class PiExecAgentProvider: HeadlessAgentProvider {
    private let config: PiExecAgentConfig
    private let toolTracking = AgentToolTrackingController()
    private var streamTask: Task<Void, Never>?
    private var ephemeralMCPConfigURL: URL?
    private var runner: CLIProcessRunner?

    private var enableDebugLogging: Bool {
        config.enableDebugLogging
    }

    init(config: PiExecAgentConfig) {
        self.config = config
    }

    // MARK: - HeadlessAgentProvider

    func streamAgentMessage(_ message: AgentMessage, runID: UUID?) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            self.streamTask?.cancel()
            self.streamTask = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await withTaskCancellationHandler {
                    do {
                        try await self.runOnce(message: message, runID: runID, continuation: continuation)
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish(throwing: CancellationError())
                    } catch {
                        continuation.yield(AIStreamResult(type: "error", text: error.localizedDescription))
                        continuation.finish(throwing: error)
                    }
                } onCancel: {
                    Task { [weak self] in
                        await self?.cancelRunningWork()
                    }
                }
            }
        }
    }

    func dispose() async {
        await cancelRunningWork()
    }

    // MARK: - Run

    private func runOnce(
        message: AgentMessage,
        runID: UUID?,
        continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation
    ) async throws {
        let actualRunID = runID ?? UUID()
        if enableDebugLogging {
            print("[PiExec] starting headless run \(actualRunID.uuidString)")
        }

        guard await ServerNetworkManager.shared.isRunning() else {
            throw AIProviderError.invalidConfiguration(detail: "Could not start MCP server. Check MCP settings and try again.")
        }

        let environment = await launchEnvironment
        let executablePath = try resolveExecutable(environment: environment)
        let mcpConfigPath = try writeEphemeralMCPConfiguration(runID: actualRunID)
        defer { removeEphemeralMCPConfiguration() }

        let combinedPrompt = combinedPrompt(from: message)
        let launchOptions = PiProviderRuntimeBridge.LaunchOptions(
            mode: .jsonEventStream(initialPrompt: combinedPrompt),
            model: modelSelection,
            session: .ephemeral,
            toolProfile: config.toolProfile,
            extensionPolicy: PiProviderRuntimeBridge.managedExtensionPolicy(
                adapterVersion: config.pinnedAdapterVersion
            ),
            mcpConfigPath: mcpConfigPath,
            suppressProjectResources: true,
            suppressContextFiles: true,
            quietStartupNetwork: true
        )

        var processConfig = CLIProcessConfiguration(
            command: executablePath,
            workingDirectory: config.workspacePath,
            environment: environment.merging(launchOptions.environment(over: [:])) { _, new in new },
            enableDebugLogging: enableDebugLogging,
            captureStdoutTailBytes: 128 * 1024,
            captureStderrTailBytes: 256 * 1024,
            logStdinSampleBytes: 0
        )
        processConfig.ensureAdditionalPaths(CLIPathHints.nativeDefaultsSupplemented(with: []))
        let runner = CLIProcessRunner(config: processConfig)
        self.runner = runner

        try await AsyncScope.withCleanup({}, cleanup: {
            await self.toolTracking.stopTracking()
            await runner.cancelAll()
            self.runner = nil
        }) {
            self.toolTracking.startTracking(
                runID: actualRunID,
                clientNameHint: AgentProviderKind.piMCPClientID,
                continuation: continuation
            )

            let stream = try await runner.runStreaming(
                args: launchOptions.arguments(),
                stdin: String?.none,
                outputMode: CLIProcessRunner.OutputFlagMode.none,
                timeout: 6000,
                onProcessStarted: { pid in
                    await ServerNetworkManager.shared.registerExpectedAgentPID(
                        pid,
                        for: AgentProviderKind.piMCPClientID,
                        runID: actualRunID
                    )
                },
                onProcessTerminated: { pid in
                    await ServerNetworkManager.shared.clearExpectedAgentPID(
                        pid,
                        for: AgentProviderKind.piMCPClientID,
                        runID: actualRunID
                    )
                }
            )

            var framer = LineFramer()
            var stderrFramer = LineFramer()
            var stdoutTail = Data()
            var stderrTail = Data()
            var exitStatus: Int32?
            var timedOut = false
            var sawCompletion = false
            var sessionID: String?

            outerLoop: for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case let .stdout(chunk):
                    appendTail(&stdoutTail, chunk: chunk, limit: 128 * 1024)
                    var sawStopThisChunk = false
                    framer.feed(chunk) { lineData in
                        if sawStopThisChunk { return }
                        for result in self.parseJSONLLine(lineData, sessionID: &sessionID) {
                            if result.type == "message_stop" {
                                sawCompletion = true
                                sawStopThisChunk = true
                            }
                            continuation.yield(result)
                        }
                    }
                    if sawStopThisChunk {
                        break outerLoop
                    }
                case let .stderr(chunk):
                    appendTail(&stderrTail, chunk: chunk, limit: 256 * 1024)
                    stderrFramer.feed(chunk) { lineData in
                        guard let message = String(data: lineData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                            !message.isEmpty
                        else { return }
                        if self.enableDebugLogging {
                            print("[PiExec][stderr] \(message)")
                        }
                        continuation.yield(AIStreamResult(type: "system", text: message))
                    }
                case let .terminated(status, didTimeout):
                    exitStatus = status
                    timedOut = didTimeout
                }
            }

            framer.flush { trailing in
                for result in self.parseJSONLLine(trailing, sessionID: &sessionID) {
                    if result.type == "message_stop" {
                        sawCompletion = true
                    }
                    continuation.yield(result)
                }
            }
            stderrFramer.flush { trailingErr in
                guard let message = String(data: trailingErr, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !message.isEmpty
                else { return }
                continuation.yield(AIStreamResult(type: "system", text: message))
            }

            if timedOut {
                throw AIProviderError.invalidResponse(detail: "pi headless run timed out.")
            }
            if let exitStatus, exitStatus != 0, !sawCompletion {
                let stderrText = String(data: stderrTail.suffix(2000), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = stderrText.flatMap { $0.isEmpty ? nil : $0 } ?? "pi exited with code \(exitStatus)"
                throw AIProviderError.invalidResponse(detail: detail)
            }
            if !sawCompletion {
                continuation.yield(
                    AIStreamResult(
                        type: "message_stop",
                        text: nil,
                        providerSessionID: sessionID
                    )
                )
            }
        }
    }

    private func cancelRunningWork() async {
        streamTask?.cancel()
        streamTask = nil
        await toolTracking.stopTracking()
        await runner?.cancelAll()
        runner = nil
        removeEphemeralMCPConfiguration()
    }

    // MARK: - Launch helpers

    private var modelSelection: PiProviderRuntimeBridge.ModelSelection? {
        guard let raw = config.modelString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw != AgentModel.defaultModel.rawValue
        else {
            return nil
        }
        return PiProviderRuntimeBridge.ModelSelection(modelPattern: raw)
    }

    private func combinedPrompt(from message: AgentMessage) -> String {
        let system = message.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = message.userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if system.isEmpty {
            return user
        }
        if user.isEmpty {
            return system
        }
        return """
        \(system)

        \(user)
        """
    }

    private var launchEnvironment: [String: String] {
        get async {
            let result = await ProcessEnvironmentBuilder.build(
                ProcessEnvironmentRequest(
                    purpose: .piNative,
                    inheritedEnvironment: ProcessInfo.processInfo.environment,
                    overrides: [:],
                    additionalRemovedKeys: [],
                    enableDebugLogging: enableDebugLogging
                )
            )
            return result.environment
        }
    }

    private func resolveExecutable(environment: [String: String]) throws -> String {
        let resolved = CommandPathResolver.resolve(
            "pi",
            environment: environment,
            additionalPaths: CLIPathHints.nativeDefaultsSupplemented(with: []),
            preferredBasenames: ["pi"]
        )
        guard resolved.contains("/"), FileManager.default.isExecutableFile(atPath: resolved) else {
            throw AIProviderError.invalidConfiguration(
                detail: "The pi coding agent CLI was not found. Install it with `npm install -g @earendil-works/pi-coding-agent` under a user-owned prefix."
            )
        }
        return resolved
    }

    private func writeEphemeralMCPConfiguration(runID: UUID) throws -> String {
        let serverConfiguration = RepoPromptMCPServerConfiguration.repoPrompt
        let document = PiProviderRuntimeBridge.MCPAdapterConfigurationDocument(
            servers: [
                serverConfiguration.name: PiProviderRuntimeBridge.MCPServerConfiguration(
                    command: serverConfiguration.command,
                    arguments: serverConfiguration.args,
                    environment: serverConfiguration.environmentDictionary,
                    lifecycle: .eager,
                    requestTimeoutMilliseconds: 15000,
                    directTools: .all
                )
            ]
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpce-pi-headless-mcp-\(runID.uuidString).json")
        do {
            try document.encodedDocument().write(to: url, options: .atomic)
            ephemeralMCPConfigURL = url
            return url.path
        } catch {
            throw AIProviderError.invalidConfiguration(
                detail: "Failed writing the ephemeral pi MCP configuration: \(error.localizedDescription)"
            )
        }
    }

    private func removeEphemeralMCPConfiguration() {
        guard let url = ephemeralMCPConfigURL else { return }
        ephemeralMCPConfigURL = nil
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Event mapping

    #if DEBUG
        /// Test seam for JSON event mapping without launching a process.
        static func test_parseJSONLLine(_ data: Data, sessionID: inout String?) -> [AIStreamResult] {
            PiExecAgentProvider(config: .init()).parseJSONLLine(data, sessionID: &sessionID)
        }
    #endif

    private func parseJSONLLine(_ data: Data, sessionID: inout String?) -> [AIStreamResult] {
        guard let json = try? PiProviderRuntimeBridge.RPCWire.decodeLine(data) else {
            return []
        }
        guard let object = json.objectValue, let type = object["type"]?.stringValue else {
            return []
        }

        switch type {
        case "session":
            if let id = object["id"]?.stringValue, !id.isEmpty {
                sessionID = id
            }
            return []
        case "agent_start", "turn_start", "agent_end", "turn_end", "tool_execution_update":
            return []
        case "message_start":
            return []
        case "message_update":
            return parseMessageUpdate(object)
        case "message_end":
            return parseMessageEnd(object)
        case "tool_execution_start":
            // MCP tools are surfaced through AgentToolTrackingController observers.
            // Built-in tools are disabled in the default mcpOnly profile.
            return []
        case "tool_execution_end":
            return []
        case "agent_settled":
            return [
                AIStreamResult(
                    type: "message_stop",
                    text: nil,
                    providerSessionID: sessionID
                )
            ]
        case "extension_error":
            let detail = object["message"]?.stringValue ?? "pi extension error"
            return [AIStreamResult(type: "error", text: detail)]
        default:
            if enableDebugLogging {
                print("[PiExec] ignoring event type: \(type)")
            }
            return []
        }
    }

    private func parseMessageUpdate(_ object: [String: PiProviderRuntimeBridge.JSONValue]) -> [AIStreamResult] {
        guard let deltaJSON = object["assistantMessageEvent"] ?? object["assistant_message_event"],
              let delta = PiProviderRuntimeBridge.AssistantMessageDelta(json: deltaJSON)
        else {
            return []
        }
        switch delta {
        case let .textDelta(_, text):
            return [AIStreamResult(type: "content", text: text)]
        case let .thinkingDelta(_, text):
            return [AIStreamResult(type: "reasoning", text: text)]
        default:
            return []
        }
    }

    private func parseMessageEnd(_ object: [String: PiProviderRuntimeBridge.JSONValue]) -> [AIStreamResult] {
        guard let messageJSON = object["message"],
              let message = PiProviderRuntimeBridge.AgentMessage(json: messageJSON)
        else {
            return []
        }
        guard case let .assistant(blocks, _, _, usage, _, errorMessage) = message else {
            return []
        }
        var results: [AIStreamResult] = []
        if let errorMessage, !errorMessage.isEmpty {
            results.append(AIStreamResult(type: "error", text: errorMessage))
        }
        let text = blocks.compactMap {
            if case let .text(value) = $0 { value } else { nil }
        }.joined()
        if !text.isEmpty {
            // Prefer streamed deltas when present; message_end is still useful when
            // providers emit only final blocks.
            results.append(AIStreamResult(type: "content", text: text))
        }
        if let usage {
            results.append(
                AIStreamResult(
                    type: "usage",
                    text: nil,
                    promptTokens: usage.input,
                    completionTokens: usage.output,
                    cost: usage.cost?.total
                )
            )
        }
        return results
    }
}
