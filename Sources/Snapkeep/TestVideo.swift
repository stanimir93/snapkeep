import AppKit
import AVFoundation

/// A synthetic screen recording for the self-tests and `--render-recording`: white with a line
/// of text, a blue square moving for the first half, then nothing changing, so there are no
/// frames for the second half, as with ScreenCaptureKit.
enum TestVideo {
    /// Returns the video's duration.
    static func write(to url: URL, pixelSize: CGSize, seconds: Double) async throws -> Double {
        let (writer, input) = try ScreenRecorder.makeWriter(url: url, pixelSize: pixelSize)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(pixelSize.width),
            kCVPixelBufferHeightKey as String: Int(pixelSize.height),
        ])
        guard writer.startWriting() else { throw RecorderError.writer(writer.error) }
        writer.startSession(atSourceTime: .zero)

        let fps = 30, moving = Int(seconds * Double(fps) / 2)
        for frame in 0..<moving {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { throw RecorderError.writer(writer.error) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw RecorderError.writer(nil) }
            draw(into: buffer, size: pixelSize, progress: Double(frame) / Double(max(moving - 1, 1)))
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else { throw RecorderError.writer(writer.error) }
        return seconds
    }

    private static func draw(into buffer: CVPixelBuffer, size: CGSize, progress: Double) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let side = size.height * 0.25
        context.setFillColor(CGColor(red: 0.1, green: 0.35, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: (size.width - side) * progress, y: size.height * 0.1, width: side, height: side))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(string: "Snapkeep records", attributes: [
            .font: NSFont.systemFont(ofSize: size.height * 0.1, weight: .semibold), .foregroundColor: NSColor.black,
        ]).draw(at: CGPoint(x: size.width * 0.08, y: size.height * 0.65))
        NSGraphicsContext.restoreGraphicsState()
    }
}
