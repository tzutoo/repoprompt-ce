import Foundation
@testable import RepoPromptApp
import RepoPromptSettingsCore
import RepoPromptShared
import XCTest

final class PiProviderIdentityAndBindingTests: XCTestCase {
    func testMCPClientIdentityResolvesBuiltinPiFamily() {
        XCTAssertEqual(MCPClientIdentity.canonicalFamilyID("pi"), "pi")
        XCTAssertTrue(MCPClientIdentity.matches("pi", AgentProviderKind.piAgent.mcpClientNameHint))
        XCTAssertEqual(MCPClientIdentity.storageKey("pi"), "pi")
        XCTAssertFalse(MCPClientIdentity.sameFamily("pi", "grok-shell-RepoPromptCE"))
        XCTAssertTrue(ServerController.isBuiltInAlwaysAllowedClient("pi"))
        // Retired adapter identity stays a distinct family so leftover entries do not
        // collapse onto the built-in client name.
        XCTAssertEqual(MCPClientIdentity.canonicalFamilyID("pi-mcp-RepoPromptCE"), "pi-mcp")
        XCTAssertFalse(MCPClientIdentity.sameFamily("pi", "pi-mcp-RepoPromptCE"))
        XCTAssertFalse(ServerController.isBuiltInAlwaysAllowedClient("pi-mcp"))
        XCTAssertFalse(ServerController.isBuiltInAlwaysAllowedClient("pi-mcpx"))
    }

    func testProviderKindMetadata() {
        XCTAssertEqual(AgentProviderKind.piAgent.commandName, "pi")
        XCTAssertEqual(AgentProviderKind.piAgent.displayName, "pi")
        XCTAssertEqual(AgentProviderKind.piAgent.runtimeKind, "pi_rpc")
        XCTAssertEqual(AgentProviderKind.piAgent.mcpClientNameHint, "pi")
        XCTAssertNil(AgentProviderKind.piAgent.acpProviderID)
        XCTAssertNil(AgentProviderKind.piAgent.claudeRuntimeVariant)
        XCTAssertTrue(AgentProviderKind.piAgent.usesPiNativeRuntime)
        XCTAssertFalse(AgentProviderKind.piAgent.usesClaudeNativeRuntime)
        XCTAssertTrue(AgentProviderKind.piAgent.requiresExpectedPIDOwnedAgentModeMCPRouting)
        XCTAssertTrue(AgentProviderKind.piAgent.requiresPrePromptAgentModeMCPRouting)
        XCTAssertEqual(AgentProviderKind.piAgent.providerBindingID, .pi)
    }

    func testPermissionLevelsAndProfiles() {
        XCTAssertEqual(AgentProviderPermissionProfile.mcpSafeDefaults.piPermissionLevel(), .mcpOnly)
        XCTAssertEqual(
            AgentProviderPermissionProfile.providerOverride(.pi(.fullAccess)).piPermissionLevel(),
            .fullAccess
        )
        XCTAssertEqual(
            PiAgentToolPreferences.PermissionLevel.mcpOnly.launchToolProfile.arguments,
            ["--no-builtin-tools"]
        )
        XCTAssertEqual(
            PiAgentToolPreferences.PermissionLevel.readOnly.launchToolProfile.arguments,
            ["--tools", "read,grep,find,ls"]
        )
        XCTAssertEqual(
            PiAgentToolPreferences.PermissionLevel.fullAccess.launchToolProfile.arguments,
            []
        )
        XCTAssertFalse(PiAgentToolPreferences.PermissionLevel.fullAccess.loadsInteractiveApprovalGate)
        XCTAssertTrue(PiAgentToolPreferences.PermissionLevel.mcpOnly.loadsInteractiveApprovalGate)
        XCTAssertTrue(PiAgentToolPreferences.PermissionLevel.readOnly.loadsInteractiveApprovalGate)
        XCTAssertEqual(AgentProviderPermissionProfile.userConfigured.piPermissionMode, PiAgentToolPreferences.permissionLevel().rawValue)
        XCTAssertEqual(AgentProviderPermissionProfile.mcpSafeDefaults.piPermissionMode, "mcpOnly")
        XCTAssertEqual(AgentProviderPermissionLevelID.subagentDefault(for: .pi), .pi(.mcpOnly))
        XCTAssertEqual(
            AgentProviderPermissionLevelID.options(for: .pi).count,
            PiAgentToolPreferences.PermissionLevel.allCases.count
        )
    }

