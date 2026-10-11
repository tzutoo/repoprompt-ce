import Foundation
@testable import RepoPromptPiProvider
import XCTest

final class PiLaunchOptionsTests: XCTestCase {
    func testDeterministicAgentModeLaunch() {
        let options = PiLaunchOptions(
            mode: .rpc,
            session: .ephemeral,
            sessionDisplayName: "CE agent run",
            extensionPolicy: .builtinMCPWithUserGlobalExtensions(
                directory: "/tmp/missing-pi-extensions",
                injectorPath: "/tmp/rpce-pi-inject.ts"
            )
        )
        XCTAssertEqual(
            options.arguments(),
            [
                "--mode", "rpc",
                "--no-session",
                "--name", "CE agent run",
                "--no-extensions", "-e", "builtin:mcp",
                "-e", "/tmp/rpce-pi-inject.ts",
                "-na",
                "-nc"
            ]
        )
        XCTAssertEqual(
            options.environment(),
            ["PI_OFFLINE": "1", "PI_SKIP_VERSION_CHECK": "1"]
        )
    }

    func testMCPOnlyHeadlessLaunch() {
        let options = PiLaunchOptions(
            mode: .jsonEventStream(initialPrompt: "Summarize this workspace"),
            toolProfile: .mcpOnly,
            extensionPolicy: .builtinMCPWithUserGlobalExtensions(
                directory: "/tmp/missing-pi-extensions",
                injectorPath: "/tmp/rpce-pi-inject.ts"
            )
        )
        XCTAssertEqual(
            options.arguments(),
            [
                "--mode", "json",
                "--no-session",
                "--no-builtin-tools",
                "--no-extensions", "-e", "builtin:mcp",
                "-e", "/tmp/rpce-pi-inject.ts",
                "-na",
                "-nc",
                "--", "Summarize this workspace"
            ]
        )
    }

    func testReadOnlyUserEnvironmentLaunch() {
        let options = PiLaunchOptions(
            mode: .print(initialPrompt: "Review the code"),
            toolProfile: .readOnly,
            extensionPolicy: .userEnvironment,
            suppressProjectResources: false,
            suppressContextFiles: false,
            quietStartupNetwork: false
        )
        XCTAssertEqual(
            options.arguments(),
            [
                "-p",
                "--no-session",
                "--tools", "read,grep,find,ls",
                "--", "Review the code"
            ]
        )
        XCTAssertTrue(options.environment().isEmpty)
    }

    func testModelSelectionAndSessionResume() {
        let options = PiLaunchOptions(
            mode: .rpc,
            model: PiModelSelection(provider: "anthropic", modelPattern: "claude-sonnet-4-20250514", thinkingLevel: "high"),
            session: .resume("01a06f3a"),
            extensionPolicy: .builtinMCPWithUserGlobalExtensions(
                directory: "/tmp/missing-pi-extensions",
                injectorPath: nil
            )
        )
        XCTAssertEqual(
            options.arguments(),
            [
                "--mode", "rpc",
                "--provider", "anthropic",
                "--model", "claude-sonnet-4-20250514",
                "--thinking", "high",
                "--session", "01a06f3a",
                "--no-extensions", "-e", "builtin:mcp",
                "-na",
                "-nc"
            ]
        )
    }

    func testSessionDirectoryAndAllowlistProfiles() {
        let directoryOptions = PiLaunchOptions(
            mode: .rpc,
            session: .directory("/tmp/rpce-pi-sessions"),
            toolProfile: .allowlist(["read", "grep"]),
            extensionPolicy: .builtinMCPWithUserGlobalExtensions(
                directory: "/tmp/missing-pi-extensions",
                injectorPath: nil
            )
        )
        XCTAssertTrue(directoryOptions.arguments().contains("--session-dir"))
        XCTAssertEqual(
            directoryOptions.arguments().drop(while: { $0 != "--tools" }).prefix(2).dropFirst().first,
            "read,grep"
        )

        let persistent = PiLaunchOptions(
            mode: .rpc,
            session: .persistent,
            extensionPolicy: .builtinMCPWithUserGlobalExtensions(
                directory: "/tmp/missing-pi-extensions",
                injectorPath: nil
            )
        )
        XCTAssertFalse(persistent.arguments().contains("--no-session"))
    }

    func testModelSelectionParsesProviderSlashId() {
        let selection = PiModelSelection(modelPattern: "xai/grok-4")
        XCTAssertEqual(selection.provider, "xai")
        XCTAssertEqual(selection.modelPattern, "grok-4")
        let explicit = PiModelSelection(provider: "zai", modelPattern: "xai/grok-4")
        XCTAssertEqual(explicit.provider, "zai")
        XCTAssertEqual(explicit.modelPattern, "xai/grok-4")
    }

    func testEnvironmentPreservesBaseValues() {
        let options = PiLaunchOptions(
            mode: .rpc,
            extensionPolicy: .builtinMCPWithUserGlobalExtensions(
                directory: "/tmp/missing-pi-extensions",
                injectorPath: nil
            )
        )
        let env = options.environment(over: ["PATH": "/usr/bin"])
        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertEqual(env["PI_OFFLINE"], "1")
    }

    func testUserGlobalExtensionDiscoveryFindsTsFilesAndIndexPackages() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpce-pi-ext-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("appmosa-sync.ts")
        try "export {}".write(to: file, atomically: true, encoding: .utf8)
        try "export {}".write(
            to: nested.appendingPathComponent("index.ts"),
            atomically: true,
            encoding: .utf8
        )
        try "ignored".write(
            to: root.appendingPathComponent("notes.md"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(
            PiUserGlobalExtensionDiscovery.sourcePaths(in: root),
            [
                file.standardizedFileURL.path,
                nested.appendingPathComponent("index.ts").standardizedFileURL.path
            ]
        )
    }

    func testBuiltinMCPWithUserGlobalExtensionsKeepsNoExtensionsAndBuiltinMCP() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpce-pi-ext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let extensionPath = root.appendingPathComponent("appmosa-sync.ts")
        try "export {}".write(to: extensionPath, atomically: true, encoding: .utf8)
        let injectorPath = root.appendingPathComponent("rpce-inject.ts").path

        let options = PiLaunchOptions(
            mode: .rpc,
            extensionPolicy: .builtinMCPWithUserGlobalExtensions(
                directory: root.path,
                injectorPath: injectorPath
            )
        )
        XCTAssertEqual(
            options.arguments(),
            [
                "--mode", "rpc",
                "--no-session",
                "--no-extensions",
                "-e", "builtin:mcp",
                "-e", extensionPath.standardizedFileURL.path,
                "-e", injectorPath,
                "-na",
                "-nc"
            ]
        )

        let missing = PiLaunchOptions(
            mode: .rpc,
            extensionPolicy: .builtinMCPWithUserGlobalExtensions(
                directory: root.appendingPathComponent("missing").path,
                injectorPath: nil
            )
        )
        XCTAssertEqual(
            missing.arguments(),
            [
                "--mode", "rpc",
                "--no-session",
                "--no-extensions",
                "-e", "builtin:mcp",
                "-na",
                "-nc"
            ]
        )
    }
}
