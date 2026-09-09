import Foundation

/// One-shot connectivity probe for the pi coding agent used by the Settings
/// connect flow. A single `pi --mode rpc --no-session` process verifies the
/// binary, RPC liveness, and pi-mcp-adapter presence (the adapter registers
/// the `/mcp` extension command), and captures a model snapshot for the
/// connect log. The dynamic Agent Mode catalog (WI4) will reuse the same
/// `get_available_models` surface.
enum PiConnectionProbe {
    struct Result: Equatable {
        let sessionId: String?
        let modelSummary: String?
        let adapterDetected: Bool
        let availableModelCount: Int
        let models: [PiProviderRuntimeBridge.ModelDescriptor]
    }

    enum ProbeError: Error, LocalizedError, Equatable {
        case piNotInstalled
        case rpcInitializationFailed(String)
        case adapterMissing
        case timedOut(seconds: Int)

        var errorDescription: String? {
            switch self {
            case .piNotInstalled:
                "The pi CLI was not found. Install it under a user-owned npm prefix (`npm i -g @earendil-works/pi-coding-agent`)."
            case let .rpcInitializationFailed(detail):
                "pi RPC did not respond: \(detail)"
            case .adapterMissing:
                "pi-mcp-adapter is not installed. Run `pi install npm:pi-mcp-adapter` so RepoPrompt MCP tools can be injected."
            case let .timedOut(seconds):
                "pi RPC probe timed out after \(seconds)s."
            }
        }
    }

    static func probe(timeout: TimeInterval = 20) async throws -> Result {
        let environment = ProcessInfo.processInfo.environment
        let resolved = CommandPathResolver.resolve("pi", environment: environment, additionalPaths: [])
        guard resolved.contains("/"), FileManager.default.isExecutableFile(atPath: resolved) else {
            throw ProbeError.piNotInstalled
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = ["--mode", "rpc", "--no-session", "-nc", "-na"]
        process.environment = environment.merging([
            "PI_OFFLINE": "1",
            "PI_SKIP_VERSION_CHECK": "1"
        ]) { _, new in new }
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
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

        return try await withTaskCancellationHandler {
            defer {
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
        // Correlated requests: state (RPC liveness + session identity + model),
        // commands (adapter detection via the registered /mcp command), and
        // available models (count for the connect log).
        let stateID = "probe-state"
        let commandsID = "probe-commands"
        let modelsID = "probe-models"
        try stdin.write(contentsOf: PiProviderRuntimeBridge.RPCWire.encodeRequestLine(.getState, id: stateID))
        try stdin.write(contentsOf: PiProviderRuntimeBridge.RPCWire.encodeRequestLine(.getCommands, id: commandsID))
        try stdin.write(contentsOf: PiProviderRuntimeBridge.RPCWire.encodeRequestLine(.getAvailableModels, id: modelsID))

        var state: PiProviderRuntimeBridge.SessionState?
        var adapterDetected = false
        var modelCount = 0
        var models: [PiProviderRuntimeBridge.ModelDescriptor] = []
        var pending = Set([stateID, commandsID, modelsID])

        var accumulator = PiProviderRuntimeBridge.RPCLineAccumulator()
        for await chunk in channel.stream {
            for line in accumulator.append(chunk) {
                guard let json = try? PiProviderRuntimeBridge.RPCWire.decodeLine(line) else { continue }
                guard let response = PiProviderRuntimeBridge.RPCResponse(json: json),
                      let id = response.id,
                      pending.contains(id)
                else { continue }
                pending.remove(id)
                guard response.success else {
                    throw ProbeError.rpcInitializationFailed(response.errorMessage ?? "\(response.command) failed")
                }
                switch id {
                case stateID:
                    state = response.data.flatMap(PiProviderRuntimeBridge.SessionState.init(json:))
                case commandsID:
                    if let commands = response.data?["commands"]?.arrayValue {
                        adapterDetected = commands.contains {
                            let name = $0["name"]?.stringValue
                            return name == "mcp" || name == "pi-mcp"
                        }
                    }
                case modelsID:
                    let modelValues = response.data?["models"]?.arrayValue ?? []
                    models = modelValues.compactMap(PiProviderRuntimeBridge.ModelDescriptor.init(json:))
                    modelCount = models.count
                default:
                    break
                }
            }
            if pending.isEmpty { break }
        }
        guard let state else {
            throw ProbeError.rpcInitializationFailed("get_state did not complete")
        }
        guard adapterDetected else {
            throw ProbeError.adapterMissing
        }
        let modelSummary = state.model.map { "\($0.provider)/\($0.id)" }
        return Result(
            sessionId: state.sessionId,
            modelSummary: modelSummary,
            adapterDetected: adapterDetected,
            availableModelCount: modelCount,
            models: models
        )
    }
}
