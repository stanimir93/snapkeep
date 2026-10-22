import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let library = ScreenshotLibrary()
    private var session: CaptureSession?
    private var previews: [PreviewController] = []
    private var lastScreenshot: URL?
    private var recorder: ScreenRecorder?
    private var recordingControls: RecordingControls?
    private var recordingPreviews: [RecordingPreviewController] = []

    private var statusItem: NSStatusItem!
    private var captureItem: NSMenuItem!
    private var captureTextItem: NSMenuItem!
    private var recordItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private lazy var settingsWindow = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview") {
            runRenderCheck(arguments: Array(CommandLine.arguments.dropFirst(index + 1)))
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-overlay") {
            runOverlayCheck(arguments: Array(CommandLine.arguments.dropFirst(index + 1)))
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-recording") {
            runRecordingCheck(arguments: Array(CommandLine.arguments.dropFirst(index + 1)))
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-settings") {
            runSettingsCheck(arguments: Array(CommandLine.arguments.dropFirst(index + 1)))
            return
        }
        setUpStatusItem()
        registerHotKeys()
        if !CGPreflightScreenCaptureAccess() {
            // Adds Snapkeep to System Settings › Privacy & Security › Screen Recording and asks once.
            CGRequestScreenCaptureAccess()
        }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Snapkeep")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.toolTip = "Snapkeep"

        let menu = NSMenu()
        menu.delegate = self
        captureItem = item("Capture", action: #selector(captureAreaFromMenu))
        menu.addItem(captureItem)
        captureTextItem = item("Capture Text", action: #selector(captureTextFromMenu))
        menu.addItem(captureTextItem)
        recordItem = item("Record Screen", action: #selector(recordFromMenu))
        menu.addItem(recordItem)
        menu.addItem(.separator())
        menu.addItem(item("Show Last Screenshot", action: #selector(showLastScreenshot)))
        menu.addItem(item("Open Screenshots Folder", action: #selector(openFolder)))
        menu.addItem(item("Close All Previews", action: #selector(closeAllPreviews)))
        menu.addItem(.separator())
        let settingsItem = item("Settings…", action: #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        loginItem = item("Open at Login", action: #selector(toggleOpenAtLogin))
        menu.addItem(loginItem)
        permissionItem = item("Grant Screen Recording Access…", action: #selector(openScreenRecordingSettings))
        menu.addItem(permissionItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Snapkeep", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        recordItem.title = recorder == nil ? "Record Screen" : "Stop Recording"
        for (item, action) in [(captureItem!, ShortcutAction.capture), (captureTextItem!, .captureText), (recordItem!, .record)] {
            let shortcut = ShortcutSettings.shared.shortcut(for: action)
            item.keyEquivalent = shortcut?.menuKeyEquivalent ?? ""
            item.keyEquivalentModifierMask = shortcut?.modifierFlags ?? []
        }
        loginItem.state = LoginItem.isEnabled ? .on : .off
        permissionItem.isHidden = CGPreflightScreenCaptureAccess()
    }

    // MARK: Shortcuts

    private func registerHotKeys() {
        let settings = ShortcutSettings.shared
        settings.handlers = [
            .capture: { [weak self] in self?.captureArea() },
            .captureText: { [weak self] in self?.captureText() },
            .record: { [weak self] in self?.toggleRecording() },
        ]
        let failed = settings.register()
        NSLog("Snapkeep shortcuts: %@", failed.isEmpty ? "registered" : "failed \(settings.describe(failed))")
        if !failed.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Snapkeep couldn't register its shortcuts"
            alert.informativeText = "\(settings.describe(failed)) may be taken by another app. "
                + "Choose different ones in Settings. The menu bar icon still works."
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "OK")
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn { openSettings() }
        }
    }

    // MARK: Capture

    @objc func captureArea() {
        startCapture(.image)
    }

    @objc func captureText() {
        startCapture(.text)
    }

    /// Waits for the menu to fade out so it isn't frozen into the capture.
    @objc private func captureAreaFromMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.captureArea() }
    }

    @objc private func captureTextFromMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.captureText() }
    }

    private func startCapture(_ mode: CaptureMode) {
        guard session == nil else { return }
        let session = CaptureSession(mode: mode) { [weak self] capture in
            guard let self else { return }
            self.session = nil
            guard let capture else { return }
            switch mode {
            case .image: capture.copyOnly ? self.copyCapture(capture) : self.keepCapture(capture)
            case .text: self.copyText(from: capture)
            case .record: self.startRecording(capture)
            }
        }
        self.session = session
        Task { @MainActor in
            do {
                try await session.start()
            } catch {
                session.finish(nil)
                NSLog("Snapkeep capture failed: %@", String(describing: error))
                if !CGPreflightScreenCaptureAccess() {
                    Toast.show("Snapkeep needs Screen Recording permission",
                               detail: "Allow it in System Settings, then quit and reopen Snapkeep", symbol: "lock.shield")
                    self.openScreenRecordingSettings()
                } else {
                    Toast.show("Couldn't capture the screen", detail: error.localizedDescription, symbol: "exclamationmark.triangle")
                }
            }
        }
    }

    /// Saves to ~/Pictures/Screenshots, copies, and opens a preview.
    private func keepCapture(_ capture: CaptureSession.Capture) {
        Sounds.screenshot()
        guard let data = Renderer.encodePNG(capture.image, pointSize: capture.pointSize) else {
            Toast.show("Couldn't encode the screenshot", symbol: "exclamationmark.triangle")
            return
        }
        Clipboard.copyPNG(data)
        let url: URL
        do {
            url = try library.newFileURL()
            try data.write(to: url, options: .atomic)
        } catch {
            Toast.show("Copied, but couldn't save the file", detail: error.localizedDescription, symbol: "exclamationmark.triangle")
            return
        }
        lastScreenshot = url
        openPreview(Screenshot(url: url, pngData: data, cgImage: capture.image, pointSize: capture.pointSize),
                    status: "Copied to clipboard")
    }

    /// Copy & Close: the image goes to the clipboard only. Nothing is kept on disk.
    private func copyCapture(_ capture: CaptureSession.Capture) {
        Sounds.screenshot()
        guard let data = Renderer.encodePNG(capture.image, pointSize: capture.pointSize) else {
            Toast.show("Couldn't encode the screenshot", symbol: "exclamationmark.triangle")
            return
        }
        Clipboard.copyPNG(data)
        Toast.show("Copied to clipboard", detail: "\(capture.image.width) × \(capture.image.height)", symbol: "checkmark.circle.fill")
    }

    /// Copy Text: copies all the text in the area. Nothing is kept on disk.
    private func copyText(from capture: CaptureSession.Capture) {
        Task { @MainActor in
            do {
                let analysis = try await TextRecognizer.analyze(capture.image)
                let text = analysis.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    Toast.show("No text found", symbol: "text.viewfinder")
                } else {
                    Clipboard.copyText(text)
                    let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
                    Toast.show("Copied text", detail: firstLine, symbol: "checkmark.circle.fill")
                }
            } catch {
                Toast.show("Text recognition failed", detail: error.localizedDescription, symbol: "exclamationmark.triangle")
            }
        }
    }

    // MARK: Recording

    /// The record shortcut starts a recording, or stops the one running.
    @objc func toggleRecording() {
        if recorder != nil {
            stopRecording()
        } else {
            startCapture(.record)
        }
    }

    @objc private func recordFromMenu() {
        if recorder != nil {
            stopRecording()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.startCapture(.record) }
        }
    }

    private func startRecording(_ capture: CaptureSession.Capture) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Snapkeep", isDirectory: true)
        let recorder: ScreenRecorder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            recorder = try ScreenRecorder(screen: capture.screen, rect: capture.rect,
                                          url: folder.appendingPathComponent("recording-\(UUID().uuidString).mp4"))
        } catch {
            Toast.show("Couldn't start recording", detail: error.localizedDescription, symbol: "exclamationmark.triangle")
            return
        }
        recorder.onInterrupted = { [weak self] in self?.stopRecording() }
        self.recorder = recorder
        Task { @MainActor [weak self] in
            do {
                try await recorder.start()
            } catch {
                self?.recorder = nil
                try? FileManager.default.removeItem(at: recorder.url)
                Toast.show("Couldn't start recording", detail: error.localizedDescription, symbol: "exclamationmark.triangle")
                return
            }
            // Stopped before it got going.
            guard let self, self.recorder === recorder else { return }
            Sounds.recordingStarted()
            let controls = RecordingControls(screen: capture.screen, rect: capture.rect)
            controls.onStop = { [weak self] in self?.stopRecording() }
            controls.onDiscard = { [weak self] in self?.stopRecording(discard: true) }
            controls.show()
            self.recordingControls = controls
            self.setRecordingIcon(true)
        }
    }

    private func stopRecording(discard: Bool = false) {
        guard let recorder else { return }
        self.recorder = nil
        recordingControls?.close()
        recordingControls = nil
        setRecordingIcon(false)
        Sounds.recordingStopped()
        Task { @MainActor in
            do {
                let recording = try await recorder.stop()
                if discard {
                    try? FileManager.default.removeItem(at: recording.url)
                    Toast.show("Recording discarded", symbol: "trash")
                } else {
                    self.openRecordingPreview(recording)
                }
            } catch {
                try? FileManager.default.removeItem(at: recorder.url)
                if !discard {
                    Toast.show("Couldn't finish the recording", detail: error.localizedDescription, symbol: "exclamationmark.triangle")
                }
            }
        }
    }

    private func setRecordingIcon(_ recording: Bool) {
        let icon = NSImage(systemSymbolName: recording ? "record.circle" : "camera.viewfinder", accessibilityDescription: "Snapkeep")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.toolTip = recording ? "Snapkeep is recording" : "Snapkeep"
    }

    @discardableResult
    private func openRecordingPreview(_ recording: Recording) -> RecordingPreviewController {
        let preview = RecordingPreviewController(recording: recording, library: library)
        preview.onClose = { [weak self] closed in
            self?.recordingPreviews.removeAll { $0 === closed }
        }
        preview.show(cascadeIndex: previews.count + recordingPreviews.count)
        recordingPreviews.append(preview)
        return preview
    }

    // MARK: Previews

    @discardableResult
    private func openPreview(_ screenshot: Screenshot, status: String? = nil) -> PreviewController {
        let preview = PreviewController(screenshot: screenshot, initialStatus: status)
        preview.onClose = { [weak self] closed in
            self?.previews.removeAll { $0 === closed }
        }
        preview.show(cascadeIndex: previews.count)
        previews.append(preview)
        return preview
    }

    @objc func showLastScreenshot() {
        guard let url = lastScreenshot.flatMap({ FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }) ?? library.newest() else {
            let hint = ShortcutSettings.shared.shortcut(for: .capture).map { "Press \($0.displayName) to capture" }
            Toast.show("No screenshots yet", detail: hint ?? "Choose Capture from the menu bar icon", symbol: "photo")
            return
        }
        if let open = previews.last(where: { $0.url.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path }) {
            open.bringToFront()
        } else if let screenshot = Screenshot.load(url) {
            openPreview(screenshot)
        }
    }

    @objc func openFolder() {
        try? FileManager.default.createDirectory(at: library.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(library.folder)
    }

    @objc func closeAllPreviews() {
        previews.forEach { $0.close() }
    }

    // MARK: Settings

    @objc func openSettings() {
        settingsWindow.show()
    }

    @objc func toggleOpenAtLogin() {
        LoginItem.toggle()
    }

    @objc func openScreenRecordingSettings() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Self-check

    /// `Snapkeep --render-preview in.png out-dir`: opens a preview with sample drawings, waits for
    /// Live Text, then writes the window and the exported image to out-dir and quits.
    private func runRenderCheck(arguments: [String]) {
        guard arguments.count >= 2, let screenshot = Screenshot.load(URL(fileURLWithPath: arguments[0])) else {
            print("usage: Snapkeep --render-preview <image.png> <output-dir>")
            exit(2)
        }
        let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let preview = openPreview(screenshot, status: "Copied to clipboard")
        let started = Date()
        Task { @MainActor in
            await preview.analysisDone?.value
            print(String(format: "live-text-seconds %.3f", Date().timeIntervalSince(started)))
            do {
                try preview.renderWindow(to: output.appendingPathComponent("window-plain.png"))
                preview.addSampleDrawings()
                try await Task.sleep(for: .milliseconds(100))
                try preview.renderWindow(to: output.appendingPathComponent("window-drawn.png"))
                try preview.currentPNG()?.write(to: output.appendingPathComponent("export.png"))
                exit(0)
            } catch {
                print("render failed: \(error)")
                exit(1)
            }
        }
    }

    /// `Snapkeep --render-recording out-dir`: records nothing. Makes a short test video, saves it
    /// as out-dir/check.gif, and shows the recording preview and controls for a few seconds. Their
    /// window numbers are printed for `screencapture -l`, since the player keeps the preview
    /// from rendering offscreen.
    private func runRecordingCheck(arguments: [String]) {
        guard let path = arguments.first else {
            print("usage: Snapkeep --render-recording <output-dir>")
            exit(2)
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        let pixelSize = CGSize(width: 1280, height: 800), pointSize = CGSize(width: 640, height: 400)
        Task { @MainActor in
            do {
                let video = output.appendingPathComponent("check.mp4")
                try? FileManager.default.removeItem(at: video)
                let duration = try await TestVideo.write(to: video, pixelSize: pixelSize, seconds: 2)
                let started = Date()
                let bytes = try await GIFExporter.export(video: video, pointSize: pointSize, preset: .medium,
                                                         to: output.appendingPathComponent("check.gif")) { _ in }
                print(String(format: "gif %d bytes in %.2f s", bytes, Date().timeIntervalSince(started)))

                let copy = output.appendingPathComponent("preview.mp4")
                try? FileManager.default.removeItem(at: copy)
                try FileManager.default.copyItem(at: video, to: copy)
                let preview = openRecordingPreview(Recording(url: copy, pointSize: pointSize, pixelSize: pixelSize, duration: duration))
                let controls = RecordingControls(screen: NSScreen.main!, rect: CGRect(x: 100, y: 100, width: 600, height: 400))
                controls.show()
                try await Task.sleep(for: .milliseconds(300))
                let others = NSApp.windows.filter { $0.isVisible && $0 !== preview.panel }.map { String($0.windowNumber) }
                print("preview window \(preview.panel.windowNumber), controls windows \(others.joined(separator: " "))")
                fflush(stdout)
                try await Task.sleep(for: .seconds(4))
                exit(0)
            } catch {
                print("check failed: \(error)")
                exit(1)
            }
        }
    }

    /// `Snapkeep --render-settings out-dir`: writes the Settings window to out-dir/settings.png.
    private func runSettingsCheck(arguments: [String]) {
        guard let path = arguments.first else {
            print("usage: Snapkeep --render-settings <output-dir>")
            exit(2)
        }
        settingsWindow.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            do {
                try self.settingsWindow.renderWindow(to: URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("settings.png"))
                exit(0)
            } catch {
                print("render failed: \(error)")
                exit(1)
            }
        }
    }

    /// `Snapkeep --render-overlay screen.png out-dir`: draws the capture overlay over an image in a
    /// few states (hovering a window, a finished selection, Copy Text before and after Select
    /// Text) without touching the real screen.
    private func runOverlayCheck(arguments: [String]) {
        guard arguments.count >= 2, let screen = Screenshot.load(URL(fileURLWithPath: arguments[0])) else {
            print("usage: Snapkeep --render-overlay <screen.png> <output-dir>")
            exit(2)
        }
        let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let size = screen.pointSize
        let fakeWindow = WindowInfo(frame: CGRect(x: size.width * 0.05, y: size.height * 0.08,
                                                  width: size.width * 0.6, height: size.height * 0.8), owner: "Notes")
        let overlay = CaptureOverlayView(size: size, image: screen.cgImage, windows: [fakeWindow], mode: .image)
        let window = CaptureOverlayWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = overlay
        overlay.setEdgeMap(EdgeMap(image: screen.cgImage))

        func render(_ name: String) {
            overlay.layoutSubtreeIfNeeded()
            guard let rep = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) else { return }
            overlay.cacheDisplay(in: overlay.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name))
        }

        overlay.setStateForCheck(mouse: CGPoint(x: size.width * 0.3, y: size.height * 0.5), selection: nil)
        render("overlay-hover.png")
        // Near the mock window's sidebar divider, right edge and toolbar line.
        let start = CGPoint(x: size.width * 0.211, y: size.height * 0.578)
        let end = CGPoint(x: size.width * 0.646, y: size.height * 0.827)
        let snapped = overlay.snappedDragForCheck(from: start, to: end)
        print("drag \(start) → \(end) snapped to \(snapped)")
        overlay.setStateForCheck(mouse: end, selection: snapped)
        render("overlay-selection.png")
        if let captured = overlay.capturedImage() {
            try? Renderer.encodePNG(captured.image, pointSize: captured.pointSize)?.write(to: output.appendingPathComponent("overlay-capture.png"))
        }

        // Copy Text mode, before and after Select Text.
        let textOverlay = CaptureOverlayView(size: size, image: screen.cgImage, windows: [fakeWindow], mode: .text)
        window.contentView = textOverlay
        textOverlay.setStateForCheck(mouse: end, selection: snapped)
        func renderText(_ name: String) {
            textOverlay.layoutSubtreeIfNeeded()
            guard let rep = textOverlay.bitmapImageRepForCachingDisplay(in: textOverlay.bounds) else { return }
            textOverlay.cacheDisplay(in: textOverlay.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name))
        }
        renderText("overlay-text.png")
        Task { @MainActor in
            await textOverlay.startPickingTextForCheck()
            renderText("overlay-text-picking.png")
            textOverlay.copyPickedTextForCheck()
            renderText("overlay-text-copied.png")
            exit(0)
        }
    }
}
