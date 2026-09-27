import Foundation

/// The MCP client identity pi-mcp-adapter presents when it connects to a server:
/// `pi-mcp-<serverName>`. RepoPrompt's connection-policy admission and run-scoped
/// tab-context binding must match this exact name (same pattern as Grok's
/// `grok-shell-<name>`).
public enum PiMCPAdapterClientIdentity {
    public static func clientName(forServer serverName: String) -> String {
        "pi-mcp-\(serverName)"
    }
}

/// Lifecycle of a server entry in the ephemeral pi `--mcp-config` document.
public enum PiMCPServerLifecycle: String, Sendable {
    /// Default. Connect on first tool call. Too late for RPCE's pre-prompt routing gate.
    case lazy
    /// Connect at extension load — required so RepoPrompt MCP routing completes before
    /// the first prompt submission.
    case eager
    case keepAlive = "keep-alive"
    case lazyKeepAlive = "lazy-keep-alive"
}

/// How a server's tools are exposed to the model.
public enum PiMCPDirectTools: Equatable, Sendable {
    /// Single `mcp` proxy tool (~200 tokens); the model searches then calls.
    case proxy
    /// Register every tool from the server as an individual pi tool.
    case all
    /// Register only the listed tools (original MCP names).
    case included([String])
}

/// One server entry in the ephemeral `--mcp-config` document handed to a managed pi
/// launch. Field names follow pi-mcp-adapter's config schema; only the subset
/// RepoPrompt writes is modeled.
public struct PiMCPServerConfiguration: Equatable, Sendable {
    public let command: String
    public let arguments: [String]
    public let environment: [String: String]
    public let lifecycle: PiMCPServerLifecycle
    public let requestTimeoutMilliseconds: Int?
    public let directTools: PiMCPDirectTools
    public let approveTools: Bool

    public init(
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        lifecycle: PiMCPServerLifecycle = .eager,
        requestTimeoutMilliseconds: Int? = nil,
        directTools: PiMCPDirectTools = .all,
        approveTools: Bool = false
    ) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.lifecycle = lifecycle
        self.requestTimeoutMilliseconds = requestTimeoutMilliseconds
        self.directTools = directTools
        self.approveTools = approveTools
    }

    var jsonValue: PiJSONValue {
        var object: [String: PiJSONValue] = [
            "command": .string(command)
        ]
        if !arguments.isEmpty {
            object["args"] = .array(arguments.map(PiJSONValue.string))
        }
        if !environment.isEmpty {
            object["env"] = .object(environment.mapValues(PiJSONValue.string))
        }
        object["lifecycle"] = .string(lifecycle.rawValue)
        if let requestTimeoutMilliseconds {
            object["requestTimeoutMs"] = .integer(requestTimeoutMilliseconds)
        }
        switch directTools {
        case .proxy:
            break
        case .all:
            object["directTools"] = .bool(true)
        case let .included(names):
            object["directTools"] = .array(names.map(PiJSONValue.string))
        }
        // `approveTools` defaults to false in the adapter; RPCE enforces tool
        // permissions server-side, so only emit the key when opting in.
        if approveTools {
            object["approveTools"] = .bool(true)
        }
        return .object(object)
    }
}

/// The complete ephemeral `--mcp-config` document for a managed pi launch. The file
/// acts as the Pi user-global config layer and merges with the user's other MCP
/// config sources; RPCE never mutates `~/.config/mcp/mcp.json` or `~/.pi/agent/`.
public struct PiMCPAdapterConfigurationDocument: Equatable, Sendable {
    public let servers: [String: PiMCPServerConfiguration]

    public init(servers: [String: PiMCPServerConfiguration]) {
        self.servers = servers
    }

    public var jsonValue: PiJSONValue {
        .object([
            "mcpServers": .object(servers.mapValues(\.jsonValue))
        ])
    }

    /// Compact single-line JSON, suitable for a temporary file read once at launch.
    public func encodedDocument() throws -> Data {
        try JSONEncoder().encode(jsonValue)
    }
}
