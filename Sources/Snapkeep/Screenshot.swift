import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A screenshot file loaded into memory.
struct Screenshot {
    let url: URL
    /// The file's bytes, so an unedited screenshot can be copied without re-encoding.
    let pngData: Data
    let cgImage: CGImage
    /// Size in points (pixels at 144 dpi are half as many points), used to size the preview.
    let pointSize: CGSize

    var pixelSize: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }

    static func load(_ url: URL) -> Screenshot? {
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
        let scale = dpi / 72
        return Screenshot(
            url: url,
            pngData: data,
            cgImage: image,
            pointSize: CGSize(width: Double(image.width) / scale, height: Double(image.height) / scale)
        )
    }
}

/// Flattens drawings onto a screenshot at its full pixel resolution.
enum Renderer {
    static func pngData(base: CGImage, pointSize: CGSize, annotations: [Annotation]) -> Data? {
        let width = base.width, height = base.height
        var space = base.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if space.model != .rgb { space = CGColorSpace(name: CGColorSpace.sRGB)! }
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        annotations.forEach { $0.draw() }
        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage() else { return nil }
        return encodePNG(image, pointSize: pointSize)
    }

    /// Encodes with the screenshot's dpi so pasted images keep their on-screen size.
    static func encodePNG(_ image: CGImage, pointSize: CGSize) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        let dpi = 72 * Double(image.width) / max(Double(pointSize.width), 1)
        let properties = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
