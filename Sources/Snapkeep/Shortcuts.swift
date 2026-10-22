import AppKit
import Carbon.HIToolbox

/// A global shortcut: one key plus any of ⌃ ⌥ ⇧ ⌘.
struct Shortcut: Codable, Equatable {
    static let allowedModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    var keyCode: Int
    var modifiers: UInt
    /// What the key types without modifiers ("1", "a"), for the label and the menu.
    var key: String

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.allowedModifiers).rawValue
        self.key = key
    }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: Int {
        var result = 0
        if modifierFlags.contains(.command) { result |= cmdKey }
        if modifierFlags.contains(.shift) { result |= shiftKey }
        if modifierFlags.contains(.option) { result |= optionKey }
        if modifierFlags.contains(.control) { result |= controlKey }
        return result
    }

    var isFunctionKey: Bool { Self.functionKeys[keyCode] != nil }

    /// Needs ⌘, ⌥ or ⌃ (function keys excepted), so ordinary typing never triggers it.
    var isValid: Bool {
        isFunctionKey || !modifierFlags.isDisjoint(with: [.command, .option, .control])
    }

    var keyLabel: String { Self.specialKeys[keyCode] ?? Self.functionKeys[keyCode] ?? key.uppercased() }

    /// "⇧⌘1", in the order macOS menus use.
    var displayName: String { Self.symbols(for: modifierFlags) + keyLabel }

    /// The menu item's key equivalent, or "" for keys a menu can't show as a plain character.
    var menuKeyEquivalent: String {
        Self.specialKeys[keyCode] == nil && !isFunctionKey && key.count == 1 ? key.lowercased() : ""
    }

    static func symbols(for flags: NSEvent.ModifierFlags) -> String {
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
    ]

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
}

enum ShortcutAction: String, CaseIterable {
    case capture
    case captureText

    var title: String {
        switch self {
        case .capture: "Capture"
        case .captureText: "Capture Text"
        }
    }

    var defaultShortcut: Shortcut {
        switch self {
        case .capture: Shortcut(keyCode: kVK_ANSI_1, modifiers: [.shift, .command], key: "1")
        case .captureText: Shortcut(keyCode: kVK_ANSI_2, modifiers: [.shift, .command], key: "2")
        }
    }
}

enum ShortcutError: LocalizedError, Equatable {
    case needsModifier
    case duplicate(Shortcut, ShortcutAction)
    case taken(Shortcut)

    var errorDescription: String? {
        switch self {
        case .needsModifier: "A shortcut needs ⌘, ⌥ or ⌃."
        case let .duplicate(shortcut, action): "\(shortcut.displayName) is already used for \(action.title)."
        case let .taken(shortcut): "\(shortcut.displayName) is used by another app. Choose a different one."
        }
    }
}

/// Keeps the shortcuts in UserDefaults and the global hot keys in step with them.
@MainActor
final class ShortcutSettings {
    static let shared = ShortcutSettings()

    private let defaults: UserDefaults
    var handlers: [ShortcutAction: () -> Void] = [:]

    /// Off while a new shortcut is being recorded, so pressing the current one doesn't start a capture.
    var isSuspended = false {
        didSet { if isSuspended != oldValue { register() } }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The saved shortcut, the default if none was saved, or nil if the user turned it off.
    func shortcut(for action: ShortcutAction) -> Shortcut? {
        guard let data = defaults.data(forKey: Self.key(action)) else { return action.defaultShortcut }
        if data.isEmpty { return nil }
        return (try? JSONDecoder().decode(Shortcut.self, from: data)) ?? action.defaultShortcut
    }

    /// Saves a shortcut (nil turns it off) and registers it. Keeps the old one if the new one can't be used.
    func set(_ shortcut: Shortcut?, for action: ShortcutAction) throws(ShortcutError) {
        if let shortcut {
            guard shortcut.isValid else { throw .needsModifier }
            if let other = ShortcutAction.allCases.first(where: { $0 != action && self.shortcut(for: $0) == shortcut }) {
                throw .duplicate(shortcut, other)
            }
        }
        let previous = defaults.data(forKey: Self.key(action))
        // Empty data means turned off; no data at all means the default.
        defaults.set(shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: Self.key(action))
        if let shortcut, register().contains(action) {
            defaults.set(previous, forKey: Self.key(action))
            register()
            throw .taken(shortcut)
        }
    }

    /// Returns the shortcuts that another app already owns.
    @discardableResult
    func restoreDefaults() -> [ShortcutAction] {
        ShortcutAction.allCases.forEach { defaults.removeObject(forKey: Self.key($0)) }
        return register()
    }

    /// Registers every shortcut that's on. Returns the ones another app already owns.
    @discardableResult
    func register() -> [ShortcutAction] {
        HotKeys.shared.unregisterAll()
        guard !isSuspended else { return [] }
        return ShortcutAction.allCases.filter { action in
            guard let shortcut = shortcut(for: action), let handler = handlers[action] else { return false }
            return !HotKeys.shared.register(keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers, handler: handler)
        }
    }

    /// "⇧⌘1 (Capture) and ⇧⌘2 (Capture Text)", for messages about shortcuts that couldn't be registered.
    func describe(_ actions: [ShortcutAction]) -> String {
        actions.map { "\(shortcut(for: $0)?.displayName ?? "None") (\($0.title))" }.joined(separator: " and ")
    }

    private static func key(_ action: ShortcutAction) -> String { "shortcut.\(action.rawValue)" }
}
