import AppKit

enum Tool: Int, CaseIterable {
    case select, pen, highlighter, arrow, rectangle, text

    var title: String {
        switch self {
        case .select: "Select text"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .text: "Text"
        }
    }

    var key: String {
        switch self {
        case .select: "v"
        case .pen: "p"
        case .highlighter: "h"
        case .arrow: "a"
        case .rectangle: "r"
        case .text: "t"
        }
    }

    var symbols: [String] {
        switch self {
        case .select: ["character.cursor.ibeam", "text.cursor"]
        case .pen: ["pencil.tip", "pencil"]
        case .highlighter: ["highlighter"]
        case .arrow: ["arrow.up.right"]
        case .rectangle: ["rectangle"]
        case .text: ["textformat"]
        }
    }
}

/// The transparent drawing layer above the screenshot. In "Select text" mode it lets every
/// click through to the Live Text overlay underneath.
@MainActor
final class CanvasView: NSView, NSTextFieldDelegate {
    /// Sizes in view points at the moment of drawing, converted to image pixels when stored.
    private static let penWidth: CGFloat = 3
    private static let highlighterWidth: CGFloat = 18
    private static let arrowWidth: CGFloat = 4
    private static let rectangleWidth: CGFloat = 3
    private static let fontSize: CGFloat = 20

    let pixelSize: CGSize
    let pointSize: CGSize
    var onChange: (() -> Void)?

    var tool: Tool = .select {
        didSet {
            if tool != .text { commitText() }
            window?.invalidateCursorRects(for: self)
        }
    }

    var color: NSColor = .systemRed {
        didSet { textField?.textColor = color }
    }

    private(set) var annotations: [Annotation] = [] {
        didSet {
            needsDisplay = true
            onChange?()
        }
    }

    private var history: [[Annotation]] = []
    private var draft: Annotation? { didSet { needsDisplay = true } }
    private var dragStart: CGPoint?
    private var textField: NSTextField?
    private var textPixelsPerPoint: CGFloat = 1

    var canUndo: Bool { !history.isEmpty }
    var isEditingText: Bool { textField != nil }

    init(pixelSize: CGSize, pointSize: CGSize) {
        self.pixelSize = pixelSize
        self.pointSize = pointSize
        super.init(frame: .zero)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Geometry

    /// Where the screenshot sits inside the view: aspect-fit and centred, like the image view below.
    var imageRect: CGRect {
        guard pointSize.width > 0, pointSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / pointSize.width, bounds.height / pointSize.height)
        let size = CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private var pixelsPerPoint: CGFloat {
        let rect = imageRect
        return rect.width > 0 ? pixelSize.width / rect.width : 1
    }

    private func toImage(_ point: CGPoint) -> CGPoint {
        let rect = imageRect, scale = pixelsPerPoint
        return CGPoint(x: (point.x - rect.minX) * scale, y: (point.y - rect.minY) * scale)
    }

    private func clampedToImage(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), pixelSize.width), y: min(max(point.y, 0), pixelSize.height))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = imageRect
        guard rect.width > 0 else { return }
        context.saveGState()
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.minY)
        let scale = rect.width / pixelSize.width
        context.scaleBy(x: scale, y: scale)
        annotations.forEach { $0.draw() }
        draft?.draw()
        context.restoreGState()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        tool == .select ? nil : super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        switch tool {
        case .select: break
        case .text: addCursorRect(imageRect, cursor: .iBeam)
        default: addCursorRect(imageRect, cursor: .crosshair)
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isEditingText {
            commitText()
            return
        }
        guard imageRect.contains(point) else { return }
        let start = toImage(point), scale = pixelsPerPoint
        switch tool {
        case .select:
            return
        case .text:
            beginText(at: point)
            return
        case .pen:
            draft = .pen(points: [start], color: color, width: Self.penWidth * scale)
        case .highlighter:
            draft = .highlighter(points: [start], color: color, width: Self.highlighterWidth * scale)
        case .arrow:
            draft = .arrow(from: start, to: start, color: color, width: Self.arrowWidth * scale)
        case .rectangle:
            draft = .rectangle(CGRect(origin: start, size: .zero), color: color, width: Self.rectangleWidth * scale)
        }
        dragStart = start
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let current = draft else { return }
        let point = clampedToImage(toImage(convert(event.locationInWindow, from: nil)))
        switch current {
        case let .pen(points, color, width):
            draft = .pen(points: points + [point], color: color, width: width)
        case let .highlighter(points, color, width):
            draft = .highlighter(points: points + [point], color: color, width: width)
        case let .arrow(from, _, color, width):
            draft = .arrow(from: from, to: point, color: color, width: width)
        case let .rectangle(_, color, width):
            let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                              width: abs(point.x - start.x), height: abs(point.y - start.y))
            draft = .rectangle(rect, color: color, width: width)
        case .text:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let finished = draft else { return }
        draft = nil
        dragStart = nil
        if finished.isMeaningful { add(finished) }
    }

    // MARK: History

    func add(_ annotation: Annotation) {
        history.append(annotations)
        annotations.append(annotation)
    }

    func undo() {
        commitText()
        guard let previous = history.popLast() else { return }
        annotations = previous
    }

    /// Clear is undoable too, so a slip doesn't lose the drawings.
    func clear() {
        commitText()
        guard !annotations.isEmpty else { return }
        history.append(annotations)
        annotations = []
    }

    // MARK: Text

    private func beginText(at point: CGPoint) {
        let field = NSTextField(string: "")
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.font = Annotation.textFont(size: Self.fontSize)
        field.textColor = color
        field.placeholderString = "Type, then Return"
        field.delegate = self
        field.sizeToFit()
        field.setFrameOrigin(NSPoint(x: point.x - 2, y: point.y - field.frame.height / 2))
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        textPixelsPerPoint = pixelsPerPoint
    }

    /// Turns the text being typed into an annotation. Safe to call when nothing is being typed.
    func commitText() {
        guard let field = textField else { return }
        textField = nil
        let string = field.stringValue
        let fontSize = Self.fontSize
        let lineHeight = NSAttributedString(string: "Xg", attributes: Annotation.textAttributes(color: color, fontSize: fontSize)).size().height
        // NSTextField insets its text by about 2 points horizontally and 1 vertically.
        let origin = CGPoint(x: field.frame.minX + 2, y: field.frame.maxY - 1 - lineHeight)
        field.removeFromSuperview()
        window?.makeFirstResponder(nil)
        let annotation = Annotation.text(string, origin: toImage(origin), color: color, fontSize: fontSize * textPixelsPerPoint)
        if annotation.isMeaningful { add(annotation) }
    }

    private func cancelText() {
        guard let field = textField else { return }
        textField = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = textField else { return }
        let top = field.frame.maxY
        field.sizeToFit()
        field.setFrameOrigin(NSPoint(x: field.frame.minX, y: top - field.frame.height))
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commitText()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commitText()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelText()
            return true
        default:
            return false
        }
    }
}

/// A round colour button with a ring around the chosen one.
final class SwatchButton: NSButton {
    let swatchColor: NSColor
    var isChosen = false { didSet { needsDisplay = true } }

    init(color: NSColor, name: String, target: AnyObject, action: Selector) {
        swatchColor = color
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        isBordered = false
        title = ""
        toolTip = name
        setAccessibilityLabel(name)
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let dot = NSBezierPath(ovalIn: bounds.insetBy(dx: 5, dy: 5))
        swatchColor.setFill()
        dot.fill()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        dot.lineWidth = 0.5
        dot.stroke()
        if isChosen {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 2
            NSColor.labelColor.setStroke()
            ring.stroke()
        }
    }
}
