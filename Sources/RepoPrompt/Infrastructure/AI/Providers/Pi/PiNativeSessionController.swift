import Foundation

/// Interactive Agent Mode controller for the pi coding agent's RPC mode.
///
/// Owns a `pi --mode rpc` subprocess: strict LF JSONL framing, id-correlated
/// command/response round trips, and translation of pi events into the neutral
/// `NativeAgentRuntimeControlling` contract. MCP injection flows through the
/// ephemeral pi-mcp-adapter `--mcp-config` document (see
/// `docs/architecture/provider-plugins.md` and the pi integration survey).
///
/// v1 boundaries (documented, deliberate):
/// - pi core has no permission requests; extension UI dialogs are auto-cancelled
///   with a lifecycle note. Per-call approval lands with the pinned gate
///   extension follow-up.
/// - `runtimeInit` carries the pi session identity; the Claude-compatible
///   initialize snapshot stays `nil`.
actor PiNativeSessionController: NativeAgentRuntimeControlling {
    struct Options {
        /// Explicit executable override (tests). When `nil`, `pi` is resolved
        /// from the launch environment.
        var executableURL: URL?
        /// Working directory for the pi process (RPCE worktree root).
        var workingDirectory: URL?
        /// Optional validator invoked with the resolved executable before launch
        /// (Agent Mode supplies `ExecutableFileIdentity` trusted-path checks).
        var processValidator: (@Sendable (URL) throws -> Void)?
        /// Ephemeral `--mcp-config` server entries for the RepoPrompt MCP server.
        var mcpServers: [String: PiProviderRuntimeBridge.MCPServerConfiguration]
        /// MCP client name the pi-mcp-adapter presents (`pi-mcp-RepoPromptCE`).
        /// When set, the launched process PID is registered as the expected agent
        /// PID for the run-scoped pending connection policy, mirroring the Claude
        /// controller's registration.
        var expectedPIDMCPClientName: String?
        /// Version pin for the deterministic extension profile.
        var pinnedAdapterVersion: String
        /// Tool surface for the managed launch.
        var toolProfile: PiProviderRuntimeBridge.ToolProfile
        /// Suppress `-na`/`-nc` determinism flags (tests with fake binaries).
        var suppressDeterminismFlags: Bool
        var enableDebugLogging: Bool
        var stateRequestTimeout: TimeInterval
        var commandTimeout: TimeInterval

        init(
            executableURL: URL? = nil,
            workingDirectory: URL? = nil,
            processValidator: (@Sendable (URL) throws -> Void)? = nil,
            mcpServers: [String: PiProviderRuntimeBridge.MCPServerConfiguration] = [:],
            expectedPIDMCPClientName: String? = nil,
            pinnedAdapterVersion: String = "2.32.1",
            toolProfile: PiProviderRuntimeBridge.ToolProfile = .standard,
            suppressDeterminismFlags: Bool = false,
            enableDebugLogging: Bool = false,
            stateRequestTimeout: TimeInterval = 20,
            commandTimeout: TimeInterval = 10
        ) {
            self.executableURL = executableURL
            self.workingDirectory = workingDirectory
            self.processValidator = processValidator
            self.mcpServers = mcpServers
            self.expectedPIDMCPClientName = expectedPIDMCPClientName
            self.pinnedAdapterVersion = pinnedAdapterVersion
            self.toolProfile = toolProfile
            self.suppressDeterminismFlags = suppressDeterminismFlags
            self.enableDebugLogging = enableDebugLogging
            self.stateRequestTimeout = stateRequestTimeout
            self.commandTimeout = commandTimeout
        }
    }

    enum ControllerError: Error, LocalizedError {
        case piNotInstalled
        case invalidExecutable(String)
        case mcpConfigurationWriteFailed(String)
        case stateRequestFailed(String)
        case commandFailed(String)
        case processTerminated(Int32)

        var errorDescription: String? {
            switch self {
            case .piNotInstalled:
                "The pi coding agent CLI was not found. Install it with `npm install -g @earendil-works/pi-coding-agent` under a user-owned prefix."
            case let .invalidExecutable(detail):
                "Invalid pi executable: \(detail)"
            case let .mcpConfigurationWriteFailed(detail):
                "Failed writing the ephemeral pi MCP configuration: \(detail)"
            case let .stateRequestFailed(detail):
                "pi RPC initialization failed: \(detail)"
            case let .commandFailed(detail):
                "pi RPC command failed: \(detail)"
            case let .processTerminated(exitCode):
                "The pi process exited unexpectedly (code \(exitCode))."
            }
        }
    }

    private let options: Options
    private let runID: UUID

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutChunkChannel: FileHandleChunkChannel?
    private var stdoutConsumerTask: Task<Void, Never>?
    private var lineAccumulator = PiProviderRuntimeBridge.RPCLineAccumulator()
    private var registeredExpectedAgentPID: pid_t?
    private var pendingResponses: [String: (Result<PiProviderRuntimeBridge.RPCResponse, Error>) -> Void] = [:]
    private var nextRequestSequence = 0
    private var ephemeralMCPConfigURL: URL?

    private var eventStreamContinuation: AsyncStream<NativeAgentRuntimeEvent>.Continuation?
    private var eventStream: AsyncStream<NativeAgentRuntimeEvent>?
    private var currentSessionIDValue: String?
    private var pendingTurnIDBuffer: [UUID] = []
    private var turnInFlight = false
    private var streamingAssistantText = false
    private var lastTurnUsage: (input: Int, output: Int, cost: Double)?
    private var lastStopReason: String?
    private var toolInvocationIDs: [String: UUID] = [:]
    private var shutDown = false

    init(options: Options, runID: UUID = UUID()) {
        self.options = options
        self.runID = runID
    }

    // MARK: - NativeAgentRuntimeControlling

    var hasActiveSession: Bool {
        process?.isRunning == true
    }

    var hasTurnInFlight: Bool {
        turnInFlight
    }

    var events: AsyncStream<NativeAgentRuntimeEvent> {
        get async {
            if let eventStream {
                return eventStream
            }
            let stream = AsyncStream<NativeAgentRuntimeEvent> { continuation in
                self.eventStreamContinuation = continuation
            }
            eventStream = stream
            return stream
        }
    }

    func ensureEventsStreamReady() async {
        _ = await events
    }

    func resetEventsStreamForNewRun() async {
        eventStreamContinuation?.finish()
        let stream = AsyncStream<NativeAgentRuntimeEvent> { continuation in
            self.eventStreamContinuation = continuation
        }
        eventStream = stream
    }

    func startOrResume(
        existingSessionID: String?,
        model: String?,
        effortLevel: NativeAgentRuntimeEffortLevel?,
        systemPromptOverride: String?
    ) async throws -> NativeAgentRuntimeSessionRef {
        if hasActiveSession {
            return NativeAgentRuntimeSessionRef(sessionID: currentSessionIDValue)
        }
        try launchProcess(
            existingSessionID: existingSessionID,
            model: model,
            effortLevel: effortLevel,
            systemPromptOverride: systemPromptOverride
        )
        // Correlate an initial get_state so Agent Mode learns the session identity
        // before the first prompt; failure here fails the run before any user input.
        let stateResponse = try await roundTrip(.getState, timeout: options.stateRequestTimeout)
        guard stateResponse.success else {
            throw ControllerError.stateRequestFailed(stateResponse.errorMessage ?? "get_state failed")
        }
        let state = stateResponse.data.flatMap(PiProviderRuntimeBridge.SessionState.init(json:))
        currentSessionIDValue = state?.sessionId ?? existingSessionID
        emit(.runtimeInit(NativeAgentRuntimeRuntimeInitStatus(
            sessionID: currentSessionIDValue,
            tools: [],
            mcpServerStatuses: [:],
            initializeResponse: nil
        )))
        return NativeAgentRuntimeSessionRef(sessionID: currentSessionIDValue)
    }

    func currentSessionRef() async -> NativeAgentRuntimeSessionRef {
        NativeAgentRuntimeSessionRef(sessionID: currentSessionIDValue)
    }

    func applyModelAndEffort(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) async throws {
        guard hasActiveSession else {
            throw NativeAgentRuntimeControllerError.processNotRunning
        }
        if let model, !model.isEmpty {
            let selection = PiProviderRuntimeBridge.ModelSelection(modelPattern: model)
            let setModel = PiProviderRuntimeBridge.RPCCommand.setModel(
                provider: selection.provider ?? "",
                modelId: selection.modelPattern
            )
            let response = try await roundTrip(setModel)
            guard response.success else {
                throw ControllerError.commandFailed(response.errorMessage ?? "set_model failed")
            }
        }
        if let effortLevel {
            let response = try await roundTrip(.setThinkingLevel(
                level: PiProviderRuntimeBridge.thinkingLevel(for: effortLevel)
            ))
            guard response.success else {
                throw ControllerError.commandFailed(response.errorMessage ?? "set_thinking_level failed")
            }
        }
    }

    func sendUserMessage(_ text: String) async throws -> UUID {
        guard hasActiveSession else {
            throw NativeAgentRuntimeControllerError.processNotRunning
        }
        let turnID = UUID()
        pendingTurnIDBuffer.append(turnID)
        let behavior: PiProviderRuntimeBridge.StreamingBehavior? = turnInFlight ? .steer : nil
        let response = try await roundTrip(.prompt(message: text, streamingBehavior: behavior))
        guard response.success else {
            pendingTurnIDBuffer.removeAll { $0 == turnID }
            throw ControllerError.commandFailed(response.errorMessage ?? "prompt was rejected")
        }
        return turnID
    }

    func interruptTurn(reason: String) async -> NativeAgentRuntimeInterruptOutcome {
        guard hasActiveSession else { return .failed }
        guard turnInFlight else { return .noTurnInFlight }
        // pi's documented Esc recipe: drop queued messages first, then abort.
        _ = try? await roundTrip(.clearQueue)
        guard let response = try? await roundTrip(.abort), response.success else {
            return .failed
        }
        return .acknowledged
    }

    private func shutdownPendingResponses() {
        for (_, completion) in pendingResponses {
            completion(.failure(NativeAgentRuntimeControllerError.processNotRunning))
        }
        pendingResponses.removeAll()
    }

    func shutdown() async {
        guard !shutDown else { return }
        shutDown = true
        shutdownPendingResponses()
        clearRegisteredExpectedAgentPID()
        if let stdinHandle {
            try? stdinHandle.close()
        }
        stdinHandle = nil
        stdoutConsumerTask?.cancel()
        stdoutConsumerTask = nil
        stdoutChunkChannel?.finish()
        stdoutChunkChannel = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        if let ephemeralMCPConfigURL {
            try? FileManager.default.removeItem(at: ephemeralMCPConfigURL)
        }
        ephemeralMCPConfigURL = nil
        eventStreamContinuation?.finish()
        eventStreamContinuation = nil
        eventStream = nil
    }

    func respondToPermissionRequest(id: String, decision: AgentApprovalDecision) async {
        // pi core raises no permission requests; extension dialogs are
        // auto-cancelled in `handleExtensionUIRequest`.
    }

    // MARK: - Process launch

    private func launchProcess(
        existingSessionID: String?,
        model: String?,
        effortLevel: NativeAgentRuntimeEffortLevel?,
        systemPromptOverride: String?
    ) throws {
        let executableURL = try resolveExecutable()
        var mcpConfigPath: String?
        if !options.mcpServers.isEmpty {
            mcpConfigPath = try writeEphemeralMCPConfiguration()
        }
        var additionalArguments: [String] = []
        if let systemPromptOverride, !systemPromptOverride.isEmpty {
            additionalArguments += ["--append-system-prompt", systemPromptOverride]
        }
        let launchOptions = PiProviderRuntimeBridge.LaunchOptions(
            mode: .rpc,
            model: model.map { PiProviderRuntimeBridge.ModelSelection(modelPattern: $0) },
            session: existingSessionID.map(PiProviderRuntimeBridge.SessionSelection.resume) ?? .persistent,
            toolProfile: options.toolProfile,
            extensionPolicy: .pinnedAdapterOnly(version: options.pinnedAdapterVersion),
            mcpConfigPath: mcpConfigPath,
            suppressProjectResources: !options.suppressDeterminismFlags,
            suppressContextFiles: !options.suppressDeterminismFlags,
            quietStartupNetwork: !options.suppressDeterminismFlags,
            additionalArguments: additionalArguments
        )
        if let effortLevel {
            // Applied live via RPC after initialization; launch flags carry it too
            // so the very first turn already uses the requested level.
            _ = effortLevel
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = launchOptions.arguments()
        if let workingDirectory = options.workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in launchOptions.environment(over: [:]) {
            environment[key] = value
        }
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        lineAccumulator = PiProviderRuntimeBridge.RPCLineAccumulator()
        do {
            try process.run()
        } catch {
            throw ControllerError.invalidExecutable(error.localizedDescription)
        }
        self.process = process
        stdinHandle = stdinPipe.fileHandleForWriting
        if let expectedPIDMCPClientName = options.expectedPIDMCPClientName, process.isRunning {
            registeredExpectedAgentPID = process.processIdentifier
            let pid = process.processIdentifier
            let runID = runID
            Task {
                await ServerNetworkManager.shared.registerExpectedAgentPID(pid, for: expectedPIDMCPClientName, runID: runID)
            }
        }
        let channel = FileHandleChunkChannel()
        stdoutChunkChannel = channel
        let stdoutHandle = stdoutPipe.fileHandleForReading
        stdoutHandle.readabilityHandler = { readable in
            let data = readable.availableData
            if data.isEmpty {
                channel.finish()
                readable.readabilityHandler = nil
            } else {
                channel.yield(data)
            }
        }
        stdoutConsumerTask = Task { [weak self] in
            for await chunk in channel.stream {
                guard let self else { break }
                await handleStdoutChunk(chunk)
            }
            await self?.handleStdoutEOF()
        }
        if options.enableDebugLogging {
            print("[PiNativeSession] launched \(executableURL.path) \(launchOptions.arguments().joined(separator: " "))")
        }
    }

    private func clearRegisteredExpectedAgentPID() {
        guard let pid = registeredExpectedAgentPID,
              let clientName = options.expectedPIDMCPClientName
        else { return }
        registeredExpectedAgentPID = nil
        let runID = runID
        Task {
            await ServerNetworkManager.shared.clearExpectedAgentPID(pid, for: clientName, runID: runID)
        }
    }

    private func resolveExecutable() throws -> URL {
        if let executableURL = options.executableURL {
            try options.processValidator?(executableURL)
            return executableURL
        }
        let environment = ProcessInfo.processInfo.environment
        let resolved = CommandPathResolver.resolve("pi", environment: environment, additionalPaths: [])
        guard resolved.contains("/"), FileManager.default.isExecutableFile(atPath: resolved) else {
            throw ControllerError.piNotInstalled
        }
        let url = URL(fileURLWithPath: resolved)
        try options.processValidator?(url)
        return url
    }

    private func writeEphemeralMCPConfiguration() throws -> String {
        let document = PiProviderRuntimeBridge.MCPAdapterConfigurationDocument(servers: options.mcpServers)
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("rpce-pi-mcp-\(runID.uuidString).json")
            try document.encodedDocument().write(to: url, options: .atomic)
            ephemeralMCPConfigURL = url
            return url.path
        } catch {
            throw ControllerError.mcpConfigurationWriteFailed(error.localizedDescription)
        }
    }

    // MARK: - Command transport

    private func roundTrip(
        _ command: PiProviderRuntimeBridge.RPCCommand,
        timeout: TimeInterval? = nil
    ) async throws -> PiProviderRuntimeBridge.RPCResponse {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try sendCommand(command, timeout: timeout ?? options.commandTimeout) { result in
                    continuation.resume(with: result)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendCommand(
        _ command: PiProviderRuntimeBridge.RPCCommand,
        timeout: TimeInterval,
        completion: @escaping (Result<PiProviderRuntimeBridge.RPCResponse, Error>) -> Void
    ) throws {
        guard let stdinHandle, process?.isRunning == true else {
            throw NativeAgentRuntimeControllerError.processNotRunning
        }
        nextRequestSequence += 1
        let requestID = "rpce-\(runID.uuidString.prefix(8))-\(nextRequestSequence)"
        let data = try PiProviderRuntimeBridge.RPCWire.encodeRequestLine(command, id: requestID)
        pendingResponses[requestID] = completion
        let timeoutNanos = UInt64(max(timeout, 0) * 1_000_000_000)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanos)
            await self?.failPendingResponseIfStillPending(requestID: requestID)
        }
        do {
            try stdinHandle.write(contentsOf: data)
        } catch {
            pendingResponses.removeValue(forKey: requestID)?(.failure(NativeAgentRuntimeControllerError.inputWriteFailed(error.localizedDescription)))
            throw NativeAgentRuntimeControllerError.inputWriteFailed(error.localizedDescription)
        }
    }

    private func failPendingResponseIfStillPending(requestID: String) {
        guard let completion = pendingResponses.removeValue(forKey: requestID) else { return }
        completion(.failure(NativeAgentRuntimeControllerError.controlRequestTimedOut(requestID: requestID)))
    }

    // MARK: - Stdout handling

    private func handleStdoutChunk(_ chunk: Data) async {
        for line in lineAccumulator.append(chunk) {
            await handleLine(line)
        }
    }

    private func handleStdoutEOF() async {
        if let remainder = lineAccumulator.finish() {
            await handleLine(remainder)
        }
        clearRegisteredExpectedAgentPID()
        guard !shutDown else { return }
        let exitCode = process?.terminationStatus ?? -1
        for (_, completion) in pendingResponses {
            completion(.failure(ControllerError.processTerminated(exitCode)))
        }
        pendingResponses.removeAll()
        if turnInFlight, let turnID = pendingTurnIDBuffer.first {
            pendingTurnIDBuffer.removeFirst()
            turnInFlight = false
            emit(.turnCompleted(turnID: turnID, status: .failed))
        }
        emit(.error("pi process exited (code \(exitCode))"))
    }

    private func handleLine(_ line: Data) async {
        let json: PiProviderRuntimeBridge.JSONValue
        do {
            json = try PiProviderRuntimeBridge.RPCWire.decodeLine(line)
        } catch {
            if options.enableDebugLogging {
                print("[PiNativeSession] dropping non-JSON stdout line: \(error.localizedDescription)")
            }
            return
        }
        if let response = PiProviderRuntimeBridge.RPCResponse(json: json) {
            if let id = response.id, let completion = pendingResponses.removeValue(forKey: id) {
                completion(.success(response))
            }
            return
        }
        let event = PiProviderRuntimeBridge.RPCEvent(json: json)
        await handleEvent(event)
    }

    // MARK: - Event mapping

    private func handleEvent(_ event: PiProviderRuntimeBridge.RPCEvent) async {
        switch event {
        case .agentStart:
            turnInFlight = true
            lastTurnUsage = nil
            lastStopReason = nil
        case .agentEnd:
            // A single low-level run may still be followed by retries, compaction,
            // or queued continuations; only agent_settled is the session boundary.
            break
        case .agentSettled:
            completePendingTurn()
        case .turnStart:
            break
        case let .turnEnd(message, _):
            if case let .assistant(_, _, _, usage, stopReason, _) = message {
                if let usage {
                    lastTurnUsage = (usage.input, usage.output, usage.cost?.total ?? 0)
                }
                lastStopReason = stopReason ?? lastStopReason
            }
        case let .messageStart(message):
            streamingAssistantText = false
            if case let .assistant(_, _, _, usage, _, _) = message {
                if let usage {
                    lastTurnUsage = (usage.input, usage.output, usage.cost?.total ?? 0)
                }
            }
        case let .messageUpdate(usage, delta):
            if let usage {
                lastTurnUsage = (usage.input, usage.output, usage.cost?.total ?? 0)
            }
            switch delta {
            case let .textDelta(_, deltaText):
                streamingAssistantText = true
                emit(.stream(AIStreamResult(type: "content", text: deltaText)))
            case let .thinkingDelta(_, deltaText):
                emit(.stream(AIStreamResult(type: "reasoning", text: deltaText)))
            default:
                break
            }
        case let .messageEnd(message):
            if case let .assistant(blocks, _, _, usage, stopReason, _) = message {
                if let usage {
                    lastTurnUsage = (usage.input, usage.output, usage.cost?.total ?? 0)
                }
                lastStopReason = stopReason ?? lastStopReason
                // Content blocks that streamed as deltas are already emitted; only
                // emit unsent non-delta text if no deltas were observed for safety.
                if !streamingAssistantText {
                    let text = blocks.compactMap {
                        if case let .text(value) = $0 { value } else { nil }
                    }.joined()
                    if !text.isEmpty {
                        emit(.stream(AIStreamResult(type: "content", text: text)))
                    }
                }
            }
        case let .toolExecutionStart(toolCallId, toolName, arguments):
            let invocationID = UUID()
            toolInvocationIDs[toolCallId] = invocationID
            let argsJSON = jsonString(from: arguments)
            emit(.stream(AIStreamResult(
                type: "tool_call",
                text: nil,
                toolName: toolName,
                toolArgs: argsJSON,
                toolInvocationID: invocationID
            )))
        case .toolExecutionUpdate:
            break
        case let .toolExecutionEnd(toolCallId, toolName, result, isError):
            let invocationID = toolInvocationIDs.removeValue(forKey: toolCallId)
            let outputText = result?["content"]?.arrayValue?.compactMap { block in
                block.objectValue?["text"]?.stringValue
            }.joined(separator: "\n") ?? ""
            emit(.stream(AIStreamResult(
                type: "tool_result",
                text: nil,
                toolName: toolName,
                toolOutput: outputText,
                toolInvocationID: invocationID,
                toolResultJSON: result.flatMap { jsonString(from: $0) },
                toolIsError: isError
            )))
        case let .queueUpdate(steering, followUp):
            if !steering.isEmpty || !followUp.isEmpty {
                emit(.stream(AIStreamResult(
                    type: "lifecycle",
                    text: "pi queue: \(steering.count) steering, \(followUp.count) follow-up"
                )))
            }
        case let .compactionStart(reason):
            emit(.stream(AIStreamResult(type: "lifecycle", text: "pi compaction started (\(reason ?? "manual"))")))
        case let .compactionEnd(reason, _, _, _, errorMessage):
            if let errorMessage {
                emit(.error("pi compaction failed: \(errorMessage)"))
            } else {
                emit(.stream(AIStreamResult(type: "lifecycle", text: "pi compaction finished (\(reason ?? "manual"))")))
            }
        case let .autoRetryStart(attempt, maxAttempts, _, errorMessage):
            emit(.stream(AIStreamResult(
                type: "lifecycle",
                text: "pi retry \(attempt)/\(maxAttempts): \(errorMessage ?? "")"
            )))
        case let .autoRetryEnd(success, attempt, finalError):
            if !success, let finalError {
                emit(.error("pi retries exhausted after \(attempt) attempts: \(finalError)"))
            }
        case let .bashExecutionUpdate(_, delta):
            emit(.stream(AIStreamResult(type: "lifecycle", text: delta)))
        case let .extensionError(extensionPath, event, message):
            emit(.error("pi extension error (\(extensionPath ?? "?") \(event ?? "?")): \(message ?? "")"))
        case let .extensionUIRequest(request):
            handleExtensionUIRequest(request)
        case let .unknown(type, _):
            if options.enableDebugLogging {
                print("[PiNativeSession] ignoring pi event type: \(type)")
            }
        }
    }

    /// v1: dialog methods are cancelled (the extension observes `undefined`/
    /// `false`, matching a dismissed dialog) and surfaced as lifecycle notes.
    /// Fire-and-forget methods are logged only. Revisit with the pinned
    /// repoprompt-gate extension follow-up.
    private func handleExtensionUIRequest(_ request: PiProviderRuntimeBridge.ExtensionUIRequest) {
        guard request.isDialog else { return }
        try? writeCommand(.extensionUIResponseCancelled(id: request.id))
        emit(.stream(AIStreamResult(
            type: "lifecycle",
            text: "cancelled pi extension dialog \(request.method.rawValue): \(request.title ?? "")"
        )))
    }

    private func completePendingTurn() {
        turnInFlight = false
        guard let turnID = pendingTurnIDBuffer.first else { return }
        pendingTurnIDBuffer.removeFirst()
        let status: NativeAgentRuntimeTurnStatus = switch lastStopReason {
        case "aborted":
            .cancelled
        case "error":
            .failed
        default:
            .completed
        }
        let usage = lastTurnUsage
        let stopReason = lastStopReason
        emit(.stream(AIStreamResult(
            type: "message_stop",
            text: nil,
            promptTokens: usage?.input,
            completionTokens: usage?.output,
            cost: usage?.cost,
            providerSessionID: currentSessionIDValue,
            stopReason: stopReason
        )))
        emit(.turnCompleted(turnID: turnID, status: status))
    }

    // MARK: - Helpers

    private func writeCommand(_ command: PiProviderRuntimeBridge.RPCCommand) throws {
        guard let stdinHandle, process?.isRunning == true else {
            throw NativeAgentRuntimeControllerError.processNotRunning
        }
        let data = try PiProviderRuntimeBridge.RPCWire.encodeRequestLine(command)
        try stdinHandle.write(contentsOf: data)
    }

    private func jsonString(from value: PiProviderRuntimeBridge.JSONValue) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func emit(_ event: NativeAgentRuntimeEvent) {
        eventStreamContinuation?.yield(event)
    }
}
