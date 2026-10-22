import AppKit
import VisionKit

/// A floating panel that hands its key presses to the preview before normal handling,
/// so single-letter tool keys and ⌘ shortcuts work without a main menu.
final class PreviewPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let keyHandler, keyHandler(event) { return }
        super.sendEvent(event)
    }
}

/// One screenshot on screen: the image, its Live Text overlay, the drawing layer and the toolbars.
@MainActor
final class PreviewController: NSObject, NSWindowDelegate {
    private static let topBarHeight: CGFloat = 44
    private static let bottomBarHeight: CGFloat = 52
    private static var barsHeight: CGFloat { topBarHeight + bottomBarHeight }

    private static let colors: [(String, NSColor)] = [
        ("Red", .systemRed),
        ("Yellow", .systemYellow),
        ("Green", .systemGreen),
        ("Blue", .systemBlue),
        ("Black", .black),
    ]

    let screenshot: Screenshot
    var url: URL { screenshot.url }
    var onClose: ((PreviewController) -> Void)?

    let panel: PreviewPanel
    private let imageView = NSImageView()
    private let overlay = ImageAnalysisOverlayView()
    private let canvas: CanvasView
    private let toolPicker = NSSegmentedControl()
    private var swatches: [SwatchButton] = []
    private var undoButton: NSButton!
    private var clearButton: NSButton!
    private var copyTextButton: NSButton!
    private let statusLabel = NSTextField(labelWithString: "")

    private var transcript = ""
    private var baseStatus = ""
    private var statusResetWork: DispatchWorkItem?
    private var analysisTask: Task<Void, Never>?
    /// Width ÷ height of the image area, kept while resizing.
    private var areaAspect: CGFloat = 1
    private var minContentWidth: CGFloat = 0

    /// Finishes when Live Text analysis does; used by the --render-preview self-check.
    private(set) var analysisDone: Task<Void, Never>?

    init(screenshot: Screenshot, initialStatus: String? = nil) {
        self.screenshot = screenshot
        canvas = CanvasView(pixelSize: screenshot.pixelSize, pointSize: screenshot.pointSize)
        panel = PreviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            // Non-activating, like Spotlight: the panel takes keyboard focus even when macOS
            // declines to bring a menu bar app to the front.
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        super.init()
        buildWindow()
        sizeWindow()
        if let initialStatus { flash(initialStatus) }
        startTextAnalysis()
    }

    // MARK: Window

    private func buildWindow() {
        panel.title = url.lastPathComponent
        panel.representedURL = url
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.delegate = self
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }

        let image = NSImage(cgImage: screenshot.cgImage, size: screenshot.pointSize)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.isEditable = false
        imageView.unregisterDraggedTypes()
        imageView.autoresizingMask = [.width, .height]

        overlay.preferredInteractionTypes = .textSelection
        overlay.isSupplementaryInterfaceHidden = true
        overlay.autoresizingMask = [.width, .height]
        imageView.addSubview(overlay)
        overlay.frame = imageView.bounds
        overlay.trackingImageView = imageView

        canvas.autoresizingMask = [.width, .height]
        canvas.onChange = { [weak self] in self?.updateButtons() }

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        container.addSubview(imageView)
        container.addSubview(canvas)

