import Foundation
import RepoPromptProcess

/// Interactive Agent Mode controller for the pi coding agent's RPC mode.
///
/// Owns a `pi --mode rpc` subprocess: strict LF JSONL framing, id-correlated
/// command/response round trips, and translation of pi events into the neutral
/// `NativeAgentRuntimeControlling` contract. MCP injection uses pi's built-in
/// MCP via `--no-extensions -e builtin:mcp` plus an ephemeral
/// `pi.registerMcpServer` extension (never `mcp.json`, never pi-mcp-adapter).
///
/// v1 boundaries (documented, deliberate):
/// - Full Access loads an ephemeral `tool_call` gate; `confirm` dialogs become
///   Agent Mode approval cards. Probe launches still auto-cancel.
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
        /// Ephemeral built-in MCP server entries for the RepoPrompt MCP server.
        var mcpServers: [String: PiProviderRuntimeBridge.MCPServerConfiguration]
        /// MCP client name pi's built-in client presents (`pi`).
        /// When set, the launched process PID is registered as the expected agent
        /// PID for the run-scoped pending connection policy, mirroring the Claude
        /// controller's registration.
        var expectedPIDMCPClientName: String?
        /// Tool surface for the managed launch.
        var toolProfile: PiProviderRuntimeBridge.ToolProfile
        /// Load the Full Access `tool_call` confirm gate. Off for MCP-only / read-only.
        var loadsApprovalGate: Bool
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
            toolProfile: PiProviderRuntimeBridge.ToolProfile = .standard,
            loadsApprovalGate: Bool = false,
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
            self.toolProfile = toolProfile
            self.loadsApprovalGate = loadsApprovalGate
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
        case processTerminated(Int32, stderr: String?)

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
            case let .processTerminated(exitCode, stderr):
                if let stderr, !stderr.isEmpty {
                    "The pi process exited unexpectedly (code \(exitCode)). \(stderr)"
                } else {
                    "The pi process exited unexpectedly (code \(exitCode))."
                }
            }
        }
    }

    private let options: Options
    private let runID: UUID

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutChunkChannel: FileHandleChunkChannel?
    private var stderrChunkChannel: FileHandleChunkChannel?
    private var stderrTail = Data()
    private var stdoutConsumerTask: Task<Void, Never>?
    private var stderrConsumerTask: Task<Void, Never>?
    private var lineAccumulator = PiProviderRuntimeBridge.RPCLineAccumulator()
    private var registeredExpectedAgentPID: pid_t?
    private var pendingResponses: [String: (Result<PiProviderRuntimeBridge.RPCResponse, Error>) -> Void] = [:]
    private var nextRequestSequence = 0
    private var ephemeralMCPInjectorURL: URL?
    private var ephemeralApprovalGateURL: URL?

    private var eventStreamContinuation: AsyncStream<NativeAgentRuntimeEvent>.Continuation?
    private var eventStream: AsyncStream<NativeAgentRuntimeEvent>?
    private var currentSessionIDValue: String?
    private var pendingTurnIDBuffer: [UUID] = []
    private var turnInFlight = false
    private var streamingAssistantText = false
    private var lastTurnUsage: (input: Int, output: Int, cost: Double)?
    private var lastStopReason: String?
    private var lastContextUsage: (used: Int?, window: Int)?
    private var toolInvocationIDs: [String: UUID] = [:]
    private var shutDown = false
    /// Lifetime token for configuration receipts. pi has no Claude-compatible flag-settings
    /// generation pipeline, so a fresh lifetime per launched process is the whole
    /// stale-receipt fence: a proof minted for a previous process cannot certify a later turn.
    private var configurationLifetime = UUID()
    private var appliedConfigurationProof: NativeAgentRuntimeConfigurationProof?
    private var cachedDiscoveredCommands: [PiProviderRuntimeBridge.DiscoveredCommand] = []

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
        try await launchProcess(
            existingSessionID: existingSessionID,
            model: nil,
            effortLevel: nil,
            systemPromptOverride: systemPromptOverride
        )
        // Correlate an initial get_state so Agent Mode learns the session identity
        // before the first prompt; failure here fails the run before any user input.
        let stateResponse = try await roundTrip(.getState, timeout: options.stateRequestTimeout)
        guard stateResponse.success else {
            throw ControllerError.stateRequestFailed(
                annotatedFailure(stateResponse.errorMessage ?? "get_state failed")
            )
        }
        let state = stateResponse.data.flatMap(PiProviderRuntimeBridge.SessionState.init(json:))
        currentSessionIDValue = state?.sessionId ?? existingSessionID
        emit(.runtimeInit(NativeAgentRuntimeRuntimeInitStatus(
            sessionID: currentSessionIDValue,
            tools: [],
            mcpServerStatuses: [:],
            initializeResponse: nil
        )))
        // Apply picker model over RPC after the process is alive. Passing
        // --provider/--model on argv can make pi exit before RPC starts when the
        // selected family is unauthenticated. Claude-shaped effortLevel is ignored
        // here: pi thinking includes `off`/`minimal`, which the coordinator applies
        // through `applyThinkingLevel` / proof-bearing apply.
        if let model, !model.isEmpty, model != AgentModel.defaultModel.rawValue {
            try await applyModelAndEffort(model: model, effortLevel: nil)
        }
        _ = effortLevel
        Task { [weak self] in
            await self?.refreshAvailableModelsBestEffort()
            await self?.refreshDiscoveredCommandsBestEffort()
        }
        return NativeAgentRuntimeSessionRef(sessionID: currentSessionIDValue)
    }

    func currentSessionRef() async -> NativeAgentRuntimeSessionRef {
        NativeAgentRuntimeSessionRef(sessionID: currentSessionIDValue)
    }

    func applyModelAndEffort(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) async throws {
        guard hasActiveSession else {
            throw NativeAgentRuntimeControllerError.processNotRunning
        }
        try await performModelAndEffortApplication(model: model, effortLevel: effortLevel)
    }

    /// Proof-bearing application. pi applies model/effort synchronously over RPC, so a
    /// successful application mints the receipt directly; there is no deferred flag-settings
    /// pipeline whose result could land after a newer intent.
    func applyModelAndEffortWithProof(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) async throws -> NativeAgentRuntimeConfigurationApplication {
        guard hasActiveSession else {
            throw NativeAgentRuntimeControllerError.processNotRunning
        }
        try await performModelAndEffortApplication(model: model, effortLevel: effortLevel)
        let proof = NativeAgentRuntimeConfigurationProof(
            lifetime: configurationLifetime,
            intentGeneration: 0,
            requestGeneration: 0
        )
        appliedConfigurationProof = proof
        return .applied(proof)
    }

    private func performModelAndEffortApplication(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) async throws {
        if let model, !model.isEmpty {
            let resolved = try resolvePiModelSelection(model)
            let setModel = PiProviderRuntimeBridge.RPCCommand.setModel(
                provider: resolved.provider ?? "",
                modelId: resolved.modelPattern
            )
            let response = try await roundTrip(setModel)
            guard response.success else {
                throw ControllerError.commandFailed(
                    annotatedFailure(response.errorMessage ?? "set_model failed")
                )
            }
            await ingestSetModelResponse(response.data, requestedModel: resolved)
        }
        if let effortLevel {
            try await applyThinkingLevel(PiProviderRuntimeBridge.thinkingLevel(for: effortLevel))
        }
    }

    func discoveredSlashCommands() async -> [PiProviderRuntimeBridge.DiscoveredCommand] {
        if cachedDiscoveredCommands.isEmpty {
            await refreshDiscoveredCommandsBestEffort()
        }
        return cachedDiscoveredCommands
    }

    /// Pi-only thinking vocabulary includes `off` and `minimal`, which are not
    /// `NativeAgentRuntimeEffortLevel` cases. Call this when the picker selected those.
    func applyThinkingLevel(_ level: String) async throws {
        guard hasActiveSession else {
            throw NativeAgentRuntimeControllerError.processNotRunning
        }
        let trimmed = level.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return }
        let response = try await roundTrip(.setThinkingLevel(level: trimmed))
        guard response.success else {
            throw ControllerError.commandFailed(response.errorMessage ?? "set_thinking_level failed")
        }
    }

    /// First-party pi compact. Unlike Claude/Codex, this is an RPC command, not a
    /// `/compact` user turn. A successful response synthesizes a completed native
    /// turn so Agent Mode's self-compact state machine can finish.
    func compactSession(customInstructions: String? = nil) async throws -> UUID {
        guard hasActiveSession else {
            throw NativeAgentRuntimeControllerError.processNotRunning
        }
        let turnID = UUID()
        pendingTurnIDBuffer.append(turnID)
        turnInFlight = true
        lastTurnUsage = nil
        lastStopReason = nil
        let response = try await roundTrip(
            .compact(customInstructions: customInstructions),
            timeout: max(options.commandTimeout, 60)
        )
        guard response.success else {
            pendingTurnIDBuffer.removeAll { $0 == turnID }
            turnInFlight = false
            throw ControllerError.commandFailed(response.errorMessage ?? "compact failed")
        }
        if let usage = response.data?["usage"].flatMap(PiProviderRuntimeBridge.TokenUsage.init(json:)) {
            lastTurnUsage = (usage.input, usage.output, usage.cost?.total ?? 0)
        }
        lastStopReason = "compact"
        completePendingTurn()
        return turnID
    }

    /// Proof-bearing send. pi mints its receipt during the same dispatch, so a receipt that
    /// no longer matches is either stale (previous process/application) or foreign; reject it
    /// rather than deliver a turn the coordinator believes was certified.
    func sendUserMessage(_ text: String, configuration: NativeAgentRuntimeConfigurationProof, images: [NativeAgentRuntimeImage]) async throws -> UUID {
        guard appliedConfigurationProof == configuration else {
            throw NativeAgentRuntimeControllerError.configurationNotCurrent
        }
        return try await sendUserMessage(text, images: images)
    }

    func sendUserMessage(_ text: String, images: [NativeAgentRuntimeImage]) async throws -> UUID {
        guard hasActiveSession else {
            throw NativeAgentRuntimeControllerError.processNotRunning
        }
        let turnID = UUID()
        pendingTurnIDBuffer.append(turnID)
        let behavior: PiProviderRuntimeBridge.StreamingBehavior? = turnInFlight ? .steer : nil
        let rpcImages = images.map {
            PiProviderRuntimeBridge.ImageAttachment(data: $0.data.base64EncodedString(), mimeType: $0.mimeType)
        }
        // Prompt acceptance can lag while the eager MCP adapter finishes its
        // first handshake; keep this above the default command timeout.
        let response = try await roundTrip(
            .prompt(message: text, images: rpcImages, streamingBehavior: behavior),
            timeout: max(options.commandTimeout, 30)
        )
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
        appliedConfigurationProof = nil
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
        stderrConsumerTask?.cancel()
        stderrConsumerTask = nil
        stderrChunkChannel?.finish()
        stderrChunkChannel = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        if let ephemeralMCPInjectorURL {
            try? FileManager.default.removeItem(at: ephemeralMCPInjectorURL)
        }
        ephemeralMCPInjectorURL = nil
        if let ephemeralApprovalGateURL {
            try? FileManager.default.removeItem(at: ephemeralApprovalGateURL)
        }
        ephemeralApprovalGateURL = nil
        eventStreamContinuation?.finish()
        eventStreamContinuation = nil
        eventStream = nil
    }

    func respondToPermissionRequest(id: String, decision: AgentApprovalDecision) async {
        let confirmed: Bool? = switch decision {
        case .accept, .acceptForSession, .acceptWithExecpolicyAmendment:
            true
        case .decline:
            false
        case .cancel:
            nil
        }
        if let confirmed {
            try? writeCommand(.extensionUIResponseConfirmed(id: id, confirmed: confirmed))
        } else {
            try? writeCommand(.extensionUIResponseCancelled(id: id))
        }
    }

    // MARK: - Process launch

    private func launchProcess(
        existingSessionID: String?,
        model: String?,
        effortLevel: NativeAgentRuntimeEffortLevel?,
        systemPromptOverride: String?
    ) async throws {
        let environment = await launchEnvironment
        let executableURL = try resolveExecutable(environment: environment)
        var injectorPath: String?
        if !options.mcpServers.isEmpty {
            injectorPath = try writeEphemeralMCPInjector()
        }
        var gatePath: String?
        if options.loadsApprovalGate {
            gatePath = try writeEphemeralApprovalGate()
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
            extensionPolicy: PiProviderRuntimeBridge.managedExtensionPolicy(
                injectorPath: injectorPath,
                gatePath: gatePath
            ),
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
        var effectiveEnvironment = environment
        for (key, value) in launchOptions.environment(over: [:]) {
            effectiveEnvironment[key] = value
        }
        process.environment = effectiveEnvironment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        lineAccumulator = PiProviderRuntimeBridge.RPCLineAccumulator()
        do {
            try process.run()
        } catch {
            throw ControllerError.invalidExecutable(error.localizedDescription)
        }
        self.process = process
        // A new process is a new configuration lifetime; a receipt minted for the
        // previous process must not certify a turn on this one.
        configurationLifetime = UUID()
        appliedConfigurationProof = nil
        stdinHandle = stdinPipe.fileHandleForWriting
        if let expectedPIDMCPClientName = options.expectedPIDMCPClientName, process.isRunning {
            let pid = process.processIdentifier
            registeredExpectedAgentPID = pid
            // Await: the eagerly-connecting adapter can reach the server within
            // seconds of launch; registration must land before the armed
            // expected-PID policy evaluates the connection.
            await ServerNetworkManager.shared.registerExpectedAgentPID(pid, for: expectedPIDMCPClientName, runID: runID)
        }
        let stdoutChannel = FileHandleChunkChannel()
        stdoutChunkChannel = stdoutChannel
        let stdoutHandle = stdoutPipe.fileHandleForReading
        stdoutHandle.readabilityHandler = { readable in
            let data = readable.availableData
            if data.isEmpty {
                stdoutChannel.finish()
                readable.readabilityHandler = nil
            } else {
                stdoutChannel.yield(data)
            }
        }
        stdoutConsumerTask = Task { [weak self] in
            for await chunk in stdoutChannel.stream {
                guard let self else { break }
                await handleStdoutChunk(chunk)
            }
            await self?.handleStdoutEOF()
        }

        // Always drain stderr. npm/adapter chatter can fill the 64KB pipe and
        // deadlock the pi process before prompt responses arrive.
        let stderrChannel = FileHandleChunkChannel()
        stderrChunkChannel = stderrChannel
        let stderrHandle = stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { readable in
            let data = readable.availableData
            if data.isEmpty {
                stderrChannel.finish()
                readable.readabilityHandler = nil
            } else {
                stderrChannel.yield(data)
            }
        }
        stderrConsumerTask = Task { [weak self] in
            for await chunk in stderrChannel.stream {
                guard let self else { break }
                await appendStderrTail(chunk)
            }
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

    /// GUI launches inherit a minimal PATH; resolve against the cached
    /// login-shell environment plus native default search paths (npm prefixes)
    /// exactly like the Claude native controller.
    private var launchEnvironment: [String: String] {
        get async {
            let result = await ProcessEnvironmentBuilder.build(
                ProcessEnvironmentRequest(
                    purpose: .piNative,
                    inheritedEnvironment: ProcessInfo.processInfo.environment,
                    overrides: [:],
                    additionalRemovedKeys: [],
                    enableDebugLogging: options.enableDebugLogging
                )
            )
            return result.environment
        }
    }

    private func resolveExecutable(environment: [String: String]) throws -> URL {
        if let executableURL = options.executableURL {
            try options.processValidator?(executableURL)
            return executableURL
        }
        let resolved = CommandPathResolver.resolve(
            "pi",
            environment: environment,
            additionalPaths: CLIPathHints.nativeDefaultsSupplemented(with: []),
            preferredBasenames: ["pi"]
        )
        guard resolved.contains("/"), FileManager.default.isExecutableFile(atPath: resolved) else {
            throw ControllerError.piNotInstalled
        }
        let url = URL(fileURLWithPath: resolved)
        try options.processValidator?(url)
        return url
    }

    private func writeEphemeralMCPInjector() throws -> String {
        guard let first = options.mcpServers.first else {
            throw ControllerError.mcpConfigurationWriteFailed("no MCP servers to inject")
        }
        do {
            let source = try PiProviderRuntimeBridge.MCPInjector.extensionSource(
                serverName: first.key,
                configuration: first.value
            )
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("rpce-pi-mcp-\(runID.uuidString).ts")
            try source.write(to: url, atomically: true, encoding: .utf8)
            ephemeralMCPInjectorURL = url
            return url.path
        } catch {
            throw ControllerError.mcpConfigurationWriteFailed(error.localizedDescription)
        }
    }

    private func writeEphemeralApprovalGate() throws -> String {
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("rpce-pi-gate-\(runID.uuidString).ts")
            try PiProviderRuntimeBridge.ApprovalGate.extensionSource().write(to: url, atomically: true, encoding: .utf8)
            ephemeralApprovalGateURL = url
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

    private func appendStderrTail(_ chunk: Data) {
        appendTail(&stderrTail, chunk: chunk, limit: 64 * 1024)
        if options.enableDebugLogging,
           let text = String(data: chunk, encoding: .utf8), !text.isEmpty
        {
            print("[PiNativeSession][stderr] \(text)")
        }
    }

    private var stderrTailSummary: String? {
        guard !stderrTail.isEmpty,
              let text = String(data: stderrTail.suffix(2000), encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func annotatedFailure(_ detail: String) -> String {
        if let stderrTailSummary {
            return "\(detail). stderr tail: \(stderrTailSummary)"
        }
        return detail
    }

    /// Prefer registry-backed provider/id. Bare leftover picker values (for example
    /// `grok`) must not be sent without a provider — pi reports them as
    /// `undefined/<id>` and fails the turn.
    private func resolvePiModelSelection(_ rawModel: String) throws -> PiProviderRuntimeBridge.ModelSelection {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if let record = PiModelRegistry.record(matchingRaw: trimmed),
           !record.provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return PiProviderRuntimeBridge.ModelSelection(
                provider: record.provider,
                modelPattern: record.id
            )
        }
        let parsed = PiProviderRuntimeBridge.ModelSelection(modelPattern: trimmed)
        if let provider = parsed.provider, !provider.isEmpty {
            return parsed
        }
        throw ControllerError.commandFailed(
            "Model '\(trimmed)' is not available for the connected pi providers. Choose Default or a model from the refreshed pi catalog."
        )
    }

    private func handleStdoutEOF() async {
        if let remainder = lineAccumulator.finish() {
            await handleLine(remainder)
        }
        clearRegisteredExpectedAgentPID()
        guard !shutDown else { return }
        let exitCode = process?.terminationStatus ?? -1
        for (_, completion) in pendingResponses {
            completion(.failure(ControllerError.processTerminated(exitCode, stderr: stderrTailSummary)))
        }
        pendingResponses.removeAll()
        if turnInFlight, let turnID = pendingTurnIDBuffer.first {
            pendingTurnIDBuffer.removeFirst()
            turnInFlight = false
            emit(.turnCompleted(turnID: turnID, status: .failed))
        }
        if let summary = stderrTailSummary {
            emit(.error("pi process exited (code \(exitCode)). stderr tail: \(summary)"))
        } else {
            emit(.error("pi process exited (code \(exitCode))"))
        }
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
            lastContextUsage = nil
        case .agentEnd:
            // A single low-level run may still be followed by retries, compaction,
            // or queued continuations; only agent_settled is the session boundary.
            break
        case .agentSettled:
            // Round-trip from a nested task so the stdout consumer can keep
            // reading the get_session_stats response.
            Task { [weak self] in
                await self?.refreshSessionStatsThenCompletePendingTurn()
            }
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

    private func handleExtensionUIRequest(_ request: PiProviderRuntimeBridge.ExtensionUIRequest) {
        switch request.method {
        case .confirm:
            let title = request.title ?? "Allow pi tool?"
            let message = request.message ?? ""
            let kind: AgentApprovalKind = title.lowercased().contains("bash") || message.lowercased().contains("shell")
                ? .commandExecution
                : .fileChange
            emit(.approvalRequest(AgentApprovalRequest(
                requestID: .piExtensionUI(request.id),
                method: "extension_ui_confirm",
                kind: kind,
                threadID: currentSessionIDValue ?? "",
                turnID: pendingTurnIDBuffer.first.map(\.uuidString) ?? "",
                itemID: request.id,
                reason: message.isEmpty ? title : message,
                command: nil,
                cwd: options.workingDirectory?.path,
                details: [
                    AgentApprovalDetail(id: UUID(), label: "Pi", value: title)
                ]
            )))
        case .select, .input, .editor:
            try? writeCommand(.extensionUIResponseCancelled(id: request.id))
            emit(.stream(AIStreamResult(
                type: "lifecycle",
                text: "cancelled pi extension dialog \(request.method.rawValue): \(request.title ?? "")"
            )))
        case .notify, .setStatus, .setWidget, .setTitle, .setEditorText:
            break
        }
    }

    private func refreshAvailableModelsBestEffort() async {
        guard let response = try? await roundTrip(.getAvailableModels),
              response.success
        else { return }
        let modelValues = response.data?["models"]?.arrayValue ?? []
        let descriptors = modelValues.compactMap(PiProviderRuntimeBridge.ModelDescriptor.init(json:))
        _ = PiModelRegistry.update(records: PiModelRegistry.records(from: descriptors))
    }

    private func ingestSetModelResponse(_ data: PiProviderRuntimeBridge.JSONValue?, requestedModel: PiProviderRuntimeBridge.ModelSelection) async {
        if let descriptor = data.flatMap(PiProviderRuntimeBridge.ModelDescriptor.init(json:)) {
            _ = PiModelRegistry.upsert(records: PiModelRegistry.records(from: [descriptor]))
            return
        }
        await refreshThinkingLevelsBestEffort(
            provider: requestedModel.provider,
            modelID: requestedModel.modelPattern
        )
    }

    private func refreshThinkingLevelsBestEffort(provider: String?, modelID: String) async {
        guard let response = try? await roundTrip(.getAvailableThinkingLevels),
              response.success
        else { return }
        let levels = response.data?["levels"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let raw = if let provider, !provider.isEmpty {
            "\(provider)/\(modelID)"
        } else {
            modelID
        }
        if !PiModelRegistry.updateThinkingLevels(forRaw: raw, thinkingLevels: levels),
           let existing = PiModelRegistry.record(matchingRaw: modelID)
        {
            _ = PiModelRegistry.updateThinkingLevels(
                forRaw: existing.catalogRawValue,
                thinkingLevels: levels
            )
        }
    }

    private func refreshDiscoveredCommandsBestEffort() async {
        guard let response = try? await roundTrip(.getCommands),
              response.success
        else { return }
        cachedDiscoveredCommands = PiProviderRuntimeBridge.DiscoveredCommand.parse(response.data)
    }

    private func refreshSessionStatsThenCompletePendingTurn() async {
        await refreshSessionStatsBestEffort()
        completePendingTurn()
    }

    private func refreshSessionStatsBestEffort() async {
        guard let response = try? await roundTrip(.getSessionStats),
              response.success,
              let stats = response.data.flatMap(PiProviderRuntimeBridge.SessionStats.init(json:))
        else { return }
        if let usage = stats.usage {
            lastTurnUsage = (usage.input, usage.output, usage.cost?.total ?? stats.cost)
        } else if stats.cost > 0 {
            lastTurnUsage = (lastTurnUsage?.input ?? 0, lastTurnUsage?.output ?? 0, stats.cost)
        }
        if let context = stats.contextUsage, context.contextWindow > 0 {
            lastContextUsage = (context.tokens, context.contextWindow)
        }
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
        let context = lastContextUsage
        emit(.stream(AIStreamResult(
            type: "message_stop",
            text: nil,
            promptTokens: usage?.input,
            completionTokens: usage?.output,
            cost: usage?.cost,
            providerSessionID: currentSessionIDValue,
            stopReason: stopReason,
            modelContextWindow: context?.window,
            contextUsedTokens: context?.used
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
