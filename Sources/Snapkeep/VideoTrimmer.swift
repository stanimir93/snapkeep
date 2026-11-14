import AVFoundation

/// Cuts a recording down to one part of it, to drop an unwanted start or end.
enum VideoTrimmer {
    /// Writes the part of `video` inside `range` to `url` as a new H.264 MP4 and returns its
    /// duration. It re-encodes rather than copying, so the cut lands on the exact frame and the
    /// file plays the same everywhere, not only in players that honour MP4 edit lists.
    static func trim(video: URL, range: CMTimeRange, to url: URL) async throws -> Double {
        let asset = AVURLAsset(url: video)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw RecorderError.writer(nil)
        }
        session.timeRange = range
        try? FileManager.default.removeItem(at: url)
        if #available(macOS 15, *) {
            try await session.export(to: url, as: .mp4)
        } else {
            session.outputURL = url
            session.outputFileType = .mp4
            await session.export()
            guard session.status == .completed else { throw RecorderError.writer(session.error) }
        }
        return try await AVURLAsset(url: url).load(.duration).seconds
    }
}
