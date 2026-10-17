import RepoPromptSettingsCore
import SwiftUI

enum ContextBuilderGeneratedAnswerActionText {
    static let useAsPromptTooltip = "Use the generated answer as your prompt"
    static let copyTooltip = "Copy answer to clipboard"
    static let previewTooltip = "Preview the generated answer"
    static let viewInChatTooltip = "Open answer in chat view"
}

struct ContextBuilderAgentView: View {
    @ObservedObject var viewModel: ContextBuilderAgentViewModel
    @ObservedObject var oracleViewModel: OracleViewModel
    let windowID: Int
    var availableWidth: CGFloat
    let openGeneratedAnswerChat: (ContextBuilderGeneratedAnswerRoute) -> Void

    init(
        viewModel: ContextBuilderAgentViewModel,
        oracleViewModel: OracleViewModel,
        windowID: Int,
        availableWidth: CGFloat,
        openGeneratedAnswerChat: @escaping (ContextBuilderGeneratedAnswerRoute) -> Void
    ) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _oracleViewModel = ObservedObject(wrappedValue: oracleViewModel)
        self.windowID = windowID
        self.availableWidth = availableWidth
        self.openGeneratedAnswerChat = openGeneratedAnswerChat
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with agent/model selection
            headerSection

            // Clarifying question input (shown when agent asks a question)
            if let pendingAskUser = viewModel.pendingAskUser(for: subjectTabID) {
                AgentAskUserWizardCard(
                    pending: pendingAskUser,
                    onDraftChange: { questionID, draft in
                        guard let tabID = subjectTabID else { return }
                        viewModel.updateAskUserDraft(
                            tabID: tabID,
                            interactionID: pendingAskUser.interaction.id,
                            questionID: questionID,
                            draft: draft
                        )
                    },
                    onQuestionIndexChange: { index in
                        guard let tabID = subjectTabID else { return }
                        viewModel.updateAskUserQuestionIndex(
                            tabID: tabID,
                            interactionID: pendingAskUser.interaction.id,
                            index: index
                        )
                    },
                    onSubmit: {
                        guard let tabID = subjectTabID else { return }
                        viewModel.submitAskUserResponse(tabID: tabID, interactionID: pendingAskUser.interaction.id)
                    },
                    onSkipAll: {
                        guard let tabID = subjectTabID else { return }
                        viewModel.skipAskUser(tabID: tabID, interactionID: pendingAskUser.interaction.id)
                    },
                    onUserActivity: {
                        guard let tabID = subjectTabID else { return }
                        viewModel.noteAskUserCardActivity(tabID: tabID, interactionID: pendingAskUser.interaction.id)
                    }
                )
            }

            // Instructions input with integrated controls
            instructionsSection

            // Background plan generation status (always visible)
            backgroundPlanSection

