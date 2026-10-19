import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let size = NSSize(width: 1080, height: 590)
let image = NSImage(size: size)
image.lockFocus()
let context = NSGraphicsContext.current!
context.imageInterpolation = .high
// Work in top-left coordinates for both the SVG geometry and contact sheet.
let cg = context.cgContext
cg.translateBy(x: 0, y: size.height)
cg.scaleBy(x: 1, y: -1)

func color(_ value: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
            green: CGFloat((value >> 8) & 255) / 255,
            blue: CGFloat(value & 255) / 255, alpha: 1)
}
func box(_ rect: CGRect, fill: UInt32, radius: CGFloat = 0) {
    color(fill).setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}
func label(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, fill: UInt32 = 0x272b23, weight: NSFont.Weight = .regular) {
    cg.saveGState()
    cg.translateBy(x: x, y: y)
    cg.scaleBy(x: 1, y: -1)
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(fill)]
    (text as NSString).draw(at: NSPoint(x: 0, y: -font.ascender), withAttributes: attributes)
    cg.restoreGState()
}
func mark(_ index: Int, x: CGFloat, y: CGFloat, size: CGFloat, ink: UInt32) {
    cg.saveGState()
    cg.translateBy(x: x, y: y)
    cg.scaleBy(x: size / 24, y: size / 24)
    color(ink).setStroke()
    let path = NSBezierPath()
    path.lineWidth = 2.25
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    if index == 0 {
        for (x, top) in [(6.0,10.0), (12.0,4.0), (18.0,7.0)] {
            path.move(to: NSPoint(x: x, y: top)); path.line(to: NSPoint(x: x, y: 15))
        }
        path.move(to: NSPoint(x: 3, y: 20)); path.line(to: NSPoint(x: 21, y: 20))
        path.stroke()
    } else if index == 1 {
        for (y, knob) in [(6.0,8.0), (12.0,16.0), (18.0,10.0)] {
            path.move(to: NSPoint(x: 3, y: y)); path.line(to: NSPoint(x: knob - 2.5, y: y))
            path.move(to: NSPoint(x: knob + 2.5, y: y)); path.line(to: NSPoint(x: 21, y: y))
            path.appendOval(in: NSRect(x: knob - 2.5, y: y - 2.5, width: 5, height: 5))
        }
        path.stroke()
    } else {
        path.appendOval(in: NSRect(x: 2.5, y: 2.5, width: 19, height: 19))
        for (x, top, bottom) in [(8.0,10.0,14.0), (12.0,7.0,17.0), (16.0,9.0,15.0)] {
            path.move(to: NSPoint(x: x, y: top)); path.line(to: NSPoint(x: x, y: bottom))
        }
        path.stroke()
    }
    cg.restoreGState()
}

box(CGRect(origin: .zero, size: size), fill: 0xf4f2ec)
label("SOUNDSHELF  /  LOGO STUDIES", x: 48, y: 30, size: 11, fill: 0x757c6b, weight: .semibold)
label("A little mark for your menu bar.", x: 48, y: 62, size: 31, weight: .medium)
label("Three directions. Clear at 18px. Light and dark ready.", x: 48, y: 110, size: 13, fill: 0x757c6b)
let names = ["01   The Shelf", "02   Mixer", "03   Wave ring"]
let descriptions = ["Sound, resting on a shelf.", "Made for controlling audio.", "A familiar audio badge."]
for index in 0..<3 {
    let x = CGFloat(48 + index * 336)
    box(CGRect(x: x, y: 166, width: 312, height: 356), fill: 0xfaf9f5, radius: 15)
    mark(index, x: x + 116, y: 204, size: 80, ink: 0x272e23)
    label(names[index], x: x + 24, y: 314, size: 20, weight: .medium)
    label(descriptions[index], x: x + 24, y: 346, size: 12, fill: 0x757c6b)
    box(CGRect(x: x + 20, y: 395, width: 272, height: 38), fill: 0xe7e9e2, radius: 7)
    label("···", x: x + 36, y: 403, size: 14, fill: 0x757c6b)
    mark(index, x: x + 162, y: 405, size: 18, ink: 0x272e23)
    label("⌁   10:24", x: x + 196, y: 405, size: 11, fill: 0x596150)
    box(CGRect(x: x + 20, y: 443, width: 272, height: 38), fill: 0x292f28, radius: 7)
    label("···", x: x + 36, y: 451, size: 14, fill: 0xa4ae9a)
    mark(index, x: x + 162, y: 453, size: 18, ink: 0xf4f5ef)
    label("⌁   10:24", x: x + 196, y: 453, size: 11, fill: 0xc0c8b8)
}
label("MY PICK: 01 — THE SHELF", x: 48, y: 550, size: 11, fill: 0x6d7d54, weight: .semibold)
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("logo-options.png"))
