import Foundation

/// Core Agent Mode contract for native CLI runtimes that keep an interactive
/// process/session alive across turns.
///
/// This is an app-internal contract, not the future external plugin API. It can
/// use core app models (`AIStreamResult`, `AgentApprovalRequest`, and
/// `AgentApprovalDecision`) because adapters/bridges are expected to translate
/// plugin-owned DTOs before events reach Agent Mode.
protocol NativeAgentRuntimeControlling: Actor {
    var hasActiveSession: Bool { get async }
    var hasTurnInFlight: Bool { get async }
    var events: AsyncStream<NativeAgentRuntimeEvent> { get async }

    func ensureEventsStreamReady() async
    func resetEventsStreamForNewRun() async
    func startOrResume(
        existingSessionID: String?,
        model: String?,
        effortLevel: NativeAgentRuntimeEffortLevel?,
        systemPromptOverride: String?
    ) async throws -> NativeAgentRuntimeSessionRef
    func currentSessionRef() async -> NativeAgentRuntimeSessionRef
    func applyModelAndEffort(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) async throws
    /// Unlike the legacy live-update helper, this proves the complete requested configuration.
    func applyModelAndEffortWithProof(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) async throws -> NativeAgentRuntimeConfigurationApplication
    /// Begins fallback only if the failed application is still current, consuming its intent.
    func applyModelAndEffortWithProof(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?, replacingFailure: NativeAgentRuntimeConfigurationFailure) async throws -> NativeAgentRuntimeConfigurationApplication
    /// Turn-scoped Auto application; fallback consumes only a still-current failure token.
    func applyModelAndEffortForTurn(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?, replacingFailure: NativeAgentRuntimeConfigurationFailure?) async throws -> NativeAgentRuntimeTurnConfigurationOutcome
    /// Sends a user turn that must prove the applied configuration first. `images` is ignored
    /// by runtimes that have no native image prompt field; pi maps them onto RPC `prompt.images`.
    func sendUserMessage(_ text: String, configuration: NativeAgentRuntimeConfigurationProof, images: [NativeAgentRuntimeImage]) async throws -> UUID
    /// Sends a user turn with no configuration proof. Used by maintenance commands and as the
    /// primitive underlying `sendUserMessage(_:)`. `images` semantics match the proof-bearing send.
    func sendUserMessage(_ text: String, images: [NativeAgentRuntimeImage]) async throws -> UUID
    /// Maintenance commands intentionally do not require an ordinary-turn configuration proof.
    func sendUserMessage(_ text: String) async throws -> UUID
    /// Sends a reasoned interrupt request to the provider runtime.
    /// - Parameter reason: "interrupt" for steering (graceful), "cancel" for forceful stop.
    func interruptTurn(reason: String) async -> NativeAgentRuntimeInterruptOutcome
    func cleanupConversation(_ handle: ProviderConversationCleanupHandle, action: ProviderConversationCleanupAction) async -> ProviderConversationCleanupOutcome
    func shutdown() async
    func respondToPermissionRequest(id: String, decision: AgentApprovalDecision) async
}

extension NativeAgentRuntimeControlling {
    /// Fail closed for runtimes that have not implemented application proof. In particular,
    /// an old no-op fake must not accidentally certify provider application.
    func applyModelAndEffortWithProof(model _: String?, effortLevel _: NativeAgentRuntimeEffortLevel?) async throws -> NativeAgentRuntimeConfigurationApplication {
        .notReady
    }

    /// A runtime without atomic failure-token validation must not recertify an older turn.
    func applyModelAndEffortWithProof(model _: String?, effortLevel _: NativeAgentRuntimeEffortLevel?, replacingFailure _: NativeAgentRuntimeConfigurationFailure) async throws -> NativeAgentRuntimeConfigurationApplication {
        .superseded
    }

    /// Runtimes must implement failure-token ownership to support conditional fallback.
    /// A legacy Void update alone cannot authorize restoring a failed turn's configuration.
    func applyModelAndEffortForTurn(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?, replacingFailure: NativeAgentRuntimeConfigurationFailure?) async throws -> NativeAgentRuntimeTurnConfigurationOutcome {
        guard replacingFailure == nil else { return .superseded }
        try await applyModelAndEffort(model: model, effortLevel: effortLevel)
        return .applied
    }

    func sendUserMessage(_: String, configuration _: NativeAgentRuntimeConfigurationProof, images _: [NativeAgentRuntimeImage]) async throws -> UUID {
        throw NativeAgentRuntimeControllerError.configurationNotCurrent
    }

    func cleanupConversation(_ handle: ProviderConversationCleanupHandle, action: ProviderConversationCleanupAction) async -> ProviderConversationCleanupOutcome {
        .unsupported(message: "Native runtime has no local API for \(action.rawValue) cleanup of conversations.")
    }

    func sendUserMessage(_ text: String) async throws -> UUID {
        try await sendUserMessage(text, images: [])
    }
}

/// In-memory image payload for native prompt APIs. Callers encode composer
/// attachments before crossing into the runtime controller.
struct NativeAgentRuntimeImage: Equatable {
    let data: Data
    let mimeType: String
}

// MARK: - Neutral native-runtime DTOs

