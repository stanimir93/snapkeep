import AppKit

/// The window a screenshot was taken from, for actions that say where it came from.
struct CaptureSource: Equatable {
    var appName: String
    var windowTitle: String
    var bundleID: String?
    var processID: pid_t?
}

/// A button you add to the preview's bottom bar in custom-buttons.json.
struct CustomButton: Equatable {
    enum Action: String {
        /// Runs a shell command with the screenshot.
        case command
        /// Hands the screenshot to T3 Code the way its own Snap Shot does.
        case t3code
    }

    var title: String
    var symbol: String?
    var action: Action
    var command: String?
    /// The key that presses the button with ⌘ in the preview.
    var key: String?
    var closePreview: Bool
    /// "#rrggbb", or nil for the default.
    var color: String? = nil
    /// Its position in the file's list, which can differ when some entries couldn't be used.
    var fileIndex = 0

    /// ⌘C, ⌘S, ⌘W and ⌘Z already do something in the preview.
    static let reservedKeys: Set<String> = ["c", "s", "w", "z"]

    static let t3Code = CustomButton(title: "Send to T3", symbol: "paperplane", action: .t3code, command: nil, key: "t",
                                     closePreview: false)

    /// T3 Code's pink (its pink theme's accent, Tailwind pink-600).
    static let t3Pink = "#db2777"
    static let defaultGrey = "#525252"

    /// The colour the button is drawn in: its own, or T3 pink for T3, grey for the rest.
    var displayColor: NSColor {
        color.flatMap(NSColor.init(hex:)) ?? NSColor(hex: action == .t3code ? Self.t3Pink : Self.defaultGrey)!
    }

    /// The JSON object written for this button.
    var json: [String: Any] {
        var object: [String: Any] = ["title": title, "action": action.rawValue]
        if let symbol { object["symbol"] = symbol }
        if let command { object["command"] = command }
        if let key { object["key"] = key }
        if closePreview { object["closePreview"] = true }
        if let color { object["color"] = color }
        return object
    }
}

/// Reads and writes ~/Library/Application Support/Snapkeep/custom-buttons.json.
enum CustomButtons {
    struct Loaded {
        var buttons: [CustomButton] = []
        /// Why some or all of the file couldn't be used.
        var problems: [String] = []
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snapkeep", isDirectory: true)
            .appendingPathComponent("custom-buttons.json")
    }

    static let helpText = "Each button runs a shell command with the screenshot, or sends it to T3 Code. "
        + "See https://github.com/stanimir93/snapkeep#custom-buttons"

    static func load(from url: URL = defaultURL) -> Loaded {
        guard let data = try? Data(contentsOf: url) else { return Loaded() }
        return parse(data)
    }

