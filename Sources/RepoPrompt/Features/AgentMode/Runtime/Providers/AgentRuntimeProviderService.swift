import Foundation
import Logging

enum ClaudeCodeRuntimeVariant: String {
    case standard
    case glm
    case kimi
    case customCompatible

    var compatibleBackendID: ClaudeCodeCompatibleBackendID? {
        switch self {
        case .standard:
            nil
        case .glm:
            .glmZAI
        case .kimi:
            .kimi
        case .customCompatible:
            .custom
        }
    }

    var agentKind: AgentProviderKind {
        switch self {
        case .standard:
            .claudeCode
        case .glm:
            .claudeCodeGLM
        case .kimi:
            .kimiCode
        case .customCompatible:
            .customClaudeCompatible
        }
    }
}

/// Supported autonomous agent providers shared by Agent Mode and Context Builder runtimes.
enum AgentProviderKind: String, CaseIterable, Hashable {
    case claudeCode
    case codexExec
    case openCode
    case cursor
    case grokBuild
    case piAgent
    case claudeCodeGLM
    case kimiCode
    case customClaudeCompatible

    static let claudeMCPClientID = "claude-code"
    static let codexMCPClientID = "codex-mcp-client"
    static let openCodeMCPClientID = "opencode"
    static let cursorMCPClientID = "cursor"
    /// Grok Build presents `grok-shell-<injected server name>` (e.g. `grok-shell-RepoPromptCE`)
    /// to MCP servers. The hint must equal that exact registered name: the pending run-scoped
    /// tab-context store keys are raw client names (no family canonicalization), so a
    /// family-only hint would never bind the run's frozen tab context. The canonical
    /// `grok-shell` family in `MCPClientIdentity` still covers family-level matching.
    static let grokBuildMCPClientID = "grok-shell-\(RepoPromptMCPServerConfiguration.defaultServerName)"
    /// pi-mcp-adapter presents `pi-mcp-<injected server name>` (e.g. `pi-mcp-RepoPromptCE`)
    /// to MCP servers. Like Grok Build, run-scoped tab-context store keys are raw client
    /// names, so the hint must equal that exact registered name; the canonical
    /// `pi-mcp` family in `MCPClientIdentity` covers family-level matching.
    static let piMCPClientID = "pi-mcp-\(RepoPromptMCPServerConfiguration.defaultServerName)"

    var commandName: String {
        switch self {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            "claude"
        case .codexExec:
            "codex"
        case .openCode:
            "opencode"
        case .cursor:
            "cursor-agent"
        case .grokBuild:
            "grok"
        case .piAgent:
            "pi"
        }
    }

    var displayName: String {
        switch self {
        case .claudeCode:
            "Claude Code"
        case .codexExec:
            "Codex CLI"
        case .openCode:
            "OpenCode"
        case .cursor:
            "Cursor CLI"
        case .grokBuild:
            "Grok Build"
        case .piAgent:
            "pi"
        case .claudeCodeGLM:
            ClaudeCodeCompatibleBackendStore.shared.config(for: .glmZAI).normalizedDisplayName
        case .kimiCode:
            ClaudeCodeCompatibleBackendStore.shared.config(for: .kimi).normalizedDisplayName
        case .customClaudeCompatible:
            ClaudeCodeCompatibleBackendStore.shared.config(for: .custom).normalizedDisplayName
        }
    }

    var mcpClientNameHint: String? {
        switch self {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            Self.claudeMCPClientID
        case .codexExec:
            Self.codexMCPClientID
        case .openCode:
            Self.openCodeMCPClientID
        case .cursor:
            Self.cursorMCPClientID
        case .grokBuild:
            Self.grokBuildMCPClientID
        case .piAgent:
            Self.piMCPClientID
        }
    }

    var acpProviderID: ACPProviderID? {
        switch self {
        case .openCode:
            .openCode
        case .cursor:
            .cursor
        case .grokBuild:
            .grokBuild
        case .piAgent:
            nil
        case .claudeCode, .codexExec, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            nil
        }
    }

    var usesClaudeNativeRuntime: Bool {
        switch self {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            true
        case .codexExec, .openCode, .cursor, .grokBuild, .piAgent:
            false
        }
    }

    /// pi runs its own native RPC runtime (PiNativeSessionController); Agent Mode
    /// treats it as a native-CLI family distinct from the Claude-compatible one.
    var usesPiNativeRuntime: Bool {
        self == .piAgent
    }

