import AppKit

/// A small confirmation that appears near the bottom of the screen and fades out.
@MainActor
enum Toast {
    private static var visible: [NSPanel] = []

    static func show(_ title: String, detail: String? = nil, symbol: String) {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .medium))
        icon.contentTintColor = .labelColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        let labels = NSStackView(views: [titleLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        if let detail, !detail.isEmpty {
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = .systemFont(ofSize: 12)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.lineBreakMode = .byTruncatingTail
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
            labels.addArrangedSubview(detailLabel)
        }

        let row = NSStackView(views: [icon, labels])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 18)

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            row.topAnchor.constraint(equalTo: background.topAnchor),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        let size = row.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = background

        let frame = (NSScreen.withMouse ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.16))
        panel.orderFrontRegardless()
        visible.append(panel)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.45
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    panel.orderOut(nil)
                    visible.removeAll { $0 === panel }
                }
            })
        }
    }
}

extension NSScreen {
    /// The screen under the mouse pointer, where the user just captured.
    static var withMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }
}
