import AppKit

/// A drawing on top of a screenshot. Geometry is in image pixels with the origin at the
/// bottom-left, so drawings stay in place when the preview window is resized.
struct Annotation {
    enum Shape {
        case pen([CGPoint])
        case highlighter([CGPoint])
        case line(from: CGPoint, to: CGPoint)
        case arrow(from: CGPoint, to: CGPoint)
        case rectangle(CGRect)
        case text(String, origin: CGPoint)
    }

    var shape: Shape
    var color: NSColor
    /// The stroke width, or the font size for text, in image pixels.
    var width: CGFloat

    static let highlighterAlpha: CGFloat = 0.38

    static func pen(points: [CGPoint], color: NSColor, width: CGFloat) -> Annotation {
        Annotation(shape: .pen(points), color: color, width: width)
    }

    static func highlighter(points: [CGPoint], color: NSColor, width: CGFloat) -> Annotation {
        Annotation(shape: .highlighter(points), color: color, width: width)
    }

    static func line(from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat) -> Annotation {
        Annotation(shape: .line(from: from, to: to), color: color, width: width)
    }

    static func arrow(from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat) -> Annotation {
        Annotation(shape: .arrow(from: from, to: to), color: color, width: width)
    }

    static func rectangle(_ rect: CGRect, color: NSColor, width: CGFloat) -> Annotation {
        Annotation(shape: .rectangle(rect), color: color, width: width)
    }

    static func text(_ string: String, origin: CGPoint, color: NSColor, fontSize: CGFloat) -> Annotation {
        Annotation(shape: .text(string, origin: origin), color: color, width: fontSize)
    }

