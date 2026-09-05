import Foundation

/// pi run mode for a managed launch.
public enum PiLaunchMode: Equatable, Sendable {
    /// `--mode rpc`: interactive JSONL process control (Agent Mode).
    case rpc
    /// `--mode json`: one-shot JSON event stream (headless discovery/delegate runs).
    case jsonEventStream(initialPrompt: String?)
    /// `-p`: print the final response and exit.
    case print(initialPrompt: String?)
}

/// Provider/model selection. `modelPattern` accepts pi's `provider/id` and
/// `:thinking` shorthand in addition to plain IDs.
public struct PiModelSelection: Equatable, Sendable {
    public let provider: String?
    public let modelPattern: String
    public let thinkingLevel: String?

    public init(provider: String? = nil, modelPattern: String, thinkingLevel: String? = nil) {
        self.provider = provider
        self.modelPattern = modelPattern
        self.thinkingLevel = thinkingLevel
    }
}

/// Session handling for a managed launch.
public enum PiSessionSelection: Equatable, Sendable {
    /// `--no-session`: ephemeral, nothing persisted.
    case ephemeral
    /// Fresh persistent session in the default cwd-keyed storage.
    case persistent
    /// `--session <path|id>`: resume a specific session (id may be a partial UUID).
    case resume(String)
    /// `--session-dir <dir>`: pin storage to an RPCE-managed location.
    case directory(String)
}

/// Tool surface for a managed launch.
public enum PiToolProfile: Equatable, Sendable {
    /// pi's default built-in tool set.
    case standard
    /// `--tools read,grep,find,ls`: read-only built-ins.
    case readOnly
    /// `--no-builtin-tools`: built-ins disabled while extension tools (RepoPrompt MCP
    /// tools via pi-mcp-adapter) stay enabled — the MCP-only restricted profile.
    case mcpOnly
    /// `--tools <list>`: explicit allowlist across built-in, extension, and custom tools.
    case allowlist([String])

    public var arguments: [String] {
        switch self {
        case .standard:
            []
        case .readOnly:
            ["--tools", "read,grep,find,ls"]
        case .mcpOnly:
            ["--no-builtin-tools"]
        case let .allowlist(tools):
            ["--tools", tools.joined(separator: ",")]
        }
    }
}

/// Which extensions a managed launch loads. The pinned profile is deterministic: user
/// and project extension discovery is disabled and only the version-pinned
/// pi-mcp-adapter loads, so user extensions cannot alter defaults, tools, or raise
/// blocking dialogs. Unpinned `npm:` specs resolve to latest and must not be used.
public enum PiExtensionPolicy: Equatable, Sendable {
    case userEnvironment
    case pinnedAdapterOnly(version: String)

    var arguments: [String] {
        switch self {
        case .userEnvironment:
            []
        case let .pinnedAdapterOnly(version):
            ["--no-extensions", "-e", "npm:pi-mcp-adapter@\(version)"]
        }
    }
}

/// Options for one managed `pi` launch. Defaults encode the determinism policy from
/// the integration survey: suppress project-local resources (`-na`), suppress
/// AGENTS.md/CLAUDE.md discovery (`-nc`), and keep startup network quiet.
public struct PiLaunchOptions: Equatable, Sendable {
    public var mode: PiLaunchMode
    public var model: PiModelSelection?
    public var session: PiSessionSelection
    public var sessionDisplayName: String?
    public var toolProfile: PiToolProfile
    public var extensionPolicy: PiExtensionPolicy
    /// Path to the ephemeral `--mcp-config` document (pi-mcp-adapter CLI flag).
    public var mcpConfigPath: String?
    public var suppressProjectResources: Bool
    public var suppressContextFiles: Bool
    public var quietStartupNetwork: Bool
    public var additionalArguments: [String]

    public init(
        mode: PiLaunchMode,
        model: PiModelSelection? = nil,
        session: PiSessionSelection = .ephemeral,
        sessionDisplayName: String? = nil,
        toolProfile: PiToolProfile = .standard,
        extensionPolicy: PiExtensionPolicy = .pinnedAdapterOnly(version: "2.32.1"),
        mcpConfigPath: String? = nil,
        suppressProjectResources: Bool = true,
        suppressContextFiles: Bool = true,
        quietStartupNetwork: Bool = true,
        additionalArguments: [String] = []
    ) {
        self.mode = mode
        self.model = model
        self.session = session
        self.sessionDisplayName = sessionDisplayName
        self.toolProfile = toolProfile
        self.extensionPolicy = extensionPolicy
        self.mcpConfigPath = mcpConfigPath
        self.suppressProjectResources = suppressProjectResources
        self.suppressContextFiles = suppressContextFiles
        self.quietStartupNetwork = quietStartupNetwork
        self.additionalArguments = additionalArguments
    }

    /// Full argv (without the executable name) for this launch.
    public func arguments() -> [String] {
        var args: [String] = []
        switch mode {
        case .rpc:
            args.append(contentsOf: ["--mode", "rpc"])
        case .jsonEventStream:
            args.append(contentsOf: ["--mode", "json"])
        case .print:
            args.append("-p")
        }
        if let model {
            if let provider = model.provider {
                args.append(contentsOf: ["--provider", provider])
            }
            args.append(contentsOf: ["--model", model.modelPattern])
            if let thinkingLevel = model.thinkingLevel {
                args.append(contentsOf: ["--thinking", thinkingLevel])
            }
        }
        switch session {
        case .ephemeral:
            args.append("--no-session")
        case .persistent:
            break
        case let .resume(identifier):
            args.append(contentsOf: ["--session", identifier])
        case let .directory(path):
            args.append(contentsOf: ["--session-dir", path])
        }
        if let sessionDisplayName, !sessionDisplayName.isEmpty {
            args.append(contentsOf: ["--name", sessionDisplayName])
        }
        args.append(contentsOf: toolProfile.arguments)
        args.append(contentsOf: extensionPolicy.arguments)
        if let mcpConfigPath {
            args.append(contentsOf: ["--mcp-config", mcpConfigPath])
        }
        if suppressProjectResources {
            args.append("-na")
        }
        if suppressContextFiles {
            args.append("-nc")
        }
        args.append(contentsOf: additionalArguments)
        // `--` stops option parsing; the initial prompt must come after every flag.
        switch mode {
        case .rpc:
            break
        case let .jsonEventStream(initialPrompt):
            if let initialPrompt {
                args.append("--")
                args.append(initialPrompt)
            }
        case let .print(initialPrompt):
            if let initialPrompt {
                args.append("--")
                args.append(initialPrompt)
            }
        }
        return args
    }

    /// Environment overlay for this launch, applied over the inherited environment.
    /// `AI_AGENT=pi` and `PI_CODING_AGENT=true` are set by the pi CLI/RPC entry
    /// points themselves and need no injection here.
    public func environment(over base: [String: String] = [:]) -> [String: String] {
        var env = base
        if quietStartupNetwork {
            env["PI_OFFLINE"] = "1"
            env["PI_SKIP_VERSION_CHECK"] = "1"
        }
        return env
    }
}
