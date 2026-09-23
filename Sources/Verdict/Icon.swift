import AppKit

/// Balance scales, beam tipped: a verdict, not a tie. One drawing feeds the
/// app icon and the menu-bar glyph so they always match.
enum ScalesIcon {
    static let night = NSColor(calibratedRed: 0.065, green: 0.067, blue: 0.085, alpha: 1)
    static let bone = NSColor(calibratedRed: 0.93, green: 0.92, blue: 0.88, alpha: 1)

    /// Draws the scales into a 1024-unit box scaled by `s`, in the current fill/stroke colour.
    static func draw(scale s: CGFloat, weight w: CGFloat = 1) {
        NSBezierPath(rect: NSRect(x: 492*s, y: 300*s, width: 40*s*w, height: 420*s)).fill()
        NSBezierPath(roundedRect: NSRect(x: 372*s, y: 240*s, width: 280*s, height: 56*s*w), xRadius: 28*s, yRadius: 28*s).fill()
        let lx: CGFloat = 232, ly: CGFloat = 660, rx: CGFloat = 792, ry: CGFloat = 740
        let beam = NSBezierPath(); beam.lineWidth = 40*s*w; beam.lineCapStyle = .round
        beam.move(to: NSPoint(x: lx*s, y: ly*s)); beam.line(to: NSPoint(x: rx*s, y: ry*s)); beam.stroke()
        NSBezierPath(ovalIn: NSRect(x: 472*s, y: 660*s, width: 80*s, height: 80*s)).fill()
        let chain = NSBezierPath(); chain.lineWidth = 14*s*w; chain.lineCapStyle = .round
        for (x, top, bottom) in [(lx, ly, CGFloat(470)), (rx, ry, CGFloat(560))] {
            chain.move(to: NSPoint(x: (x-96)*s, y: bottom*s)); chain.line(to: NSPoint(x: x*s, y: top*s)); chain.line(to: NSPoint(x: (x+96)*s, y: bottom*s))
        }
        chain.stroke()
        for (x, y) in [(lx, CGFloat(470)), (rx, CGFloat(560))] {
            let pan = NSBezierPath(); pan.move(to: NSPoint(x: (x-140)*s, y: y*s))
            pan.curve(to: NSPoint(x: (x+140)*s, y: y*s), controlPoint1: NSPoint(x: (x-100)*s, y: (y-110)*s), controlPoint2: NSPoint(x: (x+100)*s, y: (y-110)*s))
            pan.close(); pan.fill()
        }
    }

    /// Menu-bar glyph: a purpose-drawn small version. Thick beam, solid pans, no chains
    /// (they vanish at 18 pt), symmetric so it sits centred beside other icons.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setFill(); NSColor.black.setStroke()
            // base and post
            NSBezierPath(roundedRect: NSRect(x: 5, y: 1.5, width: 8, height: 1.8), xRadius: 0.9, yRadius: 0.9).fill()
            NSBezierPath(rect: NSRect(x: 8.2, y: 3, width: 1.6, height: 10)).fill()
            // beam, tipped
            let beam = NSBezierPath(); beam.lineWidth = 1.8; beam.lineCapStyle = .round
            beam.move(to: NSPoint(x: 2.2, y: 11.2)); beam.line(to: NSPoint(x: 15.8, y: 13.4)); beam.stroke()
            NSBezierPath(ovalIn: NSRect(x: 7.6, y: 11.0, width: 2.8, height: 2.8)).fill()
            // pans: short hanger, then a bowl (flat rim, rounded bottom)
            for (x, top) in [(CGFloat(3.4), CGFloat(11.2)), (CGFloat(14.6), CGFloat(13.4))] {
                NSBezierPath(rect: NSRect(x: x - 0.6, y: top - 3.0, width: 1.2, height: 3.0)).fill()
                let rim = top - 3.0
                let pan = NSBezierPath(); pan.move(to: NSPoint(x: x - 3.4, y: rim))
                pan.line(to: NSPoint(x: x + 3.4, y: rim))
                pan.curve(to: NSPoint(x: x - 3.4, y: rim), controlPoint1: NSPoint(x: x + 2.6, y: rim - 4.2), controlPoint2: NSPoint(x: x - 2.6, y: rim - 4.2))
                pan.close(); pan.fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Verdict"
        return image
    }

    static func appIcon(size: CGFloat = 1024) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let s = size / 1024
        night.setFill()
        NSBezierPath(roundedRect: NSRect(x: 32 * s, y: 32 * s, width: 960 * s, height: 960 * s), xRadius: 224 * s, yRadius: 224 * s).fill()
        bone.setFill(); bone.setStroke()
        draw(scale: s)
        image.unlockFocus()
        return image
    }
}
