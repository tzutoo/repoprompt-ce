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
    /// `--no-builtin-tools`: built-ins disabled while extension/MCP tools (RepoPrompt
    /// tools via built-in MCP) stay enabled — the MCP-only restricted profile.
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
                if fileManager.isReadableFile(atPath: index.path),
                   !Self.looksLikeMCPAdapter(url)
                {
                    paths.append(index.standardizedFileURL.path)
                }
            } else if url.pathExtension == "ts", !Self.looksLikeMCPAdapter(url) {
                paths.append(url.standardizedFileURL.path)
            }
        }
        return paths
    }

    /// Skip leftover adapter sources so a user-global copy cannot replace `builtin:mcp`.
    private static func looksLikeMCPAdapter(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased().contains("pi-mcp-adapter")
            || url.deletingPathExtension().lastPathComponent.lowercased().contains("pi-mcp-adapter")
    }
}

/// Which extensions a managed launch loads.
///
/// `--no-extensions` disables auto-discovery, installed `settings.json` packages,
/// and built-in extensions. Explicit `-e` still works, so managed launches re-enable
/// `builtin:mcp` and any user-global `~/.pi/agent/extensions` sources. Custom catalogs
/// (for example a `local` OpenAI-compatible provider) stay visible without loading
/// pi-mcp-adapter, which would replace built-in MCP for that session.
public enum PiExtensionPolicy: Equatable, Sendable {
    case userEnvironment
    /// `--no-extensions -e builtin:mcp`, then discovered user-global sources, then an
    /// optional ephemeral injector that calls `pi.registerMcpServer`, then an optional
    /// Full Access approval gate.
    case builtinMCPWithUserGlobalExtensions(directory: String, injectorPath: String?, gatePath: String? = nil)

    /// Managed Agent Mode / probe / headless launches.
    public static func builtinMCPWithDiscoveredUserGlobalExtensions(
        injectorPath: String? = nil,
        gatePath: String? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> PiExtensionPolicy {
        .builtinMCPWithUserGlobalExtensions(
            directory: PiUserGlobalExtensionDiscovery.defaultDirectory(homeDirectory: homeDirectory).path,
            injectorPath: injectorPath,
            gatePath: gatePath
        )
    }

    var arguments: [String] {
        switch self {
        case .userEnvironment:
            return []
        case let .builtinMCPWithUserGlobalExtensions(directory, injectorPath, gatePath):
            var args = ["--no-extensions", "-e", "builtin:mcp"]
            args += PiUserGlobalExtensionDiscovery.sourcePaths(
                in: URL(fileURLWithPath: directory, isDirectory: true)
            ).flatMap { ["-e", $0] }
            if let injectorPath, !injectorPath.isEmpty {
                args += ["-e", injectorPath]
            }
            if let gatePath, !gatePath.isEmpty {
                args += ["-e", gatePath]
            }
            return args
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
        extensionPolicy: PiExtensionPolicy = .builtinMCPWithUserGlobalExtensions(
            directory: "",
            injectorPath: nil
        ),
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
