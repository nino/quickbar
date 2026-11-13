// Draws Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // Apple's icon grid: an 824 pt rounded square centred in 1024.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.42, blue: 1.0, alpha: 1),
                        NSColor(srgbRed: 0.16, green: 0.14, blue: 0.62, alpha: 1)])!.draw(in: shape, angle: -90)

    // The bar.
    let bar = NSRect(x: 190 * s, y: 430 * s, width: 644 * s, height: 164 * s)
    NSColor.white.withAlphaComponent(0.96).setFill()
    NSBezierPath(roundedRect: bar, xRadius: 50 * s, yRadius: 50 * s).fill()

    // Magnifier and a text cursor inside it.
    let ink = NSColor(srgbRed: 0.18, green: 0.17, blue: 0.62, alpha: 1)
    ink.setStroke()
    let glass = NSBezierPath(ovalIn: NSRect(x: 236 * s, y: 482 * s, width: 68 * s, height: 68 * s))
    glass.lineWidth = 17 * s
    glass.stroke()
    let handle = NSBezierPath()
    handle.move(to: NSPoint(x: 296 * s, y: 490 * s))
    handle.line(to: NSPoint(x: 326 * s, y: 460 * s))
    handle.lineWidth = 17 * s
    handle.lineCapStyle = .round
    handle.stroke()
    ink.withAlphaComponent(0.85).setFill()
    NSBezierPath(roundedRect: NSRect(x: 372 * s, y: 468 * s, width: 13 * s, height: 88 * s), xRadius: 6 * s, yRadius: 6 * s).fill()

    // Result rows fading out below.
    for (i, alpha) in [0.34, 0.2].enumerated() {
        NSColor.white.withAlphaComponent(alpha).setFill()
        let row = NSRect(x: 190 * s, y: (318 - CGFloat(i) * 96) * s, width: (500 - CGFloat(i) * 110) * s, height: 62 * s)
        NSBezierPath(roundedRect: row, xRadius: 26 * s, yRadius: 26 * s).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let set = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: set)
try fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try draw(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