    /// Families that keep an interactive native controller in the tab session and
    /// share the integrated native runner machinery (steering, interrupt, resume,
    /// transcript streaming through `NativeAgentRuntimeControlling`).
    var usesNativeInteractiveRuntime: Bool {
        usesClaudeNativeRuntime || usesPiNativeRuntime
    }

    var usesClaudeTooling: Bool {
        usesClaudeNativeRuntime
    }

    var requiresExpectedPIDOwnedAgentModeMCPRouting: Bool {
        switch self {
        case .claudeCode, .codexExec, .openCode, .cursor, .grokBuild, .piAgent, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            true
        }
    }

    var requiresPrePromptAgentModeMCPRouting: Bool {
        switch self {
        case .cursor, .grokBuild:
            false
        case .claudeCode, .codexExec, .openCode, .piAgent, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            true
        }
    }

    /// Human-readable description for MCP discovery (list_agents).
    var agentDescription: String {
        switch self {
        case .claudeCode:
            return "Anthropic's Claude Code agent. Strong at general-purpose development, code understanding, architecture, and open-ended reasoning tasks."
        case .codexExec:
            return "OpenAI's Codex CLI agent. Optimized for tool-driven engineering workflows. Supports configurable reasoning effort levels per model."
        case .openCode:
            return "OpenCode ACP agent. Interactive Agent Mode uses RepoPrompt MCP tools; headless discovery/delegate runs use RepoPrompt's managed no-native-tools mode."
        case .cursor:
            return "Cursor CLI ACP agent. Uses Cursor's ACP runtime and injects RepoPrompt MCP tools through ACP session configuration."
        case .grokBuild:
            return "xAI Grok Build ACP agent. Uses Grok Build's ACP runtime (`grok agent stdio`) and injects RepoPrompt MCP tools through ACP session configuration."
        case .piAgent:
            return "The pi coding agent (pi.dev) through its RPC mode with deterministic managed launches. RepoPrompt tools are injected via the pi-mcp-adapter extension."
        case .claudeCodeGLM:
            let config = ClaudeCodeCompatibleBackendStore.shared.config(for: .glmZAI)
            if case let .claudeSlotMapping(mapping) = config.modelBehavior {
                let normalized = mapping.normalized
                return "Claude Code routed through the GLM integration. Slots: Haiku → \(normalized.haiku), Sonnet → \(normalized.sonnet), Opus → \(normalized.opus)."
            }
            return "Claude Code routed through the GLM integration for teams using that provider configuration."
        case .kimiCode:
            return "Claude Code routed through Kimi's Claude-compatible coding backend. Uses Kimi's no-model launch behavior."
        case .customClaudeCompatible:
            let config = ClaudeCodeCompatibleBackendStore.shared.config(for: .custom)
            switch config.modelBehavior {
            case .noModel:
                return "Claude Code routed through a custom Claude-compatible backend using no model flag."
            case let .claudeSlotMapping(mapping):
                let normalized = mapping.normalized
                return "Claude Code routed through a custom Claude-compatible backend. Slots: Haiku → \(normalized.haiku), Sonnet → \(normalized.sonnet), Opus → \(normalized.opus)."
            }
        }
    }

    /// Stable runtime kind identifier for MCP discovery (list_agents).
    var runtimeKind: String {
        switch self {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            "claude_native"
        case .codexExec:
            "codex_native"
        case .openCode:
            "opencode_acp"
        case .cursor:
            "cursor_acp"
        case .grokBuild:
            "grok_build_acp"
        case .piAgent:
            "pi_rpc"
        }
    }

    var claudeRuntimeVariant: ClaudeCodeRuntimeVariant? {
        switch self {
        case .claudeCode:
            .standard
        case .claudeCodeGLM:
            .glm
        case .kimiCode:
            .kimi
        case .customClaudeCompatible:
            .customCompatible
        case .codexExec, .openCode, .cursor, .grokBuild, .piAgent:
            nil
        }
    }
}

/// Factory/service responsible for instantiating provider runtimes.
final class AgentRuntimeProviderService {
    static let shared = AgentRuntimeProviderService()

    /// Enable debug logging for agent provider runtimes. Opt in with
    /// `RPCE_AGENT_DEBUG=1` when launching the app from a shell to capture the
    /// provider/controller diagnostics on stdout.
    static var enableDebugLogging = ProcessInfo.processInfo.environment["RPCE_AGENT_DEBUG"] == "1"
    private static let logger = Logger(label: "com.repoprompt.agent.runtime.provider")

