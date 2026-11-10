import AppKit
import ApplicationServices

/// Finds the page in browser windows: the web content without the tabs, toolbar or sidebar, so
/// hovering a page in the capture overlay picks just the page. Reads the Accessibility tree, where
/// every major browser shows its page as an AXWebArea, so it needs Accessibility permission.
enum BrowserPages {
    static let defaultsKey = "detectBrowserPages"

    /// Off until the user turns it on in Settings, since it needs Accessibility permission.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static var isActive: Bool { isEnabled && isTrusted }

    /// Adds Snapkeep to System Settings › Privacy & Security › Accessibility and asks once.
    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static let browserBundleIDs: Set<String> = [
        "app.zen-browser.zen", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "company.thebrowser.Browser", "company.thebrowser.dia", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.duckduckgo.macos.browser",
        "com.kagi.kagimacOS", "net.imput.helium",
    ]

    /// The pages in each browser window, by index into `windows`, in the same global Cocoa
    /// coordinates as the windows' frames. Windows of other apps, and browser windows whose page
    /// can't be found, are left out.
    ///
    /// Firefox and Zen build their Accessibility tree on the first request, and Chromium browsers
    /// only after Snapkeep asks for it, so the first look after a browser starts can come back empty.
    /// `retries` looks again after a short wait for the browser windows that had no page.
    static func find(in windows: [WindowInfo], retries: Int = 2) -> [Int: [CGRect]] {
        guard isTrusted else { return [:] }
        let browserPIDs = Set(browserWindows(in: windows).map { windows[$0].processID })
        guard !browserPIDs.isEmpty else { return [:] }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        var found: [Int: [CGRect]] = [:]
        var pending = browserPIDs
        for attempt in 0...retries {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.2) }
            for pid in pending {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.3)
                // Chromium and Electron build their tree for any app that sets this.
                AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                for window in children(of: app, kAXWindowsAttribute) {
                    guard let quartz = frame(of: window) else { continue }
                    let cocoa = toCocoa(quartz, mainHeight: mainHeight)
                    guard let index = windows.indices.first(where: { index in
                        found[index] == nil && windows[index].processID == pid && windows[index].frame.isClose(to: cocoa)
                    }) else { continue }
                    let pages = webAreas(in: window)
                        .map { toCocoa($0, mainHeight: mainHeight).intersection(cocoa) }
                        .filter { $0.width >= 40 && $0.height >= 40 }
                    if !pages.isEmpty { found[index] = pages }
                }
            }
            pending = Set(windows.indices.filter { browserPIDs.contains(windows[$0].processID) && found[$0] == nil }
                .map { windows[$0].processID })
            if pending.isEmpty { break }
        }
        return found
    }

    /// Indexes of the windows that belong to a browser.
    static func browserWindows(in windows: [WindowInfo]) -> [Int] {
        var isBrowser: [pid_t: Bool] = [:]
        return windows.indices.filter { index in
            let pid = windows[index].processID
            guard pid > 0 else { return false }
            if let known = isBrowser[pid] { return known }
            let known = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier.map(browserBundleIDs.contains) == true
            isBrowser[pid] = known
            return known
        }
    }

    /// The AXWebArea frames under a window, outermost only, in Quartz coordinates. A breadth-first
    /// walk that stops at each page, so it never reads the page's own contents.
    private static func webAreas(in window: AXUIElement) -> [CGRect] {
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var head = 0
        var pages: [CGRect] = []
        while head < queue.count, head < 4000 {
            let (element, depth) = queue[head]
            head += 1
            if string(of: element, kAXRoleAttribute) == "AXWebArea" {
                if let frame = frame(of: element) { pages.append(frame) }
                continue
            }
            guard depth < 40 else { continue }
            queue += children(of: element, kAXChildrenAttribute).map { ($0, depth + 1) }
        }
        return pages
    }

    private static func children(of element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(of element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: AnyObject?, size: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    /// Accessibility frames start at the top-left of the main display, y going down.
    private static func toCocoa(_ rect: CGRect, mainHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// `Snapkeep --list-pages`: prints the browser windows on screen and the pages found in them.
    static func printPages() {
        let windows = ScreenFreezer.visibleWindows()
        print("Accessibility permission: \(isTrusted ? "yes" : "no")")
        let start = Date()
        let pages = find(in: windows)
        print(String(format: "Looked in %.0f ms", Date().timeIntervalSince(start) * 1000))
        for index in browserWindows(in: windows) {
            let window = windows[index]
            print("\(window.owner) window \(window.frame): \(window.title)")
            for page in pages[index] ?? [] { print("  page \(page)") }
        }
    }
}

private extension CGRect {
    func isClose(to other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}
