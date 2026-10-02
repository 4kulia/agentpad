import AppKit

/// Menu-bar-specific AgentPad mark. Keep the Dock icon's tile-and-glyph identity,
/// but flatten it to a crisp white tile with a black `>_` at menu-bar size.
@MainActor
enum AgentPadMenuBarIcon {
    static let size = NSSize(width: 18, height: 18)

    static func make() -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.white.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 2, y: 2, width: 14, height: 14),
                xRadius: 3.5,
                yRadius: 3.5
            ).fill()

            NSColor.black.setStroke()

            let chevron = NSBezierPath()
            chevron.move(to: NSPoint(x: 4.75, y: 11.75))
            chevron.line(to: NSPoint(x: 7.75, y: 9))
            chevron.line(to: NSPoint(x: 4.75, y: 6.25))
            chevron.lineWidth = 1.5
            chevron.lineCapStyle = .butt
            chevron.lineJoinStyle = .miter
            chevron.stroke()

            let underscore = NSBezierPath()
            underscore.move(to: NSPoint(x: 8.75, y: 6.25))
            underscore.line(to: NSPoint(x: 13.5, y: 6.25))
            underscore.lineWidth = 1.5
            underscore.lineCapStyle = .butt
            underscore.stroke()
            return true
        }
        // A template image would tint the tile and glyph as one colour. This
        // mark intentionally keeps its white background and black foreground.
        image.isTemplate = false
        return image
    }
}