        let topBar = makeTopBar()
        let bottomBar = makeBottomBar()
        let topLine = NSBox(), bottomLine = NSBox()
        topLine.boxType = .separator
        bottomLine.boxType = .separator
        let content = NSView()
        for view in [topBar, container, bottomBar, topLine, bottomLine] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: content.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: Self.topBarHeight),
            container.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: Self.bottomBarHeight),
            topLine.topAnchor.constraint(equalTo: container.topAnchor),
            topLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomLine.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bottomLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        panel.contentView = content
        minContentWidth = ceil(max(topBar.fittingSize.width, bottomBar.fittingSize.width))

        selectTool(.select)
        selectColor(0)
        updateButtons()
    }

    private func makeTopBar() -> NSView {
        toolPicker.segmentCount = Tool.allCases.count
        toolPicker.trackingMode = .selectOne
        toolPicker.segmentStyle = .separated
        for tool in Tool.allCases {
            let symbol = tool.symbols.lazy.compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: tool.title) }.first
            if let symbol {
                toolPicker.setImage(symbol, forSegment: tool.rawValue)
                toolPicker.setWidth(34, forSegment: tool.rawValue)
            } else {
                toolPicker.setLabel(tool.title, forSegment: tool.rawValue)
            }
            toolPicker.setToolTip("\(tool.title) (\(tool.key.uppercased()))", forSegment: tool.rawValue)
        }
        toolPicker.target = self
        toolPicker.action = #selector(toolPicked)

        swatches = Self.colors.enumerated().map { index, entry in
            let swatch = SwatchButton(color: entry.1, name: entry.0, target: self, action: #selector(swatchPicked))
            swatch.tag = index
            return swatch
        }
        let swatchRow = NSStackView(views: swatches)
        swatchRow.spacing = 2

        undoButton = iconButton("arrow.uturn.backward", fallback: "Undo", tip: "Undo (⌘Z)", action: #selector(undo))
        clearButton = iconButton("trash", fallback: "Clear", tip: "Clear all drawings", action: #selector(clearDrawings))

        let bar = NSStackView(views: [toolPicker, swatchRow, flexibleSpace(), undoButton, clearButton])
        bar.spacing = 12
        bar.setCustomSpacing(4, after: undoButton)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        bar.alignment = .centerY
        return bar
    }

    private func makeBottomBar() -> NSView {
        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyImage))
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyButton.imagePosition = .imageLeading
        copyButton.controlSize = .large
        copyButton.font = .systemFont(ofSize: NSFont.systemFontSize(for: .large), weight: .semibold)
        copyButton.keyEquivalent = "\r" // default button: drawn in the accent colour, Return copies
        copyButton.toolTip = "Copy the image with drawings (⌘C)"
        copyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true

        copyTextButton = textButton("Copy Text", symbol: "text.viewfinder", tip: "Copy all the text in the screenshot", action: #selector(copyAllText))
        let saveButton = textButton("Save", symbol: "square.and.arrow.down", tip: "Save the drawings into the file (⌘S)", action: #selector(save))
        let finderButton = textButton("Show in Finder", symbol: "folder", tip: url.path, action: #selector(showInFinder))

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.alignment = .right
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true

        let bar = NSStackView(views: [copyButton, copyTextButton, saveButton, finderButton, statusLabel])
        bar.spacing = 8
        bar.setCustomSpacing(14, after: copyButton)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        bar.alignment = .centerY
        return bar
    }

    private func iconButton(_ symbol: String, fallback: String, tip: String, action: Selector) -> NSButton {
        let button: NSButton
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: fallback) {
            button = NSButton(image: image, target: self, action: action)
        } else {
            button = NSButton(title: fallback, target: self, action: action)
        }
        button.bezelStyle = .toolbar
        button.toolTip = tip
        return button
    }

    private func textButton(_ title: String, symbol: String, tip: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.controlSize = .large
        button.toolTip = tip
        return button
    }

    private func flexibleSpace() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }

    /// Opens at the screenshot's real size, shrunk to fit within about 70% of the screen.
    private func sizeWindow() {
        let visible = (NSScreen.withMouse ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let points = screenshot.pointSize
        let maxWidth = visible.width * 0.7
        let maxHeight = visible.height * 0.7 - Self.barsHeight
        let scale = min(1, maxWidth / max(points.width, 1), maxHeight / max(points.height, 1))
        let area = CGSize(width: max(points.width * scale, minContentWidth), height: max(points.height * scale, 80))
        areaAspect = area.width / area.height
        panel.setContentSize(NSSize(width: area.width, height: area.height + Self.barsHeight))
        panel.contentMinSize = NSSize(width: minContentWidth, height: minContentWidth / areaAspect + Self.barsHeight)
    }

    /// Shows the panel, offset from the previews already open so none hides another.
    func show(cascadeIndex: Int) {
        let visible = (NSScreen.withMouse ?? NSScreen.main)?.visibleFrame ?? .zero
        var frame = panel.frame
        let offset = CGFloat(cascadeIndex % 10) * 30
        frame.origin.x = visible.midX - frame.width / 2 + offset
        frame.origin.y = visible.midY - frame.height / 2 - offset
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        panel.setFrame(frame, display: false)
        bringToFront()
    }

    func bringToFront() {
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel.close()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let proposed = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let width = max(proposed.width, minContentWidth)
        let content = NSSize(width: width, height: width / areaAspect + Self.barsHeight)
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        canvas.commitText()
    }

    func windowDidResize(_ notification: Notification) {
        overlay.setContentsRectNeedsUpdate()
    }

    func windowWillClose(_ notification: Notification) {
        analysisTask?.cancel()
        canvas.commitText()
        onClose?(self)
    }

    // MARK: Live Text

    private func startTextAnalysis() {
        guard TextRecognizer.isSupported else {
            setBaseStatus("Live Text isn't available on this Mac")
            return
        }
        setBaseStatus("Finding text…")
        let image = screenshot.cgImage
        let task = Task { @MainActor [weak self] in
            let started = Date()
            do {
                let analysis = try await TextRecognizer.analyze(image)
                guard let self, !Task.isCancelled else { return }
                self.overlay.analysis = analysis
                self.transcript = analysis.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                let seconds = String(format: "%.2f", Date().timeIntervalSince(started))
                self.setBaseStatus(self.transcript.isEmpty ? "No text found" : "Text ready in \(seconds) s")
            } catch {
                self?.setBaseStatus("Text recognition failed")
            }
            self?.updateButtons()
        }
        analysisTask = task
        analysisDone = task
    }

    // MARK: Status

    private func setBaseStatus(_ text: String) {
        baseStatus = text
        if statusResetWork == nil { statusLabel.stringValue = text }
    }

    /// Shows a message for a moment, then goes back to the Live Text status.
    private func flash(_ text: String) {
        statusResetWork?.cancel()
        statusLabel.stringValue = text
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.statusResetWork = nil
            self.statusLabel.stringValue = self.baseStatus
        }
        statusResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func updateButtons() {
        undoButton.isEnabled = canvas.canUndo
        clearButton.isEnabled = !canvas.annotations.isEmpty
        copyTextButton.isEnabled = !transcript.isEmpty
    }

    // MARK: Tools

    @objc private func toolPicked() {
        selectTool(Tool(rawValue: toolPicker.selectedSegment) ?? .select)
    }

    private func selectTool(_ tool: Tool) {
        canvas.tool = tool
        toolPicker.selectedSegment = tool.rawValue
        // A text selection left behind would make ⌘C copy text instead of the drawing.
        if tool != .select { overlay.resetSelection() }
    }

    @objc private func swatchPicked(_ sender: SwatchButton) {
        selectColor(sender.tag)
    }

    private func selectColor(_ index: Int) {
        canvas.color = Self.colors[index].1
        for swatch in swatches { swatch.isChosen = swatch.tag == index }
    }

    @objc private func undo() {
        canvas.undo()
    }

    @objc private func clearDrawings() {
        canvas.clear()
    }

    // MARK: Actions

    /// The PNG to copy or save: the original file if nothing was drawn, otherwise a full-resolution render.
    func currentPNG() -> Data? {
        canvas.commitText()
        if canvas.annotations.isEmpty { return screenshot.pngData }
        return Renderer.pngData(base: screenshot.cgImage, pointSize: screenshot.pointSize, annotations: canvas.annotations)
    }

    @objc func copyImage() {
        guard let data = currentPNG() else {
            flash("Couldn't render the image")
            return
        }
        Clipboard.copyPNG(data)
        flash(canvas.annotations.isEmpty ? "Copied image" : "Copied image with drawings")
    }

    @objc private func copyAllText() {
        guard !transcript.isEmpty else { return }
        Clipboard.copyText(transcript)
        flash("Copied all text")
    }

    /// ⌘C: the selected text if there is any, otherwise the image.
    private func copySelectionOrImage() {
        let selected = overlay.hasActiveTextSelection ? overlay.selectedText : ""
        if !selected.isEmpty {
            Clipboard.copyText(selected)
            flash("Copied selected text")
        } else {
            copyImage()
        }
    }

    @objc private func save() {
        guard let data = currentPNG() else {
            flash("Couldn't render the image")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            flash("Saved")
        } catch {
            flash("Save failed: \(error.localizedDescription)")
        }
    }

    @objc private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let typing = canvas.isEditingText

        if modifiers == .command {
            switch key {
            case "c":
                if typing { return false } // let the text field copy
                copySelectionOrImage()
            case "s":
                save()
            case "z":
                if typing { return false }
                canvas.undo()
            case "w":
                close()
            default:
                return false
            }
            return true
        }

        guard modifiers.isEmpty, !typing else { return false }
        if event.keyCode == 53 { // Esc clears a text selection
            overlay.resetSelection()
            return true
        }
        if let tool = Tool.allCases.first(where: { $0.key == key }) {
            selectTool(tool)
            return true
        }
        return false
    }

    // MARK: Self-check

    /// Renders the panel's contents to a PNG, so the layout can be checked without screen access.
    func renderWindow(to url: URL) throws {
        guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Simulates drawing for the self-check render.
    func addSampleDrawings() {
        selectTool(.rectangle)
        let samples: [Annotation] = [
            .rectangle(CGRect(x: screenshot.pixelSize.width * 0.1, y: screenshot.pixelSize.height * 0.2,
                              width: screenshot.pixelSize.width * 0.5, height: screenshot.pixelSize.height * 0.5),
                       color: .systemRed, width: 8),
            .arrow(from: CGPoint(x: screenshot.pixelSize.width * 0.9, y: screenshot.pixelSize.height * 0.9),
                   to: CGPoint(x: screenshot.pixelSize.width * 0.62, y: screenshot.pixelSize.height * 0.55),
                   color: .systemBlue, width: 10),
            .highlighter(points: [CGPoint(x: screenshot.pixelSize.width * 0.1, y: screenshot.pixelSize.height * 0.12),
                                  CGPoint(x: screenshot.pixelSize.width * 0.5, y: screenshot.pixelSize.height * 0.12)],
                         color: .systemYellow, width: 36),
            .text("Snapkeep", origin: CGPoint(x: screenshot.pixelSize.width * 0.65, y: screenshot.pixelSize.height * 0.2),
                  color: .systemGreen, fontSize: 48),
        ]
        samples.forEach(canvas.add)
    }
}
