import Foundation
import RepoPromptProcess

/// One-shot connectivity probe for the pi coding agent used by the Settings
/// connect flow. A managed `pi --mode rpc --no-session` process verifies the
/// binary, RPC liveness, and built-in MCP (`/mcp` from `builtin:mcp`), and
/// captures a model snapshot for the Agent Mode catalog. Launch flags match
/// interactive/headless Agent Mode so user-global custom catalogs remain visible.
enum PiConnectionProbe {
    struct Result: Equatable {
        let sessionId: String?
        let modelSummary: String?
        let builtinMCPDetected: Bool
        let availableModelCount: Int
        let models: [PiProviderRuntimeBridge.ModelDescriptor]
    }

    enum ProbeError: Error, LocalizedError, Equatable {
        case piNotInstalled
        case rpcInitializationFailed(String)
        case builtinMCPMissing
        case timedOut(seconds: Int)

        var errorDescription: String? {
            switch self {
            case .piNotInstalled:
                "The pi CLI was not found. Install it under a user-owned npm prefix (`npm i -g @earendil-works/pi-coding-agent`)."
            case let .rpcInitializationFailed(detail):
                "pi RPC did not respond: \(detail)"
            case .builtinMCPMissing:
                "pi's built-in MCP command was not available. Update pi to 1.1.0 or newer so RepoPrompt can inject MCP tools without pi-mcp-adapter."
            case let .timedOut(seconds):
                "pi RPC probe timed out after \(seconds)s."
            }
        }
    }

