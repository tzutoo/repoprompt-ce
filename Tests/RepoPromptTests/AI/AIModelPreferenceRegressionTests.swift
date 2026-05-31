import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPrompt

final class AIModelPreferenceRegressionTests: XCTestCase {
    @MainActor
    func testPlanningDropdownInvalidStateMatrixDoesNotDisplayFirstAvailableModel() {
        let availableModels: [AIModel] = [.codexCustom(name: "gpt-5.5-low")]
        let rows = [
            (rawValue: "", expectedDisplayName: "Select an Oracle model"),
            (rawValue: "legacy-oracle-model", expectedDisplayName: "Invalid Oracle model")
        ]

        for row in rows {
            let displayName = AIModelDropdown.displayName(
                forRawValue: row.rawValue,
                destinationID: "planningModel",
                availableModels: availableModels,
                customOpenRouterModels: []
            )

            XCTAssertEqual(displayName, row.expectedDisplayName, row.rawValue)
            XCTAssertNotEqual(displayName, availableModels[0].displayName, row.rawValue)
        }
    }

    @MainActor
    func testNonPlanningDropdownRetainsFirstAvailableFallbackForInvalidRaw() {
        let availableModels: [AIModel] = [.codexCustom(name: "gpt-5.5-low")]

        let displayName = AIModelDropdown.displayName(
            forRawValue: "legacy-chat-model",
            destinationID: "chatModel",
            availableModels: availableModels,
            customOpenRouterModels: []
        )

        XCTAssertEqual(displayName, availableModels[0].displayName)
    }

    @MainActor
    func testSettingsSyncClearsStaleModelRawWhenPersistedValueIsEmptyOrMissing() {
        XCTAssertEqual(
            PromptViewModel.modelRawAfterSettingsSync(currentRaw: "stale-planning", persistedRaw: ""),
            ""
        )
        XCTAssertEqual(
            PromptViewModel.modelRawAfterSettingsSync(currentRaw: "stale-preferred", persistedRaw: nil),
            ""
        )
        XCTAssertEqual(
            PromptViewModel.modelRawAfterSettingsSync(currentRaw: "stale", persistedRaw: "gpt-5.5-low"),
            "gpt-5.5-low"
        )
    }

    func testStrictOraclePlanningResolutionRejectsEmptyInvalidAndUnavailableRaw() {
        let empty = PromptViewModel.mcpOraclePlanningModelResolution(rawValue: "", isModelAvailable: { _ in true })
        XCTAssertEqual(empty, .unconfigured)
        XCTAssertEqual(
            PromptViewModel.mcpOraclePlanningModelErrorMessage(for: empty),
            "MCP Oracle model is not configured. Select an Oracle model in the Models settings before using ask_oracle."
        )

        let invalid = PromptViewModel.mcpOraclePlanningModelResolution(
            rawValue: "legacy-oracle-model",
            isModelAvailable: { _ in true }
        )
        XCTAssertEqual(invalid, .invalid(rawValue: "legacy-oracle-model"))
        XCTAssertEqual(
            PromptViewModel.mcpOraclePlanningModelErrorMessage(for: invalid),
            "MCP Oracle model raw value 'legacy-oracle-model' is invalid. Select a valid Oracle model in the Models settings before using ask_oracle."
        )

        let unavailableModel = AIModel.codexCustom(name: "gpt-5.5-low")
        let unavailable = PromptViewModel.mcpOraclePlanningModelResolution(
            rawValue: unavailableModel.rawValue,
            isModelAvailable: { _ in false }
        )
        XCTAssertEqual(unavailable, .unavailable(unavailableModel))
        XCTAssertEqual(
            PromptViewModel.mcpOraclePlanningModelErrorMessage(for: unavailable),
            "MCP oracle model '\(unavailableModel.displayName)' is not available."
        )
    }

    func testStrictOraclePlanningResolutionReturnsConfiguredModelOnlyWhenRawParsesAndIsAvailable() {
        let configuredModel = AIModel.codexCustom(name: "gpt-5.5-low")
        let resolved = PromptViewModel.mcpOraclePlanningModelResolution(
            rawValue: "  \(configuredModel.rawValue)  ",
            isModelAvailable: { model in model == configuredModel }
        )
        XCTAssertEqual(resolved, .configured(configuredModel))
    }

    func testOracleModelsReportingUsesStrictPlanningResolutionInsteadOfPreferredFallback() throws {
        let repoRoot = try RepoRoot.url(filePath: #filePath)
        let sourcePath = "Sources/RepoPrompt/Infrastructure/MCP/MCPOracleToolService.swift"
        let contents = try String(contentsOf: repoRoot.appendingPathComponent(sourcePath), encoding: .utf8)

        XCTAssertTrue(contents.contains("promptVM.mcpOraclePlanningModelResolution()"))
        XCTAssertFalse(contents.contains("let effectiveModel = planningAvailable ? planningModel : await promptVM.preferredAIModel"))
    }

    func testMCPOraclePlanningResolutionUsesProviderConfiguredAvailabilityWithoutAutoHeal() throws {
        let repoRoot = try RepoRoot.url(filePath: #filePath)
        let sourcePath = "Sources/RepoPrompt/Features/Prompt/ViewModels/PromptViewModel.swift"
        let contents = try String(contentsOf: repoRoot.appendingPathComponent(sourcePath), encoding: .utf8)

        XCTAssertTrue(contents.contains("func mcpOraclePlanningModelResolution() -> MCPOraclePlanningModelResolution"))
        XCTAssertTrue(contents.contains("self?.isProviderConfigured(for: model) ?? false"))
        XCTAssertFalse(contents.contains("self?.isModelAvailable(model) ?? false"))
        XCTAssertFalse(contents.contains("pickPlanningModelFallback"))
        XCTAssertFalse(contents.contains("prompt.validate_planning_model.fallback"))
    }

    func testLegacyMCPPlanningModelMigrationSymbolAndStartupCallAreRemoved() throws {
        let repoRoot = try RepoRoot.url(filePath: #filePath)
        let sourcePaths = [
            "Sources/RepoPrompt/App/AppDelegate.swift",
            "Sources/RepoPrompt/Features/Settings/ViewModels/APISettingsViewModel.swift"
        ]

        for sourcePath in sourcePaths {
            let contents = try String(contentsOf: repoRoot.appendingPathComponent(sourcePath), encoding: .utf8)
            XCTAssertFalse(contents.contains("migrateLegacyMCPPlanningModel"), sourcePath)
            XCTAssertFalse(contents.contains("mcpPlanningModel"), sourcePath)
            XCTAssertFalse(contents.contains("didMigrateMCPPlanningModelToPlanningModel"), sourcePath)
        }
    }
}
