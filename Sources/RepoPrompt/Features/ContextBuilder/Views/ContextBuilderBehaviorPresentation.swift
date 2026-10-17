import RepoPromptSettingsCore

/// Read-only presentation authority for Context Builder behavior readouts.
///
/// Idle presentation describes the next run from desired settings. Active presentation
/// describes the displayed tab's immutable, ownership-valid `ContextBuilderRunBehavior`.
/// The projection never writes settings, never substitutes live preferences for an
/// active run, and ends with discovery settlement; it does not own persistence,
/// admission, run identity, or snapshot lifetime.
enum ContextBuilderBehaviorPresentation: Equatable {
    /// No discovery run is active for the displayed tab. Readouts follow desired settings
    /// exactly as the next UI run would capture them.
    case idle(ContextBuilderRunBehavior)
    /// The displayed tab's active discovery run with its captured effective behavior.
    case active(ContextBuilderRunBehavior)
    /// A discovery run is active for the displayed tab, but no ownership-valid capture is
    /// available. Nothing is inferred from desired settings.
    case unavailable

    /// UI automatic follow-up as the view presents it. `off` is a valid captured/desired
    /// decision; `unavailable` is unknown and must not be drawn as Off.
    enum AutomaticFollowUp: Equatable {
        case enabled(ContextBuilderFollowUpType)
        case off
        case unavailable
    }

    static let unavailableLabel = "Unavailable"
    static let unavailableSummary = "Current run settings unavailable"

    static func resolve(
        isRunning: Bool,
        activeRunBehavior: ContextBuilderRunBehavior?,
        desiredSettings: ContextBuilderBehaviorSettings,
        selectedFollowUp: ContextBuilderFollowUpType,
        modelContextWindowTokens: Int = ContextBuilderDefaults.fallbackContextWindowTokens
    ) -> ContextBuilderBehaviorPresentation {
        guard isRunning else {
            // Desired analysis budgets are normalized to the supported preference range on
            // read and write (#834); apply the same normalization here so idle matches the
            // preference editor. Captured effective budgets are never re-clamped.
            var desired = desiredSettings
            desired.contextTokenBudget = ContextBuilderDefaults.normalizedContextTokenBudget(desired.contextTokenBudget)
            desired.analysisTokenBudget = ContextBuilderDefaults.normalizedAnalysisTokenBudget(desired.analysisTokenBudget)
            return .idle(
                ContextBuilderRunBehavior.ui(
                    settings: desired,
                    selectedFollowUp: selectedFollowUp,
                    modelContextWindowTokens: modelContextWindowTokens
                )
            )
        }
        guard let activeRunBehavior else { return .unavailable }
        return .active(activeRunBehavior)
    }

    var isActive: Bool {
        if case .idle = self {
            return false
        }
        return true
    }

    var isUnavailable: Bool {
        self == .unavailable
    }

    /// Effective behavior for readouts; nil only when unavailable.
    var behavior: ContextBuilderRunBehavior? {
        switch self {
        case let .idle(behavior), let .active(behavior): behavior
        case .unavailable: nil
        }
    }

    var enhancementMode: PromptEnhancementMode? {
        behavior?.enhancementMode
    }

    /// Effective clarifying-question permission for either origin. Nil when unavailable so
    /// the indicator never fabricates a disabled permission.
    var allowsClarifyingQuestions: Bool? {
        behavior?.allowClarifyingQuestions
    }

    var questionTimeoutSeconds: TimeInterval? {
        behavior?.questionTimeoutSeconds
    }

    /// UI automatic follow-up. Nil with a behavior means Off; MCP captures are always nil
    /// because MCP response intent is owned separately. Nil when unavailable means unknown.
    var automaticFollowUp: ContextBuilderFollowUpType? {
        behavior?.automaticFollowUp
    }

    var isAutomaticFollowUpEnabled: Bool {
        automaticFollowUp != nil
    }

    var automaticFollowUpPresentation: AutomaticFollowUp {
        switch self {
        case .unavailable: .unavailable
        case let .idle(behavior), let .active(behavior):
            behavior.automaticFollowUp.map { .enabled($0) } ?? .off
        }
    }

    var automaticFollowUpIndicatorSymbolName: String {
        switch automaticFollowUpPresentation {
        case .enabled: "bolt.fill"
        case .off: "bolt"
        case .unavailable: "bolt.trianglebadge.exclamationmark"
        }
    }

