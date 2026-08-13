// Renders AppIcon.icns for SpeedyFan: macOS squircle, cool blue gradient,
// white fan glyph (the same SF Symbol the menu bar uses).
// Run: swift tools/make-icon.swift  (from the repo root)

import AppKit

let master: CGFloat = 1024

func makeRep(_ pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    return rep
}

func drawMaster() -> NSBitmapImageRep {
    let rep = makeRep(Int(master))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // Apple's icon grid: the squircle occupies ~824pt of the 1024pt canvas,
    // corner radius ~22.5% of its width.
    let inset: CGFloat = 100
    let rect = NSRect(x: inset, y: inset, width: master - 2 * inset, height: master - 2 * inset)
    let squircle = NSBezierPath(
        roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    // Drop shadow behind the squircle.
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 24
    shadow.set()
    NSColor.black.setFill()
    squircle.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Cool-air gradient: light cyan down to deep blue.
    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.28, green: 0.78, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.42, blue: 0.90, alpha: 1),
        NSColor(calibratedRed: 0.03, green: 0.20, blue: 0.60, alpha: 1),
    ])!.draw(in: rect, angle: -90)

    // Subtle highlight arc across the top half.
    let highlight = NSBezierPath(
        ovalIn: NSRect(x: rect.minX - rect.width * 0.25, y: rect.midY,
                       width: rect.width * 1.5, height: rect.height * 0.9))
    NSColor.white.withAlphaComponent(0.08).setFill()
    highlight.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // White fan glyph, slightly shadowed for depth.
    let config = NSImage.SymbolConfiguration(pointSize: 560, weight: .medium)
    guard let symbol = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else {
        fatalError("fan.fill symbol unavailable")
    }
    let tinted = NSImage(size: symbol.size, flipped: false) { r in
        symbol.draw(in: r)
        NSColor.white.set()
        r.fill(using: .sourceAtop)
        return true
    }
    let targetWidth = rect.width * 0.62
    let scale = targetWidth / tinted.size.width
    let glyphSize = NSSize(width: tinted.size.width * scale, height: tinted.size.height * scale)
    let glyphRect = NSRect(
        x: rect.midX - glyphSize.width / 2, y: rect.midY - glyphSize.height / 2,
        width: glyphSize.width, height: glyphSize.height)

    NSGraphicsContext.current?.saveGraphicsState()
    let glyphShadow = NSShadow()
    glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    glyphShadow.shadowOffset = NSSize(width: 0, height: -8)
    glyphShadow.shadowBlurRadius = 16
    glyphShadow.set()
    tinted.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.current?.restoreGraphicsState()

    return rep
}

let masterRep = drawMaster()
let masterImage = NSImage(size: NSSize(width: master, height: master))
masterImage.addRepresentation(masterRep)

let outDir = "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: outDir)
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// (filename, pixel size) pairs required by iconutil.
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, pixels) in variants {
    let rep = makeRep(pixels)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)
    ctx?.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    masterImage.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}

print("Wrote \(outDir); now run: iconutil -c icns \(outDir) -o AppIcon.icns")
