import Foundation

/// Configuration for headless pi discovery / Context Builder runs.
struct PiExecAgentConfig {
    let modelString: String?
    let enableDebugLogging: Bool
    let workspacePath: String?
    let toolProfile: PiProviderRuntimeBridge.ToolProfile

    init(
        modelString: String? = nil,
        enableDebugLogging: Bool = false,
        workspacePath: String? = nil,
        toolProfile: PiProviderRuntimeBridge.ToolProfile = .mcpOnly
    ) {
        self.modelString = modelString
        self.enableDebugLogging = enableDebugLogging
        self.workspacePath = workspacePath
        self.toolProfile = toolProfile
    }
}
