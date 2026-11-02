import AppKit

struct ApsaNavigationHistory {
    private(set) var entries: [URL] = []
    private(set) var index = -1
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index + 1 < entries.count }
    mutating func replaceCurrent(_ url: URL) {
        guard entries.indices.contains(index) else { record(url); return }
        entries[index] = url
    }
    mutating func record(_ url: URL) {
        guard index < 0 || entries[index] != url else { return }
        entries = Array(entries.prefix(index + 1))
        entries.append(url)
        index = entries.count - 1
    }
    mutating func move(_ offset: Int) -> URL? {
        guard abs(offset) == 1, entries.indices.contains(index + offset) else { return nil }
        index += offset
        return entries[index]
    }
}

// Command-N picks a tab by position. With fewer than N tabs it lands on the last
// one, and Command-9 always means the last tab, however many there are.
func apsaTabIndex(forShortcut number: Int, tabCount: Int) -> Int? {
    guard tabCount > 0, (1...9).contains(number) else { return nil }
    return number == 9 || number > tabCount ? tabCount - 1 : number - 1
}

// Observe only events over this content surface. AppKit decides whether a
// two-finger swipe completes or cancels; ordinary vertical scrolling is untouched.
final class ApsaNavigationSurface: NSView {
    var usesWebKitGestures = false
    var webKitCanNavigate: (Int) -> Bool = { _ in false }
    var canGoBack: () -> Bool = { false }
    var canGoForward: () -> Bool = { false }
    var navigate: (Int) -> Void = { _ in }
    private var monitor: Any?
    private var tracking = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
            guard let self, event.window === self.window,
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            let horizontal = event.type == .swipe ? event.deltaX : event.scrollingDeltaX
            if self.usesWebKitGestures, self.webKitCanNavigate(horizontal > 0 ? -1 : 1) { return event }
            if event.type == .swipe {
                if event.deltaX > 0, self.canGoBack() { self.navigate(-1); return nil }
                if event.deltaX < 0, self.canGoForward() { self.navigate(1); return nil }
                return event
            }
            guard !self.tracking, NSEvent.isSwipeTrackingFromScrollEventsEnabled,
                  event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty,
                  event.phase == .began || event.phase == .changed,
                  abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
                  abs(event.scrollingDeltaX) > 0 else { return event }
            // Let horizontal controls, text fields and wide documents scroll normally.
            var hit = self.hitTest(self.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
            while let view = hit, view !== self {
                if let text = view as? NSTextView, text.isEditable { return event }
                if let scroll = view as? NSScrollView,
                   (scroll.documentView?.bounds.width ?? 0) > scroll.contentView.bounds.width + 1 { return event }
                hit = view.superview
            }
            let back = self.canGoBack(), forward = self.canGoForward()
            guard back || forward else { return event }
            self.tracking = true
            event.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount],
                                  dampenAmountThresholdMin: forward ? -1 : 0, max: back ? 1 : 0) {
                [weak self] amount, phase, complete, _ in
                guard let self else { return }
                if phase == .cancelled { self.tracking = false; return }
                guard complete else { return }
                self.tracking = false
                if amount >= 1, back { self.navigate(-1) }
                else if amount <= -1, forward { self.navigate(1) }
            }
            return nil
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

// One zoom for the whole browser, kept across launches.
enum ApsaPageZoom {
    private static let key = "apsa-browser-page-zoom"

    static func limited(_ value: CGFloat) -> CGFloat { max(0.5, min(3, value)) }

    static func saved(in defaults: UserDefaults = .standard) -> CGFloat {
        let value = defaults.double(forKey: key)
        return value > 0 ? limited(CGFloat(value)) : 1
    }

    static func save(_ value: CGFloat, in defaults: UserDefaults = .standard) {
        defaults.set(Double(value), forKey: key)
    }
}
