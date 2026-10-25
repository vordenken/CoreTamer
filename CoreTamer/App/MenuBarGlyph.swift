import AppKit

/// Monochrome menu bar glyph matching the app icon: a CPU chip with a calm gauge needle.
/// Drawn as a template image so macOS tints it for light, dark and highlighted menu bars.
enum MenuBarGlyph {
    static func make(updateAvailable: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()

            let chip = NSBezierPath(
                roundedRect: NSRect(x: 3.5, y: 3.5, width: 11, height: 11), xRadius: 2.5,
                yRadius: 2.5)
            chip.lineWidth = 1.5
            chip.stroke()

            for offset in [6.0, 9.0, 12.0] {
                let pins = [
                    NSRect(x: offset - 0.6, y: 15, width: 1.2, height: 2),
                    NSRect(x: offset - 0.6, y: 1, width: 1.2, height: 2),
                    NSRect(x: 1, y: offset - 0.6, width: 2, height: 1.2),
                    NSRect(x: 15, y: offset - 0.6, width: 2, height: 1.2),
                ]
                for pin in pins { NSBezierPath(rect: pin).fill() }
            }

            let center = NSPoint(x: 9, y: 8)
            let dial = NSBezierPath()
            dial.appendArc(
                withCenter: center, radius: 3.6, startAngle: 200, endAngle: -20, clockwise: true)
            dial.lineWidth = 1.2
            dial.lineCapStyle = .round
            dial.stroke()

            let needle = NSBezierPath()
            needle.move(to: center)
            needle.line(to: NSPoint(x: center.x - 2.2, y: center.y + 2.6))
            needle.lineWidth = 1.3
            needle.lineCapStyle = .round
            needle.stroke()
            NSBezierPath(ovalIn: NSRect(x: center.x - 1, y: center.y - 1, width: 2, height: 2))
                .fill()
            if updateAvailable {
                NSBezierPath(ovalIn: NSRect(x: 13.5, y: 13.5, width: 4, height: 4)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = String(
            localized: updateAvailable ? "CoreTamer, update available" : "CoreTamer")
        return image
    }
}
