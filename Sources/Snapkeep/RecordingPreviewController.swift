import AppKit
import AVKit

/// A finished recording: plays it on a loop, lets the user trim its start or end, and save or copy
/// it as a video, a GIF, both, or neither. The recording stays in a temporary file until it's saved.
@MainActor
final class RecordingPreviewController: NSObject, NSWindowDelegate {
    private static let bottomBarHeight: CGFloat = 52

    /// The current cut. Trimming replaces it with a shorter file.
    private(set) var recording: Recording
    var onClose: ((RecordingPreviewController) -> Void)?

    let panel: PreviewPanel
    private let library: ScreenshotLibrary
    private let playerView = AVPlayerView()
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var videoButton: NSButton!
    private var copyVideoButton: NSButton!
    private var gifButton: NSButton!
    private var copyGIFButton: NSButton!
    private let presetButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var finderButton: NSButton!
    private var trimButton: NSButton!
    private var discardButton: NSButton!
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private var minContentWidth: CGFloat = 0

    private var savedVideo: URL?
    private var savedGIF: (url: URL, preset: GIFPreset)?
    /// GIFs of the current cut already made, by preset, kept next to it until the window closes.
    private var madeGIFs: [GIFPreset: URL] = [:]
    private var copied = false
    private var exportTask: Task<Void, Never>?
    private var preset = GIFPreset.lastUsed
    /// Each preset's GIF size in bytes: estimated, then exact once that GIF is made.
    private var gifSizes: [GIFPreset: (bytes: Int, exact: Bool)] = [:]
    private var estimateTask: Task<Void, Never>?
    private var discardConfirmed = false
    /// True from opening the trim bar until the trimmed file is ready.
    private var isTrimming = false
    private var trimTask: Task<Void, Never>?
    private var trimItemStatus: NSKeyValueObservation?
    /// The recording as it was before each trim, oldest first, so ⌘Z can put a trim back.
    private var untrimmed: [Recording] = []

    private var isSaved: Bool { savedVideo != nil || savedGIF != nil }
    /// Saved or copied: closing doesn't ask first.
    private var isKept: Bool { isSaved || copied }

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
        player.isMuted = true
        startLooping()
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

