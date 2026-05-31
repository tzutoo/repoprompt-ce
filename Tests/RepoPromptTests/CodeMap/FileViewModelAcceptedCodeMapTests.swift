import Foundation
@testable import RepoPrompt
import XCTest

final class FileViewModelAcceptedCodeMapTests: XCTestCase {
    @MainActor
    func testSetCodeMapLifecycleRejectsMismatchesAndInvalidatesAcceptedFlag() {
        let fixture = makeFileFixture()
        let validAPI = makeFileAPI(path: fixture.fileURL.path, symbol: "acceptedSymbol")
        let replacementAPI = makeFileAPI(path: fixture.fileURL.path, symbol: "replacementSymbol")
        let mismatchedAPI = makeFileAPI(path: fixture.rootURL.appendingPathComponent("other.swift").path)

        fixture.file.setCodeMap(mismatchedAPI)
        XCTAssertFalse(fixture.file.hasAcceptedCodeMap)
        XCTAssertNil(fixture.file.fileAPI)
        XCTAssertNil(fixture.file.codemapLineCount)

        fixture.file.setCodeMap(validAPI)
        XCTAssertTrue(fixture.file.hasAcceptedCodeMap)
        XCTAssertNotNil(fixture.file.fileAPI)

        fixture.file.setCodeMap(nil)
        XCTAssertFalse(fixture.file.hasAcceptedCodeMap)
        XCTAssertNil(fixture.file.fileAPI)
        XCTAssertNil(fixture.file.codemapLineCount)

        fixture.file.setCodeMap(validAPI)
        XCTAssertTrue(fixture.file.hasAcceptedCodeMap)

        fixture.file.setCodeMap(mismatchedAPI)
        XCTAssertFalse(fixture.file.hasAcceptedCodeMap)
        XCTAssertNil(fixture.file.fileAPI)
        XCTAssertNil(fixture.file.codemapLineCount)

        fixture.file.setCodeMap(replacementAPI)
        XCTAssertTrue(fixture.file.hasAcceptedCodeMap)
        XCTAssertEqual(fixture.file.fileAPI?.apiDescription, replacementAPI.apiDescription)
    }

    @MainActor
    func testFileTreeRenderingUsesAcceptedFlagWithoutRevalidatingFileAPI() {
        let fixture = makeFileFixture(useCountingFile: true)
        guard let file = fixture.file as? CountingFileViewModel else {
            return XCTFail("Expected counting file view model")
        }
        let validAPI = makeFileAPI(path: fixture.fileURL.path)

        file.setCodeMap(validAPI)
        XCTAssertTrue(file.hasAcceptedCodeMap)
        XCTAssertEqual(file.acceptsCodeMapCallCount, 1)

        let tree = CodeMapExtractor.generateFileTreeForRoots(
            rootFolders: [fixture.root],
            mode: "full",
            maxDepth: nil,
            includeHidden: true,
            filePathDisplay: .relative,
            selectedFileIDs: [],
            includeLegend: true,
            showCodeMapMarkers: true
        )

        XCTAssertTrue(tree.contains("sample.swift +"), tree)
        XCTAssertTrue(tree.contains("(+ denotes code-map available)"), tree)
        XCTAssertEqual(file.acceptsCodeMapCallCount, 1, "file-tree rendering should not re-run codemap validation")
    }

    @MainActor
    private func makeFileFixture(
        useCountingFile: Bool = false
    ) -> (rootURL: URL, fileURL: URL, root: FolderViewModel, file: FileViewModel) {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FileViewModelAcceptedCodeMapTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("sample.swift")
        let rootPath = rootURL.path
        let rootID = UUID()
        let date = Date(timeIntervalSince1970: 1000)
        let root = FolderViewModel(
            folder: Folder(name: rootURL.lastPathComponent, path: rootPath, modificationDate: date),
            rootPath: rootPath
        )
        let fileModel = File(name: "sample.swift", path: fileURL.path, modificationDate: date)
        let file: FileViewModel = if useCountingFile {
            CountingFileViewModel(
                file: fileModel,
                rootPath: rootPath,
                rootIdentifier: rootID,
                rootFolderPath: rootPath,
                fileSystemService: nil,
                parentFolder: root
            )
        } else {
            FileViewModel(
                file: fileModel,
                rootPath: rootPath,
                rootIdentifier: rootID,
                rootFolderPath: rootPath,
                fileSystemService: nil,
                parentFolder: root
            )
        }
        root.addFile(file)
        return (rootURL, fileURL, root, file)
    }

    private func makeFileAPI(path: String, symbol: String = "sampleSymbol") -> FileAPI {
        FileAPI(
            filePath: path,
            imports: [],
            classes: [],
            functions: [
                FunctionInfo(
                    name: symbol,
                    parameters: [],
                    returnType: nil,
                    definitionLine: "func \(symbol)()",
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

private final class CountingFileViewModel: FileViewModel {
    private(set) var acceptsCodeMapCallCount = 0

    override func acceptsCodeMap(_ codeMap: FileAPI) -> Bool {
        acceptsCodeMapCallCount += 1
        return super.acceptsCodeMap(codeMap)
    }
}
