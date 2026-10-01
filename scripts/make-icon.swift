// Draws the app icon and writes AppIcon.iconset/ (run by make-app.sh).
// Usage: swift scripts/make-icon.swift <output-dir>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
    .appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: outDir)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024 // design on a 1024 grid

    // macOS icon tile: inset square with continuous-looking corners.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 20 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSColor.black.setFill()
    tilePath.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(colors: [
        NSColor(srgbRed: 0.27, green: 0.31, blue: 0.86, alpha: 1), // indigo (top)
        NSColor(srgbRed: 0.09, green: 0.66, blue: 0.70, alpha: 1), // teal (bottom)
    ])!.draw(in: tilePath, angle: -90)

    // Speech bubble.
    let bubble = NSBezierPath(roundedRect: NSRect(x: 230 * s, y: 330 * s, width: 564 * s, height: 430 * s),
                              xRadius: 120 * s, yRadius: 120 * s)
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: 330 * s, y: 360 * s))
    tail.line(to: NSPoint(x: 270 * s, y: 240 * s))
    tail.line(to: NSPoint(x: 440 * s, y: 340 * s))
    tail.close()
    NSColor.white.setFill()
    bubble.fill()
    tail.fill()

    // Threads: one trunk branching into three sorted lines.
    let ink = NSColor(srgbRed: 0.20, green: 0.32, blue: 0.80, alpha: 1)
    let dots: [(CGFloat, NSColor)] = [
        (650, NSColor(srgbRed: 0.27, green: 0.31, blue: 0.86, alpha: 1)),
        (545, NSColor(srgbRed: 0.18, green: 0.50, blue: 0.80, alpha: 1)),
        (440, NSColor(srgbRed: 0.09, green: 0.66, blue: 0.70, alpha: 1)),
    ]
    let trunkX = 330 * s
    let trunk = NSBezierPath()
    trunk.lineWidth = 22 * s
    trunk.lineCapStyle = .round
    trunk.move(to: NSPoint(x: trunkX, y: 650 * s))
    trunk.line(to: NSPoint(x: trunkX, y: 440 * s))
    ink.setStroke()
    trunk.stroke()
    for (y, color) in dots {
        let branch = NSBezierPath()
        branch.lineWidth = 22 * s
        branch.lineCapStyle = .round
        branch.move(to: NSPoint(x: trunkX, y: y * s))
        branch.line(to: NSPoint(x: 400 * s, y: y * s))
        ink.setStroke()
        branch.stroke()
        let line = NSBezierPath(roundedRect: NSRect(x: 430 * s, y: (y - 22) * s, width: 280 * s, height: 44 * s),
                                xRadius: 22 * s, yRadius: 22 * s)
        color.setFill()
        line.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = drawIcon(size: px).representation(using: .png, properties: [:])!
        try data.write(to: outDir.appendingPathComponent(name))
    }
}
print("Wrote \(outDir.path)")