        copyVideoButton = textButton("Copy Video", symbol: "doc.on.doc", tip: "Copy the MP4 video without saving it (⌘C)",
                                     action: #selector(copyVideo))
        gifButton = textButton("Save GIF", symbol: "photo.stack", tip: "Save as a GIF with the preset beside it, and copy the file (⌘G)",
                               action: #selector(saveGIF))
        copyGIFButton = textButton("Copy GIF", symbol: "doc.on.doc", tip: "Copy a GIF with the preset beside it, without saving it (⇧⌘C)",
                                   action: #selector(copyGIF))
        presetButton.controlSize = .large
        presetButton.toolTip = "How big and smooth the GIF is, and about how much space it takes"
        updatePresetMenu()
        finderButton = textButton("Show in Finder", symbol: "folder", tip: "Show the saved file", action: #selector(showInFinder))
        finderButton.isEnabled = false
        trimButton = textButton("Trim", symbol: "timeline.selection", tip: "Cut off the start or the end (⌘T)", action: #selector(trim))
        discardButton = textButton("Discard", symbol: "trash", tip: "Throw the recording away (⌘⌫)", action: #selector(discard))

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

        let bar = NSStackView(views: [videoButton, copyVideoButton, gifButton, copyGIFButton, presetButton,
                                      trimButton, finderButton, discardButton, progress, statusLabel])
        bar.spacing = 8
        bar.setCustomSpacing(16, after: copyVideoButton)
        bar.setCustomSpacing(4, after: copyGIFButton)
        bar.setCustomSpacing(16, after: presetButton)
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

    /// Asks first if nothing was saved or copied.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isKept || discardConfirmed { return true }
        let alert = NSAlert()
        alert.messageText = "Discard this recording?"
        alert.informativeText = "It hasn't been saved or copied as a video or a GIF."
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
        trimTask?.cancel()
        trimItemStatus = nil
        player.pause()
        looper = nil
        player.removeAllItems()
        for file in untrimmed.map(\.url) + [recording.url] + Array(madeGIFs.values) {
            try? FileManager.default.removeItem(at: file)
        }
        onClose?(self)
    }

    private func startLooping() {
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: recording.url))
        player.play()
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
        guard !isTrimming else { return }
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

    @objc private func copyVideo() {
        guard !isTrimming else { return }
        if let savedVideo {
            Clipboard.copyFile(savedVideo)
            didCopy(savedVideo)
            return
        }
        do {
            let url = try ClipboardFiles.stage(recording.url, as: "mp4")
            Clipboard.copyFile(url)
            didCopy(url)
        } catch {
            statusLabel.stringValue = "Couldn't copy: \(error.localizedDescription)"
        }
    }

    @objc private func saveGIF() {
        if let savedGIF, savedGIF.preset == preset {
            Clipboard.copyFile(savedGIF.url)
            statusLabel.stringValue = "Copied \(savedGIF.url.lastPathComponent)"
            return
        }
        makeGIF { [weak self] gif, preset in
            guard let self else { return }
            let url = try self.library.newFileURL(prefix: "recording", extension: "gif")
            try FileManager.default.copyItem(at: gif, to: url)
            self.savedGIF = (url, preset)
            self.didSave(url, detail: self.fileSize(url))
        }
    }

    @objc private func copyGIF() {
        if let savedGIF, savedGIF.preset == preset {
            Clipboard.copyFile(savedGIF.url)
            didCopy(savedGIF.url)
            return
        }
        makeGIF { [weak self] gif, _ in
            let url = try ClipboardFiles.stage(gif, as: "gif")
            Clipboard.copyFile(url)
            self?.didCopy(url)
        }
    }

    /// Hands the selected preset's GIF to `then`, making it first unless it's already made.
    private func makeGIF(then: @escaping @MainActor (URL, GIFPreset) throws -> Void) {
        guard exportTask == nil, !isTrimming else { return }
        let preset = preset
        if let made = madeGIFs[preset] {
            do { try then(made, preset) } catch { statusLabel.stringValue = "Couldn't keep the GIF: \(error.localizedDescription)" }
            return
        }
        setGIFControlsEnabled(false)
        progress.doubleValue = 0
        progress.isHidden = false
        statusLabel.stringValue = "Making GIF…"

        let video = recording.url, pointSize = recording.pointSize
        let output = video.deletingPathExtension().appendingPathExtension("\(preset.rawValue).gif")
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.progress.doubleValue = fraction }
        }
        exportTask = Task { @MainActor [weak self] in
            let result: Result<Int, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try await GIFExporter.export(video: video, pointSize: pointSize, preset: preset,
                                                                 to: output, progress: report))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self, !Task.isCancelled else {
                try? FileManager.default.removeItem(at: output)
                return
            }
            self.exportTask = nil
            self.progress.isHidden = true
            self.setGIFControlsEnabled(true)
            do {
                let bytes = try result.get()
                self.madeGIFs[preset] = output
                self.gifSizes[preset] = (bytes, true)
                self.updatePresetMenu()
                try then(output, preset)
            } catch {
                self.statusLabel.stringValue = "Couldn't make the GIF: \(error.localizedDescription)"
            }
        }
    }

    private func setGIFControlsEnabled(_ enabled: Bool) {
        for button in [gifButton, copyGIFButton, presetButton, trimButton] as [NSButton] { button.isEnabled = enabled }
    }

    private func didCopy(_ url: URL) {
        copied = true
        Toast.show("Copied \(url.pathExtension.uppercased())", detail: "\(url.lastPathComponent)  ·  \(fileSize(url))",
                   symbol: "doc.on.clipboard.fill")
        showDetails()
        statusLabel.stringValue = "Copied \(url.pathExtension.uppercased())  ·  \(fileSize(url))"
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
        guard !isTrimming else { return }
        discardConfirmed = true
        panel.close()
        if !isSaved { Toast.show("Recording discarded", symbol: "trash") }
    }

    // MARK: Trim

    /// Opens the trim bar under the video: drag its yellow ends in, then click Trim.
    @objc func trim() {
        guard !isTrimming, exportTask == nil else { return }
        setTrimming(true)
        // The trim bar edits one player item, not the looper's copies of it.
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        let item = AVPlayerItem(url: recording.url)
        player.insert(item, after: nil)
        trimItemStatus = item.observe(\.status, options: [.initial]) { [weak self] item, _ in
            guard item.status != .unknown else { return }
            Task { @MainActor in self?.beginTrimming(item) }
        }
    }

    private func beginTrimming(_ item: AVPlayerItem) {
        guard trimItemStatus != nil else { return }
        trimItemStatus = nil
        guard item.status == .readyToPlay, playerView.canBeginTrimming else {
            endTrimming()
            statusLabel.stringValue = "This recording can't be trimmed"
            return
        }
        player.play()
        playerView.beginTrimming { [weak self] result in
            Task { @MainActor in self?.finishTrimming(item, keep: result == .okButton) }
        }
    }

    private func finishTrimming(_ item: AVPlayerItem, keep: Bool) {
        let full = CMTime(seconds: recording.duration, preferredTimescale: 600)
        let start = item.reversePlaybackEndTime.isNumeric ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isNumeric ? min(item.forwardPlaybackEndTime, full) : full
        let tolerance = CMTime(value: 1, timescale: 100)
        guard keep, end - start > tolerance, start > tolerance || full - end > tolerance else {
            endTrimming()
            return
        }

        statusLabel.stringValue = "Trimming…"
        progress.isIndeterminate = true
        progress.isHidden = false
        progress.startAnimation(nil)
        let source = recording
        let output = source.url.deletingLastPathComponent().appendingPathComponent("recording-\(UUID().uuidString).mp4")
        trimTask = Task { @MainActor [weak self] in
            let result: Result<Double, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try await VideoTrimmer.trim(video: source.url, range: CMTimeRange(start: start, end: end), to: output))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self, !Task.isCancelled else {
                try? FileManager.default.removeItem(at: output)
                return
            }
            self.trimTask = nil
            self.progress.stopAnimation(nil)
            self.progress.isIndeterminate = false
            self.progress.isHidden = true
            switch result {
            case let .success(duration):
                self.untrimmed.append(source)
                self.replaceRecording(Recording(url: output, pointSize: source.pointSize, pixelSize: source.pixelSize, duration: duration))
                Toast.show("Trimmed to \(formatDuration(duration))", detail: "⌘Z puts back the part you cut", symbol: "timeline.selection")
            case let .failure(error):
                try? FileManager.default.removeItem(at: output)
                self.endTrimming()
                self.statusLabel.stringValue = "Couldn't trim: \(error.localizedDescription)"
            }
        }
    }

