import Foundation
@testable import RepoPrompt
import XCTest

@MainActor
final class MCPSelectionContentPackagingTests: XCTestCase {
    func testContentViewIncludesCanonicalCodemapBlocksExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("MCPSelectionContentPackaging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let selectedURL = root.appendingPathComponent("Selected.swift")
        let codemapURL = root.appendingPathComponent("Canonical.swift")
        try "let selectedContentSentinel = true\n".write(to: selectedURL, atomically: true, encoding: .utf8)
        try "func canonicalFullContentSentinel() {}\n".write(to: codemapURL, atomically: true, encoding: .utf8)

        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        let previousCodeMapsDisabled = GlobalSettingsStore.shared.globalCodeMapsDisabled()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        GlobalSettingsStore.shared.setCodeMapsGloballyDisabled(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        defer {
            WindowStatesManager.shared.unregisterWindowState(window)
            GlobalSettingsStore.shared.setCodeMapsGloballyDisabled(previousCodeMapsDisabled, commit: false)
        }

        _ = try await window.workspaceFileContextStore.loadRoot(path: root.path)
        let selection = StoredSelection(
            selectedPaths: [selectedURL.path],
            autoCodemapPaths: [codemapURL.path],
            codemapAutoEnabled: true
        )
        let missingSnapshotReply = await window.mcpServer.buildSelectionPreviewReply(
            selection: selection,
            includeBlocks: true,
            display: .relative,
            extraInvalid: [],
            viewMode: nil,
            codeMapUsageOverride: .auto
        )
        let missingSnapshotBlocks = try XCTUnwrap(missingSnapshotReply.blocks)
        let missingSnapshotPackaged = missingSnapshotBlocks.joined(separator: "\n")
        XCTAssertEqual(missingSnapshotReply.files?.map(\.renderMode), ["full"])
        XCTAssertEqual(missingSnapshotReply.summary?.codemapCount, 0)
        XCTAssertEqual(missingSnapshotBlocks.count, 1)
        XCTAssertFalse(missingSnapshotPackaged.contains("canonicalFullContentSentinel"), missingSnapshotPackaged)

        await window.workspaceFileContextStore.applyObservedCodemapResults([
            WorkspaceObservedCodemapResult(
                fullPath: codemapURL.path,
                modificationDate: Date(),
                fileAPI: makeFileAPI(path: codemapURL.path, symbolName: "canonicalCodemapSymbol")
            )
        ])

        let reply = await window.mcpServer.buildSelectionPreviewReply(
            selection: selection,
            includeBlocks: true,
            display: .relative,
            extraInvalid: [],
            viewMode: nil,
            codeMapUsageOverride: .auto
        )
        let blocks = try XCTUnwrap(reply.blocks)
        let packaged = blocks.joined(separator: "\n")

        XCTAssertEqual(reply.files?.map(\.renderMode), ["full", "codemap"])
        XCTAssertEqual(reply.summary?.codemapCount, 1)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(packaged.components(separatedBy: "selectedContentSentinel").count - 1, 1, packaged)
        XCTAssertEqual(packaged.components(separatedBy: "canonicalCodemapSymbol").count - 1, 1, packaged)
        XCTAssertFalse(packaged.contains("canonicalFullContentSentinel"), packaged)
    }

    private func makeFileAPI(path: String, symbolName: String) -> FileAPI {
        FileAPI(
            filePath: path,
            imports: [],
            classes: [],
            functions: [
                FunctionInfo(
                    name: symbolName,
                    parameters: [],
                    returnType: nil,
                    definitionLine: "func \(symbolName)()",
                    lineNumber: 1
                )
            ],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: []
        )
    }
}
