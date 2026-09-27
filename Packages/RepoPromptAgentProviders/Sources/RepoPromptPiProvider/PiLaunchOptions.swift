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
        let trimmedPattern = modelPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProvider = provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedProvider == nil || trimmedProvider?.isEmpty == true,
           let slash = trimmedPattern.firstIndex(of: "/"),
           slash > trimmedPattern.startIndex,
           slash < trimmedPattern.index(before: trimmedPattern.endIndex)
        {
            self.provider = String(trimmedPattern[..<slash])
            self.modelPattern = String(trimmedPattern[trimmedPattern.index(after: slash)...])
        } else {
            self.provider = trimmedProvider?.isEmpty == true ? nil : trimmedProvider
            self.modelPattern = trimmedPattern
        }
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

/// Discovers user-global pi extension sources under `~/.pi/agent/extensions`.
///
/// Matches pi's documented auto-discovery: `*.ts` files and `*/index.ts`
/// packages. Project-local `.pi/extensions` are intentionally excluded so
/// managed launches stay independent of the current worktree.
public enum PiUserGlobalExtensionDiscovery: Sendable {
    public static func defaultDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
    }

    public static func sourcePaths(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [String] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var paths: [String] = []
        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                let index = url.appendingPathComponent("index.ts")
                if fileManager.isReadableFile(atPath: index.path) {
                    paths.append(index.standardizedFileURL.path)
                }
            } else if url.pathExtension == "ts" {
                paths.append(url.standardizedFileURL.path)
            }
        }
        return paths
    }
}

/// Which extensions a managed launch loads. Unpinned `npm:` specs resolve to
/// latest and must not be used.
///
/// `--no-extensions` disables both auto-discovery and installed `settings.json`
/// packages so a second `-e npm:pi-mcp-adapter@…` cannot double-load the
/// adapter. User-global custom providers (for example a `local` OpenAI-compatible
/// catalog) live under `~/.pi/agent/extensions` and must be re-attached
/// explicitly or Agent Mode's catalog will not match the Settings connect probe.
public enum PiExtensionPolicy: Equatable, Sendable {
    case userEnvironment
    case pinnedAdapterOnly(version: String)
    /// `--no-extensions`, then each discovered user-global extension source,
    /// then the version-pinned pi-mcp-adapter.
    case pinnedAdapterWithUserGlobalExtensions(version: String, directory: String)

    /// Managed Agent Mode / probe / headless launches: keep `--no-extensions` so
    /// installed packages cannot double-load the adapter, then re-attach the
    /// user's global extension sources and the pinned adapter.
    public static func pinnedAdapterWithDiscoveredUserGlobalExtensions(
        version: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> PiExtensionPolicy {
        .pinnedAdapterWithUserGlobalExtensions(
            version: version,
            directory: PiUserGlobalExtensionDiscovery.defaultDirectory(homeDirectory: homeDirectory).path
        )
    }

    var arguments: [String] {
        switch self {
        case .userEnvironment:
            []
        case let .pinnedAdapterOnly(version):
            ["--no-extensions", "-e", "npm:pi-mcp-adapter@\(version)"]
        case let .pinnedAdapterWithUserGlobalExtensions(version, directory):
            ["--no-extensions"]
                + PiUserGlobalExtensionDiscovery.sourcePaths(
                    in: URL(fileURLWithPath: directory, isDirectory: true)
                ).flatMap { ["-e", $0] }
                + ["-e", "npm:pi-mcp-adapter@\(version)"]
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
