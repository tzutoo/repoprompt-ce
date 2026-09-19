import Foundation
@testable import RepoPromptApp
import XCTest

final class PiPromptImageEncoderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpce-pi-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testEncodesLocalPNGAsNativeImage() throws {
        let url = directory.appendingPathComponent("icon.png")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01, 0x02])
        try png.write(to: url)
        let encoded = try PiPromptImageEncoder.encode(
            AgentImageAttachment(source: .localFile(path: url.path), title: "icon")
        )
        XCTAssertEqual(encoded.mimeType, "image/png")
        XCTAssertEqual(encoded.data, png)
    }

    func testRejectsUnsupportedExtension() throws {
        let url = directory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: url)
        XCTAssertThrowsError(
            try PiPromptImageEncoder.encode(AgentImageAttachment(source: .localFile(path: url.path)))
        ) { error in
            guard case PiPromptImageEncoder.EncoderError.unsupportedType = error else {
                return XCTFail("Expected unsupportedType, got \(error)")
            }
        }
    }

    func testRejectsRemoteURL() {
        XCTAssertThrowsError(
            try PiPromptImageEncoder.encode(
                AgentImageAttachment(source: .url("https://example.com/a.png"))
            )
        ) { error in
            guard case PiPromptImageEncoder.EncoderError.remoteURLNotSupported = error else {
                return XCTFail("Expected remoteURLNotSupported, got \(error)")
            }
        }
    }

    func testRejectsTooManyImages() throws {
        let url = directory.appendingPathComponent("icon.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        let attachments = (0 ..< 9).map { _ in
            AgentImageAttachment(source: .localFile(path: url.path))
        }
        XCTAssertThrowsError(try PiPromptImageEncoder.encode(attachments)) { error in
            guard case PiPromptImageEncoder.EncoderError.tooManyImages = error else {
                return XCTFail("Expected tooManyImages, got \(error)")
            }
        }
    }
}
