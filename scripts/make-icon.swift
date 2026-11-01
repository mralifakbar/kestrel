// Renders the Kestrel app icon (1024×1024 PNG) — usage: swift make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Squircle background
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
ctx.saveGState()
bg.addClip()
let grad = NSGradient(colors: [NSColor(red: 0.05, green: 0.09, blue: 0.20, alpha: 1), NSColor(red: 0.10, green: 0.22, blue: 0.40, alpha: 1), NSColor(red: 0.06, green: 0.42, blue: 0.48, alpha: 1)])!
grad.draw(in: rect, angle: 60)
// faint grid
NSColor.white.withAlphaComponent(0.05).setStroke()
for i in stride(from: rect.minX, to: rect.maxX, by: 64) {
    let p = NSBezierPath(); p.move(to: NSPoint(x: i, y: rect.minY)); p.line(to: NSPoint(x: i, y: rect.maxY)); p.lineWidth = 2; p.stroke()
}
ctx.restoreGState()

// Gauge arc
let center = NSPoint(x: size / 2, y: size / 2 - 40)
let radius: CGFloat = 270
let track = NSBezierPath()
track.appendArc(withCenter: center, radius: radius, startAngle: 200, endAngle: -20, clockwise: true)
track.lineWidth = 46; track.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.15).setStroke(); track.stroke()

let colors: [NSColor] = [NSColor(red: 0.25, green: 0.85, blue: 0.75, alpha: 1), NSColor(red: 0.35, green: 0.65, blue: 1, alpha: 1), NSColor(red: 1, green: 0.55, blue: 0.30, alpha: 1)]
let segs: [(CGFloat, CGFloat)] = [(200, 130), (128, 58), (56, 10)]
for (i, s) in segs.enumerated() {
    let p = NSBezierPath()
    p.appendArc(withCenter: center, radius: radius, startAngle: s.0, endAngle: s.1, clockwise: true)
    p.lineWidth = 46; p.lineCapStyle = .round
    colors[i].setStroke(); p.stroke()
}

// Pulse line through the middle (the "kestrel" hovering over a heartbeat)
let pulse = NSBezierPath()
let y0 = center.y + 10
pulse.move(to: NSPoint(x: center.x - 230, y: y0))
pulse.line(to: NSPoint(x: center.x - 90, y: y0))
pulse.line(to: NSPoint(x: center.x - 40, y: y0 + 120))
pulse.line(to: NSPoint(x: center.x + 20, y: y0 - 110))
pulse.line(to: NSPoint(x: center.x + 70, y: y0 + 40))
pulse.line(to: NSPoint(x: center.x + 230, y: y0 + 40))
pulse.lineWidth = 30; pulse.lineJoinStyle = .round; pulse.lineCapStyle = .round
NSColor.white.setStroke(); pulse.stroke()

let dot = NSBezierPath(ovalIn: NSRect(x: center.x + 210, y: y0 + 20, width: 40, height: 40))
NSColor(red: 1, green: 0.55, blue: 0.30, alpha: 1).setFill(); dot.fill()

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
