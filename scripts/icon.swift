import AppKit
// Renders the app icon PNG. Keep in sync with Sources/Verdict/Icon.swift.
let dest = CommandLine.arguments[1]
let img = NSImage(size: NSSize(width: 1024, height: 1024)); img.lockFocus()
NSColor(calibratedRed: 0.065, green: 0.067, blue: 0.085, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 224, yRadius: 224).fill()
let bone = NSColor(calibratedRed: 0.93, green: 0.92, blue: 0.88, alpha: 1); bone.setFill(); bone.setStroke()
NSBezierPath(rect: NSRect(x: 492, y: 300, width: 40, height: 420)).fill()
NSBezierPath(roundedRect: NSRect(x: 372, y: 240, width: 280, height: 56), xRadius: 28, yRadius: 28).fill()
let lx: CGFloat = 232, ly: CGFloat = 660, rx: CGFloat = 792, ry: CGFloat = 740
let beam = NSBezierPath(); beam.lineWidth = 40; beam.lineCapStyle = .round
beam.move(to: NSPoint(x: lx, y: ly)); beam.line(to: NSPoint(x: rx, y: ry)); beam.stroke()
NSBezierPath(ovalIn: NSRect(x: 472, y: 660, width: 80, height: 80)).fill()
let chain = NSBezierPath(); chain.lineWidth = 14; chain.lineCapStyle = .round
for (x, top, bottom) in [(lx, ly, CGFloat(470)), (rx, ry, CGFloat(560))] {
    chain.move(to: NSPoint(x: x-96, y: bottom)); chain.line(to: NSPoint(x: x, y: top)); chain.line(to: NSPoint(x: x+96, y: bottom))
}
chain.stroke()
for (x, y) in [(lx, CGFloat(470)), (rx, CGFloat(560))] {
    let pan = NSBezierPath(); pan.move(to: NSPoint(x: x-140, y: y))
    pan.curve(to: NSPoint(x: x+140, y: y), controlPoint1: NSPoint(x: x-100, y: y-110), controlPoint2: NSPoint(x: x+100, y: y-110))
    pan.close(); pan.fill()
}
img.unlockFocus()
try! NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dest))