    private init() {}

    /// Create a headless agent provider.
    /// - Parameters:
    ///   - agent: The provider kind to create
    ///   - modelString: Optional model string override
    ///   - runType: The type of run — determines CLI tool config
    /// - Note: MCP tool restrictions are handled via ServerNetworkManager connection policies,
    ///   not via CLI flags. Use installClientConnectionPolicy before starting the agent run.
    /// - Important: OpenCode and Cursor use their ACP runtimes for headless
    ///   discovery while keeping broader chat-provider wiring separate.
    func makeProvider(
        for agent: AgentProviderKind,
        modelString: String? = nil,
        runType: AgentRunType = .discover,
        workspacePath: String? = nil
    ) -> HeadlessAgentProvider {
        if Self.enableDebugLogging {
            Self.logger.debug("Creating provider for agent: \(agent.displayName), model: \(modelString ?? "default"), runType: \(String(describing: runType))")
        }
        switch agent {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            let runtimeVariant = agent.claudeRuntimeVariant ?? .standard
            let config: ClaudeCodeAgentConfig = .discovery(
                modelString: modelString,
                runtimeVariant: runtimeVariant,
                enableDebugLogging: Self.enableDebugLogging
            )
            var processConfig = CLIProcessConfiguration(
                command: config.commandName,
                enableDebugLogging: Self.enableDebugLogging,
                captureStdoutTailBytes: 128 * 1024,
                captureStderrTailBytes: 256 * 1024,
                logStdinSampleBytes: 0
            )
            processConfig.ensureAdditionalPaths(config.additionalPathHints)
            let runner = CLIProcessRunner(config: processConfig)
            let wrappedProvider = ClaudeCodeAgentProvider(runner: runner, config: config)
            let runtimeConfig = ClaudeCompatiblePluginBridge.runtimeConfig(from: config, mode: .discovery)
            if Self.enableDebugLogging {
                Self.logger.debug("Created ClaudeCompatibleHeadlessProviderAdapter")
            }
            return ClaudeCompatibleHeadlessProviderAdapter(
                runtimeConfig: runtimeConfig,
                wrappedProvider: wrappedProvider
            )
        case .codexExec:
            let config = CodexExecAgentConfig(
                modelString: modelString,
                enableDebugLogging: Self.enableDebugLogging,
                fullAccess: CodexAgentToolPreferences.permissionLevel() == .fullAccess
            )
            if Self.enableDebugLogging {
                Self.logger.debug("Created CodexExecAgentProvider")
            }
            return CodexExecAgentProvider(config: config)
        case .openCode:
            let config = OpenCodeAgentConfig(
                modelString: modelString,
                enableDebugLogging: Self.enableDebugLogging,
                toolProfile: .headless
            )
            if Self.enableDebugLogging {
                Self.logger.debug("Created OpenCodeACPHeadlessAgentProvider")
            }
            return OpenCodeACPHeadlessAgentProvider(config: config, workspacePath: workspacePath)
        case .cursor:
            let config = CursorAgentConfig(
                commandName: agent.commandName,
                enableDebugLogging: Self.enableDebugLogging,
                modelString: modelString,
                includeRepoPromptMCPServer: true,
                cleanupProjectMCPApproval: true
            )
            if Self.enableDebugLogging {
                Self.logger.debug("Created CursorACPHeadlessAgentProvider")
            }
            return CursorACPHeadlessAgentProvider(config: config, workspacePath: workspacePath)
        case .grokBuild:
            let config = GrokBuildAgentConfig(
                enableDebugLogging: Self.enableDebugLogging,
                modelString: modelString,
                alwaysApproveTools: GrokBuildAgentToolPreferences.permissionLevel() == .fullAccess
            )
            if Self.enableDebugLogging {
                Self.logger.debug("Created GrokBuildACPHeadlessAgentProvider")
            }
            return GrokBuildACPHeadlessAgentProvider(config: config, workspacePath: workspacePath)
        case .piAgent:
            let config = PiExecAgentConfig(
                modelString: modelString,
                enableDebugLogging: Self.enableDebugLogging,
                workspacePath: workspacePath,
                toolProfile: .mcpOnly
            )
            if Self.enableDebugLogging {
                Self.logger.debug("Created PiExecAgentProvider")
            }
            return PiExecAgentProvider(config: config)
        }
    }
}
