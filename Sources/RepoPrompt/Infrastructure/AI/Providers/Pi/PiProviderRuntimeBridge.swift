import Foundation
import RepoPromptPiProvider
import RepoPromptShared

/// Single core import point for the `RepoPromptPiProvider` package, mirroring
/// `ClaudeCompatibleProviderRuntimeBridge`. Files outside this bridge must not
/// `import RepoPromptPiProvider`; they reference the aliases declared here.
///
/// The package owns the pi RPC codec, model-catalog DTOs, launch arguments, and
/// the ephemeral built-in MCP injector (`pi.registerMcpServer`). Core owns
/// process control, persistence, and Agent Mode wiring.
enum PiProviderRuntimeBridge {
    // MARK: - Type aliases (package DTO surface used by core)

    typealias JSONValue = PiJSONValue
    typealias RPCCommand = PiRPCCommand
    typealias RPCEvent = PiRPCEvent
    typealias RPCResponse = PiRPCResponse
    typealias RPCWire = PiRPCWire
    typealias RPCLineAccumulator = PiRPCLineAccumulator
    typealias ImageAttachment = PiImageAttachment
    typealias StreamingBehavior = PiStreamingBehavior
    typealias QueueDeliveryMode = PiQueueDeliveryMode

    typealias LaunchMode = PiLaunchMode
    typealias LaunchOptions = PiLaunchOptions
    typealias ModelSelection = PiModelSelection
    typealias SessionSelection = PiSessionSelection
    typealias ToolProfile = PiToolProfile
    typealias ExtensionPolicy = PiExtensionPolicy
    typealias UserGlobalExtensionDiscovery = PiUserGlobalExtensionDiscovery

    typealias ModelDescriptor = PiModelDescriptor
    typealias ThinkingLevel = PiThinkingLevel
    typealias ThinkingLevelMapping = PiThinkingLevelMapping
    typealias SessionState = PiSessionState
    typealias SessionStats = PiSessionStats
    typealias SessionEntryList = PiSessionEntryList
    typealias DiscoveredCommand = PiDiscoveredCommand

    typealias MCPServerConfiguration = PiBuiltinMCPServerConfiguration
    typealias MCPExposure = PiBuiltinMCPExposure
    typealias MCPClientIdentity = PiBuiltinMCPClientIdentity
    typealias MCPInjector = PiBuiltinMCPInjector
    typealias ApprovalGate = PiApprovalGate
    typealias ExtensionUIRequest = PiExtensionUIRequest
    typealias AssistantMessageDelta = PiAssistantMessageDelta
    typealias AgentMessage = PiAgentMessage
    typealias TokenUsage = PiTokenUsage

    // MARK: - Pure helpers

    /// MCP initialize name presented by pi's built-in client.
    static let mcpClientName = PiBuiltinMCPClientIdentity.clientName

    /// Maps a Claude-shaped native effort onto pi's thinking-level vocabulary.
    /// `off` / `minimal` are Pi-only and applied through `applyThinkingLevel`.
    static func thinkingLevel(for effort: NativeAgentRuntimeEffortLevel) -> String {
        effort.rawValue
    }

    /// `--no-extensions -e builtin:mcp`, user-global `~/.pi/agent/extensions`, and an
    /// optional injector that registers the RepoPrompt server for this process only.
    static func managedExtensionPolicy(injectorPath: String? = nil, gatePath: String? = nil) -> ExtensionPolicy {
        .builtinMCPWithDiscoveredUserGlobalExtensions(injectorPath: injectorPath, gatePath: gatePath)
    }

    /// Built-in MCP registration for the RepoPrompt CE server. `direct` exposure
    /// makes the first prompt wait for the connection; timeout covers subagent waits.
    static func managedRepoPromptMCPServerConfiguration(
        _ server: RepoPromptMCPServerConfiguration
    ) -> MCPServerConfiguration {
        MCPServerConfiguration(
            command: server.command,
            arguments: server.args,
            environment: server.environmentDictionary,
            timeoutSeconds: MCPTimeoutPolicy.piBuiltinMCPRequestTimeoutSeconds,
            exposure: .direct,
            description: "RepoPrompt CE tools"
        )
    }
}
