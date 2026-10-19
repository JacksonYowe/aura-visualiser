import AppKit
import QuartzCore
import SwiftUI

struct MetalView: NSViewRepresentable {
    let renderer: Renderer

    func makeNSView(context: Context) -> VisualizerView { VisualizerView(renderer: renderer) }
    func updateNSView(_ nsView: VisualizerView, context: Context) {}
    static func dismantleNSView(_ nsView: VisualizerView, coordinator: ()) { nsView.stop() }
}

/// A CAMetalLayer-backed view rendered from a dedicated thread by CAMetalDisplayLink, so
/// frames never wait on SwiftUI/AppKit work and each one knows exactly when it will be shown.
final class VisualizerView: NSView, CAMetalDisplayLinkDelegate {
    private let renderer: Renderer
    private let metalLayer = CAMetalLayer()
    private var link: CAMetalDisplayLink?
    private var thread: Thread?
    private var occlusionObserver: NSObjectProtocol?

    init(renderer: Renderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = Renderer.outputFormat
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { metalLayer }
    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(bounds.width * scale, 1), height: max(bounds.height * scale, 1))
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        guard let window else { stop(); return }
        updateDrawableSize()
        start()
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self, let window = self.window else { return }
            let visible = window.occlusionState.contains(.visible)
            self.link?.isPaused = !visible
            DiagnosticsLog.write("window \(visible ? "visible" : "hidden") → rendering \(visible ? "on" : "paused")")
        }
    }

    private func start() {
        guard link == nil else { return }
        let link = CAMetalDisplayLink(metalLayer: metalLayer)
        link.delegate = self
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.preferredFrameLatency = 1
        self.link = link

        let thread = Thread {
            link.add(to: .current, forMode: .default)
            while !Thread.current.isCancelled {
                _ = RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
        thread.name = "Aura Render"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
        DiagnosticsLog.write("display link started · drawable \(Int(metalLayer.drawableSize.width))×\(Int(metalLayer.drawableSize.height))")
    }

    func stop() {
        link?.invalidate()
        link = nil
        thread?.cancel()
        thread = nil
    }

    private var firstFrame = true
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        if firstFrame {
            firstFrame = false
            DiagnosticsLog.write("first frame · target present in \(Int((update.targetPresentationTimestamp - CACurrentMediaTime()) * 1000)) ms")
        }
        renderer.render(drawable: update.drawable, presentTime: update.targetPresentationTimestamp)
    }
}
