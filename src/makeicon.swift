import AppKit

// Renders the OpenPuck Flasher app icon: a graphite "puck" disc with an amber
// lightning bolt, on a deep-indigo rounded square. Bold, high-contrast shapes
// so it still reads at 16px. Emits AppIcon.icns next to this binary (build/).

func drawIcon(px: CGFloat) {
    let rect  = NSRect(x: 0, y: 0, width: px, height: px)
    let inset = px * 0.08
    let body  = rect.insetBy(dx: inset, dy: inset)
    let bg    = NSBezierPath(roundedRect: body, xRadius: px * 0.2, yRadius: px * 0.2)

    // Deep-indigo gradient background.
    NSGradient(colors: [
        NSColor(srgbRed: 0.18, green: 0.20, blue: 0.42, alpha: 1),
        NSColor(srgbRed: 0.06, green: 0.07, blue: 0.18, alpha: 1),
    ])!.draw(in: bg, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    bg.setClip()

    // Puck disc — light rim ring around a graphite face, centered slightly low.
    let r  = px * 0.30
    let cx = px * 0.5, cy = px * 0.46
    NSColor(srgbRed: 0.86, green: 0.89, blue: 0.96, alpha: 1).setFill()           // rim
    NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)).fill()
    let ri = r * 0.86
    NSColor(srgbRed: 0.17, green: 0.19, blue: 0.27, alpha: 1).setFill()           // face
    NSBezierPath(ovalIn: NSRect(x: cx - ri, y: cy - ri, width: ri * 2, height: ri * 2)).fill()

    // Lightning bolt (Material "flash_on" outline) centered over the puck.
    // Source points are y-down on a 24-grid; map into a box centered at (bx,by)
    // and flip to the bitmap's y-up space.
    let bolt: [(CGFloat, CGFloat)] = [
        (7, 2), (7, 13), (10, 13), (10, 22), (17, 10), (13, 10), (17, 2),
    ]
    let bw = px * 0.52, bh = px * 0.52
    let bx = px * 0.5,  by = px * 0.47
    let p = NSBezierPath()
    for (i, pt) in bolt.enumerated() {
        let X = bx + (pt.0 / 24.0 - 0.5) * bw
        let Y = by + (0.5 - pt.1 / 24.0) * bh
        if i == 0 { p.move(to: NSPoint(x: X, y: Y)) } else { p.line(to: NSPoint(x: X, y: Y)) }
    }
    p.close()
    NSColor(srgbRed: 1.0, green: 0.78, blue: 0.22, alpha: 1).setFill()            // amber bolt
    p.fill()

    NSGraphicsContext.restoreGraphicsState()
}

let sizes  = [16, 32, 64, 128, 256, 512, 1024]
let script = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let dir    = script.deletingLastPathComponent()
let iset   = dir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iset, withIntermediateDirectories: true)

for sz in sizes {
    for scale in [1, 2] {
        let px = sz * scale
        guard let bmp = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { continue }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bmp)
        drawIcon(px: CGFloat(px))
        NSGraphicsContext.current = nil
        let name = scale == 1 ? "icon_\(sz)x\(sz).png" : "icon_\(sz)x\(sz)@2x.png"
        try? bmp.representation(using: .png, properties: [:])?
            .write(to: iset.appendingPathComponent(name))
    }
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", "-o",
                  dir.appendingPathComponent("AppIcon.icns").path, iset.path]
try? task.run(); task.waitUntilExit()
try? FileManager.default.removeItem(at: iset)
print("AppIcon.icns generated")
