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

    func testSelfCompactAndControlCommandsAdmitPi() {
        XCTAssertTrue(AgentProviderKind.piAgent.usesPiNativeRuntime)
        XCTAssertFalse(AgentProviderControlCommand.acpRuntimeAdvertisesNativeCommands(.piAgent))
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
