import Foundation
@testable import RepoPromptPiProvider
import XCTest

final class PiLaunchOptionsTests: XCTestCase {
    func testDeterministicAgentModeLaunch() {
        let options = PiLaunchOptions(
            mode: .rpc,
            session: .ephemeral,
            sessionDisplayName: "CE agent run",
            mcpConfigPath: "/tmp/rpce-pi-mcp.json"
        )
        XCTAssertEqual(
            options.arguments(),
            [
                "--mode", "rpc",
                "--no-session",
                "--name", "CE agent run",
                "--no-extensions", "-e", "npm:pi-mcp-adapter@2.32.1",
                "--mcp-config", "/tmp/rpce-pi-mcp.json",
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
            mcpConfigPath: "/tmp/rpce-pi-mcp.json"
        )
        XCTAssertEqual(
            options.arguments(),
            [
                "--mode", "json",
                "--no-session",
                "--no-builtin-tools",
                "--no-extensions", "-e", "npm:pi-mcp-adapter@2.32.1",
                "--mcp-config", "/tmp/rpce-pi-mcp.json",
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
            session: .resume("01a06f3a")
        )
        XCTAssertEqual(
            options.arguments(),
            [
                "--mode", "rpc",
                "--provider", "anthropic",
                "--model", "claude-sonnet-4-20250514",
                "--thinking", "high",
                "--session", "01a06f3a",
                "--no-extensions", "-e", "npm:pi-mcp-adapter@2.32.1",
                "-na",
                "-nc"
            ]
        )
    }

    func testSessionDirectoryAndAllowlistProfiles() {
        let directoryOptions = PiLaunchOptions(
            mode: .rpc,
            session: .directory("/tmp/rpce-pi-sessions"),
            toolProfile: .allowlist(["read", "grep", "mcp"])
        )
        XCTAssertTrue(directoryOptions.arguments().contains("--session-dir"))
        XCTAssertEqual(
            directoryOptions.arguments().drop(while: { $0 != "--tools" }).prefix(2).dropFirst().first,
            "read,grep,mcp"
        )

        let persistent = PiLaunchOptions(mode: .rpc, session: .persistent)
        XCTAssertFalse(persistent.arguments().contains("--no-session"))
    }

    func testEnvironmentPreservesBaseValues() {
        let options = PiLaunchOptions(mode: .rpc)
        let env = options.environment(over: ["PATH": "/usr/bin"])
        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertEqual(env["PI_OFFLINE"], "1")
    }
}
