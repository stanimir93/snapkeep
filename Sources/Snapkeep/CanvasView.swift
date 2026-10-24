import AppKit

enum Tool: Int, CaseIterable {
    case select, pen, highlighter, line, arrow, rectangle, text

    var title: String {
        switch self {
        case .select: "Select text"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .line: "Line"
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
        case .line: "l"
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
        case .line: ["minus"]
        case .arrow: ["arrow.up.right"]
        case .rectangle: ["rectangle"]
        case .text: ["textformat"]
        }
    }

    /// Whether clicking a drawing with this tool picks it up instead of drawing. Pen and
    /// Highlighter always draw, so you can scribble over other drawings.
    var canGrabDrawings: Bool {
        switch self {
        case .select, .line, .arrow, .rectangle, .text: true
        case .pen, .highlighter: false
        }
    }
}

/// How thick new drawings are, and how big new text is.
enum Thickness: Int, CaseIterable {
    case thin, regular, thick, heavy

    var title: String {
        switch self {
        case .thin: "Thin"
        case .regular: "Regular"
        case .thick: "Thick"
        case .heavy: "Heavy"
        }
    }

    var strokeScale: CGFloat { [0.5, 1, 2, 3][rawValue] }
    var textScale: CGFloat { [0.7, 1, 1.5, 2][rawValue] }
}

/// The transparent drawing layer above the screenshot. In "Select text" mode it lets every
/// click through to the Live Text overlay underneath, except on drawings, which it picks up.
@MainActor
final class CanvasView: NSView, NSTextFieldDelegate {
    /// Sizes in view points at the moment of drawing, converted to image pixels when stored.
    private static let penWidth: CGFloat = 3
    private static let highlighterWidth: CGFloat = 18
    private static let lineWidth: CGFloat = 3
    private static let arrowWidth: CGFloat = 4
    private static let rectangleWidth: CGFloat = 3
    private static let fontSize: CGFloat = 20
    /// How near a click has to be to a drawing or a handle to pick it up.
    private static let grabDistance: CGFloat = 5
    private static let handleRadius: CGFloat = 5

    let pixelSize: CGSize
    let pointSize: CGSize
    var onChange: (() -> Void)?

    var tool: Tool = .select {
        didSet {
            if tool != .text { commitText() }
            if !tool.canGrabDrawings { selectedIndex = nil }
            updateCursorAtMouse()
        }
    }

    /// Colour for new drawings. Picking one also recolours the selected drawing.
    var color: NSColor = .systemRed {
        didSet {
            textField?.textColor = color
            updateSelected { $0.color = color }
        }
    }

    /// Thickness for new drawings. Picking one also changes the selected drawing.
    var thickness: Thickness = .regular {
        didSet {
            if let field = textField {
                field.font = Annotation.textFont(size: textFontSize)
                controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            }
            updateSelected { [self] in $0.width = pointWidth(for: $0.shape) * pixelsPerPoint }
        }
    }

    private(set) var annotations: [Annotation] = [] {
        didSet {
            if let index = selectedIndex, index >= annotations.count { selectedIndex = nil }
            needsDisplay = true
            onChange?()
        }
    }

    /// The drawing picked up to move, reshape, recolour or delete.
    private(set) var selectedIndex: Int? {
        didSet {
            guard selectedIndex != oldValue else { return }
            needsDisplay = true
            onChange?()
        }
    }

    private enum Drag {
        case drawing(start: CGPoint)
        case moving(index: Int, start: CGPoint, original: Annotation)
        case reshaping(index: Int, handle: Int, original: Annotation)
    }

    private var history: [[Annotation]] = []
    private var draft: Annotation? { didSet { needsDisplay = true } }
    private var drag: Drag?
    /// The drawings before a move or reshape, added to the history once the drag changes something.
    private var dragUndoState: [Annotation]?
    private var textField: NSTextField?
    private var textPixelsPerPoint: CGFloat = 1
    private var ownsCursor = false

    var canUndo: Bool { !history.isEmpty }
    var isEditingText: Bool { textField != nil }
    var hasSelection: Bool { selectedIndex != nil }

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

