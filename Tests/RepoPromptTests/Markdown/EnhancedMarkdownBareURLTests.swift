import AppKit
import Markdown
@testable import RepoPromptApp
import XCTest

final class EnhancedMarkdownBareURLTests: XCTestCase {
    func testBareProseURLLinksOnlyWhenPolicyEnabled() {
        let disabled = compile("Visit https://example.com", policy: .disabled)
        XCTAssertTrue(linkedSubstrings(in: disabled).isEmpty)

        let enabled = compile("Visit https://example.com", policy: .httpHTTPSOnly)
        XCTAssertEqual(linkedSubstrings(in: enabled), ["https://example.com"])
    }

    func testExplicitMarkdownLinkStillWorksWhenBareURLPolicyDisabled() throws {
        let attributed = compile("Visit [the docs](https://example.com/docs)", policy: .disabled)

        XCTAssertEqual(linkedSubstrings(in: attributed), ["the docs"])
        let rawRange = try XCTUnwrap(linkRanges(in: attributed).first)
        XCTAssertEqual(
            attributed.attribute(.markdownRawLink, at: rawRange.location, effectiveRange: nil) as? String,
            "https://example.com/docs"
        )
    }

    func testInlineCodeURLDoesNotBecomeBareLink() {
        let attributed = compile("Inline `https://code.example` then https://prose.example", policy: .httpHTTPSOnly)

        XCTAssertEqual(linkedSubstrings(in: attributed), ["https://prose.example"])
    }

    func testFencedCodeBlockURLDoesNotBecomeBareLink() {
        let markdown = """
        ```
        curl https://code.example
        ```

        Prose https://prose.example
        """
        let attributed = compile(markdown, policy: .httpHTTPSOnly)

        XCTAssertEqual(linkedSubstrings(in: attributed), ["https://prose.example"])
    }

    func testPreviewLikeMarkdownProtectsInlineAndFencedCodeURLs() {
        let markdown = """
        Inline `https://inline-code.example` stays code.

        ```bash
        curl https://fenced-code.example
        ```

        Prose https://prose.example.
        """
        let attributed = compile(markdown, policy: .httpHTTPSOnly, suppressBareLinksTouchingEndBoundary: true)

        XCTAssertEqual(linkedSubstrings(in: attributed), ["https://prose.example"])
    }

    func testPreviewBoundarySuppressionRemovesBareURLAtDocumentEnd() {
        let completeBeforeBoundary = compile(
            "Prose https://example.com.",
            policy: .httpHTTPSOnly,
            suppressBareLinksTouchingEndBoundary: true
        )
        XCTAssertEqual(linkedSubstrings(in: completeBeforeBoundary), ["https://example.com"])

        let touchingBoundary = compile(
            "Prose https://example.com",
            policy: .httpHTTPSOnly,
            suppressBareLinksTouchingEndBoundary: true
        )
        XCTAssertTrue(linkedSubstrings(in: touchingBoundary).isEmpty)

        assertSuppressedBareURLIsNotVisuallyMarked(touchingBoundary, urlText: "https://example.com")
    }

    func testExplicitMarkdownLinkAtDocumentEndSurvivesBoundarySuppression() throws {
        let attributed = compile(
            "Visit [the docs](https://example.com/docs)",
            policy: .httpHTTPSOnly,
            suppressBareLinksTouchingEndBoundary: true
        )
        let linkRange = try XCTUnwrap(linkRanges(in: attributed).first)

        XCTAssertEqual(linkedSubstrings(in: attributed), ["the docs"])
        XCTAssertEqual(
            attributed.attribute(.markdownRawLink, at: linkRange.location, effectiveRange: nil) as? String,
            "https://example.com/docs"
        )
        XCTAssertNil(attributed.attribute(.repoPromptBareURLLink, at: linkRange.location, effectiveRange: nil))
    }

