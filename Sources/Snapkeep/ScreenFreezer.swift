import AppKit
import ScreenCaptureKit

/// One display as it looked when the capture shortcut was pressed.
struct FrozenScreen {
    let screen: NSScreen
    let image: CGImage
}

/// An on-screen window, for hover-to-select and snapping.
struct WindowInfo {
    /// In global Cocoa coordinates (origin at the bottom-left of the main display).
    let frame: CGRect
    let owner: String
}

enum ScreenFreezer {
    /// Takes a full-resolution picture of every display, leaving out Snapkeep's own windows
    /// so previews don't end up in new screenshots.
    @MainActor
    static func freezeAllScreens() async throws -> [FrozenScreen] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApps = content.applications.filter { $0.processID == getpid() }
        var frozen: [FrozenScreen] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int((screen.frame.width * screen.backingScaleFactor).rounded())
            config.height = Int((screen.frame.height * screen.backingScaleFactor).rounded())
            config.showsCursor = false
            config.captureResolution = .best
            if let name = screen.colorSpace?.cgColorSpace?.name { config.colorSpaceName = name }
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            frozen.append(FrozenScreen(screen: screen, image: image))
        }
        return frozen
    }

    /// Normal app windows, front to back. Window positions don't need Screen Recording permission.
    static func visibleWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let ownPID = Int(getpid())
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? Int) != ownPID,
                  let layer = info[kCGWindowLayer as String] as? Int, (0..<Int(CGWindowLevelForKey(.dockWindow))).contains(layer),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 40, bounds.height > 40
            else { return nil }
            // Quartz window bounds start at the top-left of the main display, y going down.
            let frame = CGRect(x: bounds.minX, y: mainHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            return WindowInfo(frame: frame, owner: info[kCGWindowOwnerName as String] as? String ?? "")
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
