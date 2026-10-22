import Foundation

/// Runs macOS's own interactive picker: drag an area, Space to pick a window, Esc to cancel.
@MainActor
final class ScreenCapturer {
    private(set) var isCapturing = false

    /// Calls back with true if a file was written, false if the user cancelled or it failed.
    func capture(to url: URL, completion: @escaping @MainActor (Bool) -> Void) {
        guard !isCapturing else { return }
        isCapturing = true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", url.path]
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isCapturing = false
                    completion(FileManager.default.fileExists(atPath: url.path))
                }
            }
        }
        do {
            try process.run()
        } catch {
            isCapturing = false
            completion(false)
        }
    }
}
