import AppKit

// Draws into a bitmap, with no window.
@main struct ProgressBarTests {
    static func main() {
        let bar = ApsaProgressBar(frame: NSRect(x: 0, y: 0, width: 200, height: 2))
        bar.color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        func alphas(_ value: Double) -> [[CGFloat]] {
            bar.doubleValue = value
            let bitmap = bar.bitmapImageRepForCachingDisplay(in: bar.bounds)!
            bar.cacheDisplay(in: bar.bounds, to: bitmap)
            return (0..<bitmap.pixelsHigh).map { y in (0..<bitmap.pixelsWide).map { x in bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0 } }
        }
        let half = alphas(0.5)
        let edge = half[0].count / 2
        for row in half {
            precondition(row[..<edge].allSatisfy { $0 == 1 } && row[edge...].allSatisfy { $0 == 0 }, "square ends: every row stops at the same pixel, with no soft or rounded edge")
        }
        precondition(alphas(0).allSatisfy { $0.allSatisfy { $0 == 0 } })
        precondition(alphas(1).allSatisfy { $0.allSatisfy { $0 == 1 } })
        precondition(alphas(-1).allSatisfy { $0.allSatisfy { $0 == 0 } } && alphas(7).allSatisfy { $0.allSatisfy { $0 == 1 } }, "out-of-range values stay inside the bar")
        precondition(bar.hitTest(NSPoint(x: 10, y: 1)) == nil, "it never takes clicks")
        print("Progress bar: square ends and clamped values OK")
    }
}
