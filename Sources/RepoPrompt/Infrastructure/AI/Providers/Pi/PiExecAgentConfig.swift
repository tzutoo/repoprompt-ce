import Foundation

/// Configuration for headless pi discovery / Context Builder runs.
struct PiExecAgentConfig {
    let modelString: String?
    let enableDebugLogging: Bool
    let workspacePath: String?
    let pinnedAdapterVersion: String
    let toolProfile: PiProviderRuntimeBridge.ToolProfile

    init(
        modelString: String? = nil,
        enableDebugLogging: Bool = false,
        workspacePath: String? = nil,
        pinnedAdapterVersion: String = "2.32.1",
        toolProfile: PiProviderRuntimeBridge.ToolProfile = .mcpOnly
    ) {
        self.modelString = modelString
        self.enableDebugLogging = enableDebugLogging
        self.workspacePath = workspacePath
        self.pinnedAdapterVersion = pinnedAdapterVersion
        self.toolProfile = toolProfile
    }
}
