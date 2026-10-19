import AppKit

enum SoundShelfIcon {
    /// Logo 03: resolution-independent paths, with no background fill.
    /// A template image lets macOS supply the correct light/dark menu bar color.
    static let menuBar: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.6875
            path.lineCapStyle = .round
            path.appendOval(in: NSRect(x: 1.875, y: 1.875, width: 14.25, height: 14.25))
            for (x, top, bottom) in [(6.0, 7.5, 10.5), (9.0, 5.25, 12.75), (12.0, 6.75, 11.25)] {
                path.move(to: NSPoint(x: x, y: top))
                path.line(to: NSPoint(x: x, y: bottom))
            }
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SoundShelf"
        return image
    }()
}
