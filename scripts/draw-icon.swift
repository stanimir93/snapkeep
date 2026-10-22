import AppKit

// A blue rounded square with a white viewfinder, at 1024×1024.
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

// macOS icons leave a margin around the rounded square.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.62, blue: 1.00, alpha: 1),
           ending: NSColor(srgbRed: 0.10, green: 0.30, blue: 0.85, alpha: 1))!
    .draw(in: shape, angle: -90)

let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .regular)
    .applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let symbolSize = symbol.size
    symbol.draw(in: NSRect(x: (CGFloat(size) - symbolSize.width) / 2, y: (CGFloat(size) - symbolSize.height) / 2,
                           width: symbolSize.width, height: symbolSize.height))
}

let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: output)
