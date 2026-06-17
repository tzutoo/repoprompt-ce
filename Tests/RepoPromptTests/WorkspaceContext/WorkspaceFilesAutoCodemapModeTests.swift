@testable import RepoPrompt
import XCTest

@MainActor
final class WorkspaceFilesAutoCodemapModeTests: XCTestCase {
    func testExplicitCodemapRemovalDisablesAutoForPresentAndEmptySelections() {
        do {
            let fixture = makeFixture(fileName: "Present.swift")
            fixture.viewModel.setFileAsCodemap(fixture.file)
            fixture.viewModel.codemapAutoEnabled = true

            fixture.viewModel.removeCodemapFile(fixture.file)

            XCTAssertFalse(fixture.viewModel.codemapAutoEnabled)
            XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
            XCTAssertFalse(fixture.viewModel.isAutoCodemapFile(fixture.file))
        }

        do {
            let fixture = makeFixture(fileName: "Empty.swift")
            XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
            XCTAssertTrue(fixture.viewModel.codemapAutoEnabled)

            fixture.viewModel.clearAutoCodemapFiles()

            XCTAssertFalse(fixture.viewModel.codemapAutoEnabled)
            XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
        }

        do {
            let fixture = makeFixture(fileName: "Absent.swift")

            fixture.viewModel.removeCodemapFile(fixture.file)

            XCTAssertTrue(fixture.viewModel.codemapAutoEnabled)
            XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
        }
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
            fixture.viewModel.setFileAsCodemap(fixture.file)
            XCTAssertFalse(fixture.viewModel.codemapAutoEnabled)
            XCTAssertEqual(fixture.viewModel.autoCodemapFiles.map(\.id), [fixture.file.id])

            await fixture.viewModel.clearSelection()

            XCTAssertTrue(fixture.viewModel.selectedFiles.isEmpty)
            XCTAssertTrue(fixture.viewModel.autoCodemapFiles.isEmpty)
            XCTAssertTrue(fixture.viewModel.codemapAutoEnabled)
        }
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
