import AppKit
import VisionKit

/// Live Text analysis through VisionKit, the same engine Preview uses.
@MainActor
enum TextRecognizer {
    private static let analyzer = ImageAnalyzer()

    static var isSupported: Bool { ImageAnalyzer.isSupported }

    static func analyze(_ image: CGImage) async throws -> ImageAnalysis {
        try await analyzer.analyze(image, orientation: .up, configuration: ImageAnalyzer.Configuration([.text]))
    }
}

enum Clipboard {
    static func copyPNG(_ data: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
    }

    static func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// The file itself, so pasting into Finder, Mail or a chat app attaches it.
    static func copyFile(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }
}

/// Files copied without being saved: Copy Video and Copy GIF. They wait in Snapkeep's caches
/// folder under a recording-… name so a paste attaches them with that name. Each copy replaces
/// the last one, since the clipboard only holds the newest.
enum ClipboardFiles {
    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.stanimir.snapkeep/Clipboard", isDirectory: true)
    }

    /// Copies `source` into the folder, emptied first, and returns the copy for the clipboard.
    static func stage(_ source: URL, as ext: String, in folder: URL = folder, date: Date = Date()) throws -> URL {
        let manager = FileManager.default
        try? manager.removeItem(at: folder)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(ScreenshotLibrary.fileName(for: date, prefix: "recording", extension: ext))
        try manager.copyItem(at: source, to: url)
        return url
    }
}
