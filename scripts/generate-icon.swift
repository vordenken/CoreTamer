// Generates the CoreTamer app icon from code so the artwork is reproducible and license-clean.
// Usage (from the repository root): swift scripts/generate-icon.swift
// Output: CoreTamer/Resources/Assets.xcassets/AppIcon.appiconset (the 1024 px PNG is also
// used by the README).
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Angle on the gauge for a fraction 0...1; the dial sweeps 240° from lower-left to lower-right.
func gaugeAngle(_ fraction: CGFloat) -> CGFloat { 210 - 240 * fraction }

func point(_ center: NSPoint, _ radius: CGFloat, _ degrees: CGFloat) -> NSPoint {
    let radians = degrees * .pi / 180
    return NSPoint(x: center.x + radius * cos(radians), y: center.y + radius * sin(radians))
}

func drawIcon() {
    // macOS icon grid: 824 pt body centered on a 1024 canvas, continuous-looking corners.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    color(0x1B2A4E).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [color(0x16A6A0), color(0x2A4D9B), color(0x22234F)])?
        .draw(in: squircle, angle: -70)

    // Soft top highlight for depth.
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)])?
        .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // CPU chip with pins.
    let chip = NSRect(x: 292, y: 292, width: 440, height: 440)
    let pinColor = color(0xDCE7F5)
    pinColor.setFill()
    let pinLength: CGFloat = 62
    let pinWidth: CGFloat = 34
    for index in 0..<4 {
        let offset = chip.minX + 70 + CGFloat(index) * 100 - pinWidth / 2
        let pins = [
            NSRect(x: offset, y: chip.maxY - 10, width: pinWidth, height: pinLength),
            NSRect(x: offset, y: chip.minY - pinLength + 10, width: pinWidth, height: pinLength),
            NSRect(x: chip.minX - pinLength + 10, y: offset, width: pinLength, height: pinWidth),
            NSRect(x: chip.maxX - 10, y: offset, width: pinLength, height: pinWidth),
        ]
        for pin in pins { NSBezierPath(roundedRect: pin, xRadius: 12, yRadius: 12).fill() }
    }

    NSGraphicsContext.saveGraphicsState()
    let chipShadow = NSShadow()
    chipShadow.shadowColor = color(0x000000, 0.3)
    chipShadow.shadowOffset = NSSize(width: 0, height: -8)
    chipShadow.shadowBlurRadius = 18
    chipShadow.set()
    let chipPath = NSBezierPath(roundedRect: chip, xRadius: 72, yRadius: 72)
    color(0xF7FAFF).setFill()
    chipPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0xFFFFFF), color(0xE3ECF7)])?.draw(in: chipPath, angle: -90)

    // Gauge: grey full track, then a calm green-to-teal segment ending at the tamed value.
    let center = NSPoint(x: 512, y: 492)
    let radius: CGFloat = 138
    let tamed: CGFloat = 0.36

    let track = NSBezierPath()
    track.appendArc(
        withCenter: center, radius: radius, startAngle: gaugeAngle(0), endAngle: gaugeAngle(1),
        clockwise: true)
    track.lineWidth = 40
    track.lineCapStyle = .round
    color(0xC9D5E6).setStroke()
    track.stroke()

    let segments = 24
    for step in 0..<segments {
        let from = tamed * CGFloat(step) / CGFloat(segments)
        // Slight overlap hides anti-aliasing seams between neighbouring segments.
        let to = min(tamed, tamed * CGFloat(step + 1) / CGFloat(segments) + 0.004)
        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: center, radius: radius, startAngle: gaugeAngle(from),
            endAngle: gaugeAngle(to), clockwise: true)
        arc.lineWidth = 40
        arc.lineCapStyle = step == 0 ? .round : .butt
        let mix = CGFloat(step) / CGFloat(segments - 1)
        (color(0x34C77B).blended(withFraction: mix, of: color(0x14A3A8)) ?? color(0x34C77B))
            .setStroke()
        arc.stroke()
    }

    // Needle pointing at the tamed value.
    let tip = point(center, radius - 8, gaugeAngle(tamed))
    let needle = NSBezierPath()
    let base = gaugeAngle(tamed) + 90
    needle.move(to: point(center, 20, base))
    needle.line(to: tip)
    needle.line(to: point(center, 20, base + 180))
    needle.close()
    color(0x1E2B52).setFill()
    needle.fill()
    color(0x1E2B52).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 34, y: center.y - 34, width: 68, height: 68)).fill()
    color(0x14A3A8).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 13, y: center.y - 13, width: 26, height: 26)).fill()

    // "Tamed" bar at the bottom of the chip.
    color(0x1E2B52, 0.85).setFill()
    NSBezierPath(
        roundedRect: NSRect(x: 432, y: 352, width: 160, height: 22), xRadius: 11, yRadius: 11
    ).fill()
}

func render(pixels: Int) throws -> Data {
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { throw CocoaError(.featureUnsupported) }
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let scale = CGFloat(pixels) / canvas
    context.cgContext.scaleBy(x: scale, y: scale)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return png
}

func run() throws {
    let catalog = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("CoreTamer/Resources/Assets.xcassets")
    let iconset = catalog.appendingPathComponent("AppIcon.appiconset")
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

    var images: [String] = []
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
            try render(pixels: size * scale).write(to: iconset.appendingPathComponent(name))
            images.append(
                """
                    { "filename" : "\(name)", "idiom" : "mac", "scale" : "\(scale)x", "size" : "\(size)x\(size)" }
                """)
        }
    }
    let info = "  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n"
    try Data("{\n  \"images\" : [\n\(images.joined(separator: ",\n"))\n  ],\n\(info)}\n".utf8)
        .write(to: iconset.appendingPathComponent("Contents.json"))
    try Data("{\n\(info)}\n".utf8).write(to: catalog.appendingPathComponent("Contents.json"))
    print("Wrote \(iconset.path)")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("ERROR: Icon generation failed: \(error)\n".utf8))
    exit(1)
}
