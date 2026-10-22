import AppKit
import AVKit

/// A finished recording: plays it on a loop and lets the user keep it as a video, a GIF, both,
/// or neither. The recording stays in a temporary file until it's saved.
@MainActor
final class RecordingPreviewController: NSObject, NSWindowDelegate {
    private static let bottomBarHeight: CGFloat = 52

    let recording: Recording
    var onClose: ((RecordingPreviewController) -> Void)?

    let panel: PreviewPanel
    private let library: ScreenshotLibrary
    private let playerView = AVPlayerView()
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var videoButton: NSButton!
    private var gifButton: NSButton!
    private let presetButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var finderButton: NSButton!
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private var minContentWidth: CGFloat = 0

    private var savedVideo: URL?
    private var savedGIF: (url: URL, preset: GIFPreset)?
    private var exportTask: Task<Void, Never>?
    private var preset = GIFPreset.lastUsed
    /// Each preset's GIF size in bytes: estimated, then exact once that GIF is made.
    private var gifSizes: [GIFPreset: (bytes: Int, exact: Bool)] = [:]
    private var estimateTask: Task<Void, Never>?
    private var discardConfirmed = false

    private var isSaved: Bool { savedVideo != nil || savedGIF != nil }

    init(recording: Recording, library: ScreenshotLibrary) {
        self.recording = recording
        self.library = library
        panel = PreviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        super.init()
        buildWindow()
        sizeWindow()
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: recording.url))
        player.isMuted = true
        player.play()
        estimateGIFSizes()
    }

    // MARK: Window

    private func buildWindow() {
        panel.title = "Recording, \(formatDuration(recording.duration))"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.delegate = self
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }

        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false
        playerView.videoGravity = .resizeAspect

        let bottomBar = makeBottomBar()
        let line = NSBox()
        line.boxType = .separator
        let content = NSView()
        for view in [playerView, bottomBar, line] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: Self.bottomBarHeight),
            line.bottomAnchor.constraint(equalTo: playerView.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        panel.contentView = content
        minContentWidth = ceil(bottomBar.fittingSize.width)
        showDetails()
    }

    private func makeBottomBar() -> NSView {
        videoButton = NSButton(title: "Save Video", target: self, action: #selector(saveVideo))
        videoButton.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
        videoButton.imagePosition = .imageLeading
        videoButton.controlSize = .large
        videoButton.font = .systemFont(ofSize: NSFont.systemFontSize(for: .large), weight: .semibold)
        videoButton.keyEquivalent = "\r" // default button: Return saves the video
        videoButton.toolTip = "Save as an MP4 video and copy the file (⌘S)"

        gifButton = textButton("Save GIF", symbol: "photo.stack", tip: "Save as a GIF with the preset beside it, and copy the file (⌘G)",
                               action: #selector(saveGIF))
        presetButton.controlSize = .large
        presetButton.toolTip = "How big and smooth the GIF is, and about how much space it takes"
        updatePresetMenu()
        finderButton = textButton("Show in Finder", symbol: "folder", tip: "Show the saved file", action: #selector(showInFinder))
        finderButton.isEnabled = false
        let discardButton = textButton("Discard", symbol: "trash", tip: "Throw the recording away (⌘⌫)", action: #selector(discard))

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        progress.isHidden = true
        progress.widthAnchor.constraint(equalToConstant: 90).isActive = true

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.alignment = .right
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        let bar = NSStackView(views: [videoButton, gifButton, presetButton, finderButton, discardButton, progress, statusLabel])
        bar.spacing = 8
        bar.setCustomSpacing(4, after: gifButton)
        bar.setCustomSpacing(14, after: discardButton)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        bar.alignment = .centerY
        return bar
    }

    private func textButton(_ title: String, symbol: String, tip: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.controlSize = .large
        button.toolTip = tip
        return button
    }

    /// Opens at the recorded area's size, shrunk to fit within about 70% of the screen.
    private func sizeWindow() {
        let visible = (NSScreen.withMouse ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let points = recording.pointSize
        let maxWidth = visible.width * 0.7
        let maxHeight = visible.height * 0.7 - Self.bottomBarHeight
        let scale = min(1, maxWidth / max(points.width, 1), maxHeight / max(points.height, 1))
        let area = CGSize(width: max(points.width * scale, minContentWidth), height: max(points.height * scale, 160))
        panel.setContentSize(NSSize(width: area.width, height: area.height + Self.bottomBarHeight))
        panel.contentMinSize = NSSize(width: minContentWidth, height: 160 + Self.bottomBarHeight)
    }

    func show(cascadeIndex: Int) {
        let visible = (NSScreen.withMouse ?? NSScreen.main)?.visibleFrame ?? .zero
        var frame = panel.frame
        let offset = CGFloat(cascadeIndex % 10) * 30
        frame.origin.x = visible.midX - frame.width / 2 + offset
        frame.origin.y = visible.midY - frame.height / 2 - offset
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        panel.setFrame(frame, display: false)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Asks first if nothing was saved.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isSaved || discardConfirmed { return true }
        let alert = NSAlert()
        alert.messageText = "Discard this recording?"
        alert.informativeText = "It hasn't been saved as a video or a GIF."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.discardConfirmed = true
            self.panel.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        exportTask?.cancel()
        estimateTask?.cancel()
        player.pause()
        looper = nil
        player.removeAllItems()
        try? FileManager.default.removeItem(at: recording.url)
        onClose?(self)
    }

    // MARK: Status

    private func showDetails() {
        var text = "\(formatDuration(recording.duration))  ·  \(Int(recording.pixelSize.width)) × \(Int(recording.pixelSize.height))"
        let saved = [savedVideo, savedGIF?.url].compactMap { $0?.pathExtension.uppercased() }
        if !saved.isEmpty { text = "Saved \(saved.joined(separator: " and "))  ·  " + text }
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.toolTip = nil
        // A GIF this big is slow to open and to upload, and the video is far smaller.
        if savedGIF == nil, let size = gifSizes[preset], size.bytes > Self.largeGIF {
            text = "Large GIF, about \(formatBytes(size.bytes)). The video is \(fileSize(recording.url))."
            statusLabel.textColor = .systemOrange
            statusLabel.toolTip = preset == .small ? "Save the video instead, or record a shorter part"
                : "Pick a smaller preset, or save the video instead"
        }
        statusLabel.stringValue = text
    }

    // MARK: GIF presets

    private static let largeGIF = 10_000_000

    /// Fills in each preset's estimate as it's ready, the selected one first.
    private func estimateGIFSizes() {
        let video = recording.url, pointSize = recording.pointSize
        let order = [preset] + GIFPreset.allCases.filter { $0 != preset }
        estimateTask = Task { @MainActor [weak self] in
            for preset in order {
                let bytes = await Task.detached(priority: .utility) {
                    try? await GIFExporter.estimate(video: video, pointSize: pointSize, preset: preset)
                }.value
                guard let self, !Task.isCancelled else { return }
                if let bytes, self.gifSizes[preset] == nil { self.gifSizes[preset] = (bytes, false) }
                self.updatePresetMenu()
                self.showDetails()
            }
        }
    }

    private func updatePresetMenu() {
        let menu = NSMenu()
        // A pull-down shows its first item as the button's title.
        menu.addItem(withTitle: "\(preset.title)  ·  \(sizeText(for: preset))", action: nil, keyEquivalent: "")
        for option in GIFPreset.allCases {
            let output = GIFExporter.outputSize(for: recording.pointSize, preset: option)
            let item = NSMenuItem(title: "", action: #selector(presetChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == preset ? .on : .off
            let title = NSMutableAttributedString(string: "\(option.title)  ·  \(sizeText(for: option))\n",
                                                  attributes: [.font: NSFont.menuFont(ofSize: 0)])
            title.append(NSAttributedString(
                string: "\(Int(output.width)) × \(Int(output.height)), \(Int(option.frameRate)) fps, \(option.purpose)",
                attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = title
            menu.addItem(item)
        }
        presetButton.menu = menu
    }

    private func sizeText(for preset: GIFPreset) -> String {
        guard let size = gifSizes[preset] else { return "estimating…" }
        return (size.exact ? "" : "~") + formatBytes(size.bytes)
    }

    @objc private func presetChosen(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let chosen = GIFPreset(rawValue: raw) else { return }
        preset = chosen
        GIFPreset.lastUsed = chosen
        updatePresetMenu()
        showDetails()
    }

    // MARK: Actions

    @objc private func saveVideo() {
        if let savedVideo {
            Clipboard.copyFile(savedVideo)
            statusLabel.stringValue = "Copied \(savedVideo.lastPathComponent)"
            return
        }
        do {
            let url = try library.newFileURL(prefix: "recording", extension: "mp4")
            try FileManager.default.copyItem(at: recording.url, to: url)
            savedVideo = url
            didSave(url, detail: fileSize(url))
        } catch {
            statusLabel.stringValue = "Couldn't save: \(error.localizedDescription)"
        }
    }

    @objc private func saveGIF() {
        if let savedGIF, savedGIF.preset == preset {
            Clipboard.copyFile(savedGIF.url)
            statusLabel.stringValue = "Copied \(savedGIF.url.lastPathComponent)"
            return
        }
        guard exportTask == nil else { return }
        let preset = preset
        gifButton.isEnabled = false
        presetButton.isEnabled = false
        progress.doubleValue = 0
        progress.isHidden = false
        statusLabel.stringValue = "Making GIF…"

        let video = recording.url, pointSize = recording.pointSize
        let temporary = video.deletingPathExtension().appendingPathExtension("gif")
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.progress.doubleValue = fraction }
        }
        exportTask = Task { @MainActor [weak self] in
            let result: Result<Int, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try await GIFExporter.export(video: video, pointSize: pointSize, preset: preset,
                                                                 to: temporary, progress: report))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self, !Task.isCancelled else {
                try? FileManager.default.removeItem(at: temporary)
                return
            }
            self.exportTask = nil
            self.progress.isHidden = true
            self.gifButton.isEnabled = true
            self.presetButton.isEnabled = true
            do {
                let bytes = try result.get()
                let url = try self.library.newFileURL(prefix: "recording", extension: "gif")
                try FileManager.default.moveItem(at: temporary, to: url)
                self.savedGIF = (url, preset)
                self.gifSizes[preset] = (bytes, true)
                self.updatePresetMenu()
                self.didSave(url, detail: self.fileSize(url))
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                self.statusLabel.stringValue = "Couldn't make the GIF: \(error.localizedDescription)"
            }
        }
    }

    private func didSave(_ url: URL, detail: String) {
        Clipboard.copyFile(url)
        finderButton.isEnabled = true
        panel.title = url.lastPathComponent
        Toast.show("Saved \(url.pathExtension.uppercased()) and copied it", detail: "\(url.lastPathComponent)  ·  \(detail)",
                   symbol: "checkmark.circle.fill")
        showDetails()
    }

    private func fileSize(_ url: URL) -> String {
        formatBytes((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    @objc private func showInFinder() {
        let files = [savedVideo, savedGIF?.url].compactMap { $0 }
        if !files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(files) }
    }

    @objc private func discard() {
        discardConfirmed = true
        panel.close()
        if !isSaved { Toast.show("Recording discarded", symbol: "trash") }
    }

    // MARK: Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if modifiers == .command {
            switch key {
            case "s": saveVideo()
            case "g": saveGIF()
            case "w": panel.performClose(nil)
            default:
                if event.keyCode == 51 { // ⌘⌫
                    discard()
                    return true
                }
                return false
            }
            return true
        }
        if modifiers.isEmpty, key == " " {
            if player.rate == 0 { player.play() } else { player.pause() }
            return true
        }
        return false
    }
}
