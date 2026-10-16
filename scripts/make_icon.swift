import AppKit
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(path); ctx.clip()
let colors = [NSColor(srgbRed: 0.18, green: 0.2, blue: 0.75, alpha: 1).cgColor,
              NSColor(srgbRed: 0.1, green: 0.65, blue: 0.95, alpha: 1).cgColor,
              NSColor(srgbRed: 0.45, green: 0.95, blue: 0.85, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.6, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 924, y: 924), options: [])
// glass sheen
ctx.setFillColor(NSColor.white.withAlphaComponent(0.14).cgColor)
ctx.fillEllipse(in: CGRect(x: -150, y: 520, width: 1100, height: 700))
// camera path
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
ctx.setLineWidth(26); ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 230, y: 330))
ctx.addCurve(to: CGPoint(x: 800, y: 600), control1: CGPoint(x: 420, y: 200), control2: CGPoint(x: 560, y: 720))
ctx.strokePath()
// point cloud dots
srand48(7)
for _ in 0..<70 {
    let x = 200 + drand48() * 620, y = 380 + drand48() * 420, r = 8 + drand48() * 12
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.35 + drand48() * 0.5).cgColor)
    ctx.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
}
// camera frustum at end
ctx.setLineWidth(20); ctx.setLineJoin(.round)
let c = CGPoint(x: 800, y: 600)
ctx.move(to: c); ctx.addLine(to: CGPoint(x: 700, y: 760)); ctx.addLine(to: CGPoint(x: 880, y: 800)); ctx.closePath()
ctx.setFillColor(NSColor.white.withAlphaComponent(0.3).cgColor); ctx.drawPath(using: .fillStroke)
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
