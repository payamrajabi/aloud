// Renders the app icon to a 1024px PNG: a waveform on a light squircle, blue on
// the left (the Mac speaking to you), red on the right (you speaking to it).
// Matches docs/assets/icon.svg.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(white: 0.90, alpha: 1), NSColor.white])!.draw(in: path, angle: 90)
NSColor(white: 0, alpha: 0.12).setStroke()
path.lineWidth = 4
path.stroke()

// Bars in the SVG's 100-unit grid (squircle spans 6…94), scaled onto the squircle.
let unit = rect.width / 88
let blue = NSColor(srgbRed: 0, green: 0.478, blue: 1, alpha: 1)
let ink = NSColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 1)
let red = NSColor(srgbRed: 1, green: 0.231, blue: 0.188, alpha: 1)
let bars: [(x: CGFloat, half: CGFloat, color: NSColor)] = [(24, 8, blue), (37, 18, blue), (50, 26, ink), (63, 18, red), (76, 8, red)]
for bar in bars {
    let x = inset + (bar.x - 6) * unit
    let line = NSBezierPath()
    line.move(to: NSPoint(x: x, y: size / 2 - bar.half * unit))
    line.line(to: NSPoint(x: x, y: size / 2 + bar.half * unit))
    line.lineWidth = 7.5 * unit
    line.lineCapStyle = .round
    bar.color.setStroke()
    line.stroke()
}
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
