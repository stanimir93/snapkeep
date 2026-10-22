import AppKit

/// The sounds macOS's own Screenshot tool makes: a shutter for a screenshot, and a chime when a
/// recording starts and stops. They can be turned off in Settings.
@MainActor
enum Sounds {
    static let defaultsKey = "playSounds"

    /// On unless turned off in Settings.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static func screenshot() { play("Screen Capture.aif") }
    static func recordingStarted() { play("begin_record.caf") }
    static func recordingStopped() { play("end_record.caf") }

    private static let folder = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/"
    /// NSSound stops when it's released, so each one is kept.
    private static var loaded: [String: NSSound] = [:]

    private static func play(_ name: String) {
        guard isEnabled else { return }
        let sound = loaded[name] ?? NSSound(contentsOfFile: folder + name, byReference: true)
        loaded[name] = sound
        sound?.stop()
        sound?.play()
    }
}
