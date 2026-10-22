import Accelerate
import AVFoundation

/// How big and smooth a GIF is. No preset makes a GIF larger than the recorded area in points
/// (no 2x Retina pixels), so a small area looks the same in all three, only smoother in Full.
enum GIFPreset: String, CaseIterable, Sendable {
    case small, medium, full

    static let defaultsKey = "gifPreset"

    /// The preset the last GIF was saved with, Medium at first.
    static var lastUsed: GIFPreset {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(GIFPreset.init) ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .full: "Full"
        }
    }

    var purpose: String {
        switch self {
        case .small: "for chat and tickets"
        case .medium: "for pull requests and docs"
        case .full: "when detail matters"
        }
    }

    /// The largest GIF, longer side × shorter side.
    var maxSize: (long: CGFloat, short: CGFloat) {
        switch self {
        case .small: (800, 600)
        case .medium: (1280, 800)
        case .full: (1920, 1080)
        }
    }

    var frameRate: Double {
        switch self {
        case .small: 10
        case .medium: 12
        case .full: 15
        }
    }
}

/// Turns a recording into a GIF small enough to share:
/// - the preset's size and frame rate
/// - one palette of 255 colours for the whole GIF, without dithering, so text stays sharp and
///   still areas don't shimmer
/// - each frame keeps only the pixels that changed, and frames with no change are dropped
enum GIFExporter {
    static func outputSize(for pointSize: CGSize, preset: GIFPreset) -> CGSize {
        let size = fitting(pointSize, long: preset.maxSize.long, short: preset.maxSize.short)
        return CGSize(width: max(size.width, 1), height: max(size.height, 1))
    }

    /// Writes the GIF and returns its size in bytes. `progress` goes from 0 to 1.
    static func export(video: URL, pointSize: CGSize, preset: GIFPreset, to url: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> Int {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw RecorderError.noFrames }
        let duration = try await asset.load(.duration).seconds
        let data = try encode(asset: asset, track: track, range: nil, duration: duration,
                              size: outputSize(for: pointSize, preset: preset), frameRate: preset.frameRate,
                              progress: progress).data
        try data.write(to: url, options: .atomic)
        progress(1)
        return data.count
    }

