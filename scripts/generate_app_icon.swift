import AppKit
import Foundation

let sourceURL = URL(fileURLWithPath: "scripts/assets/run-shelf-app-icon-source.png")
let iconDirectory = URL(fileURLWithPath: "RunShelf/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

guard let sourceImage = NSImage(contentsOf: sourceURL) else {
    fatalError("Unable to load app icon source at \(sourceURL.path)")
}

try FileManager.default.createDirectory(at: iconDirectory, withIntermediateDirectories: true)

let outputs: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, pixels) in outputs {
    let bitmap = renderIcon(from: sourceImage, size: pixels)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Unable to render \(filename)")
    }
    try png.write(to: iconDirectory.appendingPathComponent(filename))
}

func renderIcon(from sourceImage: NSImage, size: CGFloat) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size),
        pixelsHigh: Int(size),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    bitmap.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    guard let context = NSGraphicsContext.current?.cgContext else {
        fatalError("Unable to create graphics context")
    }

    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    context.clear(canvas)
    context.interpolationQuality = .high

    NSBezierPath(roundedRect: canvas, xRadius: size * 0.22, yRadius: size * 0.22).addClip()
    sourceImage.draw(in: canvas, from: NSRect(origin: .zero, size: sourceImage.size), operation: .sourceOver, fraction: 1)

    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}
