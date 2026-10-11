import Foundation
@testable import RepoPromptPiProvider
import XCTest

final class PiBuiltinMCPConfigurationTests: XCTestCase {
    func testClientIdentityIsBarePi() {
        XCTAssertEqual(PiBuiltinMCPClientIdentity.clientName, "pi")
    }

    func testDirectExposureDocumentShape() {
        let configuration = PiBuiltinMCPServerConfiguration(
            command: "/usr/local/bin/repoprompt-ce-cli",
            arguments: ["--backend", "app"],
            environment: ["REPOPROMPT_WINDOW_ID": "3"],
            timeoutSeconds: 3810,
            exposure: .direct,
            description: "RepoPrompt CE tools"
        )
        let server = configuration.jsonValue
        XCTAssertEqual(server["command"]?.stringValue, "/usr/local/bin/repoprompt-ce-cli")
        XCTAssertEqual(
            server["args"]?.arrayValue?.compactMap(\.stringValue),
            ["--backend", "app"]
        )
        XCTAssertEqual(server["env"]?["REPOPROMPT_WINDOW_ID"]?.stringValue, "3")
        XCTAssertEqual(server["timeout"]?.intValue, 3810)
        XCTAssertEqual(server["exposure"]?.stringValue, "direct")
        XCTAssertEqual(server["description"]?.stringValue, "RepoPrompt CE tools")
        XCTAssertNil(server["lifecycle"])
        XCTAssertNil(server["directTools"])
        XCTAssertNil(server["requestTimeoutMs"])
    }

    func testInjectorSourceRegistersServerWithoutUserConfigMutation() throws {
        let configuration = PiBuiltinMCPServerConfiguration(
            command: "/bin/true",
            timeoutSeconds: 60,
            exposure: .direct
        )
        let source = try PiBuiltinMCPInjector.extensionSource(
            serverName: "RepoPromptCE",
            configuration: configuration
        )
        XCTAssertTrue(source.contains("registerMcpServer"), source)
        XCTAssertTrue(source.contains("RepoPromptCE"), source)
        XCTAssertTrue(source.contains("/bin/true"), source)
        XCTAssertTrue(source.contains("direct"), source)
        XCTAssertTrue(source.contains("timeout"), source)
        XCTAssertFalse(source.contains("mcp.json"), source)
    }
}