    static func probe(timeout: TimeInterval = 20) async throws -> Result {
        // GUI launches inherit a minimal PATH; mirror the interactive controller and
        // resolve against the cached login-shell environment plus native defaults.
        let launchEnvironment = await ProcessEnvironmentBuilder.build(
            ProcessEnvironmentRequest(
                purpose: .piNative,
                inheritedEnvironment: ProcessInfo.processInfo.environment,
                overrides: [:],
                additionalRemovedKeys: [],
                enableDebugLogging: false
            )
        ).environment
        let resolved = CommandPathResolver.resolve(
            "pi",
            environment: launchEnvironment,
            additionalPaths: CLIPathHints.nativeDefaultsSupplemented(with: []),
            preferredBasenames: ["pi"]
        )
        guard resolved.contains("/"), FileManager.default.isExecutableFile(atPath: resolved) else {
            throw ProbeError.piNotInstalled
        }

        let launchOptions = PiProviderRuntimeBridge.LaunchOptions(
            mode: .rpc,
            session: .ephemeral,
            extensionPolicy: PiProviderRuntimeBridge.managedExtensionPolicy()
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = launchOptions.arguments()
        process.environment = launchEnvironment.merging(launchOptions.environment(over: [:])) { _, new in new }
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        let stdin = stdinPipe.fileHandleForWriting
        let channel = FileHandleChunkChannel()
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
        // Drain stderr so a chatty extension/adapter cannot fill the pipe and stall
        // the process before get_state completes.
        let stderrHandle = stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { readable in
            let data = readable.availableData
            if data.isEmpty {
                readable.readabilityHandler = nil
            }
        }

        return try await withTaskCancellationHandler {
            defer {
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                if process.isRunning {
                    process.terminate()
                }
                try? stdin.close()
            }
            let conversation = Task {
                try await runProbeConversation(stdin: stdin, channel: channel)
            }
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                conversation.cancel()
            }
            defer { timeoutTask.cancel() }
            do {
                return try await conversation.value
            } catch is CancellationError {
                throw ProbeError.timedOut(seconds: Int(timeout))
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    private static func runProbeConversation(
        stdin: FileHandle,
        channel: FileHandleChunkChannel
    ) async throws -> Result {
        // Phase 1: RPC liveness + built-in MCP. Do not batch get_available_models
        // with these — on current pi builds that multi-request burst never completes
        // models while state/commands succeed, and the probe then reports a false
        // "get_state did not complete" after the stream ends or times out.
        let stateID = "probe-state"
        let commandsID = "probe-commands"
        try stdin.write(contentsOf: PiProviderRuntimeBridge.RPCWire.encodeRequestLine(.getState, id: stateID))
        try stdin.write(contentsOf: PiProviderRuntimeBridge.RPCWire.encodeRequestLine(.getCommands, id: commandsID))

        var state: PiProviderRuntimeBridge.SessionState?
        var builtinMCPDetected = false
        var pending = Set([stateID, commandsID])
        var accumulator = PiProviderRuntimeBridge.RPCLineAccumulator()

        for await chunk in channel.stream {
            try processProbeChunk(
                chunk,
                accumulator: &accumulator,
                stdin: stdin,
                pending: &pending,
                onResponse: { id, response in
                    switch id {
                    case stateID:
                        state = response.data.flatMap(PiProviderRuntimeBridge.SessionState.init(json:))
                    case commandsID:
                        if let commands = response.data?["commands"]?.arrayValue {
                            builtinMCPDetected = commands.contains {
                                $0["name"]?.stringValue == "mcp"
                            }
                        }
                    default:
                        break
                    }
                }
            )
            if pending.isEmpty { break }
        }
        guard let state else {
            throw ProbeError.rpcInitializationFailed("get_state did not complete")
        }
        guard builtinMCPDetected else {
            throw ProbeError.builtinMCPMissing
        }

        // Phase 2: catalog snapshot. Best-effort — connect already succeeded.
        let modelsID = "probe-models"
        var models: [PiProviderRuntimeBridge.ModelDescriptor] = []
        do {
            try stdin.write(contentsOf: PiProviderRuntimeBridge.RPCWire.encodeRequestLine(.getAvailableModels, id: modelsID))
            var modelsPending = Set([modelsID])
            for await chunk in channel.stream {
                try processProbeChunk(
                    chunk,
                    accumulator: &accumulator,
                    stdin: stdin,
                    pending: &modelsPending,
                    onResponse: { id, response in
                        guard id == modelsID else { return }
                        let modelValues = response.data?["models"]?.arrayValue ?? []
                        models = modelValues.compactMap(PiProviderRuntimeBridge.ModelDescriptor.init(json:))
                    }
                )
                if modelsPending.isEmpty { break }
            }
        } catch {
            // Connect already verified; keep an empty catalog rather than failing Settings.
            models = []
        }

        let modelSummary = state.model.map { "\($0.provider)/\($0.id)" }
        return Result(
            sessionId: state.sessionId,
            modelSummary: modelSummary,
            builtinMCPDetected: builtinMCPDetected,
            availableModelCount: models.count,
            models: models
        )
    }

    private static func processProbeChunk(
        _ chunk: Data,
        accumulator: inout PiProviderRuntimeBridge.RPCLineAccumulator,
        stdin: FileHandle,
        pending: inout Set<String>,
        onResponse: (String, PiProviderRuntimeBridge.RPCResponse) throws -> Void
    ) throws {
        for line in accumulator.append(chunk) {
            guard let json = try? PiProviderRuntimeBridge.RPCWire.decodeLine(line) else { continue }

            // Auto-cancel extension UI dialogs so a status/notify dialog cannot
            // stall the one-shot probe (interactive controller does the same).
            let event = PiProviderRuntimeBridge.RPCEvent(json: json)
            if case let .extensionUIRequest(request) = event, request.isDialog {
                if let cancelLine = try? PiProviderRuntimeBridge.RPCWire.encodeRequestLine(
                    .extensionUIResponseCancelled(id: request.id)
                ) {
                    try? stdin.write(contentsOf: cancelLine)
                }
                continue
            }

            guard let response = PiProviderRuntimeBridge.RPCResponse(json: json),
                  let id = response.id,
                  pending.contains(id)
            else { continue }
            pending.remove(id)
            guard response.success else {
                throw ProbeError.rpcInitializationFailed(response.errorMessage ?? "\(response.command) failed")
            }
            try onResponse(id, response)
        }
    }
}
