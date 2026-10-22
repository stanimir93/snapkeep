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
