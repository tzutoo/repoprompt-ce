import Foundation
import RepoPromptPiProvider
import RepoPromptShared

/// Single core import point for the `RepoPromptPiProvider` package, mirroring
/// `ClaudeCompatibleProviderRuntimeBridge`. Files outside this bridge must not
/// `import RepoPromptPiProvider`; they reference the aliases declared here.
///
/// The package owns the pi RPC codec, model-catalog DTOs, the ephemeral
/// pi-mcp-adapter `--mcp-config` document, and managed-launch argument
/// construction. Core owns process control, persistence, and Agent Mode wiring.
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

    typealias MCPAdapterConfigurationDocument = PiMCPAdapterConfigurationDocument
    typealias MCPServerConfiguration = PiMCPServerConfiguration
    typealias MCPServerLifecycle = PiMCPServerLifecycle
    typealias MCPDirectTools = PiMCPDirectTools
    typealias MCPAdapterClientIdentity = PiMCPAdapterClientIdentity
    typealias ExtensionUIRequest = PiExtensionUIRequest
    typealias AssistantMessageDelta = PiAssistantMessageDelta
    typealias AgentMessage = PiAgentMessage
    typealias TokenUsage = PiTokenUsage

    // MARK: - Pure helpers

    /// The MCP client name pi-mcp-adapter presents for a given server name
    /// (`pi-mcp-RepoPromptCE` for the default CE server).
    static func mcpClientName(forServer serverName: String) -> String {
        PiMCPAdapterClientIdentity.clientName(forServer: serverName)
    }

    /// Maps a neutral effort level onto pi's thinking-level vocabulary. The
    /// neutral set (`low`…`max`) is a subset of pi's (`off`…`max`), so the raw
    /// value transfers directly.
    static func thinkingLevel(for effort: NativeAgentRuntimeEffortLevel) -> String {
        effort.rawValue
    }

    /// `--no-extensions` plus user-global `~/.pi/agent/extensions` and the pinned
    /// pi-mcp-adapter. Keeps custom catalogs (for example a `local` OpenAI-compatible
    /// provider) aligned with the Settings connect probe without double-loading
    /// the adapter from `settings.json` packages.
    static func managedExtensionPolicy(adapterVersion: String) -> ExtensionPolicy {
        .pinnedAdapterWithDiscoveredUserGlobalExtensions(version: adapterVersion)
    }

    /// Ephemeral `--mcp-config` entry for the RepoPrompt CE server in a managed pi launch.
    /// Eager connect satisfies pre-prompt routing; the request timeout must cover subagent waits.
    static func managedRepoPromptMCPServerConfiguration(
        _ server: RepoPromptMCPServerConfiguration
    ) -> MCPServerConfiguration {
        MCPServerConfiguration(
            command: server.command,
            arguments: server.args,
            environment: server.environmentDictionary,
            lifecycle: .eager,
            requestTimeoutMilliseconds: MCPTimeoutPolicy.piMCPAdapterRequestTimeoutMilliseconds,
            directTools: .all
        )
    }
}