    func testExplicitMarkdownLinkWithURLLabelSurvivesBoundarySuppression() throws {
        let attributed = compile(
            "[https://example.com](https://example.com/docs)",
            policy: .httpHTTPSOnly,
            suppressBareLinksTouchingEndBoundary: true
        )
        let linkRange = try XCTUnwrap(linkRanges(in: attributed).first)

        XCTAssertEqual(linkedSubstrings(in: attributed), ["https://example.com"])
        XCTAssertEqual(
            attributed.attribute(.markdownRawLink, at: linkRange.location, effectiveRange: nil) as? String,
            "https://example.com/docs"
        )
        XCTAssertNil(attributed.attribute(.repoPromptBareURLLink, at: linkRange.location, effectiveRange: nil))
    }

    func testImageGeneratedLinkAtDocumentEndSurvivesBoundarySuppression() throws {
        let attributed = compile(
            "![Diagram](https://example.com/image.png)",
            policy: .httpHTTPSOnly,
            suppressBareLinksTouchingEndBoundary: true
        )
        let linkRange = try XCTUnwrap(linkRanges(in: attributed).first)

        XCTAssertEqual(linkedSubstrings(in: attributed), ["Diagram (example.com)"])
        XCTAssertNil(attributed.attribute(.repoPromptBareURLLink, at: linkRange.location, effectiveRange: nil))
    }

    func testSymbolGeneratedLinkDoesNotReceiveBareURLMarker() throws {
        let attributed = compile(
            "``https://example.com/symbol``",
            policy: .httpHTTPSOnly,
            suppressBareLinksTouchingEndBoundary: true,
            options: .parseSymbolLinks
        )
        let linkRange = try XCTUnwrap(linkRanges(in: attributed).first)

        XCTAssertEqual(linkedSubstrings(in: attributed), ["https://example.com/symbol"])
        XCTAssertNil(attributed.attribute(.repoPromptBareURLLink, at: linkRange.location, effectiveRange: nil))
    }

    @MainActor
    func testMarkdownWebLinkClickFallsThroughToAppKitDefaultOpening() throws {
        let attributed = compile("Visit https://example.com", policy: .httpHTTPSOnly)
        let linkRange = try XCTUnwrap(linkRanges(in: attributed).first)
        let textView = NSTextView()
        textView.textStorage?.setAttributedString(attributed)
        let coordinator = MarkdownTextViewCoordinator()

        XCTAssertFalse(try coordinator.textView(textView, clickedOnLink: XCTUnwrap(URL(string: "https://example.com")), at: linkRange.location))
    }

    func testRenderSignatureConfigurationIncludesBareURLPolicy() {
        let disabled = MarkdownRenderSignature(
            text: "https://example.com",
            fontSize: 13,
            forceTextColor: nil,
            useMonospaced: false,
            bareURLLinkificationPolicy: .disabled
        )
        let enabled = MarkdownRenderSignature(
            text: "https://example.com",
            fontSize: 13,
            forceTextColor: nil,
            useMonospaced: false,
            bareURLLinkificationPolicy: .httpHTTPSOnly
        )

        XCTAssertNotEqual(disabled, enabled)
        XCTAssertFalse(disabled.hasSameRenderingConfiguration(as: enabled))
        XCTAssertNil(MarkdownStreamingAppendDelta.between(previous: disabled, requested: enabled))
    }

    func testRenderSignatureConfigurationIncludesBoundarySuppression() {
        let ordinary = MarkdownRenderSignature(
            text: "https://example.com",
            fontSize: 13,
            forceTextColor: nil,
            useMonospaced: false,
            bareURLLinkificationPolicy: .httpHTTPSOnly
        )
        let preview = MarkdownRenderSignature(
            text: "https://example.com",
            fontSize: 13,
            forceTextColor: nil,
            useMonospaced: false,
            bareURLLinkificationPolicy: .httpHTTPSOnly,
            suppressBareLinksTouchingEndBoundary: true
        )

        XCTAssertNotEqual(ordinary, preview)
        XCTAssertFalse(ordinary.hasSameRenderingConfiguration(as: preview))
        XCTAssertNil(MarkdownStreamingAppendDelta.between(previous: ordinary, requested: preview))
    }

