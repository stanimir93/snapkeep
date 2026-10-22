import AppKit

/// A drawing on top of a screenshot. Geometry is in image pixels with the origin at the
/// bottom-left, so drawings stay in place when the preview window is resized.
enum Annotation {
    case pen(points: [CGPoint], color: NSColor, width: CGFloat)
    case highlighter(points: [CGPoint], color: NSColor, width: CGFloat)
    case arrow(from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat)
    case rectangle(CGRect, color: NSColor, width: CGFloat)
    case text(String, origin: CGPoint, color: NSColor, fontSize: CGFloat)

    static let highlighterAlpha: CGFloat = 0.38

    /// Whether the annotation is big enough to keep (a stray click shouldn't add an empty rectangle).
    var isMeaningful: Bool {
        switch self {
        case let .pen(points, _, _), let .highlighter(points, _, _):
            return !points.isEmpty
        case let .arrow(from, to, _, _):
            return hypot(to.x - from.x, to.y - from.y) > 4
        case let .rectangle(rect, _, _):
            return rect.width > 2 && rect.height > 2
        case let .text(string, _, _, _):
            return !string.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Draws into the current graphics context, whose user space is image pixels.
    func draw() {
        switch self {
        case let .pen(points, color, width):
            Annotation.stroke(points, color: color, width: width)
        case let .highlighter(points, color, width):
            Annotation.stroke(points, color: color.withAlphaComponent(Annotation.highlighterAlpha), width: width)
        case let .arrow(from, to, color, width):
            Annotation.drawArrow(from: from, to: to, color: color, width: width)
        case let .rectangle(rect, color, width):
            let path = NSBezierPath(rect: rect)
            path.lineWidth = width
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()
        case let .text(string, origin, color, fontSize):
            NSAttributedString(string: string, attributes: Annotation.textAttributes(color: color, fontSize: fontSize))
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
}
