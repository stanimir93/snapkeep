import Foundation

/// The folder where every capture is kept: ~/Pictures/Screenshots/screenshot-YYYY-MM-DD_HH-mm-ss.png,
/// and recordings as recording-YYYY-MM-DD_HH-mm-ss.mp4 or .gif.
struct ScreenshotLibrary {
    let folder: URL

    init(folder: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/Screenshots", isDirectory: true)) {
        self.folder = folder
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    static func fileName(for date: Date, prefix: String = "screenshot", extension ext: String = "png", suffix: Int = 1) -> String {
        let stamp = formatter.string(from: date)
        return suffix > 1 ? "\(prefix)-\(stamp)-\(suffix).\(ext)" : "\(prefix)-\(stamp).\(ext)"
    }

    /// A path for a new capture. Two captures in the same second get `-2`, `-3`, … appended.
    func newFileURL(date: Date = Date(), prefix: String = "screenshot", extension ext: String = "png") throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var suffix = 1
        while true {
            let url = folder.appendingPathComponent(Self.fileName(for: date, prefix: prefix, extension: ext, suffix: suffix))
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            suffix += 1
        }
    }

    /// The most recently modified Snapkeep screenshot, if any.
    func newest() -> URL? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("screenshot-") && $0.pathExtension == "png" }
            .max { modified($0) < modified($1) }
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
