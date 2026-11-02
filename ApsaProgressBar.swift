import AppKit

// The loading bar: a plain rectangle with square ends, which the system bar cannot draw.
final class ApsaProgressBar: NSView {
    var doubleValue = 0.0 { didSet { needsDisplay = true } }
    var color = NSColor.controlAccentColor { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSRect(x: 0, y: 0, width: (bounds.width * max(0, min(1, doubleValue))).rounded(), height: bounds.height).fill()
    }
}
