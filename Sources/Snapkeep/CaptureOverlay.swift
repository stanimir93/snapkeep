import AppKit

enum CaptureMode {
    case image, text
}

final class CaptureOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Draws through a closure, so the overlay can paint above its backdrop image view.
private final class DrawingView: NSView {
    var drawHandler: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        drawHandler?()
    }
}

/// One screen's capture overlay: the frozen screen, dimmed, with guide lines, window highlighting,
/// an adjustable selection and a Capture button. Nothing is captured until the user confirms.
@MainActor
final class CaptureOverlayView: NSView {
    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1 << 0)
        static let right = Edges(rawValue: 1 << 1)
        static let bottom = Edges(rawValue: 1 << 2)
        static let top = Edges(rawValue: 1 << 3)
    }

    private enum Drag {
        case creating(anchor: CGPoint)
        case moving(start: CGPoint, original: CGRect)
        case resizing(edges: Edges, start: CGPoint, original: CGRect)
    }

    let image: CGImage
    let mode: CaptureMode
    var onBeginInteraction: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var onToggleSnapping: (() -> Void)?

    private var snapper: Snapper
    private let windows: [WindowInfo]
    private(set) var selection: CGRect? {
        didSet {
            layoutActionBar()
            redraw()
        }
    }
    private var hovered: WindowInfo?
    private var mouse: CGPoint?
    private var drag: Drag?
    private var downPoint = CGPoint.zero
    private var didDrag = false

    private let backdrop = NSImageView()
    private let chrome = DrawingView()
    private let actionBar = DrawingView()
    private var trackingArea: NSTrackingArea?

    private var isCreating: Bool {
        if case .creating = drag, didDrag { return true }
        return false
    }

    /// `windows` are in this screen's coordinates.
    init(size: CGSize, image: CGImage, windows: [WindowInfo], mode: CaptureMode) {
        self.image = image
        self.mode = mode
        self.windows = windows
        snapper = Snapper(size: size, scale: CGFloat(image.width) / size.width, windowFrames: windows.map(\.frame))
        super.init(frame: CGRect(origin: .zero, size: size))

        backdrop.image = NSImage(cgImage: image, size: size)
        backdrop.imageScaling = .scaleAxesIndependently
        backdrop.frame = bounds
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)

        chrome.frame = bounds
        chrome.autoresizingMask = [.width, .height]
        chrome.drawHandler = { [unowned self] in self.drawChrome() }
        addSubview(chrome)

        buildActionBar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if !actionBar.isHidden, let hit = actionBar.hitTest(convert(point, from: superview)) { return hit }
        return frame.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Session

    func setEdgeMap(_ map: EdgeMap?) {
        snapper.edges = map
    }

    func setSnappingEnabled(_ enabled: Bool) {
        snapper.isEnabled = enabled
        hovered = enabled && selection == nil ? mouse.flatMap(window(at:)) : nil
        redraw()
    }

    func clearSelection() {
        drag = nil
        selection = nil
        mouse = nil
        hovered = nil
    }

    /// The selected part of the frozen screen and its size in points.
    func capturedImage() -> (image: CGImage, pointSize: CGSize)? {
        guard let selection, selection.width >= 1, selection.height >= 1 else { return nil }
        let scale = snapper.scale
        let pixels = CGRect(x: (selection.minX * scale).rounded(), y: ((bounds.height - selection.maxY) * scale).rounded(),
                            width: (selection.width * scale).rounded(), height: (selection.height * scale).rounded())
        guard let cropped = image.cropping(to: pixels) else { return nil }
        return (cropped, CGSize(width: CGFloat(cropped.width) / scale, height: CGFloat(cropped.height) / scale))
    }

    // MARK: Mouse

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    /// Holding Option turns snapping off for this drag.
    private func activeSnapper(_ event: NSEvent) -> Snapper {
        var active = snapper
        if event.modifierFlags.contains(.option) { active.isEnabled = false }
        return active
    }

    private func window(at point: CGPoint) -> WindowInfo? {
        guard let match = windows.first(where: { $0.frame.contains(point) }) else { return nil }
        return WindowInfo(frame: match.frame.intersection(bounds), owner: match.owner)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = location(of: event)
        mouse = point
        if selection == nil {
            hovered = snapper.isEnabled ? window(at: point) : nil
        }
        updateCursor(at: point)
        redraw()
    }

    override func mouseExited(with event: NSEvent) {
        mouse = nil
        if selection == nil { hovered = nil }
        redraw()
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: location(of: event))
    }

    override func mouseDown(with event: NSEvent) {
        let point = location(of: event)
        onBeginInteraction?()
        window?.makeFirstResponder(self)
        downPoint = point
        didDrag = false
        if let selection {
            let edges = edges(at: point, in: selection)
            if !edges.isEmpty {
                drag = .resizing(edges: edges, start: point, original: selection)
                return
            }
            if selection.contains(point) {
                if event.clickCount >= 2 {
                    onConfirm?()
                    return
                }
                drag = .moving(start: point, original: selection)
                NSCursor.closedHand.set()
                return
            }
        }
        drag = .creating(anchor: activeSnapper(event).snapPoint(point))
    }

    override func mouseDragged(with event: NSEvent) {
        let raw = location(of: event)
        let point = clamped(raw)
        let snap = activeSnapper(event)
        mouse = point
        switch drag {
        case let .creating(anchor):
            if !didDrag {
                guard hypot(raw.x - downPoint.x, raw.y - downPoint.y) >= 3 else { return }
                didDrag = true
                hovered = nil
            }
            let x = snap.snapX(point.x, along: min(anchor.y, point.y)...max(anchor.y, point.y))
            let y = snap.snapY(point.y, along: min(anchor.x, point.x)...max(anchor.x, point.x))
            selection = CGRect(x: min(anchor.x, x), y: min(anchor.y, y), width: abs(x - anchor.x), height: abs(y - anchor.y))
        case let .moving(start, original):
            didDrag = true
            var moved = original.offsetBy(dx: raw.x - start.x, dy: raw.y - start.y)
            moved.origin.x = snap.aligned(min(max(moved.minX, 0), bounds.width - moved.width))
            moved.origin.y = snap.aligned(min(max(moved.minY, 0), bounds.height - moved.height))
            selection = moved
        case let .resizing(edges, start, original):
            didDrag = true
            let dx = raw.x - start.x, dy = raw.y - start.y
            let rows = original.minY...original.maxY, columns = original.minX...original.maxX
            var minX = original.minX, maxX = original.maxX, minY = original.minY, maxY = original.maxY
            if edges.contains(.left) { minX = snap.snapX(clamped(CGPoint(x: original.minX + dx, y: 0)).x, along: rows) }
            if edges.contains(.right) { maxX = snap.snapX(clamped(CGPoint(x: original.maxX + dx, y: 0)).x, along: rows) }
            if edges.contains(.bottom) { minY = snap.snapY(clamped(CGPoint(x: 0, y: original.minY + dy)).y, along: columns) }
            if edges.contains(.top) { maxY = snap.snapY(clamped(CGPoint(x: 0, y: original.maxY + dy)).y, along: columns) }
            selection = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        case nil:
            break
        }
        redraw()
    }

    override func mouseUp(with event: NSEvent) {
        let point = location(of: event)
        if case .creating = drag, !didDrag {
            // A click without a drag picks the window under the pointer.
            selection = snapper.isEnabled ? window(at: point)?.frame : nil
        }
        drag = nil
        if let current = selection, current.width < 4 || current.height < 4 {
            selection = nil
        }
        hovered = selection == nil && snapper.isEnabled ? window(at: point) : nil
        layoutActionBar()
        updateCursor(at: point)
        redraw()
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            onCancel?()
        case 36, 76: // Return, Enter
            if selection != nil { onConfirm?() }
        case 48: // Tab
            onToggleSnapping?()
        case 123, 124, 125, 126: // arrows
            nudge(event)
        default:
            if event.charactersIgnoringModifiers?.lowercased() == "f" {
                onBeginInteraction?()
                hovered = nil
                selection = bounds
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// Arrow keys move the selection by a point, or 10 with Shift.
    private func nudge(_ event: NSEvent) {
        guard var moved = selection else { return }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123: moved.origin.x -= step
        case 124: moved.origin.x += step
        case 125: moved.origin.y -= step
        default: moved.origin.y += step
        }
        moved.origin.x = min(max(moved.minX, 0), bounds.width - moved.width)
        moved.origin.y = min(max(moved.minY, 0), bounds.height - moved.height)
        selection = moved
    }

    // MARK: Cursor

    private func edges(at point: CGPoint, in rect: CGRect) -> Edges {
        let reach: CGFloat = 6
        guard rect.insetBy(dx: -reach, dy: -reach).contains(point) else { return [] }
        var edges: Edges = []
        if abs(point.x - rect.minX) <= reach { edges.insert(.left) } else if abs(point.x - rect.maxX) <= reach { edges.insert(.right) }
        if abs(point.y - rect.minY) <= reach { edges.insert(.bottom) } else if abs(point.y - rect.maxY) <= reach { edges.insert(.top) }
        return edges
    }

    private func updateCursor(at point: CGPoint) {
        if let selection, drag == nil {
            let edges = edges(at: point, in: selection)
            if !edges.isEmpty {
                resizeCursor(for: edges).set()
                return
            }
            if selection.contains(point) {
                NSCursor.openHand.set()
                return
            }
        }
        NSCursor.crosshair.set()
    }

    private func resizeCursor(for edges: Edges) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch (edges.contains(.left), edges.contains(.right), edges.contains(.top), edges.contains(.bottom)) {
            case (true, _, true, _): position = .topLeft
            case (true, _, _, true): position = .bottomLeft
            case (_, true, true, _): position = .topRight
            case (_, true, _, true): position = .bottomRight
            case (true, _, _, _): position = .left
            case (_, true, _, _): position = .right
            case (_, _, true, _): position = .top
            default: position = .bottom
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        if edges == .left || edges == .right { return .resizeLeftRight }
        if edges == .top || edges == .bottom { return .resizeUpDown }
        return .crosshair
    }

    // MARK: Drawing

    private func redraw() {
        chrome.needsDisplay = true
    }

    private func drawChrome() {
        let focus = selection ?? hovered?.frame
        let dim = NSBezierPath(rect: bounds)
        if let focus {
            dim.append(NSBezierPath(rect: focus))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()

        if let selection {
            if drag != nil { drawGuides(along: selection) }
            drawBorder(selection, color: .white, width: 1)
            if !isCreating { drawHandles(selection) }
            drawLabel(sizeText(selection), above: selection)
        } else if let hovered {
            drawBorder(hovered.frame, color: .controlAccentColor, width: 3)
            let title = hovered.owner.isEmpty ? sizeText(hovered.frame) : "\(hovered.owner)   \(sizeText(hovered.frame))"
            drawLabel(title, above: hovered.frame)
        }
        if let mouse, selection == nil || isCreating {
            drawCrosshair(at: mouse)
        }
        if selection == nil, drag == nil, mouse != nil {
            drawHint()
        }
    }

    private func sizeText(_ rect: CGRect) -> String {
        "\(Int((rect.width * snapper.scale).rounded())) × \(Int((rect.height * snapper.scale).rounded()))"
    }

    /// Faint lines across the screen through the pointer. A barely-there dark edge keeps them
    /// findable over white areas without drawing attention.
    private func drawCrosshair(at point: CGPoint) {
        let x = floor(point.x) + 0.5, y = floor(point.y) + 0.5
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 0, y: y))
        path.line(to: CGPoint(x: bounds.width, y: y))
        path.move(to: CGPoint(x: x, y: 0))
        path.line(to: CGPoint(x: x, y: bounds.height))
        NSColor.black.withAlphaComponent(0.08).setStroke()
        path.lineWidth = 2
        path.stroke()
        NSColor.white.withAlphaComponent(0.28).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// Dashed lines extending the selection's edges across the screen while dragging.
    private func drawGuides(along rect: CGRect) {
        let path = NSBezierPath()
        for x in [rect.minX, rect.maxX] {
            path.move(to: CGPoint(x: x, y: 0))
            path.line(to: CGPoint(x: x, y: bounds.height))
        }
        for y in [rect.minY, rect.maxY] {
            path.move(to: CGPoint(x: 0, y: y))
            path.line(to: CGPoint(x: bounds.width, y: y))
        }
        path.lineWidth = 1
        path.setLineDash([5, 4], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.2).setStroke()
        path.stroke()
    }

    private func drawBorder(_ rect: CGRect, color: NSColor, width: CGFloat) {
        let path = NSBezierPath(rect: rect.insetBy(dx: -width / 2, dy: -width / 2))
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }

    private func drawHandles(_ rect: CGRect) {
        let points = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
        ]
        for point in points {
            let handle = NSBezierPath(ovalIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
            NSColor.white.setFill()
            handle.fill()
            NSColor.black.withAlphaComponent(0.4).setStroke()
            handle.lineWidth = 1
            handle.stroke()
        }
    }

    private func drawLabel(_ text: String, above rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        var box = CGRect(x: rect.minX, y: rect.maxY + 6, width: size.width + 14, height: size.height + 6)
        if box.maxY > bounds.maxY - 4 { box.origin.y = rect.maxY - box.height - 6 } // no room above: go inside
        box.origin.x = min(max(box.minX, 4), bounds.width - box.width - 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        string.draw(at: CGPoint(x: box.minX + 7, y: box.minY + 3))
    }

    private func drawHint() {
        let action = mode == .text ? "Copy text" : "Capture"
        var text = "\(action): drag an area or click a window  ·  F full screen  ·  Tab snapping  ·  ⌥ drag without snapping  ·  Esc cancel"
        if !snapper.isEnabled { text += "  ·  Snapping off" }
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let size = string.size()
        let box = CGRect(x: (bounds.width - size.width) / 2 - 14, y: bounds.height - size.height - 60,
                         width: size.width + 28, height: size.height + 14)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        string.draw(at: CGPoint(x: box.minX + 14, y: box.minY + 7))
    }

    // MARK: Action bar

    private func buildActionBar() {
        let primary = NSButton(title: mode == .text ? "Copy Text" : "Capture", target: self, action: #selector(confirmClicked))
        primary.image = NSImage(systemSymbolName: mode == .text ? "text.viewfinder" : "camera.fill", accessibilityDescription: nil)
        primary.imagePosition = .imageLeading
        primary.controlSize = .large
        primary.keyEquivalent = "\r"
        primary.font = .systemFont(ofSize: NSFont.systemFontSize(for: .large), weight: .semibold)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.controlSize = .large

        let stack = NSStackView(views: [cancel, primary])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Solid, so the screenshot behind doesn't show through the buttons.
        actionBar.drawHandler = { [unowned actionBar] in
            NSColor(white: 0.12, alpha: 0.94).setFill()
            NSBezierPath(roundedRect: actionBar.bounds, xRadius: 12, yRadius: 12).fill()
        }
        actionBar.appearance = NSAppearance(named: .darkAqua)
        actionBar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: actionBar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: actionBar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: actionBar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: actionBar.bottomAnchor),
        ])
        actionBar.setFrameSize(stack.fittingSize)
        actionBar.isHidden = true
        addSubview(actionBar)
    }

    /// Puts the buttons under the selection's right edge, or above it, or inside it if the
    /// selection fills the screen.
    private func layoutActionBar() {
        guard let selection, drag == nil else {
            actionBar.isHidden = true
            return
        }
        let size = actionBar.frame.size, gap: CGFloat = 10
        var origin = CGPoint(x: selection.maxX - size.width, y: selection.minY - size.height - gap)
        if origin.y < 8 {
            origin.y = selection.maxY + gap + 26 // clear of the size label
            if origin.y + size.height > bounds.height - 8 {
                origin.y = selection.minY + gap * 2
                origin.x = selection.maxX - size.width - gap * 2
            }
        }
        origin.x = min(max(origin.x, 8), bounds.width - size.width - 8)
        actionBar.setFrameOrigin(origin)
        actionBar.isHidden = false
    }

    @objc private func confirmClicked() {
        onConfirm?()
    }

    @objc private func cancelClicked() {
        onCancel?()
    }

    // MARK: Self-check

    /// Puts the overlay in a given state so its look can be checked from a render.
    func setStateForCheck(mouse: CGPoint?, selection: CGRect?) {
        self.mouse = mouse
        hovered = selection == nil ? mouse.flatMap(window(at:)) : nil
        self.selection = selection
    }

    /// Runs the snapping a drag from `start` to `end` would get.
    func snappedDragForCheck(from start: CGPoint, to end: CGPoint) -> CGRect {
        let anchor = snapper.snapPoint(start)
        let x = snapper.snapX(end.x, along: min(anchor.y, end.y)...max(anchor.y, end.y))
        let y = snapper.snapY(end.y, along: min(anchor.x, end.x)...max(anchor.x, end.x))
        return CGRect(x: min(anchor.x, x), y: min(anchor.y, y), width: abs(x - anchor.x), height: abs(y - anchor.y))
    }
}