    /// Whether the annotation is big enough to keep (a stray click shouldn't add an empty rectangle).
    var isMeaningful: Bool {
        switch shape {
        case let .pen(points), let .highlighter(points):
            return !points.isEmpty
        case let .line(from, to), let .arrow(from, to):
            return hypot(to.x - from.x, to.y - from.y) > 4
        case let .rectangle(rect):
            return rect.width > 2 && rect.height > 2
        case let .text(string, _):
            return !string.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    // MARK: Drawing

    /// Draws into the current graphics context, whose user space is image pixels.
    func draw() {
        switch shape {
        case let .pen(points):
            Annotation.stroke(points, color: color, width: width)
        case let .highlighter(points):
            Annotation.stroke(points, color: color.withAlphaComponent(Annotation.highlighterAlpha), width: width)
        case let .line(from, to):
            Annotation.stroke([from, to], color: color, width: width)
        case let .arrow(from, to):
            Annotation.drawArrow(from: from, to: to, color: color, width: width)
        case let .rectangle(rect):
            let path = NSBezierPath(rect: rect)
            path.lineWidth = width
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()
        case let .text(string, origin):
            NSAttributedString(string: string, attributes: Annotation.textAttributes(color: color, fontSize: width))
                .draw(at: origin)
        }
    }

    static func textFont(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    static func textAttributes(color: NSColor, fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: textFont(size: fontSize), .foregroundColor: color]
    }

    private static func stroke(_ points: [CGPoint], color: NSColor, width: CGFloat) {
        guard let first = points.first else { return }
        let path = NSBezierPath()
        path.move(to: first)
        // A single click leaves a dot: a zero-length line with round caps.
        if points.count == 1 { path.line(to: first) }
        for point in points.dropFirst() { path.line(to: point) }
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    private static func drawArrow(from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat) {
        let length = hypot(to.x - from.x, to.y - from.y)
        guard length > 0 else { return }
        let ux = (to.x - from.x) / length, uy = (to.y - from.y) / length
        let headLength = min(max(width * 4.5, 14), length)
        let headHalfWidth = headLength * 0.55
        let base = CGPoint(x: to.x - ux * headLength, y: to.y - uy * headLength)

        // End the shaft inside the head so its round cap doesn't poke through the tip.
        let shaftEnd = CGPoint(x: to.x - ux * headLength * 0.6, y: to.y - uy * headLength * 0.6)
        let shaft = NSBezierPath()
        shaft.move(to: from)
        shaft.line(to: shaftEnd)
        shaft.lineWidth = width
        shaft.lineCapStyle = .round
        color.setStroke()
        shaft.stroke()

        let head = NSBezierPath()
        head.move(to: to)
        head.line(to: CGPoint(x: base.x - uy * headHalfWidth, y: base.y + ux * headHalfWidth))
        head.line(to: CGPoint(x: base.x + uy * headHalfWidth, y: base.y - ux * headHalfWidth))
        head.close()
        head.lineJoinStyle = .round
        head.lineWidth = max(width * 0.5, 1)
        color.setFill()
        head.fill()
        head.stroke()
    }

    // MARK: Editing

    /// The area the drawing covers, for the selection outline.
    var bounds: CGRect {
        switch shape {
        case let .pen(points), let .highlighter(points):
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .null }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -width / 2, dy: -width / 2)
        case let .line(from, to), let .arrow(from, to):
            return CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y))
                .insetBy(dx: -width / 2, dy: -width / 2)
        case let .rectangle(rect):
            return rect.insetBy(dx: -width / 2, dy: -width / 2)
        case let .text(string, origin):
            let size = NSAttributedString(string: string, attributes: Annotation.textAttributes(color: color, fontSize: width)).size()
            return CGRect(origin: origin, size: size)
        }
    }

    /// How far a point is from the visible ink, 0 or less when it's on it. Only the outline of a
    /// rectangle counts, so the area inside stays free for drawing and selecting text.
    func distance(to point: CGPoint) -> CGFloat {
        switch shape {
        case let .pen(points), let .highlighter(points):
            guard let first = points.first else { return .infinity }
            let segments = points.count == 1 ? [(first, first)] : Array(zip(points, points.dropFirst()))
            return segments.map { Annotation.distance(point, toSegment: $0.0, $0.1) }.min()! - width / 2
        case let .line(from, to), let .arrow(from, to):
            return Annotation.distance(point, toSegment: from, to) - width / 2
        case let .rectangle(rect):
            let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                           CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
            return zip(corners, corners.dropFirst() + [corners[0]])
                .map { Annotation.distance(point, toSegment: $0.0, $0.1) }.min()! - width / 2
        case .text:
            let box = bounds
            return hypot(max(box.minX - point.x, 0, point.x - box.maxX), max(box.minY - point.y, 0, point.y - box.maxY))
        }
    }

    private static func distance(_ point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    /// Which side of the rectangle each handle moves: -1 the min edge, 1 the max edge, 0 neither.
    private static let rectangleHandles: [(x: CGFloat, y: CGFloat)] = [
        (-1, -1), (1, -1), (1, 1), (-1, 1), (0, -1), (1, 0), (0, 1), (-1, 0),
    ]

    /// The points that can be dragged to reshape it: both ends of a line or an arrow, the corners
    /// and edges of a rectangle. Pen strokes, highlights and text can only be moved.
    var handles: [CGPoint] {
        switch shape {
        case let .line(from, to), let .arrow(from, to):
            return [from, to]
        case let .rectangle(rect):
            return Annotation.rectangleHandles.map { side in
                CGPoint(x: rect.midX + side.x * rect.width / 2, y: rect.midY + side.y * rect.height / 2)
            }
        case .pen, .highlighter, .text:
            return []
        }
    }

    /// The annotation with handle `index` dragged to `point`.
    func movingHandle(_ index: Int, to point: CGPoint) -> Annotation {
        var copy = self
        switch shape {
        case let .line(from, to):
            copy.shape = index == 0 ? .line(from: point, to: to) : .line(from: from, to: point)
        case let .arrow(from, to):
            copy.shape = index == 0 ? .arrow(from: point, to: to) : .arrow(from: from, to: point)
        case let .rectangle(rect):
            let side = Annotation.rectangleHandles[index]
            var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
            if side.x < 0 { minX = point.x } else if side.x > 0 { maxX = point.x }
            if side.y < 0 { minY = point.y } else if side.y > 0 { maxY = point.y }
            copy.shape = .rectangle(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        case .pen, .highlighter, .text:
            break
        }
        return copy
    }

    /// The point a handle's opposite end is anchored to, for constraining lines and arrows.
    func anchor(forHandle index: Int) -> CGPoint? {
        switch shape {
        case let .line(from, to), let .arrow(from, to):
            return index == 0 ? to : from
        default:
            return nil
        }
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> Annotation {
        let move = { (point: CGPoint) in CGPoint(x: point.x + dx, y: point.y + dy) }
        var copy = self
        switch shape {
        case let .pen(points): copy.shape = .pen(points.map(move))
        case let .highlighter(points): copy.shape = .highlighter(points.map(move))
        case let .line(from, to): copy.shape = .line(from: move(from), to: move(to))
        case let .arrow(from, to): copy.shape = .arrow(from: move(from), to: move(to))
        case let .rectangle(rect): copy.shape = .rectangle(rect.offsetBy(dx: dx, dy: dy))
        case let .text(string, origin): copy.shape = .text(string, origin: move(origin))
        }
        return copy
    }

    /// Where a line from `start` to `end` should end. With `fortyFive`, it turns in 45° steps;
    /// otherwise, with `snapToAxes`, it straightens when within a few degrees of level or upright.
    static func constrainedEnd(_ end: CGPoint, from start: CGPoint, fortyFive: Bool, snapToAxes: Bool) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return end }
        if fortyFive {
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
        }
        if snapToAxes {
            let degrees = abs(atan2(dy, dx)) * 180 / .pi
            if degrees < 4 || degrees > 176 { return CGPoint(x: end.x, y: start.y) }
            if abs(degrees - 90) < 4 { return CGPoint(x: start.x, y: end.y) }
        }
        return end
    }
}