    private func assertSuppressedBareURLIsNotVisuallyMarked(
        _ attributed: NSAttributedString,
        urlText: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let range = (attributed.string as NSString).range(of: urlText)
        XCTAssertNotEqual(range.location, NSNotFound, file: file, line: line)
        guard range.location != NSNotFound else { return }

        XCTAssertNil(attributed.attribute(.link, at: range.location, effectiveRange: nil), file: file, line: line)
        XCTAssertNil(attributed.attribute(.repoPromptBareURLLink, at: range.location, effectiveRange: nil), file: file, line: line)
        XCTAssertNil(attributed.attribute(.underlineStyle, at: range.location, effectiveRange: nil), file: file, line: line)
        let foregroundColor = attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        XCTAssertFalse(foregroundColor?.isEqual(NSColor.linkColor) ?? false, file: file, line: line)
    }

    private func compile(
        _ markdown: String,
        policy: BareURLLinkificationPolicy,
        suppressBareLinksTouchingEndBoundary: Bool = false,
        options: ParseOptions = []
    ) -> NSAttributedString {
        var compiler = EnhancedMarkdownCompiler()
        compiler.fontSize = 13
        compiler.bareURLLinkificationPolicy = policy
        compiler.suppressBareLinksTouchingEndBoundary = suppressBareLinksTouchingEndBoundary
        return compiler.attributedString(from: Document(parsing: markdown, options: options))
    }
}

final class MarkdownDiagramFenceParserTests: XCTestCase {
    func testPlainMarkdownStaysOneSegment() {
        let segments = MarkdownDiagramFenceParser.segments(in: "Hello **world**")
        XCTAssertEqual(segments, [.markdown("Hello **world**")])
        XCTAssertFalse(MarkdownDiagramFenceParser.containsCompleteMermaidFence(in: "Hello **world**"))
    }

    func testCompleteMermaidFenceSplitsOutOfSurroundingProse() {
        let markdown = """
        Before

        ```mermaid
        flowchart LR
          A --> B
        ```

        After
        """
        let segments = MarkdownDiagramFenceParser.segments(in: markdown)

        XCTAssertEqual(segments.count, 3)
        guard case let .markdown(before) = segments[0] else {
            return XCTFail("expected leading markdown")
        }
        XCTAssertEqual(before.trimmingCharacters(in: .whitespacesAndNewlines), "Before")
        XCTAssertEqual(segments[1], .mermaid("flowchart LR\n  A --> B"))
        guard case let .markdown(after) = segments[2] else {
            return XCTFail("expected trailing markdown")
        }
        XCTAssertEqual(after.trimmingCharacters(in: .whitespacesAndNewlines), "After")
        XCTAssertTrue(MarkdownDiagramFenceParser.containsCompleteMermaidFence(in: markdown))
    }

    func testUnclosedMermaidFenceStaysOrdinaryMarkdown() {
        let markdown = """
        ```mermaid
        sequenceDiagram
          Alice->>Bob: Hello
        """
        XCTAssertEqual(
            MarkdownDiagramFenceParser.segments(in: markdown),
            [.markdown(markdown)]
        )
        XCTAssertFalse(MarkdownDiagramFenceParser.containsCompleteMermaidFence(in: markdown))
    }

    func testNonMermaidFenceIsNotADiagram() {
        let markdown = """
        ```swift
        print("hi")
        ```
        """
        XCTAssertEqual(
            MarkdownDiagramFenceParser.segments(in: markdown),
            [.markdown(markdown)]
        )
    }

    func testLanguageAliasesAndTildeFencesAreAccepted() {
        let cases = [
            ("mermaid", "```"),
            ("MERMAID", "```"),
            ("flowchart", "```"),
            ("sequenceDiagram", "~~~")
        ]

        for (language, fence) in cases {
            let markdown = """
            \(fence)\(language)
            flowchart TD
              X --> Y
            \(fence)
            """
            let segments = MarkdownDiagramFenceParser.segments(in: markdown)
            XCTAssertEqual(segments, [.mermaid("flowchart TD\n  X --> Y")], language)
        }
    }

    func testInlineBackticksAreNotTreatedAsFences() {
        let markdown = "Use `mermaid` in a ``` code span"
        XCTAssertEqual(
            MarkdownDiagramFenceParser.segments(in: markdown),
            [.markdown(markdown)]
        )
    }

