import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// The Settings window: the global shortcuts, sounds and Open at Login.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: SettingsWindow
    private let settings = ShortcutSettings.shared
    private var recorders: [ShortcutAction: ShortcutRecorder] = [:]
    private let messageLabel = NSTextField(labelWithString: "")
    private let loginCheckbox = NSButton(checkboxWithTitle: "Open Snapkeep at login", target: nil, action: nil)
    private let soundsCheckbox = NSButton(checkboxWithTitle: "Play sounds for screenshots and recordings", target: nil, action: nil)

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

        let stack = NSStackView(views: [grid, hint, messageLabel, restore, separator, soundsCheckbox, loginCheckbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(16, after: grid)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        messageLabel.widthAnchor.constraint(equalTo: hint.widthAnchor).isActive = true
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
    }

    private func showMessage(_ text: String) {
        messageLabel.stringValue = text
        messageLabel.isHidden = text.isEmpty
        // Grow or shrink downwards, keeping the title bar in place.
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
