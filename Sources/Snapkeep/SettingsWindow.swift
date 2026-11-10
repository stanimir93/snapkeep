import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// The Settings window: the global shortcuts, sounds, Open at Login and the custom preview buttons.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: SettingsWindow
    private let settings = ShortcutSettings.shared
    private var recorders: [ShortcutAction: ShortcutRecorder] = [:]
    private let messageLabel = NSTextField(labelWithString: "")
    private let loginCheckbox = NSButton(checkboxWithTitle: "Open Snapkeep at login", target: nil, action: nil)
    private let soundsCheckbox = NSButton(checkboxWithTitle: "Play sounds for screenshots and recordings", target: nil, action: nil)
    private let pagesCheckbox = NSButton(checkboxWithTitle: "Pick just the page in browser windows", target: nil, action: nil)
    private let pagesHint = NSTextField(wrappingLabelWithString: "")
    private let pagesAccessButton = NSButton(title: "Open Accessibility Settings", target: nil, action: nil)
    private let buttonsLabel = NSTextField(wrappingLabelWithString: "")
    private let t3Checkbox = NSButton(checkboxWithTitle: "Send to T3 Code button", target: nil, action: nil)
    /// One row per custom button, with a colour well.
    private let colorRows = NSStackView()
    private var colorButtons: [CustomButton] = []

    override init() {
        window = SettingsWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Snapkeep Settings"
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self
        buildContent()
    }

    func show() {
        refresh()
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Picks up edits made to custom-buttons.json while the window was in the background.
    func windowDidBecomeKey(_ notification: Notification) {
        refreshButtons()
        refreshPages()
    }

    func windowWillClose(_ notification: Notification) {
        recorders.values.forEach { $0.stopRecording() }
    }

    /// For the self-check render.
    func renderWindow(to url: URL) throws {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private func buildContent() {
        var rows: [[NSView]] = []
        for action in ShortcutAction.allCases {
            let recorder = ShortcutRecorder()
            recorder.onRecordingChange = { [weak self] recording in self?.settings.isSuspended = recording }
            recorder.onRecord = { [weak self] shortcut in self?.apply(shortcut, to: action) }
            recorder.widthAnchor.constraint(equalToConstant: 150).isActive = true
            recorders[action] = recorder
            rows.append([NSTextField(labelWithString: "\(action.title):"), recorder])
        }
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 10
        grid.rowSpacing = 10

        let hint = NSTextField(wrappingLabelWithString:
            "Click a shortcut, then press the new keys. Use ⌘, ⌥ or ⌃ with a key. Esc cancels, Delete turns the shortcut off.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.widthAnchor.constraint(equalToConstant: 320).isActive = true

        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageLabel.textColor = .systemRed
        messageLabel.cell?.wraps = true
        messageLabel.isHidden = true

        let restore = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleOpenAtLogin)
        soundsCheckbox.target = self
        soundsCheckbox.action = #selector(toggleSounds)
        let separator = NSBox()
        separator.boxType = .separator
        pagesCheckbox.target = self
        pagesCheckbox.action = #selector(togglePages)
        pagesCheckbox.toolTip = "Hovering a page in Zen, Chrome, Safari, Arc or another browser picks the page without "
            + "the tabs, toolbar or sidebar. Hover the browser's own bar to pick the whole window."
        pagesHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pagesHint.preferredMaxLayoutWidth = 300
        pagesAccessButton.target = self
        pagesAccessButton.action = #selector(openAccessibilitySettings)
        pagesAccessButton.controlSize = .small

        let buttonsTitle = NSTextField(labelWithString: "Custom buttons")
        buttonsTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        buttonsLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        buttonsLabel.preferredMaxLayoutWidth = 320
        t3Checkbox.target = self
        t3Checkbox.action = #selector(toggleSendToT3)
        t3Checkbox.toolTip = "A button that puts the screenshot in the open thread in T3 Code, like T3's own Snap Shot. "
            + "Needs Snap Shot turned on in T3 Code's settings."
        let openConfig = NSButton(title: "Open Config File", target: self, action: #selector(openButtonsConfig))
        openConfig.toolTip = CustomButtons.defaultURL.path
        let buttonsSeparator = NSBox()
        buttonsSeparator.boxType = .separator

        colorRows.orientation = .vertical
        colorRows.alignment = .leading
        colorRows.spacing = 6

        let stack = NSStackView(views: [grid, hint, messageLabel, restore, separator, soundsCheckbox, loginCheckbox,
                                        pagesCheckbox, pagesHint, pagesAccessButton,
                                        buttonsSeparator, buttonsTitle, t3Checkbox, buttonsLabel, colorRows, openConfig])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(16, after: grid)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        buttonsSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        stack.setCustomSpacing(6, after: buttonsTitle)
        stack.setCustomSpacing(4, after: pagesCheckbox)
        stack.setCustomSpacing(6, after: pagesHint)
        pagesHint.widthAnchor.constraint(equalTo: hint.widthAnchor, constant: -20).isActive = true
        messageLabel.widthAnchor.constraint(equalTo: hint.widthAnchor).isActive = true
        buttonsLabel.widthAnchor.constraint(equalTo: hint.widthAnchor).isActive = true
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
    }

    private func showMessage(_ text: String) {
        messageLabel.stringValue = text
        messageLabel.isHidden = text.isEmpty
        fitHeight()
    }

    /// Grows or shrinks downwards, keeping the title bar in place.
    private func fitHeight() {
        guard let content = window.contentView else { return }
        var frame = window.frame
        let height = window.frameRect(forContentRect: NSRect(origin: .zero, size: content.fittingSize)).height
        frame.origin.y += frame.height - height
        frame.size.height = height
        window.setFrame(frame, display: true)
    }

    private func refresh() {
        for (action, recorder) in recorders {
            recorder.shortcut = settings.shortcut(for: action)
        }
        loginCheckbox.state = LoginItem.isEnabled ? .on : .off
        soundsCheckbox.state = Sounds.isEnabled ? .on : .off
        refreshButtons()
        refreshPages()
    }

    private func refreshPages() {
        pagesCheckbox.state = BrowserPages.isEnabled ? .on : .off
        let missingAccess = BrowserPages.isEnabled && !BrowserPages.isTrusted
        pagesHint.stringValue = missingAccess
            ? "Needs Accessibility permission. Turn on Snapkeep in Privacy & Security › Accessibility."
            : "Hover the tabs or toolbar to pick the whole window. Needs Accessibility permission."
        pagesHint.textColor = missingAccess ? .systemRed : .secondaryLabelColor
        let wasHidden = pagesAccessButton.isHidden
        pagesAccessButton.isHidden = !missingAccess
        if wasHidden != pagesAccessButton.isHidden, window.isVisible { fitHeight() }
    }

    private func refreshButtons() {
        let loaded = CustomButtons.load()
        var lines: [String] = []
        if loaded.buttons.isEmpty {
            lines.append("Add your own buttons to the screenshot preview. Each one runs a shell command with the image, "
                + "or sends it to T3 Code.")
        } else {
            let names = loaded.buttons.map { button in button.key.map { "\(button.title) (⌘\($0.uppercased()))" } ?? button.title }
            lines.append("In the capture bar and new previews: \(names.joined(separator: ", ")).")
        }
        lines += loaded.problems
        buttonsLabel.stringValue = lines.joined(separator: "\n")
        buttonsLabel.textColor = loaded.problems.isEmpty ? .secondaryLabelColor : .systemRed
        rebuildColorRows(loaded.buttons)
        let hasT3 = loaded.buttons.contains { $0.action == .t3code }
        t3Checkbox.state = hasT3 ? .on : .off
        if window.isVisible { fitHeight() }
    }

    /// "Send to T3  [colour]  Default" for each button.
    private func rebuildColorRows(_ buttons: [CustomButton]) {
        // Leave the rows alone while the colour panel is editing one of them.
        if buttons == colorButtons, !colorRows.arrangedSubviews.isEmpty { return }
        colorButtons = buttons
        colorRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        colorRows.isHidden = buttons.isEmpty
        for (index, button) in buttons.enumerated() {
            let name = NSTextField(labelWithString: button.title)
            name.widthAnchor.constraint(equalToConstant: 130).isActive = true
            name.lineBreakMode = .byTruncatingTail
            let well = NSColorWell(style: .minimal)
            well.color = button.displayColor
            well.tag = index
            well.target = self
            well.action = #selector(colorPicked)
            well.toolTip = "The button's colour"
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            let reset = NSButton(title: "Default", target: self, action: #selector(resetColor))
            reset.tag = index
            reset.controlSize = .small
            reset.isEnabled = button.color != nil
            reset.toolTip = button.action == .t3code ? "T3 Code pink" : "Grey"
            let row = NSStackView(views: [name, well, reset])
            row.spacing = 8
            colorRows.addArrangedSubview(row)
        }
    }

    @objc private func colorPicked(_ sender: NSColorWell) {
        setColor(sender.color.hexString, at: sender.tag)
    }

    @objc private func resetColor(_ sender: NSButton) {
        NSColorPanel.shared.close()
        setColor(nil, at: sender.tag)
    }

    private func setColor(_ hex: String?, at index: Int) {
        guard colorButtons.indices.contains(index) else { return }
        do {
            try CustomButtons.setColor(hex, forButtonAt: colorButtons[index].fileIndex)
            showMessage("")
        } catch {
            showMessage(error.localizedDescription)
        }
        let loaded = CustomButtons.load()
        // Update in place, so the colour well being edited stays connected to the panel.
        colorButtons = loaded.buttons
        for case let row as NSStackView in colorRows.arrangedSubviews {
            for case let reset as NSButton in row.arrangedSubviews where reset.action == #selector(resetColor) {
                reset.isEnabled = colorButtons.indices.contains(reset.tag) && colorButtons[reset.tag].color != nil
            }
            for case let well as NSColorWell in row.arrangedSubviews where hex == nil && colorButtons.indices.contains(well.tag) {
                well.color = colorButtons[well.tag].displayColor
            }
        }
    }

    @objc private func toggleSendToT3() {
        do {
            if t3Checkbox.state == .on {
                try CustomButtons.addT3Code()
            } else {
                NSColorPanel.shared.close()
                try CustomButtons.removeT3Code()
            }
        } catch {
            showMessage(error.localizedDescription)
            NSSound.beep()
        }
        refreshButtons()
    }

    @objc private func openButtonsConfig() {
        let url = CustomButtons.defaultURL
        do {
            try CustomButtons.createIfMissing(at: url)
        } catch {
            showMessage(error.localizedDescription)
            return
        }
        // A .json file may have no app set to open it, so fall back to TextEdit.
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func apply(_ shortcut: Shortcut?, to action: ShortcutAction) {
        do {
            try settings.set(shortcut, for: action)
            showMessage("")
        } catch {
            showMessage(error.localizedDescription)
            NSSound.beep()
        }
        refresh()
    }

    @objc private func restoreDefaults() {
        let failed = settings.restoreDefaults()
        showMessage(failed.isEmpty ? "" : "\(settings.describe(failed)) \(failed.count == 1 ? "is" : "are") used by another app.")
        refresh()
    }

    @objc private func toggleSounds() {
        Sounds.isEnabled = soundsCheckbox.state == .on
        // Let the user hear what they turned on.
        Sounds.screenshot()
    }

    @objc private func togglePages() {
        BrowserPages.isEnabled = pagesCheckbox.state == .on
        if BrowserPages.isEnabled, !BrowserPages.isTrusted { BrowserPages.requestAccess() }
        refreshPages()
    }

    @objc private func openAccessibilitySettings() {
        BrowserPages.openAccessibilitySettings()
    }

    @objc private func toggleOpenAtLogin() {
        LoginItem.toggle()
        refresh()
    }
}

/// Lets ⌘W close the window, since Snapkeep has no main menu.
private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let recording = (firstResponder as? ShortcutRecorder)?.isRecording == true
        if !recording, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// A button that shows a shortcut and, once clicked, records the next key combination.
@MainActor
final class ShortcutRecorder: NSButton {
    var shortcut: Shortcut? {
        didSet { updateTitle() }
    }
    var onRecord: ((Shortcut?) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    private(set) var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            onRecordingChange?(isRecording)
            updateTitle()
        }
    }
    private var heldModifiers: NSEvent.ModifierFlags = []

    init() {
        super.init(frame: .zero)
        bezelStyle = .push
        target = self
        action = #selector(toggleRecording)
        updateTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var acceptsFirstResponder: Bool { true }

    func stopRecording() {
        heldModifiers = []
        isRecording = false
    }

    @objc private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            isRecording = true
            window?.makeFirstResponder(self)
        }
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    // ⌘ combinations arrive here rather than in keyDown.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        record(event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        heldModifiers = event.modifierFlags.intersection(Shortcut.allowedModifiers)
        updateTitle()
    }

    private func record(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(Shortcut.allowedModifiers)
        let keyCode = Int(event.keyCode)
        if modifiers.isEmpty, keyCode == kVK_Escape {
            stopRecording()
            return
        }
        if modifiers.isEmpty, keyCode == kVK_Delete || keyCode == kVK_ForwardDelete {
            stopRecording()
            onRecord?(nil)
            return
        }
        let key = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? ""
        let shortcut = Shortcut(keyCode: keyCode, modifiers: modifiers, key: key)
        guard shortcut.isValid else {
            NSSound.beep()
            return
        }
        stopRecording()
        onRecord?(shortcut)
    }

    private func updateTitle() {
        if isRecording {
            title = heldModifiers.isEmpty ? "Type a shortcut…" : Shortcut.symbols(for: heldModifiers) + "…"
        } else {
            title = shortcut?.displayName ?? "None"
        }
    }
}

/// Open at Login through SMAppService, shared by the menu and the Settings window.
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func toggle() {
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
}
