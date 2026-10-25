// Draws the TempMonitor app icon and writes Icon/AppIcon.icns.
// Run from the repo root: swift Icon/make_icon.swift
import AppKit

let canvas: CGFloat = 1024

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func draw() {
    // Rounded-square body on Apple's 1024 grid (824pt body, 100pt margin).
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 24
    shadow.set()
    NSColor.black.setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Cool-to-hot background: deep blue at the top, warm orange at the bottom.
    NSGradient(colors: [
        NSColor(srgbRed: 0.98, green: 0.45, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.80, green: 0.22, blue: 0.42, alpha: 1),
        NSColor(srgbRed: 0.16, green: 0.20, blue: 0.52, alpha: 1),
    ])!.draw(in: squircle, angle: 90)

    // Thermometer outline (white glass).
    let cx: CGFloat = 470, bulbY: CGFloat = 330
    let glass = NSBezierPath(ovalIn: NSRect(x: cx - 125, y: bulbY - 125, width: 250, height: 250))
    glass.append(NSBezierPath(roundedRect: NSRect(x: cx - 75, y: bulbY, width: 150, height: 480),
                              xRadius: 75, yRadius: 75))
    NSColor.white.setFill()
    glass.fill()

    // Empty tube inside the glass.
    let track = NSBezierPath(roundedRect: NSRect(x: cx - 38, y: bulbY, width: 76, height: 442),
                             xRadius: 38, yRadius: 38)
    NSColor(srgbRed: 0.88, green: 0.89, blue: 0.94, alpha: 1).setFill()
    track.fill()

    // Mercury: bulb plus column filled about two thirds of the way.
    let mercury = NSBezierPath(ovalIn: NSRect(x: cx - 88, y: bulbY - 88, width: 176, height: 176))
    mercury.append(NSBezierPath(roundedRect: NSRect(x: cx - 38, y: bulbY, width: 76, height: 330),
                                xRadius: 38, yRadius: 38))
    NSGradient(colors: [
        NSColor(srgbRed: 0.93, green: 0.16, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.55, blue: 0.18, alpha: 1),
    ])!.draw(in: mercury, angle: 90)

    // Scale ticks to the right of the tube.
    NSColor.white.withAlphaComponent(0.9).setFill()
    for i in 0..<5 {
        let y = 500 + CGFloat(i) * 70
        let w: CGFloat = i % 2 == 0 ? 120 : 75
        NSBezierPath(roundedRect: NSRect(x: cx + 115, y: y - 14, width: w, height: 28),
                     xRadius: 14, yRadius: 14).fill()
    }
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: "Icon/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Icon/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
try? fm.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "Wrote Icon/AppIcon.icns" : "iconutil failed")
