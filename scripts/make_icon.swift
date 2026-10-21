import AppKit

// Draws a 1024px marmalade-orange icon and writes it to the path given as the first argument.
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let rect = NSRect(x: 40, y: 40, width: 944, height: 944)
let body = NSBezierPath(roundedRect: rect, xRadius: 210, yRadius: 210)
NSGradient(colors: [NSColor(red: 1.0, green: 0.74, blue: 0.20, alpha: 1),
                    NSColor(red: 0.93, green: 0.40, blue: 0.08, alpha: 1)])!
    .draw(in: body, angle: -90)

// Citrus slice
let center = NSPoint(x: 512, y: 512)
NSColor(white: 1, alpha: 0.95).setFill()
NSBezierPath(ovalIn: NSRect(x: center.x - 330, y: center.y - 330, width: 660, height: 660)).fill()
NSColor(red: 1.0, green: 0.62, blue: 0.14, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: center.x - 290, y: center.y - 290, width: 580, height: 580)).fill()
NSColor(white: 1, alpha: 0.9).setStroke()
for i in 0..<8 {
    let a = CGFloat(i) * .pi / 4
    let seg = NSBezierPath()
    seg.lineWidth = 16
    seg.move(to: center)
    seg.line(to: NSPoint(x: center.x + cos(a) * 285, y: center.y + sin(a) * 285))
    seg.stroke()
}
NSColor(white: 1, alpha: 0.95).setFill()
NSBezierPath(ovalIn: NSRect(x: center.x - 36, y: center.y - 36, width: 72, height: 72)).fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