    /// Tooltip for the compact Auto control. Idle describes the desired next run (Off is
    /// explicit); active describes the captured decision and budget. `planModelName` is the
    /// separate Oracle model authority supplied by the view, not part of the capture.
    func automaticFollowUpTooltip(planModelName: String) -> String {
        switch self {
        case .unavailable:
            return Self.unavailableSummary
        case let .active(behavior):
            guard let followUp = behavior.automaticFollowUp else {
                return "Automatic follow-up: Off for this run"
            }
            return "Auto-run \(followUp.buttonLabel.lowercased()) after Context Builder\n\nUses \(planModelName) with \(behavior.tokenBudget / 1000)k tokens"
        case let .idle(behavior):
            guard let followUp = behavior.automaticFollowUp else {
                return "Automatic follow-up: Off\n\nTurn on to run the selected analysis after Context Builder"
            }
            return "Auto-run \(followUp.buttonLabel.lowercased()) after Context Builder\n\nUses \(planModelName) with \(behavior.tokenBudget / 1000)k tokens"
        }
    }

    var tokenBudgetLabel: String {
        behavior.map { "\($0.tokenBudget / 1000)k" } ?? Self.unavailableLabel
    }

    var headerTitle: String {
        switch enhancementMode {
        case .fullRewrite: "Task Description"
        case .augment: "Additional Context (Optional)"
        case .preserve: "Build Context"
        case nil: "Context Builder"
        }
    }

    var modeLabel: String {
        switch enhancementMode {
        case .fullRewrite: "Rewrite"
        case .augment: "Augment"
        case .preserve: "Preserve"
        case nil: Self.unavailableLabel
        }
    }

    var headerTooltip: String {
        switch enhancementMode {
        case .fullRewrite:
            "Describe your task here.\n\nThe agent will:\n• Analyze your codebase\n• Select relevant files\n• Write detailed instructions above\n\nThis is your primary input in Rewrite mode."
        case .augment:
            "Add extra context to help the agent.\n\nThe agent will:\n• Keep your existing instructions\n• Add relevant context\n• Select appropriate files\n\nLeave empty to just enhance with file context."
        case .preserve:
            "Provide hints for context building.\n\nThe agent will:\n• Only select relevant files\n• Leave your instructions unchanged\n\nUseful when you've already written detailed instructions."
        case nil:
            Self.unavailableSummary
        }
    }

    /// Empty input still describes this run while discovery is active, not the next-run preference.
    var instructionsPlaceholder: String {
        switch enhancementMode {
        case .fullRewrite:
            "Describe your task here...\n\nExample: \"Add a dark mode toggle to the settings page with system, light, and dark options. Store the preference and apply it app-wide.\""
        case .augment:
            "Add extra details to help the agent find relevant files and enhance your prompt"
        case .preserve:
            "Describe what files to look for (your instructions won't be modified)"
        case nil:
            Self.unavailableSummary
        }
    }

    var questionIndicatorSymbolName: String {
        switch allowsClarifyingQuestions {
        case true?: "questionmark.circle.fill"
        case false?: "questionmark.circle"
        case nil: "questionmark.circle.dashed"
        }
    }

    /// Behavior summary lines for the settings tooltip. The timeout appears only when the
    /// run can ask questions, so a disabled run never implies a timeout is being awaited.
    var summaryLines: [String] {
        guard let behavior else { return [Self.unavailableSummary] }
        var lines = [isActive ? "Current run settings" : "Context Builder Settings"]
        lines.append("Token budget: \(tokenBudgetLabel)")
        lines.append("Prompt mode: \(modeLabel)")
        if behavior.allowClarifyingQuestions {
            lines.append("Clarifying questions: On")
            lines.append("Question timeout: \(Self.questionTimeoutLabel(behavior.questionTimeoutSeconds))")
        } else {
            lines.append("Clarifying questions: Off")
        }
        return lines
    }

    static func questionTimeoutLabel(_ seconds: TimeInterval) -> String {
        let wholeSeconds = Int(seconds.rounded())
        if wholeSeconds >= 60, wholeSeconds % 60 == 0 {
            return "\(wholeSeconds / 60) min"
        }
        return "\(wholeSeconds) sec"
    }
}
