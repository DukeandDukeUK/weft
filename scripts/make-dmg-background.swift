// Draws the disk-image window background: "Drag Weft to Applications" with
// an arrow between the two icon spots. Writes a 1x and a 2x PNG.
// Usage: swift scripts/make-dmg-background.swift <output-dir>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Window content size in points; icon centers must match dmg-settings.py.
let width: CGFloat = 600, height: CGFloat = 400
let leftIconX: CGFloat = 160, rightIconX: CGFloat = 440, iconY: CGFloat = 190 // from top

func draw(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: width, height: height) // so 2x is tagged as Retina
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Soft background in the icon's colors.
    NSGradient(colors: [
        NSColor(srgbRed: 0.95, green: 0.96, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.90, green: 0.97, blue: 0.97, alpha: 1),
    ])!.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

    // Title.
    let title = "Drag Weft to Applications"
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
        .foregroundColor: NSColor(srgbRed: 0.16, green: 0.20, blue: 0.40, alpha: 1),
    ]
    let titleSize = title.size(withAttributes: titleAttrs)
    title.draw(at: NSPoint(x: (width - titleSize.width) / 2, y: height - 70), withAttributes: titleAttrs)

    // Arrow between the two icons (AppKit's y axis runs bottom-up).
    let y = height - iconY
    let ink = NSColor(srgbRed: 0.20, green: 0.32, blue: 0.80, alpha: 0.85)
    let shaft = NSBezierPath()
    shaft.lineWidth = 6
    shaft.lineCapStyle = .round
    shaft.move(to: NSPoint(x: leftIconX + 85, y: y))
    shaft.line(to: NSPoint(x: rightIconX - 95, y: y))
    ink.setStroke()
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: rightIconX - 75, y: y))
    head.line(to: NSPoint(x: rightIconX - 100, y: y + 16))
    head.line(to: NSPoint(x: rightIconX - 100, y: y - 16))
    head.close()
    ink.setFill()
    head.fill()

    // Footer hint.
    let hint = "Then open Weft from your Applications folder."
    let hintAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13),
        .foregroundColor: NSColor(srgbRed: 0.30, green: 0.34, blue: 0.45, alpha: 1),
    ]
    let hintSize = hint.size(withAttributes: hintAttrs)
    hint.draw(at: NSPoint(x: (width - hintSize.width) / 2, y: 50), withAttributes: hintAttrs)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try draw(scale: 1).write(to: outDir.appendingPathComponent("dmg-background.png"))
try draw(scale: 2).write(to: outDir.appendingPathComponent("dmg-background@2x.png"))
print("Wrote backgrounds to \(outDir.path)")
