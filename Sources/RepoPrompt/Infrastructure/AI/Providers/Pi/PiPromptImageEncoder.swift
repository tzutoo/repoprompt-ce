import Foundation
import UniformTypeIdentifiers

/// Encodes composer image attachments into pi RPC `ImageContent` payloads.
///
/// RPCE stores attachments as local files or URLs. pi RPC wants base64 + mimeType.
/// Keep this encoder independent of the session actor so tests can cover the
/// file/mime/size rules without launching pi.
enum PiPromptImageEncoder {
    static let maximumBytesPerImage = 8 * 1024 * 1024
    static let maximumImageCount = 8

    enum EncoderError: Error, LocalizedError, Equatable {
        case emptyAttachmentList
        case tooManyImages(count: Int)
        case unsupportedSource(String)
        case unreadableFile(String)
        case emptyFile(String)
        case tooLarge(path: String, byteCount: Int)
        case unsupportedType(String)
        case remoteURLNotSupported(String)

        var errorDescription: String? {
            switch self {
            case .emptyAttachmentList:
                "No image attachments were provided."
            case let .tooManyImages(count):
                "pi accepts at most \(maximumImageCount) images per turn (\(count) attached)."
            case let .unsupportedSource(detail):
                "Unsupported image attachment: \(detail)"
            case let .unreadableFile(path):
                "Could not read image file: \(path)"
            case let .emptyFile(path):
                "Image file is empty: \(path)"
            case let .tooLarge(path, byteCount):
                "Image is too large (\(byteCount) bytes, max \(maximumBytesPerImage)): \(path)"
            case let .unsupportedType(path):
                "Unsupported image type for pi: \(path). Use PNG, JPEG, GIF, or WebP."
            case let .remoteURLNotSupported(url):
                "pi image prompts currently support local files, not remote URLs (\(url))."
            }
        }
    }

    static func encode(_ attachments: [AgentImageAttachment]) throws -> [NativeAgentRuntimeImage] {
        guard !attachments.isEmpty else { return [] }
        guard attachments.count <= maximumImageCount else {
            throw EncoderError.tooManyImages(count: attachments.count)
        }
        return try attachments.map(encode)
    }

    static func encode(_ attachment: AgentImageAttachment) throws -> NativeAgentRuntimeImage {
        switch attachment.source {
        case let .url(rawURL):
            throw EncoderError.remoteURLNotSupported(rawURL)
        case let .localFile(path):
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            let mimeType = try mimeType(for: url)
            let data: Data
            do {
                data = try Data(contentsOf: url, options: [.mappedIfSafe])
            } catch {
                throw EncoderError.unreadableFile(url.path)
            }
            guard !data.isEmpty else {
                throw EncoderError.emptyFile(url.path)
            }
            guard data.count <= maximumBytesPerImage else {
                throw EncoderError.tooLarge(path: url.path, byteCount: data.count)
            }
            return NativeAgentRuntimeImage(data: data, mimeType: mimeType)
        }
    }

    static func mimeType(for url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png":
            return "image/png"
        case "jpg", "jpeg", "jpe", "jfif":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        default:
            if let type = UTType(filenameExtension: ext),
               let mime = type.preferredMIMEType,
               mime.hasPrefix("image/"),
               ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime)
            {
                return mime
            }
            throw EncoderError.unsupportedType(url.path)
        }
    }
}
