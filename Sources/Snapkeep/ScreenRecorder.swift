import AppKit
import AVFoundation
import ScreenCaptureKit

/// A finished recording, still in a temporary file until the user keeps it.
struct Recording {
    let url: URL
    /// The recorded area in points, used to size the preview and the GIF.
    let pointSize: CGSize
    let pixelSize: CGSize
    let duration: TimeInterval
}

enum RecorderError: LocalizedError {
    case displayNotFound
    case noFrames
    case writer(Error?)

    var errorDescription: String? {
        switch self {
        case .displayNotFound: "The display is no longer connected."
        case .noFrames: "Nothing was recorded."
        case let .writer(error): error?.localizedDescription ?? "The video couldn't be written."
        }
    }
}

/// Records one area of a display to an MP4 file, leaving out Snapkeep's own windows.
/// ScreenCaptureKit only delivers a frame when something on screen changes, so a still screen
/// costs almost nothing.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let frameRate = 60
    /// H.264 encoders top out around 4K, so larger areas are scaled down to fit.
    static let maxPixels = (long: 3840.0, short: 2160.0)

    let url: URL
    let pointSize: CGSize
    let pixelSize: CGSize
    /// Called on the main thread when the stream ends without stop(), for example from the
    /// screen sharing item in the menu bar.
    var onInterrupted: (@MainActor () -> Void)?

    private let screen: NSScreen
    private let rect: CGRect
    private let queue = DispatchQueue(label: "Snapkeep.ScreenRecorder")
    private var stream: SCStream?
    private var isStopped = false
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    // Touched only on `queue`.
    private var firstFrame: CMTime?
    private var firstFrameHostTime: CFTimeInterval = 0
    private var lastFrame = CMTime.zero

    /// `rect` is in the screen's points, origin at its bottom-left.
    @MainActor
    init(screen: NSScreen, rect: CGRect, url: URL) throws {
        self.screen = screen
        self.rect = rect
        self.url = url
        pointSize = rect.size
        let scale = screen.backingScaleFactor
        pixelSize = Self.evenSize(fitting(CGSize(width: rect.width * scale, height: rect.height * scale),
                                          long: Self.maxPixels.long, short: Self.maxPixels.short))
        (writer, input) = try Self.makeWriter(url: url, pixelSize: pixelSize)
        super.init()
    }

    @MainActor
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else {
            throw RecorderError.displayNotFound
        }
        let ownApps = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        // sourceRect starts at the display's top-left.
        config.sourceRect = CGRect(x: rect.minX, y: screen.frame.height - rect.maxY, width: rect.width, height: rect.height)
        config.width = Int(pixelSize.width)
        config.height = Int(pixelSize.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.frameRate))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.queueDepth = 6

        guard writer.startWriting() else { throw RecorderError.writer(writer.error) }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        // stop() came while the stream was starting.
        if isStopped {
            try? await stream.stopCapture()
            return
        }
        self.stream = stream
    }

    /// Stops and finishes the file. The video lasts until the moment stop() was called, even if
    /// the screen didn't change at the end.
    @MainActor
    func stop() async throws -> Recording {
        let stopHostTime = CACurrentMediaTime()
        isStopped = true
        let stream = self.stream
        self.stream = nil
        try? await stream?.stopCapture()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let firstFrame else {
                    writer.cancelWriting()
                    continuation.resume(throwing: RecorderError.noFrames)
                    return
                }
                let elapsed = CMTime(seconds: max(stopHostTime - firstFrameHostTime, 0), preferredTimescale: 600)
                let oneFrame = CMTime(value: 1, timescale: CMTimeScale(Self.frameRate))
                let end = CMTimeMaximum(firstFrame + elapsed, lastFrame + oneFrame)
                input.markAsFinished()
                writer.endSession(atSourceTime: end)
                writer.finishWriting { [self] in
                    guard writer.status == .completed else {
                        continuation.resume(throwing: RecorderError.writer(writer.error))
                        return
                    }
                    continuation.resume(returning: Recording(url: url, pointSize: pointSize, pixelSize: pixelSize,
                                                             duration: (end - firstFrame).seconds))
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = (attachments.first?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)),
              status == .complete, writer.status == .writing
        else { return }
        let time = sampleBuffer.presentationTimeStamp
        if firstFrame == nil {
            writer.startSession(atSourceTime: time)
            firstFrame = time
            firstFrameHostTime = CACurrentMediaTime()
        }
        guard input.isReadyForMoreMediaData, time > lastFrame else { return }
        if input.append(sampleBuffer) { lastFrame = time }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Snapkeep recording stopped: %@", String(describing: error))
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                guard self.stream != nil else { return }
                onInterrupted?()
            }
        }
    }

    // MARK: Writing

    /// An H.264 MP4 writer, tagged sRGB-like (BT.709) so colours match the screen.
    static func makeWriter(url: URL, pixelSize: CGSize) throws -> (AVAssetWriter, AVAssetWriterInput) {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let pixels = pixelSize.width * pixelSize.height
        // Screen content is mostly still, so the encoder rarely needs the full rate.
        let bitRate = min(max(pixels * 4, 2_000_000), 30_000_000)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(pixelSize.width),
            AVVideoHeightKey: Int(pixelSize.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(bitRate),
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: 4,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.writer(writer.error) }
        writer.add(input)
        writer.shouldOptimizeForNetworkUse = true
        return (writer, input)
    }

    /// 4:2:0 video needs even dimensions.
    static func evenSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(2, (size.width / 2).rounded() * 2), height: max(2, (size.height / 2).rounded() * 2))
    }
}

/// Scales `size` down, keeping its shape, so its longer side is at most `long` and its shorter
/// side at most `short`. Never scales up.
func fitting(_ size: CGSize, long: CGFloat, short: CGFloat) -> CGSize {
    let longer = max(size.width, size.height), shorter = min(size.width, size.height)
    let scale = min(1, long / max(longer, 1), short / max(shorter, 1))
    return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
}
