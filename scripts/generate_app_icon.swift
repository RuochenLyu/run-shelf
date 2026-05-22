import AppKit
import Foundation

let iconDirectory = URL(fileURLWithPath: "RunShelf/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
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
    let bitmap = drawIcon(size: pixels)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Unable to render \(filename)")
    }
    try png.write(to: iconDirectory.appendingPathComponent(filename))
}

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
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

    let scale = size / 1024
    func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
        NSRect(x: x * scale, y: y * scale, width: width * scale, height: height * scale)
    }
    func radius(_ value: CGFloat) -> CGFloat { value * scale }

    NSColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect(64, 64, 896, 896), xRadius: radius(190), yRadius: radius(190)).fill()

    NSColor(red: 0.14, green: 0.16, blue: 0.19, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect(150, 164, 724, 696), xRadius: radius(68), yRadius: radius(68)).fill()

    NSColor(red: 0.20, green: 0.71, blue: 0.39, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect(220, 698, 584, 70), xRadius: radius(35), yRadius: radius(35)).fill()

    NSColor(red: 0.94, green: 0.97, blue: 0.94, alpha: 1).setFill()
    let play = NSBezierPath()
    play.move(to: NSPoint(x: 422 * scale, y: 360 * scale))
    play.line(to: NSPoint(x: 422 * scale, y: 608 * scale))
    play.line(to: NSPoint(x: 638 * scale, y: 484 * scale))
    play.close()
    play.fill()

    NSColor(red: 0.60, green: 0.66, blue: 0.70, alpha: 1).setStroke()
    let prompt = NSBezierPath()
    prompt.lineWidth = max(8 * scale, 1)
    prompt.move(to: NSPoint(x: 248 * scale, y: 284 * scale))
    prompt.line(to: NSPoint(x: 334 * scale, y: 332 * scale))
    prompt.line(to: NSPoint(x: 248 * scale, y: 380 * scale))
    prompt.stroke()

    NSBezierPath(roundedRect: rect(378, 284, 248, 24), xRadius: radius(12), yRadius: radius(12)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}
