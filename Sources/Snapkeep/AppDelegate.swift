import AppKit
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let library = ScreenshotLibrary()
    private let capturer = ScreenCapturer()
    private var previews: [PreviewController] = []
    private var lastScreenshot: URL?

    private var statusItem: NSStatusItem!
    private var loginItem: NSMenuItem!
    private var permissionItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview") {
            runRenderCheck(arguments: Array(CommandLine.arguments.dropFirst(index + 1)))
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
        menu.addItem(item("Capture", action: #selector(captureArea), key: "2"))
        menu.addItem(item("Capture Text", action: #selector(captureText), key: "1"))
        menu.addItem(.separator())
        menu.addItem(item("Show Last Screenshot", action: #selector(showLastScreenshot)))
        menu.addItem(item("Open Screenshots Folder", action: #selector(openFolder)))
        menu.addItem(item("Close All Previews", action: #selector(closeAllPreviews)))
        menu.addItem(.separator())
        loginItem = item("Open at Login", action: #selector(toggleOpenAtLogin))
        menu.addItem(loginItem)
        permissionItem = item("Grant Screen Recording Access…", action: #selector(openScreenRecordingSettings))
        menu.addItem(permissionItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Snapkeep", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if !key.isEmpty { item.keyEquivalentModifierMask = [.command, .shift] }
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        permissionItem.isHidden = CGPreflightScreenCaptureAccess()
    }

    // MARK: Shortcuts

    private func registerHotKeys() {
        let modifiers = cmdKey | shiftKey
        var failed: [String] = []
        if !HotKeys.shared.register(keyCode: kVK_ANSI_2, modifiers: modifiers, handler: { [weak self] in self?.captureArea() }) {
            failed.append("⇧⌘2 (Capture)")
        }
        if !HotKeys.shared.register(keyCode: kVK_ANSI_1, modifiers: modifiers, handler: { [weak self] in self?.captureText() }) {
            failed.append("⇧⌘1 (Capture Text)")
        }
        NSLog("Snapkeep shortcuts: %@", failed.isEmpty ? "registered ⇧⌘2 and ⇧⌘1" : "failed \(failed)")
        if !failed.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Snapkeep couldn't register its shortcuts"
            alert.informativeText = "\(failed.joined(separator: " and ")) may be taken by another app. The menu bar icon still works."
            NSApp.activate()
            alert.runModal()
        }
    }

    // MARK: Capture

    @objc func captureArea() {
        let url: URL
        do {
            url = try library.newFileURL()
        } catch {
            Toast.show("Couldn't create the Screenshots folder", detail: error.localizedDescription, symbol: "exclamationmark.triangle")
            return
        }
        capturer.capture(to: url) { [weak self] captured in
            guard captured, let self else { return }
            guard let screenshot = Screenshot.load(url) else {
                Toast.show("Couldn't read the screenshot", symbol: "exclamationmark.triangle")
                return
            }
            Clipboard.copyPNG(screenshot.pngData)
            self.lastScreenshot = url
            self.openPreview(screenshot, status: "Copied to clipboard")
        }
    }

    /// Captures an area and copies only its text. Nothing is kept on disk.
    @objc func captureText() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapkeep-text-\(UUID().uuidString).png")
        capturer.capture(to: url) { captured in
            guard captured else { return }
            let screenshot = Screenshot.load(url)
            try? FileManager.default.removeItem(at: url)
            guard let screenshot else {
                Toast.show("Couldn't read the capture", symbol: "exclamationmark.triangle")
                return
            }
            Task { @MainActor in
                do {
                    let analysis = try await TextRecognizer.analyze(screenshot.cgImage)
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
            Toast.show("No screenshots yet", detail: "Press ⇧⌘2 to capture", symbol: "photo")
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

    @objc func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            NSApp.activate()
            alert.runModal()
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
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
}
