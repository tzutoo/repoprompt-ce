import Foundation

/// MCP initialize `name` presented by pi's built-in MCP client (`runtime.js`:
/// `new McpClient({ name: "pi", ... })`). Expected-PID routing and always-allow
/// must match this exact name. This is not the adapter's `pi-mcp-<server>` form.
public enum PiBuiltinMCPClientIdentity {
    public static let clientName = "pi"
}

/// How built-in MCP tools reach the model. `direct` declares them like built-ins
/// so the first prompt waits up to 10s for the server — required for RPCE's
/// pre-prompt routing gate.
public enum PiBuiltinMCPExposure: String, Sendable {
    case codemode
    case deferred
    case direct
    case hidden
}

/// One RepoPrompt server registration for a managed pi launch. Field names follow
/// pi 1.1.0 `mcp.json` / `pi.registerMcpServer()` (`command`, `args`, `env`,
/// `timeout` in seconds, `exposure`). RPCE never writes `~/.pi/agent/mcp.json`.
public struct PiBuiltinMCPServerConfiguration: Equatable, Sendable {
    public let command: String
    public let arguments: [String]
    public let environment: [String: String]
    public let timeoutSeconds: Int?
    public let exposure: PiBuiltinMCPExposure
    public let description: String?

    public init(
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        timeoutSeconds: Int? = nil,
        exposure: PiBuiltinMCPExposure = .direct,
        description: String? = nil
    ) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.timeoutSeconds = timeoutSeconds
        self.exposure = exposure
        self.description = description
    }

    public var jsonValue: PiJSONValue {
        var object: [String: PiJSONValue] = [
            "command": .string(command),
            "exposure": .string(exposure.rawValue)
        ]
        if !arguments.isEmpty {
            object["args"] = .array(arguments.map(PiJSONValue.string))
        }
        if !environment.isEmpty {
            object["env"] = .object(environment.mapValues(PiJSONValue.string))
        }
        if let timeoutSeconds {
            object["timeout"] = .integer(timeoutSeconds)
        }
        if let description, !description.isEmpty {
            object["description"] = .string(description)
        }
        return .object(object)
    }
}

/// Generates a one-file TypeScript extension that calls `pi.registerMcpServer`
/// at load. Combined with `--no-extensions -e builtin:mcp -e <this file>`, the
/// built-in MCP client connects the RepoPrompt server for that process only.
public enum PiBuiltinMCPInjector {
    public static func extensionSource(
        serverName: String,
        configuration: PiBuiltinMCPServerConfiguration
    ) throws -> String {
        let configJSON = try configuration.jsonValue.encodedJSONString()
        let escapedName = serverName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        export default function (pi) {
          pi.registerMcpServer("\(escapedName)", \(configJSON));
        }
        """
    }
}
