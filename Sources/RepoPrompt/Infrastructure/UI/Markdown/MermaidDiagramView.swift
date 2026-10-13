import AppKit
import SwiftUI
import WebKit

private struct MermaidDiagramWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Renders a complete Mermaid fence as a diagram, with source fallback.
struct MermaidDiagramCard: View {
    let source: String
    let allowInteraction: Bool

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var fontScale = FontScaleManager.shared
    @State private var showSource = false
    @State private var containerWidth: CGFloat = 0
    @State private var intrinsicSize: CGSize = .zero
    @State private var zoom: CGFloat = MermaidRenderPolicy.defaultZoom
    @State private var pan: CGSize = .zero
    @State private var renderError: String?
    @StateObject private var exporter = MermaidExportHandle()

    private var theme: String {
        colorScheme == .dark ? "dark" : "default"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if showSource || !MermaidRenderPolicy.shouldRender(source) || renderError != nil {
                sourceFallback
            } else {
                MermaidCanvasView(
                    source: source,
                    theme: theme,
                    zoom: $zoom,
                    pan: $pan,
                    intrinsicSize: $intrinsicSize,
                    onError: { renderError = $0 },
                    exporter: exporter
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: canvasHeight)
                .clipped()
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: MermaidDiagramWidthPreferenceKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(MermaidDiagramWidthPreferenceKey.self) { width in
            guard width > 1, abs(containerWidth - width) > 0.5 else { return }
            containerWidth = width
        }
        .onChange(of: source) { _, _ in
            resetRenderState()
        }
        .onChange(of: theme) { _, _ in
            resetRenderState()
        }
    }

    private var canvasHeight: CGFloat {
        MermaidRenderPolicy.fittedHeight(
            intrinsic: intrinsicSize,
            zoom: MermaidRenderPolicy.defaultZoom,
            containerWidth: containerWidth
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Diagram")
                .font(fontScale.preset.captionFont)
                .foregroundColor(.secondary)
            Spacer(minLength: 8)
            if MermaidRenderPolicy.shouldRender(source) {
                Button(showSource ? "Show diagram" : "Show source") {
                    showSource.toggle()
                }
                .buttonStyle(.plain)
                .font(fontScale.preset.captionFont)
                .foregroundColor(.secondary)
            }
            Menu("Save") {
                Button("PNG Image") {
                    saveDiagram(.png)
                }
                Button("SVG Vector") {
                    saveDiagram(.svg)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(fontScale.preset.captionFont)
            .foregroundColor(.secondary)
            .disabled(!allowInteraction || renderError != nil || showSource)
            Button("Copy") {
                copySource()
            }
            .buttonStyle(.plain)
            .font(fontScale.preset.captionFont)
            .foregroundColor(.secondary)
            .disabled(!allowInteraction)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mermaid diagram")
    }

    private var sourceFallback: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let renderError {
                Text(renderError)
                    .font(fontScale.preset.captionFont)
                    .foregroundColor(.secondary)
            } else if !MermaidRenderPolicy.shouldRender(source) {
                Text(
                    source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Diagram source is empty."
                        : "Diagram source is too large to render."
                )
                .font(fontScale.preset.captionFont)
                .foregroundColor(.secondary)
            }
            Text(source)
                .font(.system(size: max(CGFloat(fontScale.preset.rawValue) - 1, 10), design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func resetRenderState() {
        renderError = nil
        intrinsicSize = .zero
        zoom = MermaidRenderPolicy.defaultZoom
        pan = .zero
        if !MermaidRenderPolicy.shouldRender(source) {
            showSource = true
        }
    }

    private func copySource() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source, forType: .string)
    }

    private func saveDiagram(_ format: MermaidExportFormat) {
        Task { @MainActor in
            do {
                let markup = try await exporter.svgMarkup()
                let data: Data
                switch format {
                case .svg:
                    guard let svg = MermaidExportPayload.svgDocument(from: markup, intrinsic: intrinsicSize),
                          let svgData = svg.data(using: .utf8)
                    else {
                        throw MermaidRenderError.renderFailed("Could not build an SVG document.")
                    }
                    data = svgData
                case .png:
                    guard let pngData = MermaidPNGExport.pngData(from: markup, intrinsic: intrinsicSize) else {
                        throw MermaidRenderError.renderFailed("Could not convert the diagram to PNG.")
                    }
                    data = pngData
                }
                presentSavePanel(format: format, data: data)
            } catch {
                renderError = error.localizedDescription
            }
        }
    }

    private func presentSavePanel(format: MermaidExportFormat, data: Data) {
        let panel = NSSavePanel()
        panel.title = "Save Diagram"
        panel.prompt = "Save"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = format.defaultFileName
        panel.allowedContentTypes = format == .png ? [.png] : [.svg]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            renderError = error.localizedDescription
        }
    }
}

enum MermaidPNGExport {
    static func pngData(from svgMarkup: String, intrinsic: CGSize, scale: CGFloat = 2) -> Data? {
        guard let svg = MermaidExportPayload.svgDocument(from: svgMarkup, intrinsic: intrinsic),
              let svgData = svg.data(using: .utf8),
              let image = NSImage(data: svgData)
        else {
            return nil
        }

        let pixelWidth = max(1, Int((max(intrinsic.width, image.size.width) * scale).rounded()))
        let pixelHeight = max(1, Int((max(intrinsic.height, image.size.height) * scale).rounded()))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        bitmap.size = NSSize(width: pixelWidth, height: pixelHeight)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight).fill()
        image.draw(
            in: NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}

@MainActor
final class MermaidExportHandle: ObservableObject {
    weak var coordinator: MermaidCanvasCoordinator?

    func svgMarkup() async throws -> String {
        guard let coordinator else {
            throw MermaidRenderError.renderFailed("Diagram renderer is unavailable.")
        }
        return try await coordinator.exportSVGMarkup()
    }
}

private struct MermaidCanvasView: NSViewRepresentable {
    let source: String
    let theme: String
    @Binding var zoom: CGFloat
    @Binding var pan: CGSize
    @Binding var intrinsicSize: CGSize
    let onError: (String) -> Void
    let exporter: MermaidExportHandle

    func makeCoordinator() -> MermaidCanvasCoordinator {
        MermaidCanvasCoordinator()
    }

    func makeNSView(context: Context) -> MermaidCanvasHostView {
        let view = MermaidCanvasHostView()
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: MermaidCanvasHostView, context: Context) {
        context.coordinator.zoomBinding = $zoom
        context.coordinator.panBinding = $pan
        context.coordinator.intrinsicBinding = $intrinsicSize
        context.coordinator.onError = onError
        exporter.coordinator = context.coordinator
        view.coordinator = context.coordinator
        view.applyCamera(zoom: zoom, pan: pan)
        context.coordinator.render(source: source, theme: theme)
    }

    static func dismantleNSView(_ view: MermaidCanvasHostView, coordinator: MermaidCanvasCoordinator) {
        coordinator.cancel()
        view.coordinator = nil
    }
}

final class MermaidCanvasCoordinator: NSObject, WKNavigationDelegate {
    weak var host: MermaidCanvasHostView?
    var zoomBinding: Binding<CGFloat>?
    var panBinding: Binding<CGSize>?
    var intrinsicBinding: Binding<CGSize>?
    var onError: ((String) -> Void)?

    private var pendingSource: String?
    private var pendingTheme: String?
    private var renderedSource: String?
    private var renderedTheme: String?
    private var pageReady = false
    private var inFlight = false
    private var generation: UInt64 = 0

    func attach(_ host: MermaidCanvasHostView) {
        self.host = host
        host.webView.navigationDelegate = self
        host.coordinator = self
    }

    func render(source: String, theme: String) {
        pendingSource = source
        pendingTheme = theme
        guard pageReady, !inFlight else { return }
        renderPending()
    }

    func cancel() {
        generation &+= 1
        inFlight = false
        pendingSource = nil
        pendingTheme = nil
        host?.webView.navigationDelegate = nil
        host?.webView.stopLoading()
    }

    func exportSVGMarkup() async throws -> String {
        guard let webView = host?.webView else {
            throw MermaidRenderError.renderFailed("Diagram renderer is unavailable.")
        }
        let result = try await webView.callAsyncJavaScript(
            "return document.querySelector('#host svg')?.outerHTML ?? '';",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        guard let markup = result as? String, markup.contains("<svg") else {
            throw MermaidRenderError.renderFailed("Could not read the rendered SVG.")
        }
        return markup
    }

    func applyZoom(deltaY: CGFloat, hasPreciseDeltas: Bool, anchor: CGPoint) {
        guard let host else { return }
        let current = zoomBinding?.wrappedValue ?? MermaidRenderPolicy.defaultZoom
        let pan = panBinding?.wrappedValue ?? .zero
        let factor = MermaidRenderPolicy.zoomFactor(
            normalizedDeltaY: deltaY,
            hasPreciseDeltas: hasPreciseDeltas
        )
        let viewport = host.bounds.size
        let next = MermaidRenderPolicy.applyingZoom(
            current * factor,
            currentZoom: current,
            pan: pan,
            anchor: anchor,
            viewport: viewport,
            content: CGSize(width: viewport.width * current, height: viewport.height * current)
        )
        zoomBinding?.wrappedValue = next.zoom
        panBinding?.wrappedValue = next.pan
        host.applyCamera(zoom: next.zoom, pan: next.pan)
    }

    func applyPan(_ delta: CGSize) {
        guard let host else { return }
        let zoom = zoomBinding?.wrappedValue ?? MermaidRenderPolicy.defaultZoom
        let next = MermaidRenderPolicy.clampedPan(
            CGSize(
                width: (panBinding?.wrappedValue.width ?? 0) + delta.width,
                height: (panBinding?.wrappedValue.height ?? 0) + delta.height
            ),
            viewport: host.bounds.size,
            zoom: zoom
        )
        panBinding?.wrappedValue = next
        host.applyCamera(zoom: zoom, pan: next)
    }

    func resetCamera() {
        zoomBinding?.wrappedValue = MermaidRenderPolicy.defaultZoom
        panBinding?.wrappedValue = .zero
        host?.applyCamera(zoom: MermaidRenderPolicy.defaultZoom, pan: .zero)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        renderPending()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        if navigationAction.navigationType == .other,
           url?.scheme == "about" || url?.isFileURL == true || url == nil
        {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onError?(error.localizedDescription)
    }

    private func renderPending() {
        guard let webView = host?.webView else { return }
        guard let source = pendingSource, let theme = pendingTheme else { return }
        if source == renderedSource, theme == renderedTheme {
            return
        }
        guard MermaidRenderPolicy.shouldRender(source) else {
            onError?("Diagram source cannot be rendered.")
            return
        }
        guard MermaidWebRuntime.isAvailable else {
            onError?("Diagram renderer is unavailable in this build.")
            return
        }

        inFlight = true
        generation &+= 1
        let currentGeneration = generation
        let diagramID = "rpceMermaid" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        Task { @MainActor in
            defer {
                if currentGeneration == self.generation {
                    self.inFlight = false
                    self.renderPending()
                }
            }
            do {
                let result = try await webView.callAsyncJavaScript(
                    "return await rpceRender(source, theme, id);",
                    arguments: [
                        "source": source,
                        "theme": theme,
                        "id": diagramID
                    ],
                    in: nil,
                    contentWorld: .page
                )
                guard currentGeneration == self.generation else { return }
                let size = try Self.size(from: result)
                self.renderedSource = source
                self.renderedTheme = theme
                if self.pendingSource == source, self.pendingTheme == theme {
                    self.pendingSource = nil
                    self.pendingTheme = nil
                }
                self.intrinsicBinding?.wrappedValue = size
            } catch {
                guard currentGeneration == self.generation else { return }
                self.onError?("Could not render diagram: \(error.localizedDescription)")
            }
        }
    }

    private static func size(from result: Any?) throws -> CGSize {
        let dictionary = result as? [String: Any]
        let width = cgFloat(dictionary?["width"]) ?? 0
        let height = cgFloat(dictionary?["height"]) ?? 0
        guard width > 1, height > 1 else {
            throw MermaidRenderError.renderFailed("Diagram produced an empty graphic.")
        }
        return CGSize(width: width, height: height)
    }

    private static func cgFloat(_ value: Any?) -> CGFloat? {
        if let number = value as? NSNumber {
            return CGFloat(truncating: number)
        }
        if let value = value as? Double {
            return CGFloat(value)
        }
        if let value = value as? CGFloat {
            return value
        }
        return nil
    }
}

final class MermaidCanvasHostView: NSView {
    let webView: WKWebView
    weak var coordinator: MermaidCanvasCoordinator?

    private var lastDragLocation: NSPoint?

    override var isFlipped: Bool {
        true
    }

    override var isOpaque: Bool {
        false
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        webView = WKWebView(frame: .zero, configuration: MermaidWebRuntime.makeConfiguration())
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        webView.underPageBackgroundColor = .clear
        webView.isInspectable = false
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")
        addSubview(webView)
        webView.loadHTMLString(MermaidWebRuntime.pageHTML, baseURL: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    func applyCamera(zoom: CGFloat, pan: CGSize) {
        let resolvedZoom = MermaidRenderPolicy.clampedZoom(zoom)
        webView.frame = bounds
        webView.evaluateJavaScript(
            "rpceSetCamera(\(resolvedZoom), \(pan.width), \(pan.height));",
            completionHandler: nil
        )
    }

    override func resetCursorRects() {
        let zoom = coordinator?.zoomBinding?.wrappedValue ?? MermaidRenderPolicy.defaultZoom
        addCursorRect(bounds, cursor: zoom > MermaidRenderPolicy.defaultZoom + 0.001 ? .openHand : .arrow)
    }

    override func scrollWheel(with event: NSEvent) {
        coordinator?.applyZoom(
            deltaY: event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            anchor: convert(event.locationInWindow, from: nil)
        )
    }

    override func magnify(with event: NSEvent) {
        coordinator?.applyZoom(
            deltaY: event.magnification / MermaidRenderPolicy.preciseZoomGain,
            hasPreciseDeltas: true,
            anchor: convert(event.locationInWindow, from: nil)
        )
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            lastDragLocation = nil
            coordinator?.resetCamera()
            return
        }
        lastDragLocation = event.locationInWindow
        let zoom = coordinator?.zoomBinding?.wrappedValue ?? MermaidRenderPolicy.defaultZoom
        if zoom > MermaidRenderPolicy.defaultZoom + 0.001 {
            NSCursor.closedHand.push()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let lastDragLocation else { return }
        let location = event.locationInWindow
        coordinator?.applyPan(
            CGSize(
                width: location.x - lastDragLocation.x,
                height: lastDragLocation.y - location.y
            )
        )
        self.lastDragLocation = location
    }

    override func mouseUp(with event: NSEvent) {
        lastDragLocation = nil
        let zoom = coordinator?.zoomBinding?.wrappedValue ?? MermaidRenderPolicy.defaultZoom
        if zoom > MermaidRenderPolicy.defaultZoom + 0.001 {
            NSCursor.pop()
        }
    }
}

private enum MermaidRenderError: LocalizedError {
    case renderFailed(String)

    var errorDescription: String? {
        switch self {
        case let .renderFailed(message):
            message
        }
    }
}

@MainActor
private enum MermaidWebRuntime {
    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.suppressesIncrementalRendering = true
        if let script = bundledMermaidScript {
            configuration.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
            configuration.userContentController.addUserScript(
                WKUserScript(source: helperScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            )
        }
        return configuration
    }

    static var isAvailable: Bool {
        bundledMermaidScript != nil
    }

    static let pageHTML = """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        html, body {
          margin: 0;
          padding: 0;
          background: transparent;
          overflow: hidden;
          width: 100%;
          height: 100%;
        }
        #host {
          width: 100%;
          height: 100%;
          transform-origin: 50% 50%;
        }
        svg {
          display: block;
          width: 100% !important;
          height: 100% !important;
        }
      </style>
    </head>
    <body>
      <div id="host"></div>
    </body>
    </html>
    """

    private static let helperScript = """
    window.rpceRender = async function(source, theme, id) {
      if (typeof mermaid === "undefined") {
        throw new Error("Mermaid runtime missing");
      }
      mermaid.initialize({
        startOnLoad: false,
        theme: theme,
        securityLevel: "strict",
        flowchart: { htmlLabels: false, useMaxWidth: true },
        sequence: { useMaxWidth: true },
        fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif"
      });
      const rendered = await mermaid.render(id, source);
      const host = document.getElementById("host");
      host.replaceChildren();
      host.innerHTML = rendered.svg;
      const svg = host.querySelector("svg");
      if (svg) {
        svg.removeAttribute("width");
        svg.removeAttribute("height");
        svg.setAttribute("preserveAspectRatio", "xMidYMid meet");
        svg.style.width = "100%";
        svg.style.height = "100%";
      }
      const size = rpceSvgSize(svg);
      return { svg: rendered.svg, width: size.width, height: size.height };
    };

    window.rpceSetCamera = function(zoom, panX, panY) {
      const host = document.getElementById("host");
      if (!host) {
        return;
      }
      host.style.transform = "translate(" + panX + "px, " + panY + "px) scale(" + zoom + ")";
    };

    function rpceSvgSize(svg) {
      if (!svg) {
        return { width: 0, height: 0 };
      }
      const viewBox = svg.viewBox && svg.viewBox.baseVal;
      if (viewBox && viewBox.width > 1 && viewBox.height > 1) {
        return { width: viewBox.width, height: viewBox.height };
      }
      try {
        const bbox = svg.getBBox();
        if (bbox && bbox.width > 1 && bbox.height > 1) {
          return { width: bbox.width, height: bbox.height };
        }
      } catch (error) {}
      const attrWidth = parseFloat(svg.getAttribute("width"));
      const attrHeight = parseFloat(svg.getAttribute("height"));
      if (attrWidth > 1 && attrHeight > 1) {
        return { width: attrWidth, height: attrHeight };
      }
      const rect = svg.getBoundingClientRect();
      return { width: rect.width, height: rect.height };
    }
    """

    private static let bundledMermaidScript: String? = {
        guard let url = bundledScriptURL() else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    private static func bundledScriptURL() -> URL? {
        Bundle.main.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "Markdown")
            ?? Bundle.main.url(forResource: "mermaid.min", withExtension: "js")
    }
}