    /// Roughly how many bytes `export` would write, within a third or so. A short recording is
    /// encoded whole. A longer one is sampled: it's cut into equal parts, a second from the middle
    /// of each is encoded, and the bytes their changes take are scaled up to the whole length.
    /// That beats a formula, since the size depends on how much moves, not just on how long it
    /// is. The very start isn't sampled: it often changes more than the rest.
    static func estimate(video: URL, pointSize: CGSize, preset: GIFPreset) async throws -> Int {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw RecorderError.noFrames }
        let duration = try await asset.load(.duration).seconds
        let size = outputSize(for: pointSize, preset: preset)
        if duration <= 4 {
            return try encode(asset: asset, track: track, range: nil, duration: duration, size: size,
                              frameRate: preset.frameRate, progress: { _ in }).data.count
        }
        let window = 1.0, samples = min(6, max(3, Int(duration / 5)))
        var opening = 0, changes = 0
        for i in 0..<samples {
            try Task.checkCancellation()
            let start = duration * (Double(i) + 0.5) / Double(samples) - window / 2
            let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                    duration: CMTime(seconds: window, preferredTimescale: 600))
            let sample = try encode(asset: asset, track: track, range: range, duration: window, size: size,
                                    frameRate: preset.frameRate, progress: { _ in })
            // Every sample starts with a whole frame, but the GIF has only one.
            if i == 0 { opening = sample.openingBytes }
            changes += sample.data.count - sample.openingBytes
        }
        let step = 1 / preset.frameRate
        let perSecond = Double(changes) / (Double(samples) * (window - step))
        return opening + Int(perSecond * (duration - step))
    }

    /// The GIF of `range` (or all of the video), and how many bytes its header and first frame take.
    private static func encode(asset: AVAsset, track: AVAssetTrack, range: CMTimeRange?, duration: Double,
                               size: CGSize, frameRate: Double,
                               progress: (Double) -> Void) throws -> (data: Data, openingBytes: Int) {
        let width = Int(size.width), height = Int(size.height)

        // First pass: which colours appear.
        var histogram = GIFPalette.Histogram()
        try forEachFrame(of: asset, track: track, range: range, width: width, height: height, duration: duration,
                         frameRate: frameRate) { pixels, time in
            histogram.add(bgra: pixels, step: 2)
            progress(0.3 * time / max(duration, 0.001))
        }
        let palette = GIFPalette(histogram: histogram)

        // Second pass: encode.
        let encoder = GIFEncoder(width: width, height: height, palette: palette)
        var openingBytes = 0
        try forEachFrame(of: asset, track: track, range: range, width: width, height: height, duration: duration,
                         frameRate: frameRate) { pixels, time in
            encoder.add(bgra: pixels, at: time)
            if openingBytes == 0 { openingBytes = encoder.byteCount }
            progress(0.3 + 0.7 * time / max(duration, 0.001))
        }
        return (encoder.finish(at: duration), openingBytes)
    }

    /// Calls `body` with each frame of `range` (or all of the video) as seen at `frameRate`,
    /// scaled to width × height (BGRA, top row first). Times count from the start of the range.
    /// A frame that would repeat the one before is skipped.
    private static func forEachFrame(of asset: AVAsset, track: AVAssetTrack, range: CMTimeRange?, width: Int, height: Int,
                                     duration: Double, frameRate: Double,
                                     _ body: (UnsafeBufferPointer<UInt8>, Double) throws -> Void) throws {
        let reader = try AVAssetReader(asset: asset)
        if let range { reader.timeRange = range }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw RecorderError.writer(reader.error) }

        var scaled = [UInt8](repeating: 0, count: width * height * 4)
        let step = 1 / frameRate
        var tick = 0.0
        var held: CVPixelBuffer?
        var heldShown = false
        var start: CMTime?

        func showHeld(at time: Double) throws {
            guard !heldShown, let held else { return }
            heldShown = true
            try scale(held, into: &scaled, width: width, height: height)
            try scaled.withUnsafeBufferPointer { try body($0, time) }
        }

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = sample.presentationTimeStamp
            let time = (pts - (start ?? pts)).seconds
            if start == nil { start = pts }
            // The ticks before this frame show the one before it.
            while held != nil, tick < time - 1e-6 {
                try showHeld(at: tick)
                tick += step
            }
            held = buffer
            heldShown = false
        }
        if reader.status == .failed { throw RecorderError.writer(reader.error) }
        while held != nil, tick < max(duration, step) - 1e-6 {
            try showHeld(at: tick)
            tick += step
        }
    }

    private static func scale(_ buffer: CVPixelBuffer, into pixels: inout [UInt8], width: Int, height: Int) throws {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var source = vImage_Buffer(data: CVPixelBufferGetBaseAddress(buffer),
                                   height: vImagePixelCount(CVPixelBufferGetHeight(buffer)),
                                   width: vImagePixelCount(CVPixelBufferGetWidth(buffer)),
                                   rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        let error = pixels.withUnsafeMutableBytes { bytes in
            var destination = vImage_Buffer(data: bytes.baseAddress, height: vImagePixelCount(height),
                                            width: vImagePixelCount(width), rowBytes: width * 4)
            // Lanczos, which keeps small text readable when shrinking 2x frames.
            return vImageScale_ARGB8888(&source, &destination, nil, vImage_Flags(kvImageHighQualityResampling))
        }
        if error != kvImageNoError { throw RecorderError.writer(nil) }
    }
}

/// Up to 255 colours chosen by median cut (index 255 is transparent), and a table from each
/// 15-bit colour to its nearest palette entry.
struct GIFPalette {
    static let transparent: UInt8 = 255

    /// Pixel counts and colour sums per 15-bit colour, so each palette entry is the exact average
    /// of its pixels (pure white stays 255, 255, 255).
    struct Histogram {
        var count = [Int](repeating: 0, count: 1 << 15)
        var sum = [Int](repeating: 0, count: 3 << 15)

