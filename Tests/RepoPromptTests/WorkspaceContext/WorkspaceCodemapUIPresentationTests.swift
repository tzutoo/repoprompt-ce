@testable import RepoPromptApp
import RepoPromptFileSystem
import XCTest

@MainActor
final class WorkspaceCodemapUIPresentationTests: XCTestCase {
    func testCurrentMarkerRequiresRenderablePresentationIdentity() throws {
        let file = makeFileViewModel(name: "Marker.swift")
        let entry = try makePresentationEntry(file: file)

        XCTAssertFalse(PromptFileEntry(file: file, codemap: nil, ranges: nil).isCodemap)
        XCTAssertTrue(PromptFileEntry(file: file, codemap: entry, ranges: nil).isCodemap)
        XCTAssertEqual(entry.fileID, file.id)
    }

    func testPreviewPayloadUsesImmutableLogicalPathAndText() throws {
        let file = makeFileViewModel(name: "Preview.swift")
        let entry = try makePresentationEntry(file: file)
        let originalText = entry.text
        let originalLogicalPath = entry.logicalPath.displayPath

        XCTAssertEqual(entry.text, originalText)
        XCTAssertEqual(entry.logicalPath.displayPath, originalLogicalPath)
        XCTAssertFalse(entry.logicalPath.displayPath.contains(file.rootFolderPath))
    }

    func testPreviewRevokesWhenRenderableFileIdentityIsGone() async {
        let manager = WorkspaceFilesViewModel()

        let disposition = await manager.codemapPreview(for: UUID())

        XCTAssertEqual(disposition, .revoked)
    }

    func testNonGitOptOutDoesNotShowIndeterminateCatalogDiscovery() {
        let presentation = AgentWorkspaceCodemapPresentation.make(
            makeStatus(availability: .unavailable, unavailableReason: .nonGitOptOut)
        )
        XCTAssertEqual(presentation.state, .unavailable)
        XCTAssertFalse(presentation.isActivelyMapping)
        XCTAssertFalse(presentation.showsProgress)
        XCTAssertTrue(presentation.tooltip.contains("plain folder"))

        let summary = AgentWorkspaceCodemapSummary.make([presentation])
        XCTAssertEqual(summary.state, .unavailable)
        XCTAssertFalse(summary.showsIndeterminateProgress)
        XCTAssertEqual(summary.detailText, "Code Maps unavailable")
    }

    func testMissingOrIdleStatusDoesNotShowIndeterminateCatalogDiscovery() {
        let pending = AgentWorkspaceCodemapPresentation.make(nil)
        XCTAssertEqual(pending.state, .notInitialized)
        XCTAssertFalse(pending.isActivelyMapping)
        XCTAssertFalse(pending.showsProgress)

        let preparing = AgentWorkspaceCodemapPresentation.make(
            makeStatus(availability: .notInitialized)
        )
        XCTAssertEqual(preparing.state, .notInitialized)
        XCTAssertFalse(preparing.isActivelyMapping)
        XCTAssertFalse(preparing.showsProgress)

        let summary = AgentWorkspaceCodemapSummary.make([pending, preparing])
        XCTAssertEqual(summary.state, .unavailable)
        XCTAssertFalse(summary.showsIndeterminateProgress)
        XCTAssertEqual(summary.detailText, "Code Maps unavailable")
    }

    func testGitIndexingStillShowsActiveDiscovery() {
        let presentation = AgentWorkspaceCodemapPresentation.make(
            makeStatus(availability: .indexing)
        )
        XCTAssertEqual(presentation.state, .indexing)
        XCTAssertTrue(presentation.isActivelyMapping)
        XCTAssertTrue(presentation.showsProgress)

        let summary = AgentWorkspaceCodemapSummary.make([presentation])
        XCTAssertEqual(summary.state, .indexing)
        XCTAssertTrue(summary.showsIndeterminateProgress)
    }