            // Current/last run log (below plan status)
            if !viewModel.agentLog.isEmpty {
                currentRunSection
            }
        }
        .messageTimestampEnvironment()
        .onAppear {
            viewModel.refreshActiveSessionBindings()
        }
    }

    // MARK: - Context Builder Prompts

    @State private var showPromptsOverlay = false
    @ObservedObject private var promptStorage = ContextBuilderPromptStorage.shared

    // MARK: - Background Plan Section

    @State private var showingPlanPreview = false

    /// The tab ID to use for plan status queries - single source of truth from ViewModel
    private var subjectTabID: UUID? {
        viewModel.currentTabID
    }

    /// Whether this specific tab has an active Context Builder run
    private var isContextBuilderRunningForTab: Bool {
        guard let tabID = subjectTabID else { return false }
        return viewModel.tabsWithActiveContextBuilderRun.contains(tabID)
    }

    private var activeRunBehavior: ContextBuilderRunBehavior? {
        guard isContextBuilderRunningForTab else { return nil }
        return viewModel.activeRunBehavior(for: subjectTabID)
    }

    /// Desired next-run configuration. Only idle presentation reads it.
    private var desiredBehaviorSettings: ContextBuilderBehaviorSettings {
        ContextBuilderBehaviorSettings(
            contextTokenBudget: viewModel.contextTokenBudget,
            analysisTokenBudget: viewModel.analysisTokenBudget,
            enhancementMode: viewModel.enhancementMode,
            questionTimeoutSeconds: viewModel.questionTimeoutSeconds,
            allowUIClarifyingQuestions: viewModel.allowUIClarifyingQuestions,
            allowMCPClarifyingQuestions: viewModel.allowMCPClarifyingQuestions,
            followUpAnalysisEnabled: viewModel.followUpAnalysisEnabled
        )
    }

    private var selectedModelContextWindowTokens: Int {
        ContextBuilderBudgetResolver.contextWindowTokens(
            agentKind: viewModel.selectedAgent,
            modelRaw: viewModel.selectedModelRaw
        )
    }

    /// Single presentation authority for every readout that describes run behavior.
    private var behaviorPresentation: ContextBuilderBehaviorPresentation {
        ContextBuilderBehaviorPresentation.resolve(
            isRunning: isContextBuilderRunningForTab,
            activeRunBehavior: activeRunBehavior,
            desiredSettings: desiredBehaviorSettings,
            selectedFollowUp: viewModel.selectedFollowUpType,
            modelContextWindowTokens: selectedModelContextWindowTokens
        )
    }

    private var displayedFollowUpAnalysisEnabled: Bool {
        behaviorPresentation.isAutomaticFollowUpEnabled
    }

    private var followUpTooltip: String {
        behaviorPresentation.automaticFollowUpTooltip(planModelName: planModelName)
    }

    private var followUpIndicatorColor: Color {
        switch behaviorPresentation.automaticFollowUpPresentation {
        case .enabled, .unavailable: .orange
        case .off: .secondary
        }
    }

    /// Whether a prompt is available for plan generation
    private var hasPromptForPlan: Bool {
        guard let tabID = subjectTabID else { return false }
        return viewModel.effectivePrompt(for: tabID) != nil
    }

    /// Whether the Generate Plan button should be enabled
    private var canGeneratePlan: Bool {
        guard let tabID = subjectTabID, hasPromptForPlan else { return false }
        switch viewModel.planStatus(for: tabID) {
        case .generating:
            return false
        default:
            // Also block if Context Builder is running for this tab
            return !isContextBuilderRunningForTab
        }
    }

    /// Tooltip explaining why Generate Plan is disabled
    private var generatePlanDisabledReason: String? {
        guard let tabID = subjectTabID else { return "No tab active" }
        switch viewModel.planStatus(for: tabID) {
        case .generating:
            return "Plan generation in progress"
        case .idle, .ready, .error:
            if isContextBuilderRunningForTab {
                if viewModel.isMCPControlledRun {
                    return "Context Builder running via context_builder"
                }
                if displayedFollowUpAnalysisEnabled {
                    return "Will auto-generate when Context Builder completes"
                }
                return "Wait for Context Builder to complete"
            }
            if !hasPromptForPlan {
                return "Run Context Builder first to generate a prompt"
            }
            return nil
        }
    }

    /// The primary Oracle model that will be used for follow-up generation.
    private var planModelName: String {
        let rawValue = oracleViewModel.promptViewModel.planningModelName
        return AIModel.fromModelName(rawValue)?.displayName ?? "Select an Oracle model"
    }

    /// Text describing what MCP will do after Context Builder completes
    private var mcpWaitingText: String {
        guard let responseType = viewModel.mcpResponseType?.lowercased() else {
            return "MCP Context Builder running..."
        }
        switch responseType {
        case "plan":
            return "MCP: Will generate plan after Context Builder"
        case "question":
            return "MCP: Will answer question after Context Builder"
        case "clarify":
            return "MCP: Context-only (no plan generation)"
        default:
            return "MCP Context Builder running..."
        }
    }

    /// Selected follow-up type for plan generation - now uses ViewModel's property for persistence
    private var selectedFollowUpType: ContextBuilderFollowUpType {
        get { viewModel.selectedFollowUpType }
        nonmutating set { viewModel.selectedFollowUpType = newValue }
    }

    @ViewBuilder
    private var backgroundPlanSection: some View {
        let status = viewModel.planStatus(for: subjectTabID)

        VStack(alignment: .leading, spacing: 8) {
            // MCP Control indicator (when MCP is controlling the run)
            if viewModel.isMCPControlledRun {
                mcpControlIndicator
            }

            // Line 1: Analysis follow-up label + auto toggle (hidden when MCP controlled)
            if !viewModel.isMCPControlledRun {
                HStack(spacing: 6) {
                    Text("Analysis follow-up")
                        .font(.callout)
                        .foregroundColor(.secondary)

                    // Auto toggle (compact) with label. The switch depicts a valid desired
                    // (idle) or captured (active) decision only; an active run without an
                    // ownership-valid capture shows a read-only Unavailable readout instead of
                    // a false Off position.
                    let followUpPresentation = behaviorPresentation.automaticFollowUpPresentation
                    HStack(spacing: 4) {
                        Image(systemName: behaviorPresentation.automaticFollowUpIndicatorSymbolName)
                            .font(.caption)
                            .foregroundColor(followUpIndicatorColor)
                        Text("Auto")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if followUpPresentation == .unavailable {
                            Text(ContextBuilderBehaviorPresentation.unavailableLabel)
                                .font(.caption)
                                .foregroundColor(.orange)
                        } else {
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { followUpPresentation != .off },
                                    set: { viewModel.followUpAnalysisEnabled = $0 }
                                )
                            )
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                            .disabled(isContextBuilderRunningForTab)
                        }
                    }
                    .hoverTooltip(followUpTooltip)

                    Spacer()
                }
            }

            // Line 2: Status indicator + Model picker + Generate button
            HStack(spacing: 8) {
                // Status indicator
                planStatusIndicator
                    .layoutPriority(1)

                Spacer(minLength: 0)

                // Generate/Regenerate/Cancel button
                planPrimaryButton
            }

            // Line 3: Plan actions (only when plan is ready)
            if case let .ready(route, previewText) = status {
                planReadyActions(route: route, previewText: previewText)
            } else if let route = viewModel.failedAnswerRoute(for: subjectTabID) {
                Button("View in Chat", systemImage: "bubble.left.and.bubble.right") {
                    viewGeneratedPlan(route: route)
                }
                .hoverTooltip(ContextBuilderGeneratedAnswerActionText.viewInChatTooltip)
            }
        }
        .padding(10)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
    }

    /// MCP control indicator showing settings captured for the current run
    @ViewBuilder
    private var mcpControlIndicator: some View {
        let responseTypeRaw = viewModel.mcpResponseType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let wantsResponse = switch responseTypeRaw {
        case "plan", "question", "review":
            true
        default:
            false
        }
        let responseTypeLabel: String = {
            guard let raw = responseTypeRaw, !raw.isEmpty else { return "Clarify" }
            return raw.capitalized
        }()

        // MCP response type/model are separately owned metadata and always shown. The
        // discovery budget shows only while the run is active; an active run without an
        // ownership-valid capture marks its settings unavailable without hiding the rest.
        let presentation = behaviorPresentation
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.orange)

            Text("MCP Controlled")
                .font(.callout)
                .fontWeight(.medium)
                .foregroundColor(.orange)

            Text("•")
                .foregroundColor(.secondary)

            Text(responseTypeLabel)
                .font(.callout)
                .foregroundColor(.primary)

            if case let .active(behavior) = presentation {
                Text("•")
                    .foregroundColor(.secondary)

                Text("\(behavior.tokenBudget / 1000)k tokens")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            if let model = viewModel.mcpPlanModel, wantsResponse {
                Text("•")
                    .foregroundColor(.secondary)
                Text(model)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            if presentation.isUnavailable {
                Text("•")
                    .foregroundColor(.secondary)
                Label(ContextBuilderBehaviorPresentation.unavailableSummary, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundColor(.orange)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.1))
        )
    }

    /// Label for the current follow-up type (uses MCP response type when MCP-controlled)
    private var currentFollowUpLabel: String {
        if viewModel.isMCPControlledRun, let mcpType = viewModel.mcpResponseType?.lowercased() {
            switch mcpType {
            case "question": return "answer"
            case "review": return "review"
            case "plan": return "plan"
            default: return selectedFollowUpType.buttonLabel.lowercased()
            }
        }
        return selectedFollowUpType.buttonLabel.lowercased()
    }

    private var currentOracleGroupStreamingLabel: String? {
        guard let tabID = subjectTabID, let session = viewModel.sessions[tabID] else { return nil }
        return ContextBuilderOracleGroupProgressProjection.streamingLabel(
            members: session.followUpOracleGroupState.members,
            streamingSessionIDs: oracleViewModel.streamingSessions
        )
    }

    @ViewBuilder
    private var planStatusIndicator: some View {
        let status = viewModel.planStatus(for: subjectTabID)

        switch status {
        case .generating:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                Text(currentOracleGroupStreamingLabel ?? "Generating \(currentFollowUpLabel)...")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

        case let .error(message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(message)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Button(action: {
                    viewModel.cancelBackgroundPlanGeneration()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

        case .ready:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Ready ·")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                planModelPicker
                followUpTypePicker
            }

        case .idle:
            // Show waiting state for UI auto-plan and MCP-controlled runs, and for an active
            // run whose captured behavior is unavailable (never drawn as Auto Off).
            let presentation = behaviorPresentation
            let isWaitingForContextBuilder = isContextBuilderRunningForTab &&
                (displayedFollowUpAnalysisEnabled || viewModel.isMCPControlledRun || presentation.isUnavailable)

            if isWaitingForContextBuilder {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    // MCP intent/model are separate authority and stay visible; the MCP control
                    // strip above already carries the unavailable-settings warning for MCP runs.
                    if viewModel.isMCPControlledRun {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mcpWaitingText)
                                .font(.callout)
                                .foregroundColor(.secondary)
                            if let model = viewModel.mcpPlanModel {
                                Text("Plan model: \(model)")
                                    .font(.caption)
                                    .foregroundColor(.secondary.opacity(0.8))
                            }
                        }
                    } else if presentation.isUnavailable {
                        Text(ContextBuilderBehaviorPresentation.unavailableSummary)
                            .font(.callout)
                            .foregroundColor(.orange)
                    } else {
                        Text("Waiting for Context Builder...")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    planModelPicker
                    followUpTypePicker
                    if !hasPromptForPlan {
                        Text("• No prompt")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    /// Inline model picker for plan generation
    private var planModelPicker: some View {
        OptimizedModelPicker(
            selection: $oracleViewModel.promptViewModel.planningModelName,
            availableModels: oracleViewModel.promptViewModel.availableModels,
            font: .callout,
            widthStyle: .flexible()
        )
        .disabled(isContextBuilderRunningForTab)
        .hoverTooltip("Primary Oracle for \(selectedFollowUpType.buttonLabel.lowercased()) generation. Additional Oracles come from Agent Models.")
    }

    /// Inline follow-up type picker (Plan/Review/Question)
    private var followUpTypePicker: some View {
        Menu {
            ForEach(ContextBuilderFollowUpType.allCases, id: \.self) { type in
                Button(action: { selectedFollowUpType = type }) {
                    Label(type.displayName, systemImage: type.icon)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selectedFollowUpType.icon)
                    .font(.callout)
                Text(selectedFollowUpType.displayName)
                    .font(.callout)
                    .fontWeight(.medium)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(isContextBuilderRunningForTab)
        .hoverTooltip(selectedFollowUpType.description)
    }

    /// Primary button: Generate / Regenerate / Cancel depending on state
    @ViewBuilder
    private var planPrimaryButton: some View {
        let status = viewModel.planStatus(for: subjectTabID)

        switch status {
        case .generating:
            HStack(spacing: 8) {
                // Preview button while generating (icon only)
                let hasReasoningContent = !(viewModel.backgroundPlanReasoningPreviewText ?? "").isEmpty
                let hasResponseContent = !(viewModel.backgroundPlanResponsePreviewText ?? "").isEmpty
                if hasReasoningContent || hasResponseContent {
                    Button(action: { showingPlanPreview.toggle() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.callout)
                            // Show brain icon when reasoning is streaming
                            if hasReasoningContent, !hasResponseContent {
                                Image(systemName: "brain")
                                    .font(.caption)
                                    .foregroundColor(.purple)
                            }
                        }
                    }
                    .buttonStyle(CustomButtonStyle(
                        verticalPadding: 6,
                        horizontalPadding: 10,
                        height: 28
                    ))
                    .hoverTooltip(hasReasoningContent && !hasResponseContent ? "Preview reasoning in progress" : "Preview plan in progress")
                    .popover(isPresented: $showingPlanPreview) {
                        planPreviewPopover()
                    }
                }

                // Cancel button
                Button(action: { viewModel.cancelBackgroundPlanGeneration() }) {
                    Text("Cancel")
                        .font(.callout)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
                .buttonStyle(CustomButtonStyle(
                    verticalPadding: 6,
                    horizontalPadding: 12,
                    height: 28
                ))
                .hoverTooltip("Cancel plan generation")
            }

        case .ready:
            // Regenerate button
            Button(action: generatePlan) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.callout)
                    Text("Regenerate")
                        .font(.callout)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
            }
            .buttonStyle(CustomButtonStyle(
                verticalPadding: 6,
                horizontalPadding: 12,
                height: 28
            ))
            .hoverTooltip("Regenerate \(selectedFollowUpType.buttonLabel.lowercased()) using \(planModelName)")

        case .idle, .error:
            // Generate button with dynamic type
            Button(action: generatePlan) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.callout)
                    Text("Generate \(selectedFollowUpType.buttonLabel)")
                        .font(.callout)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
            }
            .buttonStyle(CustomButtonStyle(
                verticalPadding: 6,
                horizontalPadding: 12,
                height: 28
            ))
            .disabled(!canGeneratePlan)
            .hoverTooltip(generatePlanDisabledReason ?? "Generate \(selectedFollowUpType.buttonLabel.lowercased()) using \(planModelName)")
        }
    }

    /// Second line actions when plan is ready
    @ViewBuilder
    private func planReadyActions(
        route: ContextBuilderGeneratedAnswerRoute,
        previewText: String?
    ) -> some View {
        let fullResponseText = viewModel.generatedPlanResponseText(for: subjectTabID)
        HStack(spacing: 8) {
            // Use as Prompt - primary action
            Button(action: useAsPrompt) {
                HStack(spacing: 4) {
                    Image(systemName: "text.badge.plus")
                        .font(.callout)
                    Text("Use as Prompt")
                        .font(.callout)
                }
            }
            .buttonStyle(CustomButtonStyle(
                verticalPadding: 6,
                horizontalPadding: 12,
                height: 28
            ))
            .disabled(previewText == nil)
            .hoverTooltip(ContextBuilderGeneratedAnswerActionText.useAsPromptTooltip)

            if let text = previewText {
                Button(action: copyGeneratedPlanToClipboard) {
                    HStack(spacing: 4) {
                        Image(systemName: showPlanCopied ? "checkmark" : "doc.on.doc")
                            .font(.callout)
                        Text(showPlanCopied ? "Copied!" : "Copy")
                            .font(.callout)
                    }
                }
                .buttonStyle(CustomButtonStyle(
                    verticalPadding: 6,
                    horizontalPadding: 12,
                    height: 28
                ))
                .disabled(fullResponseText == nil)
                .hoverTooltip(ContextBuilderGeneratedAnswerActionText.copyTooltip)

                // Preview
                Button(action: { showingPlanPreview.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.callout)
                        Text("Preview")
                            .font(.callout)
                    }
                }
                .buttonStyle(CustomButtonStyle(
                    verticalPadding: 6,
                    horizontalPadding: 12,
                    height: 28
                ))
                .hoverTooltip(ContextBuilderGeneratedAnswerActionText.previewTooltip)
                .popover(isPresented: $showingPlanPreview) {
                    planPreviewPopover(overrideText: text)
                }
            }

            Spacer()

            // View in Chat
            Button(action: { viewGeneratedPlan(route: route) }) {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.callout)
                    Text("View in Chat")
                        .font(.callout)
                }
            }
            .buttonStyle(CustomButtonStyle(
                verticalPadding: 6,
                horizontalPadding: 12,
                height: 28
            ))
            .hoverTooltip(ContextBuilderGeneratedAnswerActionText.viewInChatTooltip)
        }
    }

    @State private var isReasoningExpanded = true
    /// Tracks whether user has manually toggled reasoning expansion
    @State private var userToggledReasoning = false
    @State private var showPlanCopied = false

    @ViewBuilder
    private func planPreviewPopover(overrideText: String? = nil, overrideReasoning: String? = nil) -> some View {
        let responsePreviewText = overrideText ?? viewModel.backgroundPlanResponsePreviewText
        let reasoningPreviewText = overrideReasoning ?? viewModel.backgroundPlanReasoningPreviewText
        let hasReasoning = !(reasoningPreviewText ?? "").isEmpty
        let hasResponse = !(responsePreviewText ?? "").isEmpty

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(viewModel.isBackgroundPlanGenerating ? "\(currentFollowUpLabel.capitalized) (generating...)" : "\(currentFollowUpLabel.capitalized) Preview")
                    .font(.headline)
                Spacer()
                if viewModel.isBackgroundPlanGenerating {
                    ProgressView()
                        .scaleEffect(0.6)
                } else if viewModel.generatedPlanResponseText(for: subjectTabID) != nil {
                    Button(action: copyGeneratedPlanToClipboard) {
                        HStack(spacing: 4) {
                            Image(systemName: showPlanCopied ? "checkmark" : "doc.on.doc")
                                .font(.callout)
                            Text(showPlanCopied ? "Copied!" : "Copy")
                                .font(.callout)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Reasoning section (shown at top when available)
                    if let reasoning = reasoningPreviewText, !reasoning.isEmpty {
                        reasoningSection(text: reasoning)
                    }

                    // Main response text
                    if let text = responsePreviewText, !text.isEmpty {
                        Text(text)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if viewModel.isBackgroundPlanGenerating {
                        // Show placeholder while waiting for response
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text(reasoningPreviewText != nil ? "Thinking..." : "Starting...")
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .frame(maxHeight: 400)
        }
        .padding()
        .frame(width: 500, height: 450)
        // Auto-expand/collapse reasoning based on content (unless user manually toggled)
        .onChange(of: hasResponse) { _, hasResponseNow in
            guard !userToggledReasoning else { return }
            if hasResponseNow, hasReasoning {
                // Main response started - auto-collapse reasoning
                withAnimation(.easeInOut(duration: 0.2)) {
                    isReasoningExpanded = false
                }
            }
        }
        .onChange(of: hasReasoning) { _, hasReasoningNow in
            guard !userToggledReasoning else { return }
            if hasReasoningNow, !hasResponse {
                // Only reasoning available - auto-expand
                withAnimation(.easeInOut(duration: 0.2)) {
                    isReasoningExpanded = true
                }
            }
        }
        // Reset user toggle flag when popover reopens with fresh content
        .onAppear {
            userToggledReasoning = false
            // Set initial state based on current content
            isReasoningExpanded = hasReasoning && !hasResponse
        }
    }

    private func reasoningSection(text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Collapsible header
            Button(action: {
                userToggledReasoning = true
                withAnimation(.easeInOut(duration: 0.2)) {
                    isReasoningExpanded.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: isReasoningExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Image(systemName: "brain")
                        .font(.callout)
                        .foregroundColor(.purple)
                    Text("Reasoning")
                        .font(.callout)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    if viewModel.isBackgroundPlanGenerating, (viewModel.backgroundPlanResponsePreviewText ?? "").isEmpty {
                        ProgressView()
                            .scaleEffect(0.5)
                    }
                    Spacer()
                    Text("\(text.count) chars")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            // Reasoning content
            if isReasoningExpanded {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.purple.opacity(0.05))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.purple.opacity(0.2), lineWidth: 1)
                    )
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Follow-up Analysis

    /// Generate a plan/review/answer from built context based on selected follow-up type.
    /// Always uses headless generation so we can offer "View in Chat" or "Use as Prompt" options.
    private func generatePlan() {
        guard let tabID = viewModel.currentTabID else { return }
        guard viewModel.effectivePrompt(for: tabID) != nil else { return }

        let mode = selectedFollowUpType.headlessMode
        let chatName = selectedFollowUpType.buttonLabel

        viewModel.startBackgroundPlanGeneration(
            tabID: tabID,
            oracleViewModel: oracleViewModel,
            chatName: chatName,
            mode: mode
        )
    }

    /// Open the generated answer's Oracle chat session.
    private func viewGeneratedPlan(route: ContextBuilderGeneratedAnswerRoute) {
        openGeneratedAnswerChat(route)
    }

    /// Use the generated answer text as the prompt
    private func useAsPrompt() {
        viewModel.useGeneratedPlanAsPrompt()
    }

    private func copyGeneratedPlanToClipboard() {
        guard let text = viewModel.generatedPlanResponseText(for: subjectTabID) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showPlanCopied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            await MainActor.run {
                showPlanCopied = false
            }
        }
    }

    private var headerSection: some View {
        HStack(spacing: 8) {
            // Nested Agent/Model menu picker
            StableMenuButton(
                items: contextBuilderAgentModelMenuItems,
                triggerStyle: .borderless
            ) {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    AgentModelSelectionSummaryLabel(
                        agentKind: viewModel.selectedAgent,
                        rawModel: viewModel.selectedModelRaw,
                        title: "\(viewModel.selectedAgent.displayName) · \(viewModel.selectedModelDisplayName)",
                        iconFont: .caption
                    )
                    .font(.callout)
                }
            }
            .disabled(isContextBuilderRunningForTab)
            .hoverTooltip("Select agent and model for Context Builder")

            if let providerID = viewModel.selectedAgent.acpProviderID {
                let expectedModelRaw = viewModel.selectedModelRaw
                let expectedScope = viewModel.contextBuilderEditingScope
                ACPModelParameterProbeView(
                    modelRaw: expectedModelRaw,
                    providerID: providerID,
                    probeContext: .resolved(viewModel.chooserProbeWorkspacePath),
                    pinnedValueRaw: viewModel.contextBuilderThinkingParameterValueRaw,
                    isEnabled: !isContextBuilderRunningForTab
                ) { configID, value in
                    // Guarded write: re-check the live run permission, then re-check the
                    // captured provider/model against live state inside the setter.
                    guard !isContextBuilderRunningForTab else { return }
                    viewModel.setContextBuilderModelParameter(
                        ACPModelParameterSelection.thinkingPin(
                            configID: configID,
                            valueRaw: value,
                            providerID: providerID,
                            modelRaw: expectedModelRaw
                        ),
                        expectedProviderID: providerID,
                        expectedModelRaw: expectedModelRaw,
                        expectedScope: expectedScope
                    )
                }
            }

            // Context Builder Prompts button
            ContextBuilderPromptsButton(
                selectedPromptIDs: $viewModel.selectedContextBuilderPromptIDs,
                showOverlay: $showPromptsOverlay,
                storage: promptStorage
            )
            .disabled(isContextBuilderRunningForTab)
            .hoverTooltip("Prompts to include for this Context Builder run")

            Spacer()
        }
        .sheet(isPresented: $showPromptsOverlay) {
            ContextBuilderPromptsOverlay(
                isVisible: $showPromptsOverlay,
                selectedPromptIDs: $viewModel.selectedContextBuilderPromptIDs,
                storage: promptStorage
            )
        }
    }

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header bar with Build Context label, settings, and run button
            ContextBuilderHeaderBar(
                contextBuilderInstructions: $viewModel.contextBuilderInstructions,
                modelContextWindowTokens: selectedModelContextWindowTokens,
                contextTokenBudget: Binding(
                    get: { viewModel.contextTokenBudget },
                    set: { viewModel.contextTokenBudget = $0 }
                ),
                enhancementMode: Binding(
                    get: { viewModel.enhancementMode },
                    set: { viewModel.enhancementMode = $0 }
                ),
                allowUIClarifyingQuestions: Binding(
                    get: { viewModel.allowUIClarifyingQuestions },
                    set: { viewModel.allowUIClarifyingQuestions = $0 }
                ),
                allowMCPClarifyingQuestions: Binding(
                    get: { viewModel.allowMCPClarifyingQuestions },
                    set: { viewModel.allowMCPClarifyingQuestions = $0 }
                ),
                questionTimeoutSeconds: Binding(
                    get: { viewModel.questionTimeoutSeconds },
                    set: { viewModel.questionTimeoutSeconds = $0 }
                ),
                analysisTokenBudget: Binding(
                    get: { ContextBuilderDefaults.normalizedAnalysisTokenBudget(viewModel.analysisTokenBudget) },
                    set: { viewModel.analysisTokenBudget = $0 }
                ),
                followUpAnalysisEnabled: Binding(
                    get: { viewModel.followUpAnalysisEnabled },
                    set: { viewModel.followUpAnalysisEnabled = $0 }
                ),
                presentation: behaviorPresentation,
                resetBehaviorSettings: viewModel.resetContextBuilderBehaviorSettings,
                isRunning: isContextBuilderRunningForTab,
                isDisabled: !isContextBuilderRunningForTab && viewModel.isAgentBusy,
                isBusy: viewModel.isAgentBusy,
                isCancelling: viewModel.isCancelling,
                isMCPControlled: viewModel.isMCPControlledRun,
                runAction: runOrCancelAction
            )

            // Text editor
            ContextBuilderInstructionsEditor(
                text: $viewModel.contextBuilderInstructions,
                windowID: windowID,
                presentation: behaviorPresentation,
                allowNonContiguousLayout: viewModel.agentRunState.isRunning
            )
        }
    }

    private var currentRunSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Log entries (fixed list of up to 5 items - no scrolling needed)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(viewModel.agentLog) { entry in
                    AgentLogEntryRowView(entry: entry, style: .compact)
                }
            }
            .padding(10)

            // Tool call indicator
            if viewModel.toolCallCount > 0 {
                Divider()
                HStack {
                    Image(systemName: "gearshape")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(viewModel.toolCallCount) tool call\(viewModel.toolCallCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    // Agent indicator on the right
                    HStack(spacing: 4) {
                        if viewModel.isMCPControlledRun {
                            Image(systemName: "server.rack")
                                .font(.caption2)
                                .foregroundColor(.green)
                        }
                        let runAgent = viewModel.runAgentKind ?? viewModel.selectedAgent
                        AgentModelSelectionSummaryLabel(
                            agentKind: runAgent,
                            rawModel: viewModel.runModelRaw ?? viewModel.selectedModelRaw,
                            title: "\(runAgent.displayName) · \(viewModel.runModelDisplayName)",
                            iconFont: .caption2
                        )
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(6)
    }

    private func runOrCancelAction() {
        if isContextBuilderRunningForTab {
            guard viewModel.beginCancellation() else { return }
            Task {
                await viewModel.cancelAgentRun()
            }
        } else {
            viewModel.runContextBuilderAgent()
        }
    }

    private func contextBuilderAgentModelMenuItems() -> [StableMenuItem] {
        var items = viewModel.availableAgents.map { agent in
            if agent == .cursor {
                return StableMenuItem.submenu(agent.displayName, items: viewModel.cursorModelMenuItems())
            }
            return AgentModelStableMenuItems.agentSubmenu(
                agentKind: agent,
                options: viewModel.modelOptions(for: agent),
                selectedAgent: viewModel.selectedAgent,
                selectedModelRaw: viewModel.selectedModelRaw
            ) { selectedAgent, selectedOption in
                viewModel.selectedAgent = selectedAgent
                viewModel.selectModel(rawModel: selectedOption.rawValue)
            }
        }
        AgentProviderSettingsMenuAction.appendStableMenuItem(
            to: &items,
            windowID: windowID,
            availableAgents: viewModel.availableAgents
        )
        return items
    }
}

// MARK: - Reusable Components

private struct ContextBuilderInstructionsEditor: View {
    @Binding var text: String
    let windowID: Int
    let presentation: ContextBuilderBehaviorPresentation
    /// When true, enables non-contiguous layout to avoid expensive full-layout on click
    let allowNonContiguousLayout: Bool

    // Local state for TextKitView bidirectional sync (mirrors InstructionsView pattern)
    @State private var localText: String = ""
    @State private var isEditing: Bool = false
    /// Suppresses echo when writing back to the binding
    @State private var isWritingBack: Bool = false
    @State private var externalUpdateTick: Int = 0
    @State private var writeBackDebounceItem: DispatchWorkItem? = nil
    @State private var writeBackWorkGate = WorkItemGate()

    private var enhancementMode: PromptEnhancementMode? {
        presentation.enhancementMode
    }

    private var editorMinHeight: CGFloat {
        enhancementMode == .fullRewrite ? 120 : 100
    }

    private var editorMaxHeight: CGFloat {
        enhancementMode == .fullRewrite ? 400 : 300
    }

    var body: some View {
        TextKitView(
            text: $localText,
            isEditable: true,
            isSpellCheckEnabled: false,
            fontSize: 13,
            useMonospacedFont: false,
            wrapLines: true,
            externalUpdateTick: externalUpdateTick,
            allowNonContiguousLayout: allowNonContiguousLayout,
            onEditingChanged: { editing in
                isEditing = editing
                if !editing {
                    // Flush any pending debounced writes immediately when editing ends
                    writeBackDebounceItem?.cancel()
                    writeBackWorkGate.cancel()
                    if text != localText {
                        isWritingBack = true
                        text = localText
                        isWritingBack = false
                    }
                }
            }
        )
        .frame(minHeight: editorMinHeight, maxHeight: editorMaxHeight)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(enhancementMode == .fullRewrite ? Color.accentColor.opacity(0.3) : Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.1), lineWidth: enhancementMode == .fullRewrite ? 1 : 0.5)
        )
        .overlay(
            Group {
                if localText.isEmpty {
                    Text(presentation.instructionsPlaceholder)
                        .font(.callout)
                        .foregroundColor(.secondary.opacity(0.5))
                }
            }
            .allowsHitTesting(false)
            // Match TextKitView's textContainerInset (8pt) plus a small visual offset
            .padding(.leading, 12)
            .padding(.top, 10),
            alignment: .topLeading
        )
        // Sync hooks - mirrors InstructionsView pattern
        .onAppear {
            localText = text
            // Bump tick to ensure TextKitView syncs on appear
            externalUpdateTick &+= 1
        }
        .onChange(of: text) { _, newValue in
            // Accept external source-of-truth updates unless they originated from our writeback
            if isWritingBack {
                isWritingBack = false
                return
            }
            if newValue != localText {
                localText = newValue
                externalUpdateTick &+= 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeComposeTabChanged)) { notification in
            // Force sync when tab changes - guards against race conditions where
            // onChange(of: text) fires before the binding is fully updated
            guard let notificationWindowID = notification.userInfo?["windowID"] as? Int,
                  notificationWindowID == windowID
            else {
                return
            }
            // Schedule sync on next run loop to ensure binding has updated
            DispatchQueue.main.async {
                if text != localText {
                    localText = text
                    externalUpdateTick &+= 1
                }
            }
        }
        .onChange(of: localText) { _, value in
            writeBackDebounceItem?.cancel()
            writeBackWorkGate.cancel()
            // If not actively editing, write through immediately
            guard isEditing else {
                if text != value {
                    isWritingBack = true
                    text = value
                    isWritingBack = false
                }
                return
            }
            // While editing, debounce writes to reduce churn
            writeBackDebounceItem = writeBackWorkGate.schedule(after: 0.5) { [value] in
                if text != value {
                    isWritingBack = true
                    text = value
                    isWritingBack = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .willSwitchComposeTab)) { notification in
            // Only respond to notifications for this window
            guard let notificationWindowID = notification.userInfo?["windowID"] as? Int,
                  notificationWindowID == windowID
            else {
                return
            }

            // Only flush if there's actually a pending user edit (debounce was active).
            // If writeBackDebounceItem is nil, localText should already be synced from the binding,
            // OR it's stale because SwiftUI's onChange hasn't fired yet after a workspace switch.
            // Flushing stale localText would overwrite the correct value loaded from the new workspace.
            guard let pendingWrite = writeBackDebounceItem else { return }
            pendingWrite.cancel()
            writeBackDebounceItem = nil
            writeBackWorkGate.cancel()
            if text != localText {
                isWritingBack = true
                text = localText
                isWritingBack = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .workspaceWillSave)) { notification in
            // Only respond to notifications for this window
            guard let notificationWindowID = notification.userInfo?["windowID"] as? Int,
                  notificationWindowID == windowID
            else {
                return
            }

            // Only flush if there's actually a pending user edit (debounce was active).
            // If writeBackDebounceItem is nil, localText should already be synced from the binding,
            // OR it's stale because SwiftUI's onChange hasn't fired yet after a workspace switch.
            // Flushing stale localText would overwrite the correct value loaded from the new workspace.
            guard let pendingWrite = writeBackDebounceItem else { return }
            pendingWrite.cancel()
            writeBackDebounceItem = nil
            writeBackWorkGate.cancel()
            if text != localText {
                isWritingBack = true
                text = localText
                isWritingBack = false
            }
        }
        .onDisappear {
            // Flush any pending writes when view disappears
            writeBackDebounceItem?.cancel()
            writeBackWorkGate.cancel()
            if text != localText {
                isWritingBack = true
                text = localText
                isWritingBack = false
            }
        }
    }
}

/// Header bar above the text editor with Build Context label, token budget, settings, and run button
private struct ContextBuilderHeaderBar: View {
    @Binding var contextBuilderInstructions: String
    let modelContextWindowTokens: Int
    @Binding var contextTokenBudget: Int
    @Binding var enhancementMode: PromptEnhancementMode
    @Binding var allowUIClarifyingQuestions: Bool
    @Binding var allowMCPClarifyingQuestions: Bool
    @Binding var questionTimeoutSeconds: TimeInterval
    @Binding var analysisTokenBudget: Int
    @Binding var followUpAnalysisEnabled: Bool
    /// Read-only authority for every behavioral readout in the header. The bindings above
    /// remain the desired next-run editor for the settings popover only.
    let presentation: ContextBuilderBehaviorPresentation
    let resetBehaviorSettings: () -> Void
    let isRunning: Bool
    let isDisabled: Bool
    let isBusy: Bool
    let isCancelling: Bool
    let isMCPControlled: Bool
    let runAction: () -> Void

    @State private var showingSettingsPopover = false
    @State private var isSettingsHovered = false

    private var settingsTooltip: String {
        var lines = presentation.summaryLines
        // MCP control metadata can outlive discovery; only an active presentation is a run.
        if isMCPControlled, presentation.isActive {
            lines.append("")
            lines.append("MCP-controlled run active")
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        HStack(spacing: 8) {
            // Left side: Label and info
            HStack(spacing: 6) {
                Text(presentation.headerTitle)
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .hoverTooltip(presentation.headerTooltip)

                // Clear button
                Button(action: {
                    contextBuilderInstructions = ""
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(contextBuilderInstructions.isEmpty ? .gray.opacity(0.5) : .secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(contextBuilderInstructions.isEmpty)
                .hoverTooltip("Clear")
            }

            Spacer(minLength: 4)

            // Right side: Settings button (token count + icons) and Run button
            HStack(spacing: 8) {
                // Settings button - opens popover
                Button(action: { showingSettingsPopover.toggle() }) {
                    HStack(spacing: 5) {
                        // Token budget label and count
                        Text("Budget")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.head)
                        Text(presentation.tokenBudgetLabel)
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundColor(.secondary)

                        // Separator dot
                        Text("·")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.6))

                        // Question mark indicator: effective permission for the current run,
                        // or the desired UI permission when idle. Dashed when unavailable.
                        Image(systemName: presentation.questionIndicatorSymbolName)
                            .font(.callout)
                            .foregroundColor(presentation.allowsClarifyingQuestions == true ? .blue : .secondary.opacity(0.5))

                        // Gear icon
                        Image(systemName: "gearshape.fill")
                            .font(.callout)
                            .foregroundColor(.secondary)

                        // MCP indicator when active
                        if isMCPControlled {
                            Text("·")
                                .font(.caption)
                                .foregroundColor(.secondary.opacity(0.6))
                            Image(systemName: "server.rack")
                                .font(.callout)
                                .foregroundColor(.green)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(NSColor.controlBackgroundColor).opacity(isSettingsHovered ? 0.8 : 0.5))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(isSettingsHovered ? 0.15 : 0.05), lineWidth: 1)
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isSettingsHovered = hovering
                    }
                }
                .disabled(isRunning)
                .hoverTooltip(settingsTooltip)
                .onChange(of: isRunning) { _, running in
                    // The popover edits desired next-run settings only. Dismiss it when the
                    // displayed tab enters active discovery (new admission or switching to a
                    // tab whose run is already active) so it cannot be mistaken for the run.
                    if running {
                        showingSettingsPopover = false
                    }
                }
                .popover(isPresented: $showingSettingsPopover) {
                    ContextBuilderSettingsPopover(
                        modelContextWindowTokens: modelContextWindowTokens,
                        contextTokenBudget: $contextTokenBudget,
                        enhancementMode: $enhancementMode,
                        allowUIClarifyingQuestions: $allowUIClarifyingQuestions,
                        allowMCPClarifyingQuestions: $allowMCPClarifyingQuestions,
                        questionTimeoutSeconds: $questionTimeoutSeconds,
                        analysisTokenBudget: $analysisTokenBudget,
                        followUpAnalysisEnabled: $followUpAnalysisEnabled,
                        resetBehaviorSettings: resetBehaviorSettings,
                        isDisabled: isRunning
                    )
                }

                // Run/Cancel button
                CompactRunButton(
                    isRunning: isRunning,
                    isDisabled: isDisabled,
                    isBusy: isBusy,
                    isCancelling: isCancelling,
                    action: runAction
                )
                .fixedSize()
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }
}

/// Compact run/cancel button for the header bar
private struct CompactRunButton: View {
    let isRunning: Bool
    let isDisabled: Bool
    let isBusy: Bool
    let isCancelling: Bool
    let action: () -> Void

    private var label: String {
        if isCancelling {
            "Cancelling..."
        } else if isRunning {
            "Cancel"
        } else if isBusy {
            "..."
        } else {
            "Run"
        }
    }

    private var icon: String {
        if isCancelling {
            "hourglass"
        } else if isRunning {
            "stop.fill"
        } else if isBusy {
            "hourglass"
        } else {
            "play.fill"
        }
    }

    private var tooltipText: String {
        if isCancelling {
            "Cancellation in progress..."
        } else if isRunning {
            "Cancel Context Builder run"
        } else if isBusy {
            "Context Builder is cleaning up"
        } else {
            "Run Context Builder (Cmd + Return)"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(label)
                    .font(.callout)
                    .fontWeight(.medium)
            }
        }
        .buttonStyle(CustomButtonStyle(
            verticalPadding: 5,
            horizontalPadding: 12,
            height: 26
        ))
        .disabled((isDisabled && !isRunning) || isCancelling)
        .hoverTooltip(tooltipText)
    }
}

/// Settings popover content extracted from TokenBudgetControl
private struct ContextBuilderSettingsPopover: View {
    let modelContextWindowTokens: Int
    @Binding var contextTokenBudget: Int
    @Binding var enhancementMode: PromptEnhancementMode
    @Binding var allowUIClarifyingQuestions: Bool
    @Binding var allowMCPClarifyingQuestions: Bool
    @Binding var questionTimeoutSeconds: TimeInterval
    @Binding var analysisTokenBudget: Int
    @Binding var followUpAnalysisEnabled: Bool
    let resetBehaviorSettings: () -> Void
    let isDisabled: Bool

    @State private var showAnalysisBudget = false

    private var modeDescription: String {
        switch enhancementMode {
        case .fullRewrite:
            "Agent writes a new prompt based on what it learns while building context."
        case .augment:
            "Keeps your original instructions and appends relevant context."
        case .preserve:
            "Leaves your instructions unchanged. Only updates the file selection."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Context Builder Settings")
                    .font(.headline)
                Spacer()
                Button(action: resetBehaviorSettings) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset")
                    }
                    .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .disabled(isDisabled)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Token Budgets Section
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Token Budgets")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Text("Sets the target size of the context package. The slider max follows the selected model's context window; switching models does not change the saved budget.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        SettingsBudgetSliderRow(
                            label: "Target size",
                            value: $contextTokenBudget,
                            range: ContextBuilderDefaults.contextSliderRange(
                                modelContextWindowTokens: modelContextWindowTokens
                            ),
                            isDisabled: isDisabled
                        )

                        // Collapsible Post-Discovery Analysis budget section
                        Button(action: { withAnimation { showAnalysisBudget.toggle() } }) {
                            HStack(spacing: 6) {
                                Image(systemName: showAnalysisBudget ? "chevron.down" : "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(width: 12)
                                Image(systemName: "bolt.fill")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                Text("Analysis Budget")
                                    .font(.callout)
                                    .foregroundColor(.primary)
                                Spacer()
                                Text("\(analysisTokenBudget / 1000)k")
                                    .font(.callout)
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if showAnalysisBudget {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Sets the target size of the context package when Context Builder will immediately produce a plan, review, or answer.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)

                                SettingsBudgetSliderRow(
                                    label: "Target size",
                                    value: $analysisTokenBudget,
                                    range: ContextBuilderDefaults.analysisSliderRange(
                                        modelContextWindowTokens: modelContextWindowTokens
                                    ),
                                    isDisabled: isDisabled
                                )
                            }
                            .padding(.leading, 18)
                            .padding(.top, 8)
                        }
                    }

                    Divider()

                    // Prompt Mode Section
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Prompt Enhancement")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Text("How the agent modifies your instructions while building context.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Picker("", selection: $enhancementMode) {
                            Text("Rewrite").tag(PromptEnhancementMode.fullRewrite)
                            Text("Augment").tag(PromptEnhancementMode.augment)
                            Text("Preserve").tag(PromptEnhancementMode.preserve)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(isDisabled)

                        Text(modeDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    SettingsToggleRow(
                        icon: "bolt.fill",
                        iconColor: .orange,
                        label: "Follow-up Analysis",
                        description: "Automatically run this tab’s selected analysis after Context Builder",
                        isOn: $followUpAnalysisEnabled,
                        isDisabled: isDisabled
                    )

                    Divider()

                    // Clarifying Questions Section
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Clarifying Questions")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Text("Allow the agent to ask you questions while building context to better understand your intent.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(spacing: 8) {
                            SettingsToggleRow(
                                icon: "questionmark.bubble.fill",
                                iconColor: .blue,
                                label: "Manual Runs (UI)",
                                description: "When you click Run Context Builder",
                                isOn: $allowUIClarifyingQuestions,
                                isDisabled: isDisabled
                            )

                            SettingsToggleRow(
                                icon: "server.rack",
                                iconColor: .green,
                                label: "MCP Runs",
                                description: "When called via context_builder",
                                isOn: $allowMCPClarifyingQuestions,
                                isDisabled: isDisabled
                            )
                        }

                        if allowUIClarifyingQuestions || allowMCPClarifyingQuestions {
                            HStack(spacing: 8) {
                                Text("Timeout")
                                    .font(.callout)
                                    .foregroundColor(.secondary)
                                Picker("", selection: $questionTimeoutSeconds) {
                                    Text("30 sec").tag(TimeInterval(30))
                                    Text("1 min").tag(TimeInterval(60))
                                    Text("2 min").tag(TimeInterval(120))
                                    Text("5 min").tag(TimeInterval(300))
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .disabled(isDisabled)
                            }
                            .padding(8)
                            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                            .cornerRadius(6)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .frame(width: 360)
    }
}

/// Budget slider row for settings popover
private struct SettingsBudgetSliderRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Double>
    let isDisabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(width: 110, alignment: .leading)

            Slider(
                value: Binding(
                    get: { min(max(Double(value), range.lowerBound), range.upperBound) },
                    set: { value = Int($0) }
                ),
                in: range,
                step: 5000
            )
            .disabled(isDisabled)

            Text("\(value / 1000)k")
                .font(.callout)
                .foregroundColor(.primary)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }
}

/// Toggle row for Context Builder settings
private struct SettingsToggleRow: View {
    let icon: String
    let iconColor: Color
    let label: String
    let description: String
    @Binding var isOn: Bool
    let isDisabled: Bool

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundColor(iconColor)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.callout)
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(isDisabled)
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }
}

private extension View {
    @ViewBuilder
    func contextBuilderKeyboardShortcut(enabled: Bool) -> some View {
        if enabled {
            keyboardShortcut(.return, modifiers: .command)
        } else {
            self
        }
    }
}
