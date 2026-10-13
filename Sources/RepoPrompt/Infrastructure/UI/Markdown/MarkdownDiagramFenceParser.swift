import Foundation

/// One contiguous slice of a markdown transcript.
///
/// Complete Mermaid fences are split out so chat/agent markdown can render them
/// as diagrams while every other fence stays ordinary highlighted code.
enum MarkdownTranscriptSegment: Equatable {
    case markdown(String)
    case mermaid(String)

    var isMermaid: Bool {
        if case .mermaid = self { return true }
        return false
    }
}

enum MarkdownDiagramFenceParser {
    static let mermaidLanguageIDs: Set<String> = [
        "mermaid",
        "flowchart",
        "sequence",
        "sequencediagram"
    ]

    static func containsCompleteMermaidFence(in text: String) -> Bool {
        segments(in: text).contains(where: \.isMermaid)
    }

    static func segments(in text: String) -> [MarkdownTranscriptSegment] {
        guard !text.isEmpty else { return [.markdown(text)] }

        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        var segments: [MarkdownTranscriptSegment] = []
        var markdownStart = 0
        var index = 0

        while index < lines.count {
            let line = lines[index]
            guard let header = fenceHeader(line),
                  isMermaidLanguage(header.info)
            else {
                index += 1
                continue
            }

            guard let closeIndex = closingFenceIndex(
                in: lines,
                openingIndex: index,
                fenceCharacter: header.character,
                fenceLength: header.length
            ) else {
                index += 1
                continue
            }

            appendMarkdown(from: lines, start: markdownStart, end: index, into: &segments)
            let source = mermaidSource(from: lines, openingIndex: index, closingIndex: closeIndex)
            segments.append(.mermaid(source))
            markdownStart = closeIndex + 1
            index = closeIndex + 1
        }

        appendMarkdown(from: lines, start: markdownStart, end: lines.count, into: &segments)
        if segments.isEmpty {
            return [.markdown(text)]
        }
        return segments
    }

    private struct FenceHeader {
        let character: Character
        let length: Int
        let info: String
    }

    private static func fenceHeader(_ rawLine: Substring) -> FenceHeader? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let character: Character
        if line.hasPrefix("```") {
            character = "`"
        } else if line.hasPrefix("~~~") {
            character = "~"
        } else {
            return nil
        }

        var length = 0
        for scalar in line {
            if scalar == character {
                length += 1
            } else {
                break
            }
        }
        guard length >= 3 else { return nil }