    func testMultipleMermaidFencesPreserveSwiftCodeBetweenThem() {
        let markdown = """
        ```mermaid
        pie title Pets
          \"Cats\": 2
        ```

        ```swift
        let value = 1
        ```

        ```mermaid
        sequenceDiagram
          A->>B: ping
        ```
        """
        let segments = MarkdownDiagramFenceParser.segments(in: markdown)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0], .mermaid("pie title Pets\n  \"Cats\": 2"))
        guard case let .markdown(swiftChunk) = segments[1] else {
            return XCTFail("expected swift code to remain markdown")
        }
        XCTAssertTrue(swiftChunk.contains("```swift"))
        XCTAssertTrue(swiftChunk.contains("let value = 1"))
        XCTAssertEqual(segments[2], .mermaid("sequenceDiagram\n  A->>B: ping"))
    }

    func testEmptyAndOversizedSourcesAreRejected() {
        XCTAssertFalse(MermaidRenderPolicy.shouldRender("   \n"))
        XCTAssertFalse(MermaidRenderPolicy.shouldRender(String(repeating: "A", count: MermaidRenderPolicy.maxSourceCharacters + 1)))
        XCTAssertTrue(MermaidRenderPolicy.shouldRender("flowchart LR\nA --> B"))
    }

    func testHeightIsClampedToVisibleBounds() {
        XCTAssertEqual(MermaidRenderPolicy.clampedHeight(10), MermaidRenderPolicy.minimumHeight)
        XCTAssertEqual(MermaidRenderPolicy.clampedHeight(9000), MermaidRenderPolicy.maximumHeight)
        XCTAssertEqual(MermaidRenderPolicy.clampedHeight(400), 400)
    }

    func testFittedHeightUsesCardWidthAndDoesNotShrinkBelowMinimum() {
        let wide = MermaidRenderPolicy.fittedHeight(
            intrinsic: CGSize(width: 400, height: 200),
            zoom: 1,
            containerWidth: 800
        )
        let unknownWidth = MermaidRenderPolicy.fittedHeight(
            intrinsic: CGSize(width: 400, height: 200),
            zoom: 1,
            containerWidth: 0
        )
        let short = MermaidRenderPolicy.fittedHeight(
            intrinsic: CGSize(width: 1200, height: 200),
            zoom: 1,
            containerWidth: 400
        )

        XCTAssertEqual(wide, 400)
        XCTAssertEqual(unknownWidth, 400)
        XCTAssertEqual(short, MermaidRenderPolicy.minimumHeight)
    }

    func testContentSizeUsesPlaceholderUntilContainerWidthIsKnown() {
        let size = MermaidRenderPolicy.contentSize(
            intrinsic: CGSize(width: 400, height: 200),
            containerWidth: 0,
            zoom: 1
        )

        XCTAssertEqual(size.width, 1)
        XCTAssertEqual(size.height, 200)
    }

    func testWideDiagramFitsCardWidthAndKeepsFullGraphicVisible() {
        let viewport = MermaidRenderPolicy.viewportSize(
            intrinsic: CGSize(width: 1200, height: 800),
            containerWidth: 400
        )
        let content = MermaidRenderPolicy.contentSize(
            intrinsic: CGSize(width: 1200, height: 800),
            containerWidth: 400,
            zoom: 1
        )

        XCTAssertEqual(viewport.width, 400)
        XCTAssertEqual(viewport.height, 800 * 400 / 1200, accuracy: 0.001)
        XCTAssertEqual(content, viewport)
        XCTAssertFalse(MermaidRenderPolicy.isPannable(viewport: viewport, content: content))
    }

    func testNarrowDiagramScalesUpToFillWiderChat() {
        let viewport = MermaidRenderPolicy.viewportSize(
            intrinsic: CGSize(width: 400, height: 200),
            containerWidth: 800
        )

        XCTAssertEqual(viewport, CGSize(width: 800, height: 400))
        XCTAssertFalse(
            MermaidRenderPolicy.isPannable(
                viewport: viewport,
                content: MermaidRenderPolicy.contentSize(
                    intrinsic: CGSize(width: 400, height: 200),
                    containerWidth: 800,
                    zoom: 1
                )
            )
        )
    }

    func testContentSizeGrowsWhenZoomingInAndShrinksWhenZoomingOut() {
        let zoomedIn = MermaidRenderPolicy.contentSize(
            intrinsic: CGSize(width: 400, height: 200),
            containerWidth: 400,
            zoom: 2
        )
        let zoomedOut = MermaidRenderPolicy.contentSize(
            intrinsic: CGSize(width: 400, height: 200),
            containerWidth: 400,
            zoom: 0.5
        )

        XCTAssertEqual(zoomedIn, CGSize(width: 800, height: 400))
        XCTAssertEqual(zoomedOut, CGSize(width: 200, height: 100))
    }

    func testZoomIsClampedToAllowedRange() {
        XCTAssertEqual(MermaidRenderPolicy.clampedZoom(0.1), MermaidRenderPolicy.minimumZoom)
        XCTAssertEqual(MermaidRenderPolicy.clampedZoom(8), MermaidRenderPolicy.maximumZoom)
    }

    func testMouseWheelZoomUsesDiscreteSteps() {
        XCTAssertEqual(
            MermaidRenderPolicy.zoomFactor(normalizedDeltaY: 1, hasPreciseDeltas: false),
            MermaidRenderPolicy.mouseWheelZoomFactor,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MermaidRenderPolicy.zoomFactor(normalizedDeltaY: -1, hasPreciseDeltas: false),
            1 / MermaidRenderPolicy.mouseWheelZoomFactor,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MermaidRenderPolicy.zoomFactor(normalizedDeltaY: 0, hasPreciseDeltas: false),
            1,
            accuracy: 0.0001
        )
    }

    func testPanIsClampedToZoomedOverflow() {
        let viewport = CGSize(width: 400, height: 200)
        XCTAssertEqual(
            MermaidRenderPolicy.clampedPan(
                CGSize(width: 80, height: 40),
                viewport: viewport,
                zoom: 1
            ),
            .zero
        )
        XCTAssertEqual(
            MermaidRenderPolicy.clampedPan(
                CGSize(width: 500, height: 500),
                viewport: viewport,
                zoom: 2
            ),
            CGSize(width: 200, height: 100)
        )
    }

    func testZoomedPanCanReachEveryEdge() {
        let viewport = CGSize(width: 400, height: 240)
        let limit = MermaidRenderPolicy.panLimit(viewport: viewport, zoom: 3)

        XCTAssertEqual(limit.width, 400)
        XCTAssertEqual(limit.height, 240)
        XCTAssertEqual(
            MermaidRenderPolicy.clampedPan(
                CGSize(width: 0, height: -1000),
                viewport: viewport,
                zoom: 3
            ).height,
            -240
        )
    }

    func testZoomKeepsTheCursorAnchorStationary() {
        let next = MermaidRenderPolicy.applyingZoom(
            2,
            currentZoom: 1,
            pan: .zero,
            anchor: CGPoint(x: 100, y: 40),
            viewport: CGSize(width: 400, height: 200),
            content: CGSize(width: 400, height: 200)
        )

        XCTAssertEqual(next.zoom, 2)
        XCTAssertEqual(next.pan.width, 100, accuracy: 0.001)
        XCTAssertEqual(next.pan.height, 60, accuracy: 0.001)
    }

    func testSVGExportAddsNamespaceAndViewBox() {
        let svg = MermaidExportPayload.svgDocument(
            from: "<svg width=\"10\" height=\"20\"></svg>",
            intrinsic: CGSize(width: 10, height: 20)
        )

        XCTAssertEqual(
            svg,
            "<svg viewBox=\"0 0 10.0 20.0\" xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"20\"></svg>"
        )
    }

    func testNonSVGMarkupIsRejectedForExport() {
        XCTAssertNil(MermaidExportPayload.svgDocument(from: "flowchart LR", intrinsic: .zero))
    }
}