    func testAvailabilityContextCarriesPiFlag() {
        let available = AgentModelCatalog.AvailabilityContext(piAvailable: true)
        XCTAssertTrue(AgentModelCatalog.isAgentAvailable(.piAgent, availability: available))
        XCTAssertFalse(AgentModelCatalog.isAgentAvailable(.piAgent, availability: .none))
        // Recommendation filtering threads the pi flag through the .pi provider kind.
        let filtered = AgentModelCatalog.AvailabilityContext(piAvailable: true)
            .filteredForRecommendationProviders([])
        XCTAssertFalse(filtered.piAvailable)
        XCTAssertTrue(AgentModelCatalog.AvailabilityContext.current.piAvailable)
        XCTAssertTrue(
            AgentModelCatalog.AvailabilityContext.none.assumingAvailable(.piAgent).piAvailable
        )
        XCTAssertTrue(
            AgentModelCatalog.selectableAgents(availability: available).contains(.piAgent)
        )
        XCTAssertFalse(
            AgentModelCatalog.selectableAgents(availability: .none).contains(.piAgent)
        )
        XCTAssertTrue(AgentModelCatalog.supportedCLIProviderAgents.contains(.piAgent))
    }

    @MainActor
    func testCodexNormalizationPreservesPiThinkingSelection() {
        let coordinator = CodexAgentModeCoordinator(
            windowID: 1,
            runtimeWorkspacePathsProvider: { _ in .uniform("/tmp") },
            codexControllerFactory: { _, _, _, _, _, _, _, _ in
                fatalError("unused")
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            shouldManageCodexTooling: false,
            codexHookApprovalSettings: GlobalSettingsStore.shared
        )
        let piSession = AgentTabSession(tabID: UUID())
        piSession.selectedAgent = .piAgent
        piSession.selectedModelRaw = "local/free"
        piSession.selectedReasoningEffortRaw = "high"
        coordinator.normalizeCodexSelectionForSession(piSession, preservingExplicitEffort: true)
        XCTAssertEqual(piSession.selectedReasoningEffortRaw, "high")
        coordinator.normalizeCodexSelectionForSession(piSession, preservingExplicitEffort: false)
        XCTAssertEqual(piSession.selectedReasoningEffortRaw, "high")

        let claudeSession = AgentTabSession(tabID: UUID())
        claudeSession.selectedAgent = .claudeCode
        claudeSession.selectedReasoningEffortRaw = "high"
        coordinator.normalizeCodexSelectionForSession(claudeSession, preservingExplicitEffort: true)
        XCTAssertNil(claudeSession.selectedReasoningEffortRaw)
    }

    func testLastUsedThinkingEffortPersistsByModelSlug() throws {
        let suiteName = "PiThinkingPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        PiAgentToolPreferences.setLastUsedThinkingEffort(.medium, forModelRaw: "openai/gpt-5", defaults: defaults)
        XCTAssertEqual(
            PiAgentToolPreferences.lastUsedThinkingEffort(forModelRaw: "openai/gpt-5", defaults: defaults),
            .medium
        )
        XCTAssertEqual(PiAgentToolPreferences.lastUsedThinkingEffort(defaults: defaults), .medium)
        PiAgentToolPreferences.setLastUsedThinkingEffort(.high, forModelRaw: "anthropic/claude", defaults: defaults)
        XCTAssertEqual(
            PiAgentToolPreferences.lastUsedThinkingEffort(forModelRaw: "openai/gpt-5", defaults: defaults),
            .medium
        )
        XCTAssertEqual(
            PiAgentToolPreferences.lastUsedThinkingEffort(forModelRaw: "anthropic/claude", defaults: defaults),
            .high
        )
    }

    @MainActor
    func testRestoredPiThinkingPrefersSavedSessionOverLastUsed() {
        let previous = PiAgentToolPreferences.lastUsedThinkingEffort()
        defer { PiAgentToolPreferences.setLastUsedThinkingEffort(previous) }
        PiAgentToolPreferences.setLastUsedThinkingEffort(.high, forModelRaw: "openai/gpt-5")
        let viewModel = AgentModeViewModel(
            testWindowID: 99013,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Pi thinking restore tests must not start Codex")
            },
            claudeControllerFactory: { _, _, _, _ in
                preconditionFailure("Pi thinking restore tests must not start Claude")
            },
            headlessProviderFactory: { _, _ in UnsupportedHeadlessAgentProvider(reason: "pi thinking restore test") },
            mcpServerEnabler: { false },
            testUsesProductionAgentDefaultsAndModelPolling: false
        )
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .piAgent
        session.selectedModelRaw = "openai/gpt-5"
        let persisted = AgentSession(
            name: "Saved pi thinking",
            agentKind: AgentProviderKind.piAgent.rawValue,
            agentModel: "openai/gpt-5",
            agentReasoningEffort: "medium"
        )
        viewModel.restorePiThinking(from: persisted, to: session)
        XCTAssertEqual(session.selectedReasoningEffortRaw, "medium")
    }

