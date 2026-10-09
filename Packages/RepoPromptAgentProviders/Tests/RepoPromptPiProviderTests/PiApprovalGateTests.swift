import Foundation
@testable import RepoPromptPiProvider
import XCTest

final class PiApprovalGateTests: XCTestCase {
    func testGateSourceFailsClosedWithoutUIAndConfirmsGatedTools() {
        let source = PiApprovalGate.extensionSource()
        XCTAssertTrue(source.contains("tool_call"))
        XCTAssertTrue(source.contains("ctx.ui.confirm"))
        XCTAssertTrue(source.contains("pi gate: no UI"))
        for tool in PiApprovalGate.gatedToolNames {
            XCTAssertTrue(source.contains("\"\(tool)\""), tool)
        }
        XCTAssertFalse(source.contains("mcp__"))
    }

    func testFullAccessLaunchAppendsGatePath() {
        let options = PiLaunchOptions(
            mode: .rpc,
            extensionPolicy: .builtinMCPWithUserGlobalExtensions(
                directory: "/tmp/missing-pi-extensions",
                injectorPath: "/tmp/inject.ts",
                gatePath: "/tmp/gate.ts"
            )
        )
        XCTAssertEqual(
            Array(options.arguments().suffix(6)),
            ["-e", "/tmp/inject.ts", "-e", "/tmp/gate.ts", "-na", "-nc"]
        )
    }
}
