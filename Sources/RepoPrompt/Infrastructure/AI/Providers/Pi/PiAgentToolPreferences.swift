import Foundation

enum PiAgentToolPreferences {
    /// pi core has no permission prompts, so RPCE shapes the tool surface at
    /// launch instead. `mcpOnly` keeps pi's built-in tools disabled while the
    /// RepoPrompt MCP tools (via built-in MCP) stay enabled — RPCE's
    /// server-side policies remain the single permission authority.
    /// `readOnly` allows pi's read-only built-ins, and `fullAccess` enables
    /// pi's full built-in tool set (`read`, `bash`, `edit`, `write`) without
    /// per-call approval cards. Interactive runs still load the confirm gate
    /// for `mcpOnly`/`readOnly` so an unexpected built-in mutation is blocked.
    enum PermissionLevel: String, CaseIterable {
        case mcpOnly
        case readOnly
        case fullAccess

        var displayName: String {
            switch self {
            case .mcpOnly:
                "MCP Only"
            case .readOnly:
                "Read Only"
            case .fullAccess:
                "Full Access"
            }
        }

        var detailText: String {
            switch self {
            case .mcpOnly:
                "pi launches with `--no-builtin-tools`, so the agent works exclusively through RepoPrompt MCP tools. RepoPrompt's server-side policies govern every call."
            case .readOnly:
                "pi launches with `--tools read,grep,find,ls`. RepoPrompt MCP tools remain available and governed server-side."
            case .fullAccess:
                "pi launches with its full built-in tool set. Bash, edit, and write run without per-call approval cards. Use only in trusted environments."
            }
        }

        var iconName: String {
            switch self {
            case .mcpOnly:
                "lock"
            case .readOnly:
                "shield"
            case .fullAccess:
                "exclamationmark.shield.fill"
            }
        }

        var isWarning: Bool {
            self == .fullAccess
        }

        var launchToolProfile: PiProviderRuntimeBridge.ToolProfile {
            switch self {
            case .mcpOnly:
                .mcpOnly
            case .readOnly:
                .readOnly
            case .fullAccess:
                .standard
            }
        }

        /// Full Access is the only level that skips the bash/edit/write confirm gate.
        var loadsInteractiveApprovalGate: Bool {
            self != .fullAccess
        }
    }

    private static let permissionLevelKey = "PiAgentPermissionLevel"

    static func permissionLevel(
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> PermissionLevel {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            let stored = secureStore.piPermissions().permissionLevel()
            if let legacy = PermissionLevel(rawValue: defaults.string(forKey: permissionLevelKey) ?? ""),
               stored == .mcpOnly,
               legacy != .mcpOnly,
               defaults.object(forKey: permissionLevelKey) != nil
            {
                secureStore.setPiPermissionLevel(legacy)
                return legacy
            }
            return stored
        }
        return PermissionLevel(rawValue: defaults.string(forKey: permissionLevelKey) ?? "") ?? .mcpOnly
    }

    static func setPermissionLevel(
        _ level: PermissionLevel,
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            secureStore.setPiPermissionLevel(level)
            return
        }
        defaults.set(level.rawValue, forKey: permissionLevelKey)
    }

    private static let lastUsedThinkingLevelKey = "piAgent.thinking.lastUsedLevel"
    private static let lastUsedThinkingLevelByModelSlugKey = "piAgent.thinking.lastUsedLevelByModelSlug"

    static func lastUsedThinkingEffort(defaults: UserDefaults = .standard) -> CodexReasoningEffort? {
        CodexReasoningEffort.parse(defaults.string(forKey: lastUsedThinkingLevelKey))
    }

    static func lastUsedThinkingEffort(
        forModelRaw modelRaw: String?,
        defaults: UserDefaults = .standard
    ) -> CodexReasoningEffort? {
        let slug = CodexAgentToolPreferences.reasoningEffortPreferenceSlug(forModelRaw: modelRaw)
        if let rawValue = rawLastUsedThinkingEffortsByModelSlug(defaults: defaults)[slug],
           let effort = CodexReasoningEffort.parse(rawValue)
        {
            return effort
        }
        return lastUsedThinkingEffort(defaults: defaults)
    }

    static func setLastUsedThinkingEffort(
        _ effort: CodexReasoningEffort?,
        forModelRaw modelRaw: String? = nil,
        defaults: UserDefaults = .standard
    ) {
        let slug = CodexAgentToolPreferences.reasoningEffortPreferenceSlug(forModelRaw: modelRaw)
        var stored = rawLastUsedThinkingEffortsByModelSlug(defaults: defaults)
        guard let effort else {
            stored.removeValue(forKey: slug)
            defaults.set(stored, forKey: lastUsedThinkingLevelByModelSlugKey)
            defaults.removeObject(forKey: lastUsedThinkingLevelKey)
            return
        }
        stored[slug] = effort.rawValue
        defaults.set(stored, forKey: lastUsedThinkingLevelByModelSlugKey)
        defaults.set(effort.rawValue, forKey: lastUsedThinkingLevelKey)
    }

    private static func rawLastUsedThinkingEffortsByModelSlug(defaults: UserDefaults) -> [String: String] {
        guard let dictionary = defaults.dictionary(forKey: lastUsedThinkingLevelByModelSlugKey) else { return [:] }
        return dictionary.reduce(into: [:]) { result, entry in
            if let value = entry.value as? String {
                result[entry.key] = value
            }
        }
    }

    private static func resolvedSecureStore(
        defaults: UserDefaults,
        secureStore: AgentPermissionSecureStore?
    ) -> AgentPermissionSecureStore? {
        if let secureStore {
            return secureStore
        }
        return defaults === UserDefaults.standard ? AgentPermissionSecureStore.shared : nil
    }
}
