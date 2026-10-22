import AppKit

/// One capture: freezes every screen, shows an overlay on each, and reports the selected
/// image when the user confirms (or nil if they cancel).
@MainActor
final class CaptureSession {
    struct Capture {
        let image: CGImage
        let pointSize: CGSize
    }

    let mode: CaptureMode
    private let completion: (Capture?) -> Void
    private var windows: [CaptureOverlayWindow] = []
    private var overlays: [CaptureOverlayView] = []
    private var snappingEnabled = true
    private var finished = false

    init(mode: CaptureMode, completion: @escaping (Capture?) -> Void) {
        self.mode = mode
        self.completion = completion
    }

    func start() async throws {
        let openWindows = ScreenFreezer.visibleWindows()
        let screens = try await ScreenFreezer.freezeAllScreens()
        guard !finished else { return }
        for frozen in screens {
            showOverlay(for: frozen, windows: openWindows)
        }
        let mouse = NSEvent.mouseLocation
        let pairs = Array(zip(windows, overlays))
        if let (window, overlay) = pairs.first(where: { NSMouseInRect(mouse, $0.0.frame, false) }) ?? pairs.first {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(overlay)
        }
        NSCursor.crosshair.set()
    }

    private func showOverlay(for frozen: FrozenScreen, windows openWindows: [WindowInfo]) {
        let frame = frozen.screen.frame
        let local = openWindows
            .filter { $0.frame.intersects(frame) }
            .map { WindowInfo(frame: $0.frame.offsetBy(dx: -frame.minX, dy: -frame.minY), owner: $0.owner) }
        let overlay = CaptureOverlayView(size: frame.size, image: frozen.image, windows: local, mode: mode)
        overlay.onBeginInteraction = { [weak self, weak overlay] in
            guard let self, let overlay else { return }
            self.focus(overlay)
        }
        overlay.onConfirm = { [weak self, weak overlay] in
            guard let self, let overlay else { return }
            self.confirm(overlay)
        }
        overlay.onCancel = { [weak self] in self?.finish(nil) }
        overlay.onToggleSnapping = { [weak self] in self?.toggleSnapping() }

        let window = CaptureOverlayWindow(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = overlay
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        windows.append(window)
        overlays.append(overlay)

        // Finding lines takes a few tens of milliseconds on a 5K screen, so do it off the main thread.
        let image = frozen.image
        Task.detached(priority: .userInitiated) {
            let map = EdgeMap(image: image)
            await MainActor.run { [weak overlay] in overlay?.setEdgeMap(map) }
        }
    }

    /// A selection lives on one screen at a time.
    private func focus(_ overlay: CaptureOverlayView) {
        for other in overlays where other !== overlay {
            other.clearSelection()
        }
        overlay.window?.makeKey()
    }

    private func toggleSnapping() {
        snappingEnabled.toggle()
        overlays.forEach { $0.setSnappingEnabled(snappingEnabled) }
    }

    private func confirm(_ overlay: CaptureOverlayView) {
        guard let captured = overlay.capturedImage() else { return }
        finish(Capture(image: captured.image, pointSize: captured.pointSize))
    }

    func finish(_ capture: Capture?) {
        guard !finished else { return }
        finished = true
        windows.forEach { $0.orderOut(nil) }
        windows = []
        overlays = []
        NSCursor.arrow.set()
        completion(capture)
    }
}
