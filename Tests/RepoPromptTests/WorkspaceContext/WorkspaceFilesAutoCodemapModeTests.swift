@testable import RepoPrompt
import XCTest

@MainActor
final class WorkspaceFilesAutoCodemapModeTests: XCTestCase {
    func testExplicitCodemapOnlyIntentSelectsRequestedManualFileAndDisablesAuto() {
        let fixture = makeFixture(fileName: "Present.swift")
        XCTAssertTrue(fixture.viewModel.codemapAutoEnabled)

        fixture.viewModel.setFileAsCodemap(fixture.file)

        XCTAssertFalse(fixture.viewModel.codemapAutoEnabled)
        XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
        XCTAssertFalse(fixture.viewModel.isAutoCodemapFile(fixture.file))
        XCTAssertTrue(fixture.viewModel.snapshotSelection().selectedPaths.isEmpty)
        XCTAssertEqual(
            fixture.viewModel.snapshotSelection().manualCodemapPaths,
            [fixture.file.standardizedFullPath]
        )
    }

    func testOrdinaryFileRemovalPreservesAutoAndFullClearRestoresIt() async {
        do {
            let fixture = makeFixture(fileName: "Selected.swift")
            fixture.viewModel.selectFileForTesting(fixture.file)
            XCTAssertTrue(fixture.viewModel.codemapAutoEnabled)

            fixture.viewModel.removeFileFromAllSelections(fixture.file)

            XCTAssertTrue(fixture.viewModel.selectedFiles.isEmpty)
            XCTAssertTrue(fixture.viewModel.codemapAutoEnabled)
        }

        do {
            let fixture = makeFixture(fileName: "Clear.swift")
            fixture.viewModel.enterManualCodemapMode()
            XCTAssertFalse(fixture.viewModel.codemapAutoEnabled)

            await fixture.viewModel.clearSelection()

            XCTAssertTrue(fixture.viewModel.selectedFiles.isEmpty)
            XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
            XCTAssertTrue(fixture.viewModel.codemapAutoEnabled)
        }
    }

    func testSnapshotAndEncodingContainNoInferredPathState() throws {
        let fixture = makeFixture(fileName: "Dependency.swift")
        fixture.viewModel.selectFileForTesting(fixture.file)

        let snapshot = fixture.viewModel.snapshotSelection()
        XCTAssertEqual(snapshot.selectedPaths, [fixture.file.standardizedFullPath])
        XCTAssertTrue(snapshot.codemapAutoEnabled)

        let encoded = try JSONEncoder().encode(snapshot)
        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(encodedText.contains("autoCodemapPaths"))

        fixture.viewModel.setAutoCodemapFilesForTesting([fixture.file])
        XCTAssertEqual(fixture.viewModel.autoCodemapFiles.map(\.id), [fixture.file.id])
        fixture.viewModel.enterManualCodemapMode()
        XCTAssertFalse(fixture.viewModel.codemapAutoEnabled)
        XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
        XCTAssertTrue(fixture.viewModel.manualCodemapFiles.isEmpty)
        XCTAssertTrue(fixture.viewModel.snapshotSelection().manualCodemapPaths.isEmpty)
    }

    func testGraphReadinessDoesNotMutateManualMode() {
        let fixture = makeFixture(fileName: "Manual.swift")
        fixture.viewModel.enterManualCodemapMode()

        fixture.viewModel.handleAutomaticCodemapReadinessForTesting(
            rootEpoch: WorkspaceCodemapRootEpoch(
                rootID: fixture.file.rootIdentifier,
                rootLifetimeID: UUID()
            )
        )

        XCTAssertFalse(fixture.viewModel.codemapAutoEnabled)
        XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
    }

    func testMilestoneDProductionCallersContainNoEagerCodemapOrCacheActions() throws {
        let repoRoot = try RepoRoot.url()
        let relativePaths = [
            "Sources/RepoPrompt/Features/WorkspaceFiles/ViewModels/WorkspaceFilesViewModel.swift",
            "Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift",
            "Sources/RepoPrompt/Features/Workspaces/WorkspaceCheckoutRefreshService.swift",
            "Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift",
            "Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+WorktreeMerge.swift",
            "Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentMCPStartWorktreeCoordinator.swift",
            "Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceRootBindingProjection.swift"
        ]
        let forbidden = [
            "initializeCodemapsForSessionWorktreeRoots",
            "requestCodemapScans",
            "repairMissingCodemapSnapshots",
            "purgeStaleCodemapCaches",
            "clearCodeMapCache",
            "codeMapUpdatePublisher",
            "codemapUpdates()"
        ]

        for relativePath in relativePaths {
            let source = try String(
                contentsOf: repoRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for symbol in forbidden {
                XCTAssertFalse(source.contains(symbol), "\(relativePath) still references \(symbol)")
            }
        }
    }

    func testPublicationRevalidationIsFinalAwaitBeforeSynchronousCommit() throws {
        let repoRoot = try RepoRoot.url()
        let sourceURL = repoRoot.appendingPathComponent(
            "Sources/RepoPrompt/Features/WorkspaceFiles/ViewModels/WorkspaceFilesViewModel.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let revalidation = try XCTUnwrap(try source.range(
            of: "guard automaticCodemapSelectionIsCurrent(",
            range: XCTUnwrap(source.range(
                of: "revalidateAutomaticCodemapSelectionForPublication("
            )).upperBound ..< source.endIndex
        ))
        let commit = try XCTUnwrap(source.range(
            of: "resetAutoCodemapFiles(resolvedTargets)",
            range: revalidation.lowerBound ..< source.endIndex
        ))
        let synchronousCommitRegion = source[revalidation.lowerBound ..< commit.upperBound]
        XCTAssertFalse(synchronousCommitRegion.contains("await"))
    }

    private func makeFixture(fileName: String) -> (
        viewModel: WorkspaceFilesViewModel,
        file: FileViewModel
    ) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceFilesAutoCodemapModeTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rootID = UUID()
        let file = FileViewModel(
            file: File(
                name: fileName,
                path: rootURL.appendingPathComponent(fileName).path,
                modificationDate: Date(timeIntervalSince1970: 1000)
            ),
            rootPath: rootURL.path,
            rootIdentifier: rootID,
            rootFolderPath: rootURL.path,
            fileSystemService: nil
        )
        return (WorkspaceFilesViewModel(), file)
    }
}
