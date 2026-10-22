import AppKit
import Carbon.HIToolbox
import ImageIO

/// Checks the parts that don't need a screen: file naming, full-resolution rendering, shortcuts,
/// GIF export and Live Text.
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
        check(ScreenshotLibrary.fileName(for: date, prefix: "recording", extension: "gif") == "recording-2026-03-07_09-05-02.gif", "recordings are named recording-…")

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

        print("Shortcuts")
        let captureDefault = ShortcutAction.capture.defaultShortcut
        check(captureDefault.displayName == "⇧⌘1", "capture defaults to ⇧⌘1")
        check(ShortcutAction.captureText.defaultShortcut.displayName == "⇧⌘2", "capture text defaults to ⇧⌘2")
        check(ShortcutAction.record.defaultShortcut.displayName == "⇧⌘7", "record defaults to ⇧⌘7")
        check(captureDefault.carbonModifiers == cmdKey | shiftKey, "⇧⌘ maps to Carbon cmdKey | shiftKey")
        check(captureDefault.menuKeyEquivalent == "1", "menu shows the key as 1")
        let allMods = Shortcut(keyCode: kVK_ANSI_S, modifiers: [.command, .shift, .option, .control], key: "s")
        check(allMods.displayName == "⌃⌥⇧⌘S", "modifiers read in menu order: \(allMods.displayName)")
        check(!Shortcut(keyCode: kVK_ANSI_A, modifiers: [.shift], key: "a").isValid, "⇧A alone is refused")
        check(Shortcut(keyCode: kVK_F5, modifiers: [], key: "").isValid, "F5 alone is allowed")
        check(Shortcut(keyCode: kVK_Space, modifiers: [.option], key: " ").displayName == "⌥Space", "space is named Space")

        let suite = "snapkeep-selftest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShortcutSettings(defaults: defaults)
        check(store.shortcut(for: .capture) == captureDefault, "unset shortcut is the default")
        let custom = Shortcut(keyCode: kVK_ANSI_X, modifiers: [.control, .option], key: "x")
        try? store.set(custom, for: .capture)
        check(ShortcutSettings(defaults: defaults).shortcut(for: .capture) == custom, "a new shortcut is saved")
        do {
            try store.set(custom, for: .captureText)
            check(false, "the same shortcut twice is refused")
        } catch {
            check(error == .duplicate(custom, .capture), "the same shortcut twice is refused")
        }
        do {
            try store.set(Shortcut(keyCode: kVK_ANSI_A, modifiers: [], key: "a"), for: .captureText)
            check(false, "a shortcut without ⌘, ⌥ or ⌃ is refused")
        } catch {
            check(error == .needsModifier, "a shortcut without ⌘, ⌥ or ⌃ is refused")
        }
        try? store.set(nil, for: .captureText)
        check(store.shortcut(for: .captureText) == nil, "a shortcut can be turned off")
        store.restoreDefaults()
        check(store.shortcut(for: .capture) == captureDefault && store.shortcut(for: .captureText) != nil, "restore defaults")

        print("Sizes")
        check(fitting(CGSize(width: 2560, height: 1440), long: 1920, short: 1080) == CGSize(width: 1920, height: 1080), "a 1440p area fits 1920 × 1080")
        check(fitting(CGSize(width: 900, height: 2400), long: 1920, short: 1080) == CGSize(width: 720, height: 1920), "a tall area keeps its shape: 900 × 2400 → 720 × 1920")
        check(fitting(CGSize(width: 640, height: 400), long: 1920, short: 1080) == CGSize(width: 640, height: 400), "a small area is never scaled up")
        let screen = CGSize(width: 1512, height: 982)
        check(GIFExporter.outputSize(for: screen, preset: .full) == screen, "Full GIFs use points, not 2x pixels")
        check(GIFExporter.outputSize(for: screen, preset: .medium) == CGSize(width: 1232, height: 800), "a Medium GIF of the screen is 1232 × 800")
        check(GIFExporter.outputSize(for: screen, preset: .small) == CGSize(width: 800, height: 520), "a Small GIF of the screen is 800 × 520")
        check(GIFExporter.outputSize(for: CGSize(width: 640, height: 400), preset: .small) == CGSize(width: 640, height: 400), "no preset scales a small area up")
        check(ScreenRecorder.evenSize(CGSize(width: 1001, height: 603)) == CGSize(width: 1002, height: 604), "video sizes are even")
        check(formatDuration(7.9) == "0:07" && formatDuration(83) == "1:23" && formatDuration(3723) == "1:02:03", "durations read 0:07, 1:23, 1:02:03")

        print("GIF")
        checkGIFEncoder(in: dir)
        do {
            let video = dir.appendingPathComponent("test.mp4")
            let duration = try await TestVideo.write(to: video, pixelSize: CGSize(width: 1280, height: 800), seconds: 2)
            let gifURL = dir.appendingPathComponent("test.gif")
            let started = Date()
            let bytes = try await GIFExporter.export(video: video, pointSize: CGSize(width: 640, height: 400), preset: .full, to: gifURL) { _ in }
            let seconds = Date().timeIntervalSince(started)
            let source = CGImageSourceCreateWithURL(gifURL as CFURL, nil)!
            let frames = CGImageSourceGetCount(source)
            let firstFrame = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            check(firstFrame.width == 640 && firstFrame.height == 400, "2x video becomes a 640 × 400 GIF: \(firstFrame.width) × \(firstFrame.height)")
            check((14...16).contains(frames), "1 s of motion at 15 fps, then one long still frame: \(frames) frames")
            check(abs(gifDuration(source) - duration) < 0.05, "GIF lasts as long as the video, still end included: \(gifDuration(source)) s")
            let last = CGImageSourceCreateImageAtIndex(source, frames - 1, nil)!
            let square = pixel(last, x: 600, y: 60)
            check(square.b > 200 && square.r < 80, "the last frame shows the square at the right: \(square)")
            check(bytes < 200_000, "GIF is small: \(bytes / 1000) KB in \(String(format: "%.2f", seconds)) s")
            let estimate = try await GIFExporter.estimate(video: video, pointSize: CGSize(width: 640, height: 400), preset: .full)
            check(estimate == bytes, "a short recording's estimate is exact: \(estimate) bytes")

            let smallURL = dir.appendingPathComponent("test-small.gif")
            _ = try await GIFExporter.export(video: video, pointSize: CGSize(width: 640, height: 400), preset: .small, to: smallURL) { _ in }
            let smallFrames = CGImageSourceGetCount(CGImageSourceCreateWithURL(smallURL as CFURL, nil)!)
            check((9...11).contains(smallFrames), "Small runs at 10 fps: \(smallFrames) frames")

            // A longer recording is sampled.
            let long = dir.appendingPathComponent("long.mp4")
            let point = CGSize(width: 1512, height: 982)
            _ = try await TestVideo.write(to: long, pixelSize: CGSize(width: 3024, height: 1964), seconds: 12)
            for preset in GIFPreset.allCases {
                let estimateStarted = Date()
                let guess = try await GIFExporter.estimate(video: long, pointSize: point, preset: preset)
                let estimateSeconds = Date().timeIntervalSince(estimateStarted)
                let actual = try await GIFExporter.export(video: long, pointSize: point, preset: preset,
                                                          to: dir.appendingPathComponent("long-\(preset.rawValue).gif")) { _ in }
                let error = Double(guess - actual) / Double(actual)
                check(abs(error) < 0.35, String(format: "%@: estimate %d KB, actual %d KB (%+.0f%%) in %.2f s",
                                                preset.title, guess / 1000, actual / 1000, error * 100, estimateSeconds))
            }
        } catch {
            check(false, "video to GIF threw \(error)")
        }

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

    /// Three frames: grey, a red square over it, then the same again with a little noise that
    /// should count as unchanged.
    static func checkGIFEncoder(in dir: URL) {
        let width = 64, height = 48
        func frame(square: Bool, noise: Int = 0) -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let p = (y * width + x) * 4
                    let inSquare = square && (10..<30).contains(x) && (8..<24).contains(y)
                    let (r, g, b) = inSquare ? (220, 30, 40) : (128, 128, 128)
                    let n = (x + y) % 2 == 0 ? noise : -noise
                    pixels[p] = UInt8(b + n); pixels[p + 1] = UInt8(g + n); pixels[p + 2] = UInt8(r + n); pixels[p + 3] = 255
                }
            }
            return pixels
        }
        var histogram = GIFPalette.Histogram()
        let frames = [frame(square: false), frame(square: true), frame(square: true, noise: 3)]
        frames.forEach { f in f.withUnsafeBufferPointer { histogram.add(bgra: $0) } }
        let palette = GIFPalette(histogram: histogram)
        let entries = palette.red.indices.map { (Int(palette.red[$0]), Int(palette.green[$0]), Int(palette.blue[$0])) }
        check(entries.contains { $0 == (128, 128, 128) } && entries.contains { $0 == (220, 30, 40) },
              "palette keeps the exact grey and red: \(entries.count) colours")
        let encoder = GIFEncoder(width: width, height: height, palette: palette)
        for (i, f) in frames.enumerated() {
            f.withUnsafeBufferPointer { encoder.add(bgra: $0, at: Double(i) * 0.5) }
        }
        let data = encoder.finish(at: 1.5)
        let url = dir.appendingPathComponent("encoder.gif")
        try? data.write(to: url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            check(false, "ImageIO reads the GIF")
            return
        }
        check(CGImageSourceGetCount(source) == 2, "noise-only frame is dropped: \(CGImageSourceGetCount(source)) frames")
        check(abs(gifDuration(source) - 1.5) < 0.01, "frame times add up to 1.5 s: \(gifDuration(source))")
        let second = CGImageSourceCreateImageAtIndex(source, 1, nil)!
        let red = pixel(second, x: 20, y: height - 16), grey = pixel(second, x: 50, y: 40)
        check(red.r > 200 && red.g < 60, "second frame draws the square: \(red)")
        check(abs(grey.r - 128) < 4 && abs(grey.b - 128) < 4, "and keeps the grey from the first frame: \(grey)")
        // Header, 256-colour table and loop block: 800 bytes. A full 64 × 48 frame of noise would be about 3 KB.
        check(data.count - 800 < 200, "both frames take \(data.count - 800) bytes after the header")
    }

    static func gifDuration(_ source: CGImageSource) -> Double {
        (0..<CGImageSourceGetCount(source)).reduce(0) { total, index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            return total + (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0)
        }
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
