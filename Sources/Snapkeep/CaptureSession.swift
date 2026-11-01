import AppKit

/// One capture: freezes every screen, shows an overlay on each, and reports the selected
/// area when the user confirms (or nil if they cancel).
@MainActor
final class CaptureSession {
    struct Capture {
        let image: CGImage
        let pointSize: CGSize
        let screen: NSScreen
        /// The selection in the screen's points, origin at its bottom-left.
        let rect: CGRect
        /// Copy & Close: copy only, no preview and no file.
        var copyOnly = false
        /// The front window under the middle of the selection.
        var source: CaptureSource?
        /// A custom button pressed in the capture bar, to run instead of opening a preview.
        var button: CustomButton?
    }

    let mode: CaptureMode
    private let customButtons: [CustomButton]
    private let completion: (Capture?) -> Void
    private var windows: [CaptureOverlayWindow] = []
    private var overlays: [CaptureOverlayView] = []
    private var screens: [NSScreen] = []
    private var openWindows: [WindowInfo] = []
    private var snappingEnabled = true
    private var finished = false

    init(mode: CaptureMode, customButtons: [CustomButton] = [], completion: @escaping (Capture?) -> Void) {
        self.mode = mode
        self.customButtons = customButtons
        self.completion = completion
    }

    func start() async throws {
        let openWindows = ScreenFreezer.visibleWindows()
        self.openWindows = openWindows
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
            .map { WindowInfo(frame: $0.frame.offsetBy(dx: -frame.minX, dy: -frame.minY), owner: $0.owner,
                              title: $0.title, processID: $0.processID) }
        let overlay = CaptureOverlayView(size: frame.size, image: frozen.image, windows: local, mode: mode,
                                         customButtons: customButtons)
        overlay.onBeginInteraction = { [weak self, weak overlay] in
            guard let self, let overlay else { return }
            self.focus(overlay)
        }
        overlay.onConfirm = { [weak self, weak overlay] in
            guard let self, let overlay else { return }
            self.confirm(overlay)
        }
        overlay.onCopy = { [weak self, weak overlay] in
            guard let self, let overlay else { return }
            self.confirm(overlay, copyOnly: true)
        }
        overlay.onCustomButton = { [weak self, weak overlay] index in
            guard let self, let overlay, self.customButtons.indices.contains(index) else { return }
            self.confirm(overlay, button: self.customButtons[index])
        }
        overlay.onCopyText = { text in Clipboard.copyText(text) }
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
        screens.append(frozen.screen)

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

    private func confirm(_ overlay: CaptureOverlayView, copyOnly: Bool = false, button: CustomButton? = nil) {
        guard let captured = overlay.capturedImage(), let selection = overlay.selection,
              let index = overlays.firstIndex(where: { $0 === overlay }) else { return }
        finish(Capture(image: captured.image, pointSize: captured.pointSize, screen: screens[index], rect: selection,
                       copyOnly: copyOnly, source: source(of: selection, on: screens[index]), button: button))
    }

    /// The app and window under the middle of the selection.
    private func source(of selection: CGRect, on screen: NSScreen) -> CaptureSource? {
        let middle = CGPoint(x: selection.midX + screen.frame.minX, y: selection.midY + screen.frame.minY)
        guard let window = openWindows.first(where: { $0.frame.contains(middle) }), !window.owner.isEmpty else { return nil }
        let processID = window.processID > 0 ? window.processID : nil
        return CaptureSource(appName: window.owner, windowTitle: window.title,
                             bundleID: processID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier },
                             processID: processID)
    }

    func finish(_ capture: Capture?) {
        guard !finished else { return }
        finished = true
        windows.forEach { $0.orderOut(nil) }
        windows = []
        overlays = []
        screens = []
        openWindows = []
        NSCursor.arrow.set()
        completion(capture)
    }
}