    static func parse(_ data: Data) -> Loaded {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            return Loaded(problems: ["The file isn't valid JSON: \(jsonErrorDetail(error))"])
        }
        guard let list = (root as? [String: Any])?["buttons"] as? [Any] else {
            return Loaded(problems: [#"The file needs a "buttons" list."#])
        }
        var loaded = Loaded()
        var usedKeys: Set<String> = []
        for (index, item) in list.enumerated() {
            let label = "Button \(index + 1)"
            guard let object = item as? [String: Any] else {
                loaded.problems.append("\(label) isn't an object.")
                continue
            }
            let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else {
                loaded.problems.append(#"\#(label) needs a "title"."#)
                continue
            }
            let command = (object["command"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            let action: CustomButton.Action
            if let name = object["action"] as? String {
                guard let known = CustomButton.Action(rawValue: name) else {
                    loaded.problems.append(#"“\#(title)”: unknown action "\#(name)". Use "command" or "t3code"."#)
                    continue
                }
                action = known
            } else {
                action = .command
            }
            if action == .command, command == nil {
                loaded.problems.append(#"“\#(title)” needs a "command"."#)
                continue
            }
            var key = (object["key"] as? String)?.lowercased()
            if let wanted = key {
                if wanted.count != 1 || CustomButton.reservedKeys.contains(wanted) || usedKeys.contains(wanted) {
                    loaded.problems.append("“\(title)”: ⌘\(wanted.uppercased()) can't be used, so the button has no shortcut.")
                    key = nil
                } else {
                    usedKeys.insert(wanted)
                }
            }
            let symbol = (object["symbol"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            var color = object["color"] as? String
            if let wanted = color, NSColor(hex: wanted) == nil {
                loaded.problems.append("“\(title)”: “\(wanted)” isn't a colour like #db2777.")
                color = nil
            }
            loaded.buttons.append(CustomButton(title: title, symbol: symbol, action: action, command: command, key: key,
                                               closePreview: object["closePreview"] as? Bool ?? false, color: color,
                                               fileIndex: index))
        }
        return loaded
    }

    /// Creates the file with an empty list if it doesn't exist yet.
    static func createIfMissing(at url: URL = defaultURL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try write(["_help": helpText, "buttons": [Any]()], to: url)
    }

    /// Adds the Send to T3 button unless one is there already. Returns false if it was.
    @discardableResult
    static func addT3Code(to url: URL = defaultURL) throws -> Bool {
        var root: [String: Any] = ["_help": helpText]
        if let data = try? Data(contentsOf: url) {
            guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [
                    NSLocalizedDescriptionKey: "custom-buttons.json isn't valid JSON. Fix it or delete it first.",
                ])
            }
            root = existing
        }
        var list = root["buttons"] as? [Any] ?? []
        let present = list.contains { ($0 as? [String: Any])?["action"] as? String == CustomButton.Action.t3code.rawValue }
        if present { return false }
        list.append(CustomButton.t3Code.json)
        root["buttons"] = list
        try write(root, to: url)
        return true
    }

    /// Takes out the Send to T3 button, leaving the others.
    static func removeT3Code(from url: URL = defaultURL) throws {
        guard let data = try? Data(contentsOf: url),
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["buttons"] as? [Any]
        else { return }
        root["buttons"] = list.filter { ($0 as? [String: Any])?["action"] as? String != CustomButton.Action.t3code.rawValue }
        try write(root, to: url)
    }

    /// Sets or clears (nil) the colour of the button at `fileIndex` in the file's list.
    static func setColor(_ hex: String?, forButtonAt fileIndex: Int, in url: URL = defaultURL) throws {
        guard let data = try? Data(contentsOf: url),
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var list = root["buttons"] as? [Any], list.indices.contains(fileIndex),
              var button = list[fileIndex] as? [String: Any]
        else { throw ButtonError("Couldn't update custom-buttons.json") }
        button["color"] = hex
        list[fileIndex] = button
        root["buttons"] = list
        try write(root, to: url)
    }

    private static func write(_ root: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    private static func jsonErrorDetail(_ error: Error) -> String {
        let nsError = error as NSError
        return (nsError.userInfo[NSDebugDescriptionErrorKey] as? String) ?? nsError.localizedDescription
    }
}

extension NSColor {
    /// From "#rrggbb" or "rrggbb".
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat(value >> 16 & 0xff) / 255, green: CGFloat(value >> 8 & 0xff) / 255,
                  blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }

    /// "#rrggbb" in sRGB.
    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        func byte(_ component: CGFloat) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(color.redComponent), byte(color.greenComponent), byte(color.blueComponent))
    }
}

/// What a custom button gets to work with.
struct ButtonContext {
    /// The image with any drawings.
    let png: Data
    /// The screenshot file in ~/Pictures/Screenshots.
    let fileURL: URL
    let transcript: String
    let source: CaptureSource?
    let capturedAt: Date
}

struct ButtonError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Runs a button's action and returns a short message for the preview's status line.
@MainActor
enum ButtonRunner {
    static func run(_ button: CustomButton, context: ButtonContext) async throws -> String {
        switch button.action {
        case .t3code: try await T3Code.send(context)
        case .command: try await runCommand(button.command ?? "", title: button.title, context: context)
        }
    }

    private static let commandTimeout: Duration = .seconds(60)

    /// Runs the command in a login zsh, so it finds what's on your PATH, with the screenshot in
    /// SNAPKEEP_IMAGE. On success the last line it prints becomes the status message.
    private static func runCommand(_ command: String, title: String, context: ButtonContext) async throws -> String {
        let runFolder = try freshRunFolder()
        let imageURL = runFolder.appendingPathComponent(context.fileURL.lastPathComponent)
        try context.png.write(to: imageURL)
        let outputURL = runFolder.appendingPathComponent("output.txt")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = runFolder
        var environment = ProcessInfo.processInfo.environment
        environment["SNAPKEEP_IMAGE"] = imageURL.path
        environment["SNAPKEEP_FILE"] = context.fileURL.path
        environment["SNAPKEEP_TEXT"] = context.transcript
        environment["SNAPKEEP_APP"] = context.source?.appName ?? ""
        environment["SNAPKEEP_WINDOW_TITLE"] = context.source?.windowTitle ?? ""
        environment["SNAPKEEP_BUNDLE_ID"] = context.source?.bundleID ?? ""
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
            Task { @MainActor in
                try? await Task.sleep(for: commandTimeout)
                if process.isRunning { process.terminate() }
            }
        }
        let lastLine = (try? String(contentsOf: outputURL, encoding: .utf8))?
            .split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard status == 0 else {
            throw ButtonError(lastLine.isEmpty ? "\(title) failed (exit \(status))" : "\(title) failed: \(lastLine)")
        }
        return lastLine.isEmpty ? "\(title): done" : lastLine
    }

    /// A new folder under the temporary folder for one run. Runs older than a day are removed.
    private static func freshRunFolder() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("Snapkeep/buttons", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let dayAgo = Date().addingTimeInterval(-86_400)
        let old = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in old where ((try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture) < dayAgo {
            try? FileManager.default.removeItem(at: folder)
        }
        let folder = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

/// Hands a screenshot to T3 Code through the folder its Snap Shot feature uses.
///
/// T3 Code saves a Snap Shot as `<id>.png` plus `<id>.json` in `~/.t3/userdata/snap-shots`, and
/// its window picks up whatever is in that folder whenever it gets focus: the image goes into the
/// composer of the open thread and T3 deletes both files. So Snapkeep writes the same two files,
/// then brings T3 Code to the front. This isn't a public T3 API, so a T3 update can change it.
@MainActor
enum T3Code {
    static let bundleID = "com.t3tools.t3code"
    /// T3 Code turns down images larger than this.
    static let maxImageBytes = 10 * 1024 * 1024
    static let maxTextCharacters = 32_000
    /// Returned when T3 hasn't picked the screenshot up yet. The files stay, so it arrives later.
    static let waitingMessage = "Waiting for T3 Code: it appears when you switch to T3"

    static var userData: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3/userdata", isDirectory: true)
    }

    static func send(_ context: ButtonContext) async throws -> String {
        let folder = userData.appendingPathComponent("snap-shots", isDirectory: true)
        guard FileManager.default.fileExists(atPath: userData.path) else {
            throw ButtonError("T3 Code isn't set up on this Mac (no ~/.t3/userdata)")
        }
        guard snapShotsEnabled() else {
            throw ButtonError("Turn on Snap Shot in T3 Code's Settings first")
        }
        guard context.png.count <= maxImageBytes else {
            throw ButtonError("Too big for T3 Code (over 10 MB)")
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw ButtonError("T3 Code isn't installed")
        }

        let id = UUID().uuidString.lowercased()
        let pending = pendingSnapShot(id: id, name: context.fileURL.lastPathComponent, sizeBytes: context.png.count,
                                      capturedAt: context.capturedAt, source: context.source, text: context.transcript)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The image first, then the metadata: T3 looks for the .json files.
        let image = folder.appendingPathComponent("\(id).png")
        try context.png.write(to: folder.appendingPathComponent("\(id).tmp.png"))
        try FileManager.default.moveItem(at: folder.appendingPathComponent("\(id).tmp.png"), to: image)
        let metadata = folder.appendingPathComponent("\(id).json")
        let json = try JSONSerialization.data(withJSONObject: pending, options: [.withoutEscapingSlashes])
        try json.write(to: folder.appendingPathComponent("\(id).json.tmp"))
        try FileManager.default.moveItem(at: folder.appendingPathComponent("\(id).json.tmp"), to: metadata)

        // T3 only looks when its window gets focus. If it's already the front app, step in front of
        // it for a moment so coming back counts as getting focus.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
            NSApp.activate()
            try? await Task.sleep(for: .milliseconds(150))
        }
        await bringForward(appURL)
        if await waitUntilPickedUp(metadata, seconds: 4) { return "Sent to T3 Code" }

        // Once more, in case T3 Code was launching or the focus change didn't register.
        NSApp.activate()
        try? await Task.sleep(for: .milliseconds(150))
        await bringForward(appURL)
        if await waitUntilPickedUp(metadata, seconds: 4) { return "Sent to T3 Code" }
        return waitingMessage
    }

    /// The `<id>.json` T3 Code expects, matching what its own Snap Shot writes.
    static func pendingSnapShot(id: String, name: String, sizeBytes: Int, capturedAt: Date, source: CaptureSource?,
                                text: String, appIconDataURL: String? = nil) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let appName = clip(source?.appName, 255) ?? "Snapkeep"
        var details: [String: Any] = [
            "kind": "snap-shot",
            "capturedAt": formatter.string(from: capturedAt),
            "appName": appName,
            "windowTitle": clip(source?.windowTitle, 1000) ?? "",
        ]
        if let text = clip(text, maxTextCharacters) { details["accessibleText"] = text }
        if let bundle = clip(source?.bundleID, 255) { details["appIdentifier"] = bundle }
        if let icon = appIconDataURL ?? source.flatMap(iconDataURL) { details["appIconDataUrl"] = icon }
        return [
            "id": id,
            "name": clip(name, 255) ?? "screenshot.png",
            "mimeType": "image/png",
            "sizeBytes": sizeBytes,
            "source": details,
        ]
    }

    /// Trimmed and cut to the length T3 Code accepts, or nil when nothing is left.
    private static func clip(_ text: String?, _ limit: Int) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The captured app's icon as a small PNG, which T3 Code shows on the attachment.
    private static func iconDataURL(_ source: CaptureSource) -> String? {
        let app = source.processID.flatMap { NSRunningApplication(processIdentifier: $0) }
        guard let icon = app?.icon else { return nil }
        let size = 64
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = "data:image/png;base64," + png.base64EncodedString()
        return url.count <= 100_000 ? url : nil
    }

    /// Snap Shot is off until it's turned on in T3 Code's Settings, and T3 ignores the folder while it's off.
    private static func snapShotsEnabled() -> Bool {
        let url = userData.appendingPathComponent("client-settings.json")
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return settings["snapShotEnabled"] as? Bool ?? false
    }

    /// Opens T3 Code, or brings it to the front and shows its window if it's minimized.
    private static func bringForward(_ appURL: URL) async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }

    /// T3 deletes the files once the image is in the composer.
    private static func waitUntilPickedUp(_ metadata: URL, seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !FileManager.default.fileExists(atPath: metadata.path) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !FileManager.default.fileExists(atPath: metadata.path)
    }
}
