import Foundation
@testable import RepoPromptPiProvider
import XCTest

final class PiMCPAdapterConfigurationTests: XCTestCase {
    func testClientIdentityMirrorsAdapterConvention() {
        XCTAssertEqual(PiMCPAdapterClientIdentity.clientName(forServer: "RepoPromptCE"), "pi-mcp-RepoPromptCE")
        XCTAssertEqual(PiMCPAdapterClientIdentity.clientName(forServer: "docs"), "pi-mcp-docs")
    }

    func testEagerDirectToolsDocumentShape() throws {
        let document = PiMCPAdapterConfigurationDocument(servers: [
            "RepoPromptCE": PiMCPServerConfiguration(
                command: "/usr/local/bin/repoprompt-ce-cli",
                arguments: ["--backend", "app"],
                environment: ["REPOPROMPT_WINDOW_ID": "3"],
                lifecycle: .eager,
                requestTimeoutMilliseconds: 10_000_000,
                directTools: .all
            )
        ])
        let json = try JSONDecoder().decode(
            PiJSONValue.self,
            from: document.encodedDocument()
        )
        let server = try XCTUnwrap(json["mcpServers"]?["RepoPromptCE"]?.objectValue)
        XCTAssertEqual(server["command"]?.stringValue, "/usr/local/bin/repoprompt-ce-cli")
        XCTAssertEqual(
            server["args"]?.arrayValue?.compactMap(\.stringValue),
            ["--backend", "app"]
        )
        XCTAssertEqual(server["env"]?["REPOPROMPT_WINDOW_ID"]?.stringValue, "3")
        XCTAssertEqual(server["lifecycle"]?.stringValue, "eager")
        XCTAssertEqual(server["requestTimeoutMs"]?.intValue, 10_000_000)
        XCTAssertEqual(server["directTools"]?.boolValue, true)
        // approveTools stays absent: RPCE enforces permissions server-side.
        XCTAssertNil(server["approveTools"])
    }

    func testProxyAndIncludedToolModes() {
        let proxy = PiMCPServerConfiguration(command: "/bin/true", directTools: .proxy).jsonValue
        XCTAssertNil(proxy["directTools"])

        let included = PiMCPServerConfiguration(
            command: "/bin/true",
            directTools: .included(["tree", "get"])
        ).jsonValue
        XCTAssertEqual(
            included["directTools"]?.arrayValue?.compactMap(\.stringValue),
            ["tree", "get"]
        )
    }

    func testLifecycleWireValues() {
        XCTAssertEqual(PiMCPServerLifecycle.lazy.rawValue, "lazy")
        XCTAssertEqual(PiMCPServerLifecycle.eager.rawValue, "eager")
        XCTAssertEqual(PiMCPServerLifecycle.keepAlive.rawValue, "keep-alive")
        XCTAssertEqual(PiMCPServerLifecycle.lazyKeepAlive.rawValue, "lazy-keep-alive")
    }

    func testDocumentIsCompactSingleObjectJSON() throws {
        let document = PiMCPAdapterConfigurationDocument(servers: [
            "s": PiMCPServerConfiguration(command: "/bin/true")
        ])
        let text = try XCTUnwrap(String(data: document.encodedDocument(), encoding: .utf8))
        XCTAssertFalse(text.contains("\n"))
        XCTAssertTrue(text.hasPrefix("{\"mcpServers\":"))
    }
}
