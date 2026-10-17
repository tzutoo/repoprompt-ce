import Foundation
import RepoPromptSettingsCore

/// Centralizes context builder budget selection so UI and MCP paths resolve
/// clarify/omitted runs and follow-up-generation runs consistently.
enum ContextBuilderBudgetResolver {
    static func resolveUIBudget(
        behaviorSettings: ContextBuilderBehaviorSettings,
        modelContextWindowTokens: Int = ContextBuilderDefaults.fallbackContextWindowTokens
    ) -> Int {
        let requested = behaviorSettings.followUpAnalysisEnabled
            ? behaviorSettings.analysisTokenBudget
            : behaviorSettings.contextTokenBudget
        return clamp(requested, to: modelContextWindowTokens)
    }

    static func resolveMCPBudget(
        wantsResponse: Bool,
        behaviorSettings: ContextBuilderBehaviorSettings,
        modelContextWindowTokens: Int = ContextBuilderDefaults.fallbackContextWindowTokens
    ) -> Int {
        let requested = wantsResponse
            ? behaviorSettings.analysisTokenBudget
            : behaviorSettings.contextTokenBudget
        return clamp(requested, to: modelContextWindowTokens)
    }

    /// Caps a requested package size to the selected model's window without raising it.
    static func clamp(_ requested: Int, to modelContextWindowTokens: Int) -> Int {
        min(max(requested, 0), max(modelContextWindowTokens, 0))
    }

    /// Known context window for a Context Builder discovery selection.
    /// Matches Agent Mode's catalog/fallback lookup so sliders and runs share one authority.
    static func contextWindowTokens(
        agentKind: AgentProviderKind?,
        modelRaw: String?
    ) -> Int {
        let model: AgentModel? = if let agentKind {
            AgentModel.resolvedModel(forRaw: modelRaw, agentKind: agentKind)
        } else {
            modelRaw.flatMap(AgentModel.init(rawValue:))
        }
        if let agentKind,
           let compatibleContextWindow = ClaudeCompatibleModelCatalogAdapter.contextWindowTokens(
               forRequestedModelRaw: modelRaw,
               agentKind: agentKind
           )
        {
            return compatibleContextWindow
        }
        if let modelContextWindow = model?.contextWindowTokens {
            return modelContextWindow
        }
        if let modelRaw {
            let lower = modelRaw.lowercased()
            if lower.contains("deepseek-v4") {
                return 1_000_000
            }
            if lower.contains("262k") || lower.contains("262144") {
                return 262_144
            }
            if lower.contains("grok") {
                return 500_000
            }
        }
        switch agentKind {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            return 200_000
        case .openCode, .cursor, .antigravity:
            return 200_000
        case .grokBuild:
            return 500_000
        case .piAgent:
            return PiModelRegistry.contextWindow(forRaw: modelRaw ?? "") ?? 200_000
        case .codexExec, .devin, .none:
            return 200_000
        }
    }
}