        let info = String(line.dropFirst(length)).trimmingCharacters(in: .whitespaces)
        if character == "`", info.contains("`") {
            return nil
        }
        return FenceHeader(character: character, length: length, info: info)
    }

    private static func isMermaidLanguage(_ info: String) -> Bool {
        guard let token = info.split(whereSeparator: { $0.isWhitespace || $0 == "{" }).first else {
            return false
        }
        return mermaidLanguageIDs.contains(token.lowercased())
    }

    private static func closingFenceIndex(
        in lines: [Substring],
        openingIndex: Int,
        fenceCharacter: Character,
        fenceLength: Int
    ) -> Int? {
        var index = openingIndex + 1
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(String(repeating: String(fenceCharacter), count: fenceLength)) else {
                index += 1
                continue
            }

            var closeLength = 0
            for scalar in line {
                if scalar == fenceCharacter {
                    closeLength += 1
                } else {
                    break
                }
            }
            let remainder = line.dropFirst(closeLength)
            if closeLength >= fenceLength, remainder.allSatisfy(\.isWhitespace) {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func mermaidSource(
        from lines: [Substring],
        openingIndex: Int,
        closingIndex: Int
    ) -> String {
        guard openingIndex + 1 < closingIndex else { return "" }
        return lines[(openingIndex + 1) ..< closingIndex].joined(separator: "\n")
    }

    private static func appendMarkdown(
        from lines: [Substring],
        start: Int,
        end: Int,
        into segments: inout [MarkdownTranscriptSegment]
    ) {
        guard start < end, start < lines.count else { return }
        let sliceEnd = min(end, lines.count)
        let chunk = lines[start ..< sliceEnd].joined(separator: "\n")
        if chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        segments.append(.markdown(chunk))
    }
}

enum MermaidRenderPolicy {
    static let maxSourceCharacters = 16000
    static let minimumHeight: CGFloat = 360
    static let maximumHeight: CGFloat = 4000
    static let fallbackFitWidth: CGFloat = 800
    static let minimumZoom: CGFloat = 0.5
    static let maximumZoom: CGFloat = 4.0
    static let defaultZoom: CGFloat = 1.0
    static let mouseWheelZoomFactor: CGFloat = 1.04
    static let preciseZoomGain: CGFloat = 0.006
    static let pannableZoomSlop: CGFloat = 0.001

    static func shouldRender(_ source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maxSourceCharacters
    }

    static func clampedHeight(_ height: CGFloat) -> CGFloat {
        min(max(height, minimumHeight), maximumHeight)
    }

    static func clampedZoom(_ zoom: CGFloat) -> CGFloat {
        min(max(zoom, minimumZoom), maximumZoom)
    }

    /// Default view fills the Diagram card width and keeps the whole graphic visible.
    /// Mouse zoom can then enlarge past this fitted size.
    static func fitWidthScale(intrinsic: CGSize, containerWidth: CGFloat) -> CGFloat {
        guard containerWidth > 1, intrinsic.width > 1 else { return 1 }
        return containerWidth / intrinsic.width
    }

    static func isPannable(viewport: CGSize, content: CGSize) -> Bool {
        content.width > viewport.width + pannableZoomSlop
            || content.height > viewport.height + pannableZoomSlop
    }

    /// Visible card size for the full diagram at a readable scale.
    /// Zoom/pan happen inside this viewport so mouse interaction does not jump chat layout.
    /// Height of a width-fitted diagram. Until the SVG size is known, use a
    /// readable placeholder. Never invent a 1pt-wide canvas.
    static func fittedHeight(
        intrinsic: CGSize,
        zoom: CGFloat,
        containerWidth: CGFloat,
        assumedWidth: CGFloat = fallbackFitWidth
    ) -> CGFloat {
        let resolvedZoom = clampedZoom(zoom)
        guard intrinsic.width > 1, intrinsic.height > 1 else {
            return minimumHeight
        }
        let width = containerWidth > 1 ? containerWidth : assumedWidth
        let fitted = intrinsic.height * (width / intrinsic.width) * resolvedZoom
        return min(max(fitted, minimumHeight), maximumHeight)
    }

    static func viewportSize(
        intrinsic: CGSize,
        containerWidth: CGFloat
    ) -> CGSize {
        let content = contentSize(intrinsic: intrinsic, containerWidth: containerWidth, zoom: defaultZoom)
        return CGSize(
            width: max(containerWidth, content.width),
            height: content.height
        )
    }

    static func contentSize(
        intrinsic: CGSize,
        containerWidth: CGFloat,
        zoom: CGFloat
    ) -> CGSize {
        let width = max(containerWidth, 1)
        guard intrinsic.width > 1, intrinsic.height > 1 else {
            return CGSize(width: width, height: minimumHeight)
        }
        let scale = fitWidthScale(intrinsic: intrinsic, containerWidth: width) * clampedZoom(zoom)
        return CGSize(
            width: width * clampedZoom(zoom),
            height: min(intrinsic.height * scale, maximumHeight)
        )
    }

    /// How far the zoomed diagram can be dragged. Uses the scaled graphic, not the
    /// unzoomed box, so every edge remains reachable.
    static func panLimit(viewport: CGSize, zoom: CGFloat) -> CGSize {
        let resolvedZoom = clampedZoom(zoom)
        return CGSize(
            width: max(0, viewport.width * (resolvedZoom - 1) / 2),
            height: max(0, viewport.height * (resolvedZoom - 1) / 2)
        )
    }

    static func panLimit(viewport: CGSize, content: CGSize) -> CGSize {
        CGSize(
            width: max(0, (content.width - viewport.width) / 2),
            height: max(0, (content.height - viewport.height) / 2)
        )
    }

    static func clampedPan(_ pan: CGSize, viewport: CGSize, zoom: CGFloat) -> CGSize {
        let limit = panLimit(viewport: viewport, zoom: zoom)
        return CGSize(
            width: min(max(pan.width, -limit.width), limit.width),
            height: min(max(pan.height, -limit.height), limit.height)
        )
    }

    static func clampedPan(_ pan: CGSize, viewport: CGSize, content: CGSize) -> CGSize {
        let limit = panLimit(viewport: viewport, content: content)
        return CGSize(
            width: min(max(pan.width, -limit.width), limit.width),
            height: min(max(pan.height, -limit.height), limit.height)
        )
    }

    /// Positive `normalizedDeltaY` zooms in. Mouse wheels use discrete steps;
    /// trackpad pinches/scrolls use a continuous exponential gain.
    static func zoomFactor(normalizedDeltaY: CGFloat, hasPreciseDeltas: Bool) -> CGFloat {
        if hasPreciseDeltas {
            return exp(normalizedDeltaY * preciseZoomGain)
        }
        if normalizedDeltaY > 0 {
            return mouseWheelZoomFactor
        }
        if normalizedDeltaY < 0 {
            return 1 / mouseWheelZoomFactor
        }
        return 1
    }

    static func applyingZoom(
        _ zoom: CGFloat,
        currentZoom: CGFloat,
        pan: CGSize,
        anchor: CGPoint,
        viewport: CGSize,
        content: CGSize
    ) -> (zoom: CGFloat, pan: CGSize) {
        let newZoom = clampedZoom(zoom)
        let oldZoom = max(currentZoom, 0.0001)
        let center = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let newPan = CGSize(
            width: anchor.x - center.x - (anchor.x - center.x - pan.width) * newZoom / oldZoom,
            height: anchor.y - center.y - (anchor.y - center.y - pan.height) * newZoom / oldZoom
        )
        return (newZoom, clampedPan(newPan, viewport: viewport, zoom: newZoom))
    }
}

enum MermaidExportFormat: String, CaseIterable {
    case png
    case svg

    var fileExtension: String {
        rawValue
    }

    var defaultFileName: String {
        "diagram.\(rawValue)"
    }
}

enum MermaidExportPayload {
    static func svgDocument(from rawMarkup: String, intrinsic: CGSize) -> String? {
        let trimmed = rawMarkup.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("<svg") else { return nil }

        var svg = trimmed
        if svg.hasPrefix("<svg"), !svg.contains("xmlns=") {
            svg = svg.replacingOccurrences(
                of: "<svg",
                with: "<svg xmlns=\"http://www.w3.org/2000/svg\"",
                range: svg.startIndex ..< svg.index(svg.startIndex, offsetBy: 4)
            )
        }
        if intrinsic.width > 1, intrinsic.height > 1, !svg.contains("viewBox=") {
            let viewBox = "viewBox=\"0 0 \(intrinsic.width) \(intrinsic.height)\""
            svg = svg.replacingOccurrences(of: "<svg", with: "<svg \(viewBox)", range: svg.startIndex ..< svg.index(svg.startIndex, offsetBy: 4))
        }
        return svg
    }
}