    func testAgentModePromptQualifiesPiSetStatusAsNamespacedMCPTool() {
        let prompt = SystemPromptService.agentModePrompt(agentKind: .piAgent)
        XCTAssertTrue(prompt.contains("`mcp__RepoPromptCE__set_status`"))
        XCTAssertFalse(prompt.contains("`set_status`"))
        XCTAssertTrue(prompt.contains("Do not announce this in chat."))
        XCTAssertEqual(
            AgentModePrompts.Fragments.qualifiedRepoPromptToolName("set_status", agentKind: .piAgent),
            "mcp__RepoPromptCE__set_status"
        )
        XCTAssertEqual(
            AgentModePrompts.Fragments.qualifiedRepoPromptToolName("set_status", agentKind: .claudeCode),
            "set_status"
        )
    }

    func testSelfCompactAndControlCommandsAdmitPi() {
        XCTAssertTrue(AgentProviderKind.piAgent.usesPiNativeRuntime)
        XCTAssertFalse(AgentProviderControlCommand.acpRuntimeAdvertisesNativeCommands(.piAgent))
        XCTAssertEqual(AgentSessionLinkCompactSupport.pi.rawValue, "pi")
    }

    @MainActor
    func testSessionLinkCompactSupportTreatsPiLikeClaudeAndCodex() async {
        let viewModel = AgentModeViewModel(
            testWindowID: 99014,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Pi compact support tests must not start Codex")
            },
            claudeControllerFactory: { _, _, _, _ in
                preconditionFailure("Pi compact support tests must not start Claude")
            },
            headlessProviderFactory: { _, _ in UnsupportedHeadlessAgentProvider(reason: "pi compact support test") },
            mcpServerEnabler: { false },
            testUsesProductionAgentDefaultsAndModelPolling: false
        )
        let tabID = UUID()
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .piAgent
        let withoutConversation = await viewModel.agentSessionLinkCompactSupport(for: session)
        XCTAssertEqual(withoutConversation, .noProviderSession)

        session.providerSessionID = "pi-session"
        let withConversation = await viewModel.agentSessionLinkCompactSupport(for: session)
        XCTAssertEqual(withConversation, .pi)
    }

    func testManagedPiMCPConfigCoversSubagentLifecycleWaits() {
        let server = RepoPromptMCPServerConfiguration.repoPrompt
        let configuration = PiProviderRuntimeBridge.managedRepoPromptMCPServerConfiguration(server)
        XCTAssertEqual(configuration.exposure, .direct)
        XCTAssertEqual(
            configuration.timeoutSeconds,
            MCPTimeoutPolicy.piBuiltinMCPRequestTimeoutSeconds
        )
        XCTAssertNotEqual(configuration.timeoutSeconds, 15)
        XCTAssertGreaterThanOrEqual(
            configuration.timeoutSeconds ?? 0,
            Int(
                (
                    MCPTimeoutPolicy.cliImplicitLifecycleCompatibilityGuardSeconds
                        + MCPTimeoutPolicy.agentLifecycleSetupAllowanceSeconds
                ).rounded(.up)
            )
        )
    }
}
