import Foundation

enum PiAgentToolPreferences {
    /// pi core has no permission prompts, so RPCE shapes the tool surface at
    /// launch instead. `mcpOnly` keeps pi's built-in tools disabled while the
    /// RepoPrompt MCP tools (via pi-mcp-adapter) stay enabled — RPCE's
    /// server-side policies remain the single permission authority.
    /// `readOnly` allows pi's read-only built-ins, and `fullAccess` enables
    /// pi's full built-in tool set (`read`, `bash`, `edit`, `write`).
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
                "pi launches with its full built-in tool set, so pi's own shell and edit tools run without per-request confirmation. Applies to newly launched pi processes."
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
    }

    static func permissionLevel() -> PermissionLevel {
        PermissionLevel(rawValue: UserDefaults.standard.string(forKey: "PiAgentPermissionLevel") ?? "") ?? .mcpOnly
    }

    static func setPermissionLevel(_ level: PermissionLevel) {
        UserDefaults.standard.set(level.rawValue, forKey: "PiAgentPermissionLevel")
    }
}