/// Outcome of a completed native-runtime turn.
enum NativeAgentRuntimeTurnStatus {
    case completed
    case cancelled
    case failed
}

/// Initialization snapshot emitted by a native runtime once its process/session
/// is ready. `initializeResponse` carries the Claude-compatible family's
/// Claude Code SDK initialize payload; other native runtimes leave it `nil` and
/// surface provider detail through their own channels.
struct NativeAgentRuntimeRuntimeInitStatus: Equatable {
    struct InitializeResponseSnapshot: Equatable {
        struct Command: Equatable {
            let name: String
            let description: String
            let argumentHint: String
        }

        struct Agent: Equatable {
            let name: String
            let description: String
            let model: String?
        }

        struct Account: Equatable {
            let email: String?
            let organization: String?
            let subscriptionType: String?
            let tokenSource: String?
            let apiKeySource: String?
            let apiProvider: String?
        }

        let commands: [Command]
        let agents: [Agent]
        let outputStyle: String?
        let availableOutputStyles: [String]
        let account: Account?
        let pid: Int?
        let modelsJSON: String?
        let fastModeStateJSON: String?
    }

    let sessionID: String?
    let tools: [String]
    let mcpServerStatuses: [String: String]
    let initializeResponse: InitializeResponseSnapshot?

    var repoPromptServerStatus: String? {
        mcpServerStatuses.first {
            $0.key.compare(MCPIntegrationHelper.repoPromptMCPServerName, options: .caseInsensitive) == .orderedSame
        }?.value
    }

    var isRepoPromptServerFailed: Bool {
        guard let status = repoPromptServerStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return status == "failed"
    }
}

/// Event stream shared by every native runtime. Provider-specific detail is
/// translated into these neutral shapes by each controller before events reach
/// coordinators, runners, and tab-session storage.
enum NativeAgentRuntimeEvent {
    case stream(AIStreamResult)
    case runtimeInit(NativeAgentRuntimeRuntimeInitStatus)
    case approvalRequest(AgentApprovalRequest)
    case approvalCancelled(requestID: String)
    case turnCompleted(turnID: UUID, status: NativeAgentRuntimeTurnStatus)
    case error(String)
}

/// Opaque handle to a provider-native session (e.g. a Claude session id or a
/// pi session UUID) used for resume across runs.
struct NativeAgentRuntimeSessionRef {
    var sessionID: String?
}

/// Outcome of an interrupt control request, used by the coordinator to decide
/// whether it is safe to proceed with a superseding user turn.
enum NativeAgentRuntimeInterruptOutcome: Equatable {
    /// The runtime acknowledged the interrupt.
    case acknowledged
    /// No turn was in flight; the turn likely completed naturally before the interrupt.
    case noTurnInFlight
    /// The interrupt control request timed out without an acknowledgement.
    case timedOut
    /// The interrupt request failed (e.g. process not running or write error).
    case failed
}

enum NativeAgentRuntimeControllerError: Error, LocalizedError {
    case processNotRunning
    case initializationFailed(String)
    case invalidControlResponse(String)
    case inputWriteFailed(String)
    case controlRequestTimedOut(requestID: String)
    case liveModelSwitchRequiresRestart
    case configurationNotCurrent
    /// Cancellation observed at the proof-bearing send entry, before any user-message write.
    case cancelledBeforeWrite

    var errorDescription: String? {
        switch self {
        case .processNotRunning:
            "Native runtime process is not running."
        case let .initializationFailed(message):
            "Native runtime initialization failed: \(message)"
        case let .invalidControlResponse(message):
            "Native runtime control response failed: \(message)"
        case let .inputWriteFailed(message):
            "Failed writing to native runtime process stdin: \(message)"
        case let .controlRequestTimedOut(requestID):
            "Native runtime control request timed out: \(requestID)"
        case .liveModelSwitchRequiresRestart:
            "Changing to the selected model requires restarting the agent because its launch environment changes."
        case .configurationNotCurrent:
            "Native runtime model configuration is not current. No message was sent; retry the turn."
        case .cancelledBeforeWrite:
            "Native dispatch was cancelled before writing. No message was sent."
        }
    }
}

// MARK: - Effort levels

/// Neutral effort-level vocabulary shared by native runtimes. Provider-specific
/// level sets (for example pi's per-model thinking levels) are mapped into
/// these values by each provider adapter.
typealias NativeAgentRuntimeEffortLevel = ClaudeCodeEffortLevel

// MARK: - Claude-compatible conformance

/// The neutral DTOs above originated from the Claude-compatible native runtime.
/// The Claude controller conforms to the contract directly through these
/// compatibility aliases, and new native providers (pi) emit the neutral types
/// from their own controllers.
/// See docs/architecture/provider-plugins.md for the full bridge/adapter layout.
extension ClaudeNativeProcessSessionController: NativeAgentRuntimeControlling {
    typealias Event = NativeAgentRuntimeEvent
    typealias SessionRef = NativeAgentRuntimeSessionRef
    typealias TurnStatus = NativeAgentRuntimeTurnStatus
    typealias RuntimeInitStatus = NativeAgentRuntimeRuntimeInitStatus
    typealias InterruptOutcome = NativeAgentRuntimeInterruptOutcome
    typealias ControllerError = NativeAgentRuntimeControllerError
}