        mutating func add(bgra pixels: UnsafeBufferPointer<UInt8>, step: Int = 1) {
            count.withUnsafeMutableBufferPointer { count in
                sum.withUnsafeMutableBufferPointer { sum in
                    var i = 0
                    while i + 3 < pixels.count {
                        let b = Int(pixels[i]), g = Int(pixels[i + 1]), r = Int(pixels[i + 2])
                        let bin = GIFPalette.bin(r, g, b)
                        count[bin] += 1
                        sum[bin * 3] += r
                        sum[bin * 3 + 1] += g
                        sum[bin * 3 + 2] += b
                        i += 4 * step
                    }
                }
            }
        }
    }

    private(set) var red: [UInt8] = []
    private(set) var green: [UInt8] = []
    private(set) var blue: [UInt8] = []
    /// 15-bit colour → palette index.
    private(set) var lookup: [UInt8]

    @inline(__always)
    static func bin(_ r: Int, _ g: Int, _ b: Int) -> Int { (r >> 3) << 10 | (g >> 3) << 5 | b >> 3 }

    init(histogram: Histogram, maxColors: Int = 255) {
        // Each used bin as its average colour.
        struct Entry { var color: (Int, Int, Int); var count: Int }
        var entries: [Entry] = []
        for bin in 0..<(1 << 15) where histogram.count[bin] > 0 {
            let n = histogram.count[bin]
            entries.append(Entry(color: (histogram.sum[bin * 3] / n, histogram.sum[bin * 3 + 1] / n, histogram.sum[bin * 3 + 2] / n), count: n))
        }
        if entries.isEmpty { entries = [Entry(color: (0, 0, 0), count: 1)] }

        func channel(_ entry: Entry, _ c: Int) -> Int { c == 0 ? entry.color.0 : c == 1 ? entry.color.1 : entry.color.2 }
        struct Box {
            var entries: ArraySlice<Entry>
            var count = 0
            var channel = 0
            var range = 0
        }
        func makeBox(_ entries: ArraySlice<Entry>) -> Box {
            var box = Box(entries: entries)
            box.count = entries.reduce(0) { $0 + $1.count }
            box.range = -1
            for c in 0..<3 {
                var low = 255, high = 0
                for entry in entries {
                    let value = channel(entry, c)
                    low = min(low, value)
                    high = max(high, value)
                }
                if high - low > box.range { (box.channel, box.range) = (c, high - low) }
            }
            return box
        }

        // Median cut: keep splitting the box with the most pixels × widest colour range.
        var boxes = [makeBox(entries[...])]
        while boxes.count < maxColors {
            var bestIndex = -1, bestScore = 0.0
            for (index, box) in boxes.enumerated() where box.entries.count > 1 {
                let score = Double(box.count) * Double(box.range)
                if score > bestScore { (bestIndex, bestScore) = (index, score) }
            }
            guard bestIndex >= 0 else { break }
            let box = boxes[bestIndex]
            let sorted = box.entries.sorted { channel($0, box.channel) < channel($1, box.channel) }
            var running = 0, cut = 1
            for (i, entry) in sorted.enumerated() {
                running += entry.count
                if running * 2 >= box.count { cut = min(max(i + 1, 1), sorted.count - 1); break }
            }
            boxes[bestIndex] = makeBox(sorted[0..<cut])
            boxes.append(makeBox(sorted[cut...]))
        }
        for box in boxes {
            let total = max(box.count, 1)
            red.append(UInt8(box.entries.reduce(0) { $0 + $1.color.0 * $1.count } / total))
            green.append(UInt8(box.entries.reduce(0) { $0 + $1.color.1 * $1.count } / total))
            blue.append(UInt8(box.entries.reduce(0) { $0 + $1.color.2 * $1.count } / total))
        }

        lookup = [UInt8](repeating: 0, count: 1 << 15)
        for bin in 0..<(1 << 15) {
            let n = histogram.count[bin]
            let (r, g, b) = n > 0
                ? (histogram.sum[bin * 3] / n, histogram.sum[bin * 3 + 1] / n, histogram.sum[bin * 3 + 2] / n)
                : ((bin >> 10) << 3 | 4, ((bin >> 5) & 31) << 3 | 4, (bin & 31) << 3 | 4)
            var best = 0, bestDistance = Int.max
            for i in red.indices {
                let dr = r - Int(red[i]), dg = g - Int(green[i]), db = b - Int(blue[i])
                let distance = 3 * dr * dr + 4 * dg * dg + 2 * db * db
                if distance < bestDistance { (best, bestDistance) = (i, distance) }
            }
            lookup[bin] = UInt8(best)
        }
    }
}