    /// Puts back the recording as it was before the last trim.
    private func undoTrim() {
        guard !isTrimming, exportTask == nil, let previous = untrimmed.popLast() else { return }
        try? FileManager.default.removeItem(at: recording.url)
        replaceRecording(previous)
        Toast.show("Trim undone", detail: formatDuration(previous.duration), symbol: "arrow.uturn.backward")
    }

    /// A new cut is a different recording: what was saved or copied, the GIFs made and every GIF
    /// size no longer apply.
    private func replaceRecording(_ new: Recording) {
        player.removeAllItems()
        recording = new
        savedVideo = nil
        savedGIF = nil
        copied = false
        madeGIFs.values.forEach { try? FileManager.default.removeItem(at: $0) }
        madeGIFs = [:]
        discardConfirmed = false
        estimateTask?.cancel()
        gifSizes = [:]
        panel.title = "Recording, \(formatDuration(new.duration))"
        updatePresetMenu()
        endTrimming()
        estimateGIFSizes()
    }

    private func endTrimming() {
        setTrimming(false)
        startLooping()
        showDetails()
    }

    /// While the trim bar is open, its own Trim and Cancel buttons take Return and Escape.
    private func setTrimming(_ trimming: Bool) {
        isTrimming = trimming
        for button in [videoButton, copyVideoButton, gifButton, copyGIFButton, presetButton, trimButton, discardButton] as [NSButton] {
            button.isEnabled = !trimming
        }
        finderButton.isEnabled = !trimming && isSaved
        videoButton.keyEquivalent = trimming ? "" : "\r"
    }

    // MARK: Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        if isTrimming { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if modifiers == .command {
            switch key {
            case "s": saveVideo()
            case "c": copyVideo()
            case "g": saveGIF()
            case "t": trim()
            case "z": undoTrim()
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
        if modifiers == [.command, .shift], key == "c" {
            copyGIF()
            return true
        }
        if modifiers.isEmpty, key == " " {
            if player.rate == 0 { player.play() } else { player.pause() }
            return true
        }
        return false
    }
}
