import CoreGraphics

/// Brightness of a frozen screen, used to find the lines that divide an app into sections
/// (sidebars, toolbars, panes) so selection edges can snap to them.
final class EdgeMap: @unchecked Sendable {
    let width: Int
    let height: Int
    /// Rows from the top of the image.
    private let luma: [UInt8]
    /// Neighbouring pixels must differ by this much to count as an edge.
    private let threshold = 10

    init?(image: CGImage) {
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        luma = buffer
    }

    /// How much of the boundary between columns x-1 and x, over `rows`, is a visible line (0…1).
    func verticalEdgeStrength(column x: Int, rows: Range<Int>) -> Double {
        guard x > 0, x < width else { return 0 }
        let lower = max(rows.lowerBound, 0), upper = min(rows.upperBound, height)
        guard upper - lower >= 2 else { return 0 }
        let step = max(1, (upper - lower) / 300)
        var hits = 0, samples = 0
        for row in stride(from: lower, to: upper, by: step) {
            let index = row * width + x
            if abs(Int(luma[index]) - Int(luma[index - 1])) >= threshold { hits += 1 }
            samples += 1
        }
        return Double(hits) / Double(samples)
    }

    /// How much of the boundary between rows y-1 and y (from the top), over `columns`, is a visible line (0…1).
    func horizontalEdgeStrength(row y: Int, columns: Range<Int>) -> Double {
        guard y > 0, y < height else { return 0 }
        let lower = max(columns.lowerBound, 0), upper = min(columns.upperBound, width)
        guard upper - lower >= 2 else { return 0 }
        let step = max(1, (upper - lower) / 300)
        var hits = 0, samples = 0
        for column in stride(from: lower, to: upper, by: step) {
            let index = y * width + column
            if abs(Int(luma[index]) - Int(luma[index - width])) >= threshold { hits += 1 }
            samples += 1
        }
        return Double(hits) / Double(samples)
    }
}

/// Pulls selection edges onto nearby window borders, screen edges and lines in the image.
/// Works in the overlay's points: origin at the bottom-left of the screen.
struct Snapper {
    var size: CGSize
    var scale: CGFloat
    var windowFrames: [CGRect] = []
    var edges: EdgeMap?
    var isEnabled = true
    /// How close, in points, an edge has to be to pull the selection.
    var radius: CGFloat = 8
    /// The share of an edge that must be a visible line to count.
    var minimumStrength = 0.6

    func snapX(_ x: CGFloat, along span: ClosedRange<CGFloat>) -> CGFloat {
        guard isEnabled else { return aligned(x) }
        let span = widened(span)
        var nearest = Nearest(target: x, radius: radius)
        nearest.consider(0)
        nearest.consider(size.width)
        for frame in windowFrames where frame.minY <= span.upperBound && frame.maxY >= span.lowerBound {
            nearest.consider(frame.minX)
            nearest.consider(frame.maxX)
        }
        if let edges {
            let rows = Int(((size.height - span.upperBound) * scale).rounded())..<Int(((size.height - span.lowerBound) * scale).rounded())
            let center = Int((x * scale).rounded()), reach = Int(radius * scale)
            for column in (center - reach)...(center + reach)
            where edges.verticalEdgeStrength(column: column, rows: rows) >= minimumStrength {
                nearest.consider(CGFloat(column) / scale)
            }
        }
        return aligned(nearest.best ?? x)
    }

    func snapY(_ y: CGFloat, along span: ClosedRange<CGFloat>) -> CGFloat {
        guard isEnabled else { return aligned(y) }
        let span = widened(span)
        var nearest = Nearest(target: y, radius: radius)
        nearest.consider(0)
        nearest.consider(size.height)
        for frame in windowFrames where frame.minX <= span.upperBound && frame.maxX >= span.lowerBound {
            nearest.consider(frame.minY)
            nearest.consider(frame.maxY)
        }
        if let edges {
            let columns = Int((span.lowerBound * scale).rounded())..<Int((span.upperBound * scale).rounded())
            let center = Int(((size.height - y) * scale).rounded()), reach = Int(radius * scale)
            for row in (center - reach)...(center + reach)
            where edges.horizontalEdgeStrength(row: row, columns: columns) >= minimumStrength {
                nearest.consider(size.height - CGFloat(row) / scale)
            }
        }
        return aligned(nearest.best ?? y)
    }

    /// Snaps a single point, judging edges over a short stretch around it.
    func snapPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: snapX(point.x, along: (point.y - 20)...(point.y + 20)),
                y: snapY(point.y, along: (point.x - 20)...(point.x + 20)))
    }

    /// Rounds to the pixel grid so the capture has no half pixels.
    func aligned(_ value: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }

    /// A very short edge can't tell a line from a letter, so judge at least 40 points of it.
    private func widened(_ span: ClosedRange<CGFloat>) -> ClosedRange<CGFloat> {
        guard span.upperBound - span.lowerBound < 40 else { return span }
        let middle = (span.lowerBound + span.upperBound) / 2
        return (middle - 20)...(middle + 20)
    }

    private struct Nearest {
        let target: CGFloat
        let radius: CGFloat
        var best: CGFloat?
        private var distance: CGFloat

        init(target: CGFloat, radius: CGFloat) {
            self.target = target
            self.radius = radius
            distance = radius
        }

        mutating func consider(_ candidate: CGFloat) {
            let candidateDistance = abs(candidate - target)
            if candidateDistance <= distance {
                best = candidate
                distance = candidateDistance
            }
        }
    }
}
