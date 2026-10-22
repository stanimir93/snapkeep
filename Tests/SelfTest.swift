import AppKit

/// Checks the parts that don't need a screen: file naming, full-resolution rendering and Live Text.
@main
@MainActor
struct SelfTest {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        print(condition ? "  ok    \(message)" : "  FAIL  \(message)")
        if !condition { failures += 1 }
    }

    static func main() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snapkeep-selftest-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        print("File names")
        var components = DateComponents()
        (components.year, components.month, components.day) = (2026, 3, 7)
        (components.hour, components.minute, components.second) = (9, 5, 2)
        let date = Calendar.current.date(from: components)!
        check(ScreenshotLibrary.fileName(for: date) == "screenshot-2026-03-07_09-05-02.png", "date-stamped name")
        let library = ScreenshotLibrary(folder: dir.appendingPathComponent("Screenshots"))
        let first = try! library.newFileURL(date: date)
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = try! library.newFileURL(date: date)
        check(FileManager.default.fileExists(atPath: library.folder.path), "creates the folder")
        check(second.lastPathComponent == "screenshot-2026-03-07_09-05-02-2.png", "same-second capture gets -2")
        check(library.newest()?.resolvingSymlinksInPath().path == first.resolvingSymlinksInPath().path, "finds the newest screenshot: \(library.newest()?.lastPathComponent ?? "none")")

        print("Rendering")
        let sampleURL = dir.appendingPathComponent("sample.png")
        try! makeSample(text: "Invoice 4821 due Friday", pixelSize: CGSize(width: 1600, height: 400), dpi: 144).write(to: sampleURL)
        guard let shot = Screenshot.load(sampleURL) else {
            check(false, "loads the sample")
            exit(1)
        }
        check(shot.pointSize == CGSize(width: 800, height: 200), "144 dpi image is 800×200 points")
        let rect = CGRect(x: 100, y: 100, width: 400, height: 200)
        let annotations: [Annotation] = [
            .rectangle(rect, color: .systemRed, width: 10),
            .highlighter(points: [CGPoint(x: 900, y: 50), CGPoint(x: 1500, y: 50)], color: .systemYellow, width: 40),
        ]
        let data = Renderer.pngData(base: shot.cgImage, pointSize: shot.pointSize, annotations: annotations)!
        let renderedURL = dir.appendingPathComponent("rendered.png")
        try! data.write(to: renderedURL)
        let rendered = Screenshot.load(renderedURL)!
        check(rendered.pixelSize == shot.pixelSize, "export keeps full pixel size \(Int(rendered.pixelSize.width))×\(Int(rendered.pixelSize.height))")
        check(rendered.pointSize == shot.pointSize, "export keeps 144 dpi")
        let edge = pixel(rendered.cgImage, x: 100, y: 200)
        check(edge.r > 200 && edge.g < 90 && edge.b < 90, "rectangle edge is red at image pixel (100, 200): \(edge)")
        let highlight = pixel(rendered.cgImage, x: 1200, y: 50)
        check(highlight.r > 230 && highlight.g > 200 && highlight.b < 200 && highlight.b > 60, "highlighter is translucent yellow: \(highlight)")
        let untouched = pixel(rendered.cgImage, x: 1550, y: 380)
        check(untouched.r > 245 && untouched.g > 245 && untouched.b > 245, "undrawn area stays white: \(untouched)")

        print("Snapping")
        // 200×150 pt at 2x: white, with a 1 px grey line down column 200 and across row 100 (from the top).
        let lines = makeLines(pixelSize: CGSize(width: 400, height: 300), column: 200, row: 100)
        var snapper = Snapper(size: CGSize(width: 200, height: 150), scale: 2, edges: EdgeMap(image: lines))
        let snappedX = snapper.snapX(103, along: 20...130)
        check(snappedX == 100 || snappedX == 100.5, "x 103 snaps to the vertical line at 100: \(snappedX)")
        let snappedY = snapper.snapY(97, along: 10...190)
        check(snappedY == 100 || snappedY == 99.5, "y 97 snaps to the horizontal line at 100: \(snappedY)")
        check(snapper.snapX(150, along: 20...130) == 150, "x 150 stays put, nothing nearby")
        check(snapper.snapX(195, along: 20...130) == 200, "x 195 snaps to the screen edge")
        snapper.windowFrames = [CGRect(x: 30, y: 20, width: 50, height: 100)]
        check(snapper.snapX(84, along: 40...60) == 80, "x 84 snaps to a window edge at 80")
        snapper.isEnabled = false
        check(snapper.snapX(103.2, along: 20...130) == 103, "snapping off only rounds to the pixel grid")

        print("Live Text")
        check(TextRecognizer.isSupported, "ImageAnalyzer is supported")
        let started = Date()
        do {
            let analysis = try await TextRecognizer.analyze(shot.cgImage)
            let seconds = Date().timeIntervalSince(started)
            check(analysis.transcript.contains("Invoice 4821"), "reads \"\(analysis.transcript)\" in \(String(format: "%.2f", seconds)) s")
        } catch {
            check(false, "analysis threw \(error)")
        }

        print(failures == 0 ? "All checks passed" : "\(failures) check(s) failed")
        exit(failures == 0 ? 0 : 1)
    }

    /// Black text on white, the shape of a typical screenshot.
    static func makeSample(text: String, pixelSize: CGSize, dpi: Double) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: Int(pixelSize.width), height: Int(pixelSize.height), bitsPerComponent: 8,
                                bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: pixelSize))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 96), .foregroundColor: NSColor.black])
            .draw(at: CGPoint(x: 80, y: 150))
        NSGraphicsContext.restoreGraphicsState()
        let image = context.makeImage()!
        return Renderer.encodePNG(image, pointSize: CGSize(width: pixelSize.width * 72 / dpi, height: pixelSize.height * 72 / dpi))!
    }

    static func makeLines(pixelSize: CGSize, column: Int, row: Int) -> CGImage {
        let context = CGContext(data: nil, width: Int(pixelSize.width), height: Int(pixelSize.height), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: pixelSize))
        context.setFillColor(CGColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: column, y: 0, width: 1, height: Int(pixelSize.height)))
        // CG's origin is bottom-left, so row-from-top r sits at y = height - r - 1.
        context.fill(CGRect(x: 0, y: Int(pixelSize.height) - row - 1, width: Int(pixelSize.width), height: 1))
        return context.makeImage()!
    }

    /// Reads a pixel in image coordinates (origin bottom-left), converted to sRGB.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }
}
