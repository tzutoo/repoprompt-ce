import Foundation
import RepoPromptShared

/// Controls how Context Builder handles the user's original prompt
package enum PromptEnhancementMode: String, Codable, CaseIterable {
    case fullRewrite // Agent rewrites prompt from discoveries
    case augment // Preserve original + add context
    case preserve // Don't touch the prompt at all
}

package struct ContextBuilderBehaviorSettings: Equatable {
    package var contextTokenBudget: Int
    package var analysisTokenBudget: Int
    package var enhancementMode: PromptEnhancementMode
    package var questionTimeoutSeconds: TimeInterval
    package var allowUIClarifyingQuestions: Bool
    package var allowMCPClarifyingQuestions: Bool
    package var followUpAnalysisEnabled: Bool

    package init(
        contextTokenBudget: Int,
        analysisTokenBudget: Int,
        enhancementMode: PromptEnhancementMode,
        questionTimeoutSeconds: TimeInterval,
        allowUIClarifyingQuestions: Bool,
        allowMCPClarifyingQuestions: Bool,
        followUpAnalysisEnabled: Bool
    ) {
        self.contextTokenBudget = contextTokenBudget
        self.analysisTokenBudget = analysisTokenBudget
        self.enhancementMode = enhancementMode
        self.questionTimeoutSeconds = questionTimeoutSeconds
        self.allowUIClarifyingQuestions = allowUIClarifyingQuestions
        self.allowMCPClarifyingQuestions = allowMCPClarifyingQuestions
        self.followUpAnalysisEnabled = followUpAnalysisEnabled
    }
}

/// Centralized default values for Context Builder.
/// Update these values to change defaults across the entire app.
package enum ContextBuilderDefaults {
    // MARK: - Token Budgets

    /// Default selected-context budget for context-only runs
    package static let contextTokenBudget: Int = 160_000

    /// Default selected-context budget for plan, review, and question runs
    package static let analysisTokenBudget: Int = 120_000

    /// Conservative window used when the selected model has no verified size.
    package static let fallbackContextWindowTokens: Int = 200_000

    /// Supported persisted/UI range for context-only token budgets.
    package static let contextTokenBudgetRange: ClosedRange<Int> = 10000 ... 1_000_000

    /// Supported persisted/UI range for plan, review, and question token budgets.
    package static let analysisTokenBudgetRange: ClosedRange<Int> = 40000 ... 1_000_000

    package static func normalizedContextTokenBudget(_ value: Int) -> Int {
        min(max(value, contextTokenBudgetRange.lowerBound), contextTokenBudgetRange.upperBound)
    }

    package static func normalizedAnalysisTokenBudget(_ value: Int) -> Int {
        min(max(value, analysisTokenBudgetRange.lowerBound), analysisTokenBudgetRange.upperBound)
    }

    /// Slider upper bound follows the selected model's window without exceeding the product range.
    package static func sliderUpperBound(
        modelContextWindowTokens: Int,
        lowerBound: Int
    ) -> Int {
        let window = max(modelContextWindowTokens, lowerBound)
        return min(max(window, lowerBound), analysisTokenBudgetRange.upperBound)
    }

    package static func contextSliderRange(modelContextWindowTokens: Int) -> ClosedRange<Double> {
        let upper = sliderUpperBound(
            modelContextWindowTokens: modelContextWindowTokens,
            lowerBound: contextTokenBudgetRange.lowerBound
        )
        return Double(contextTokenBudgetRange.lowerBound) ... Double(upper)
    }

    package static func analysisSliderRange(modelContextWindowTokens: Int) -> ClosedRange<Double> {
        let upper = sliderUpperBound(
            modelContextWindowTokens: modelContextWindowTokens,
            lowerBound: analysisTokenBudgetRange.lowerBound
        )
        return Double(analysisTokenBudgetRange.lowerBound) ... Double(upper)
    }

    // MARK: - Enhancement Mode

    /// Default prompt enhancement mode
    package static let enhancementMode: PromptEnhancementMode = .fullRewrite

    // MARK: - Clarifying Questions

    /// Whether clarifying questions are allowed by default for UI-triggered discovery
    package static let allowUIClarifyingQuestions: Bool = true

    /// Whether clarifying questions are allowed for MCP-triggered discovery
    package static let allowMCPClarifyingQuestions: Bool = false

    /// Default timeout (in seconds) for user responses to clarifying questions
    package static let questionTimeoutSeconds = MCPTimeoutPolicy.askUserDefaultTimeoutSeconds

    // MARK: - Follow-up Analysis

    /// Whether to automatically analyze selected context after a UI run
    package static let followUpAnalysisEnabled: Bool = false

    package static let behaviorSettings = ContextBuilderBehaviorSettings(
        contextTokenBudget: contextTokenBudget,
        analysisTokenBudget: analysisTokenBudget,
        enhancementMode: enhancementMode,
        questionTimeoutSeconds: questionTimeoutSeconds,
        allowUIClarifyingQuestions: allowUIClarifyingQuestions,
        allowMCPClarifyingQuestions: allowMCPClarifyingQuestions,
        followUpAnalysisEnabled: followUpAnalysisEnabled
    )
}