/// Writes an animated GIF one frame at a time. Every frame after the first stores only the
/// rectangle that changed, with unchanged pixels inside it transparent, and is drawn over the
/// frames before it.
final class GIFEncoder {
    /// How far (per channel, 0–255) a pixel may drift and still count as unchanged. Hides video
    /// compression noise, which would otherwise rewrite the whole frame at every key frame.
    static let tolerance = 5

    let width: Int
    let height: Int
    private let palette: GIFPalette
    private var data = Data()
    /// The palette index each pixel shows so far.
    private var shown: [UInt8]
    private var hasFrame = false
    private var indices: [UInt8]
    private var pending: (body: Data, start: Double)?
    private let lzw = LZWEncoder()

    init(width: Int, height: Int, palette: GIFPalette) {
        self.width = width
        self.height = height
        self.palette = palette
        shown = [UInt8](repeating: GIFPalette.transparent, count: width * height)
        indices = [UInt8](repeating: GIFPalette.transparent, count: width * height)

        data.append(contentsOf: Array("GIF89a".utf8))
        appendUInt16(width)
        appendUInt16(height)
        data.append(contentsOf: [0xF7, 0, 0]) // 256-colour global table, background 0, square pixels
        for i in 0..<256 {
            if i < palette.red.count {
                data.append(contentsOf: [palette.red[i], palette.green[i], palette.blue[i]])
            } else {
                data.append(contentsOf: [0, 0, 0])
            }
        }
        // Loop forever.
        data.append(contentsOf: [0x21, 0xFF, 0x0B])
        data.append(contentsOf: Array("NETSCAPE2.0".utf8))
        data.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00])
    }

    /// `pixels` is width × height BGRA, top row first, shown from `time` seconds on.
    func add(bgra pixels: UnsafeBufferPointer<UInt8>, at time: Double) {
        var minX = width, minY = height, maxX = -1, maxY = -1
        let first = !hasFrame
        let tolerance = Self.tolerance
        palette.red.withUnsafeBufferPointer { red in
        palette.green.withUnsafeBufferPointer { green in
        palette.blue.withUnsafeBufferPointer { blue in
        palette.lookup.withUnsafeBufferPointer { lookup in
        shown.withUnsafeMutableBufferPointer { shown in
        indices.withUnsafeMutableBufferPointer { indices in
            for y in 0..<height {
                for x in 0..<width {
                    let i = y * width + x, p = i * 4
                    let b = Int(pixels[p]), g = Int(pixels[p + 1]), r = Int(pixels[p + 2])
                    if !first {
                        let s = Int(shown[i])
                        if abs(r - Int(red[s])) <= tolerance, abs(g - Int(green[s])) <= tolerance, abs(b - Int(blue[s])) <= tolerance {
                            indices[i] = GIFPalette.transparent
                            continue
                        }
                    }
                    let index = lookup[GIFPalette.bin(r, g, b)]
                    if !first, index == shown[i] {
                        indices[i] = GIFPalette.transparent
                        continue
                    }
                    indices[i] = index
                    shown[i] = index
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }}}}}}
        guard maxX >= 0 else { return } // nothing changed: the frame before stays up longer
        hasFrame = true
        flushPending(until: time)

        let w = maxX - minX + 1, h = maxY - minY + 1
        var region = [UInt8](repeating: 0, count: w * h)
        for row in 0..<h {
            let from = (minY + row) * width + minX
            region.replaceSubrange(row * w..<(row + 1) * w, with: indices[from..<from + w])
        }
        var body = Data([0x2C])
        body.append(uint16: minX)
        body.append(uint16: minY)
        body.append(uint16: w)
        body.append(uint16: h)
        body.append(0) // no local colour table, not interlaced
        region.withUnsafeBufferPointer { lzw.encode($0, into: &body) }
        pending = (body, time)
    }

    /// The bytes written so far, the frame waiting for its delay included.
    var byteCount: Int {
        data.count + (pending.map { $0.body.count + 8 } ?? 0)
    }

    /// Ends the GIF; the last frame lasts until `time`.
    func finish(at time: Double) -> Data {
        flushPending(until: time)
        data.append(0x3B)
        return data
    }

    private func flushPending(until end: Double) {
        guard let pending else { return }
        self.pending = nil
        // Delays are in hundredths of a second; rounding both ends keeps the total in step.
        let delay = min(max(Int((end * 100).rounded()) - Int((pending.start * 100).rounded()), 2), 65535)
        // Graphic control: leave the frame in place, use the transparent index.
        data.append(contentsOf: [0x21, 0xF9, 0x04, 0x05])
        appendUInt16(delay)
        data.append(contentsOf: [GIFPalette.transparent, 0x00])
        data.append(pending.body)
    }

    private func appendUInt16(_ value: Int) {
        data.append(uint16: value)
    }
}

/// GIF's variable-width LZW, 8-bit codes.
final class LZWEncoder {
    private static let minCodeSize = 8
    private static let clearCode = 1 << minCodeSize
    /// children[code << 8 | byte] is the code for that string plus byte, or 0.
    private var children = [UInt16](repeating: 0, count: 4096 << 8)
    private var used: [Int] = []

    func encode(_ input: UnsafeBufferPointer<UInt8>, into out: inout Data) {
        let clear = Self.clearCode, end = clear + 1
        var codeSize = Self.minCodeSize + 1
        var maxCode = end
        var bits = BitWriter()
        out.append(UInt8(Self.minCodeSize))
        bits.write(clear, size: codeSize)

        children.withUnsafeMutableBufferPointer { children in
            var current = -1
            for value in input {
                let byte = Int(value)
                if current < 0 {
                    current = byte
                    continue
                }
                let key = current << 8 | byte
                let child = Int(children[key])
                if child != 0 {
                    current = child
                    continue
                }
                bits.write(current, size: codeSize)
                maxCode += 1
                children[key] = UInt16(maxCode)
                used.append(key)
                if maxCode >= 1 << codeSize { codeSize += 1 }
                if maxCode == 4095 {
                    bits.write(clear, size: codeSize)
                    for key in used { children[key] = 0 }
                    used.removeAll(keepingCapacity: true)
                    codeSize = Self.minCodeSize + 1
                    maxCode = end
                }
                current = byte
            }
            if current >= 0 { bits.write(current, size: codeSize) }
            for key in used { children[key] = 0 }
            used.removeAll(keepingCapacity: true)
        }
        bits.write(clear, size: codeSize)
        bits.write(end, size: Self.minCodeSize + 1)
        bits.flush()

        // Sub-blocks of at most 255 bytes, then an empty one.
        var offset = 0
        while offset < bits.bytes.count {
            let count = min(255, bits.bytes.count - offset)
            out.append(UInt8(count))
            out.append(contentsOf: bits.bytes[offset..<offset + count])
            offset += count
        }
        out.append(0)
    }

    private struct BitWriter {
        var bytes: [UInt8] = []
        private var buffer: UInt32 = 0
        private var count = 0

        mutating func write(_ code: Int, size: Int) {
            buffer |= UInt32(code) << count
            count += size
            while count >= 8 {
                bytes.append(UInt8(buffer & 0xFF))
                buffer >>= 8
                count -= 8
            }
        }

        mutating func flush() {
            if count > 0 { bytes.append(UInt8(buffer & 0xFF)) }
            buffer = 0
            count = 0
        }
    }
}

private extension Data {
    mutating func append(uint16 value: Int) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }
}
