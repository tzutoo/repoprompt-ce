import Foundation
@testable import RepoPromptApp
import XCTest

final class PiProviderIdentityAndBindingTests: XCTestCase {
    func testMCPClientIdentityResolvesPiMCPAdapterFamily() {
        XCTAssertEqual(MCPClientIdentity.canonicalFamilyID("pi-mcp-RepoPromptCE"), "pi-mcp")
        XCTAssertEqual(MCPClientIdentity.canonicalFamilyID("pi-mcp"), "pi-mcp")
        XCTAssertTrue(MCPClientIdentity.matches("pi-mcp-RepoPromptCE", AgentProviderKind.piAgent.mcpClientNameHint))
        // Separator boundary: `pi-mcpx` must not match the family.
        XCTAssertNil(MCPClientIdentity.canonicalFamilyID("pi-mcpx"))
        // Storage keys canonicalize the exact registered client name.
        XCTAssertEqual(MCPClientIdentity.storageKey("pi-mcp-RepoPromptCE"), "pi-mcp")
        XCTAssertFalse(MCPClientIdentity.sameFamily("pi-mcp-RepoPromptCE", "grok-shell-RepoPromptCE"))
        XCTAssertTrue(ServerController.isBuiltInAlwaysAllowedClient("pi-mcp-RepoPromptCE"))
        XCTAssertTrue(ServerController.isBuiltInAlwaysAllowedClient("pi-mcp"))
        XCTAssertFalse(ServerController.isBuiltInAlwaysAllowedClient("pi-mcpx"))
    }

    func testProviderKindMetadata() {
        XCTAssertEqual(AgentProviderKind.piAgent.commandName, "pi")
        XCTAssertEqual(AgentProviderKind.piAgent.displayName, "pi")
        XCTAssertEqual(AgentProviderKind.piAgent.runtimeKind, "pi_rpc")
        XCTAssertEqual(AgentProviderKind.piAgent.mcpClientNameHint, "pi-mcp-RepoPromptCE")
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
    }
}
