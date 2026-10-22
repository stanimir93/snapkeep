import AppKit

/// While recording: a red frame just outside the recorded area and a small bar with the time,
/// Stop and Discard. Both are Snapkeep windows, so they never appear in the video.
@MainActor
final class RecordingControls {
    var onStop: (() -> Void)?
    var onDiscard: (() -> Void)?

    private let frameWindow: NSPanel
    private let bar: NSPanel
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private let started = Date()
    private var timer: Timer?

    /// `rect` is in the screen's points, origin at its bottom-left.
    init(screen: NSScreen, rect: CGRect) {
        let area = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        frameWindow = Self.makePanel(frame: area.insetBy(dx: -3, dy: -3))
        frameWindow.ignoresMouseEvents = true
        let border = FrameView()
        frameWindow.contentView = border

        bar = Self.makePanel(frame: .zero)
        bar.isMovableByWindowBackground = true
        bar.contentView = makeBar()
        bar.setContentSize(bar.contentView!.fittingSize)
        bar.setFrameOrigin(Self.barOrigin(size: bar.frame.size, area: area, visible: screen.visibleFrame))
    }

    func show() {
        frameWindow.orderFrontRegardless()
        bar.orderFrontRegardless()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTime() }
        }
        // .common keeps it ticking while the menu bar menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func close() {
        timer?.invalidate()
        timer = nil
        frameWindow.orderOut(nil)
        bar.orderOut(nil)
    }

    private func updateTime() {
        timeLabel.stringValue = formatDuration(Date().timeIntervalSince(started))
    }

    private static func makePanel(frame: CGRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    private func makeBar() -> NSView {
        let dot = NSImageView()
        dot.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        dot.contentTintColor = .systemRed

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        timeLabel.textColor = .white
        timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        let stop = NSButton(title: "Stop", target: self, action: #selector(stopClicked))
        stop.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        stop.imagePosition = .imageLeading
        stop.controlSize = .large
        stop.toolTip = "Stop and preview the recording"

        let discard = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Discard")!,
                               target: self, action: #selector(discardClicked))
        discard.controlSize = .large
        discard.toolTip = "Stop and throw the recording away"

        let stack = NSStackView(views: [dot, timeLabel, discard, stop])
        stack.spacing = 8
        stack.setCustomSpacing(14, after: timeLabel)
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 10)

        // Same look as the capture overlay's buttons.
        let background = BarBackground()
        background.appearance = NSAppearance(named: .darkAqua)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        return background
    }

    /// Under the area, or above it, or inside its bottom edge if it fills the screen.
    static func barOrigin(size: CGSize, area: CGRect, visible: CGRect) -> CGPoint {
        let gap: CGFloat = 12
        var origin = CGPoint(x: area.midX - size.width / 2, y: area.minY - size.height - gap)
        if origin.y < visible.minY + 8 {
            origin.y = area.maxY + gap
            if origin.y + size.height > visible.maxY - 8 {
                origin.y = max(area.minY, visible.minY) + gap * 2
            }
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        return origin
    }

    @objc private func stopClicked() {
        onStop?()
    }

    @objc private func discardClicked() {
        onDiscard?()
    }
}

private final class FrameView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        NSColor.systemRed.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }
}

private final class BarBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.12, alpha: 0.94).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    }
}

/// "0:07", "1:23", "1:02:03".
func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded(.down))
    let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
    return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
}