    func testWorkspaceKeepsGitIndexingWhenAPlainFolderIsOptedOut() {
        let git = AgentWorkspaceCodemapPresentation.make(makeStatus(availability: .indexing))
        let plain = AgentWorkspaceCodemapPresentation.make(
            makeStatus(availability: .unavailable, unavailableReason: .nonGitOptOut)
        )
        XCTAssertTrue(git.isActivelyMapping)
        XCTAssertFalse(plain.isActivelyMapping)

        let summary = AgentWorkspaceCodemapSummary.make([git, plain])
        XCTAssertEqual(summary.state, .indexing)
        XCTAssertTrue(summary.showsIndeterminateProgress)
    }

    func testWorkspaceStaysMappedWhenAReadyGitRootSitsBesideAnOptedOutFolder() {
        let git = AgentWorkspaceCodemapPresentation.make(makeStatus(availability: .ready))
        let plain = AgentWorkspaceCodemapPresentation.make(
            makeStatus(availability: .unavailable, unavailableReason: .nonGitOptOut)
        )

        let summary = AgentWorkspaceCodemapSummary.make([git, plain])
        XCTAssertEqual(summary.state, .ready)
        XCTAssertFalse(summary.showsIndeterminateProgress)
        XCTAssertEqual(summary.readyRootCount, 1)
    }

    // The obsolete plain-folder "typed unavailable" preview contract was removed with non-Git
    // Code Map support. Positive preview coverage for a plain on-disk root now lives in
    // `CodemapAutomaticSelectionGraphNativeTests`
    // `.testFilesystemTSAndTSXCodeMapsUseCurrentBytesWithoutGitOrManifestAccess`, which asserts a
    // rendered entry containing the actual current symbols instead of an unavailability reason.

    private func makeFileViewModel(name: String) -> FileViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceCodemapUIPresentationTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return FileViewModel(
            file: File(
                name: name,
                path: root.appendingPathComponent(name).path,
                modificationDate: Date(timeIntervalSince1970: 1000)
            ),
            rootPath: root.path,
            rootIdentifier: UUID(),
            rootFolderPath: root.path,
            fileSystemService: nil
        )
    }

    private func makePresentationEntry(file: FileViewModel) throws -> WorkspaceCodemapUIPresentationEntry {
        let logicalPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "LogicalRoot",
            standardizedRelativePath: file.name
        ))
        return WorkspaceCodemapUIPresentationEntry(
            presentationID: UUID(),
            fileID: file.id,
            rootEpoch: WorkspaceCodemapRootEpoch(
                rootID: file.rootIdentifier,
                rootLifetimeID: UUID()
            ),
            logicalPath: logicalPath,
            text: SwiftFixtureSource.emptyStruct("RenderedPreview", trailingNewline: false),
            tokenCount: 7
        )
    }

    private func makeStatus(
        availability: WorkspaceCodemapRootAvailability,
        unavailableReason: WorkspaceCodemapRootStatusUnavailableReason? = nil
    ) -> WorkspaceCodemapRootStatusSnapshot {
        WorkspaceCodemapRootStatusSnapshot(
            rootEpoch: WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID()),
            availability: availability,
            isGenerationSuspended: false,
            coverage: nil,
            graphRevision: nil,
            appliedGeneration: .init(rawValue: 0),
            observedGeneration: .init(rawValue: 0),
            updatesPending: false,
            reconciliationAttempt: nil,
            reconciliationDeadlineUptimeNanoseconds: nil,
            commitCadence: WorkspaceCodemapGraphCommitCadence(
                successfulCommitCount: 0,
                resyncCommitCount: 0,
                lastCommittedUptimeNanoseconds: nil,
                lastCommitIntervalMilliseconds: nil
            ),
            diagnostics: WorkspaceCodemapGraphRootDiagnostics(
                rejectedApplyCount: 0,
                fencedFileCount: 0,
                activeApply: false,
                safetyCounter: 0,
                revocationReason: nil
            ),
            unavailableReason: unavailableReason
        )
    }
}