    private func fromImage(_ point: CGPoint) -> CGPoint {
        let rect = imageRect, scale = pixelsPerPoint
        return CGPoint(x: rect.minX + point.x / scale, y: rect.minY + point.y / scale)
    }

    private func clampedToImage(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), pixelSize.width), y: min(max(point.y, 0), pixelSize.height))
    }

    /// The width in view points for a drawing of this shape at the current thickness.
    private func pointWidth(for shape: Annotation.Shape) -> CGFloat {
        switch shape {
        case .pen: Self.penWidth * thickness.strokeScale
        case .highlighter: Self.highlighterWidth * thickness.strokeScale
        case .line: Self.lineWidth * thickness.strokeScale
        case .arrow: Self.arrowWidth * thickness.strokeScale
        case .rectangle: Self.rectangleWidth * thickness.strokeScale
        case .text: textFontSize
        }
    }

    private var textFontSize: CGFloat { Self.fontSize * thickness.textScale }

    /// The topmost drawing under a point in view coordinates.
    private func annotationIndex(at point: CGPoint) -> Int? {
        let target = toImage(point), reach = Self.grabDistance * pixelsPerPoint
        return annotations.indices.reversed().first { annotations[$0].distance(to: target) <= reach }
    }

    /// The handle of the selected drawing under a point in view coordinates.
    private func handleIndex(at point: CGPoint) -> Int? {
        guard let index = selectedIndex else { return nil }
        let reach = Self.handleRadius + 3
        return annotations[index].handles.indices.first { handle in
            let center = fromImage(annotations[index].handles[handle])
            return hypot(center.x - point.x, center.y - point.y) <= reach
        }
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
        if let index = selectedIndex { drawSelection(of: annotations[index]) }
    }

    /// Round handles on the points that reshape it, or a dashed outline when it can only be moved.
    private func drawSelection(of annotation: Annotation) {
        let handles = annotation.handles
        if handles.isEmpty {
            let box = annotation.bounds
            let origin = fromImage(box.origin), corner = fromImage(CGPoint(x: box.maxX, y: box.maxY))
            let outline = NSBezierPath(rect: CGRect(x: origin.x, y: origin.y, width: corner.x - origin.x, height: corner.y - origin.y)
                .insetBy(dx: -4, dy: -4))
            outline.lineWidth = 1.5
            outline.setLineDash([5, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            outline.stroke()
            return
        }
        for handle in handles {
            let center = fromImage(handle), radius = Self.handleRadius
            let dot = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            NSColor.white.setFill()
            dot.fill()
            dot.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            dot.stroke()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard tool == .select else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        // With a drawing selected, a click anywhere on the image is ours, to put it down.
        if selectedIndex != nil, imageRect.contains(local) { return self }
        return annotationIndex(at: local) != nil ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updateCursorAtMouse() {
        guard let window else { return }
        updateCursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func updateCursor(at point: CGPoint) {
        guard drag == nil else { return }
        let cursor: NSCursor?
        if handleIndex(at: point) != nil {
            cursor = .pointingHand
        } else if tool.canGrabDrawings, annotationIndex(at: point) != nil {
            cursor = .openHand
        } else if tool == .select {
            cursor = nil // Live Text shows its own cursor
        } else if imageRect.contains(point) {
            cursor = tool == .text ? .iBeam : .crosshair
        } else {
            cursor = .arrow
        }
        if let cursor {
            cursor.set()
            ownsCursor = true
        } else if ownsCursor {
            NSCursor.arrow.set()
            ownsCursor = false
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isEditingText {
            commitText()
            return
        }
        if let index = selectedIndex, let handle = handleIndex(at: point) {
            dragUndoState = annotations
            drag = .reshaping(index: index, handle: handle, original: annotations[index])
            return
        }
        if tool.canGrabDrawings, let index = annotationIndex(at: point) {
            selectedIndex = index
            dragUndoState = annotations
            drag = .moving(index: index, start: toImage(point), original: annotations[index])
            NSCursor.closedHand.set()
            return
        }
        selectedIndex = nil
        guard imageRect.contains(point) else { return }
        let start = toImage(point), scale = pixelsPerPoint
        let shape: Annotation.Shape
        switch tool {
        case .select:
            return
        case .text:
            beginText(at: point)
            return
        case .pen: shape = .pen([start])
        case .highlighter: shape = .highlighter([start])
        case .line: shape = .line(from: start, to: start)
        case .arrow: shape = .arrow(from: start, to: start)
        case .rectangle: shape = .rectangle(CGRect(origin: start, size: .zero))
        }
        draft = Annotation(shape: shape, color: color, width: pointWidth(for: shape) * scale)
        drag = .drawing(start: start)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let raw = toImage(convert(event.locationInWindow, from: nil))
        let point = clampedToImage(raw)
        let shift = event.modifierFlags.contains(.shift), option = event.modifierFlags.contains(.option)
        switch drag {
        case let .drawing(start):
            guard var current = draft else { return }
            switch current.shape {
            case let .pen(points):
                current.shape = .pen(points + [point])
            case let .highlighter(points):
                current.shape = .highlighter(points + [point])
            case let .line(from, _):
                // Lines straighten to level or upright on their own, for underlining. ⌥ turns that off.
                current.shape = .line(from: from, to: Annotation.constrainedEnd(point, from: from, fortyFive: shift, snapToAxes: !option))
            case let .arrow(from, _):
                current.shape = .arrow(from: from, to: Annotation.constrainedEnd(point, from: from, fortyFive: shift, snapToAxes: false))
            case .rectangle:
                current.shape = .rectangle(CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                                                  width: abs(point.x - start.x), height: abs(point.y - start.y)))
            case .text:
                break
            }
            draft = current
        case let .moving(index, start, original):
            saveDragUndoState()
            annotations[index] = original.offsetBy(dx: raw.x - start.x, dy: raw.y - start.y)
        case let .reshaping(index, handle, original):
            saveDragUndoState()
            var target = point
            if let anchor = original.anchor(forHandle: handle) {
                var isLine = false
                if case .line = original.shape { isLine = true }
                target = Annotation.constrainedEnd(point, from: anchor, fortyFive: shift, snapToAxes: isLine && !option)
            }
            annotations[index] = original.movingHandle(handle, to: target)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let finished = draft
        draft = nil
        drag = nil
        dragUndoState = nil
        if let finished, finished.isMeaningful { add(finished) }
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func saveDragUndoState() {
        guard let state = dragUndoState else { return }
        history.append(state)
        dragUndoState = nil
    }

    // MARK: History

    func add(_ annotation: Annotation) {
        history.append(annotations)
        annotations.append(annotation)
    }

    func undo() {
        commitText()
        guard let previous = history.popLast() else { return }
        selectedIndex = nil
        annotations = previous
    }

    /// Clear is undoable too, so a slip doesn't lose the drawings.
    func clear() {
        commitText()
        guard !annotations.isEmpty else { return }
        selectedIndex = nil
        history.append(annotations)
        annotations = []
    }

    // MARK: Selection

    func select(_ index: Int?) {
        selectedIndex = index.flatMap { annotations.indices.contains($0) ? $0 : nil }
    }

    /// Deletes the selected drawing. Returns false when nothing is selected.
    @discardableResult
    func deleteSelected() -> Bool {
        guard let index = selectedIndex else { return false }
        selectedIndex = nil
        history.append(annotations)
        annotations.remove(at: index)
        return true
    }

    /// Puts the selected drawing down. Returns false when nothing is selected.
    @discardableResult
    func deselect() -> Bool {
        guard selectedIndex != nil else { return false }
        selectedIndex = nil
        return true
    }

    private func updateSelected(_ change: (inout Annotation) -> Void) {
        guard let index = selectedIndex else { return }
        var changed = annotations[index]
        change(&changed)
        history.append(annotations)
        annotations[index] = changed
    }

    // MARK: Text

    private func beginText(at point: CGPoint) {
        let field = NSTextField(string: "")
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.font = Annotation.textFont(size: textFontSize)
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
        let fontSize = textFontSize
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
