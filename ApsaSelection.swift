import AppKit

// Paint order can differ from reading order in a positioned page.
protocol ApsaSelectionOrder {
    var selectionSubviews: [NSView] { get }
}

class ApsaSelectableTextView: NSTextView {
    weak var pageSelection: ApsaPageSelection?
    var onOpenLink: ((URL) -> Void)?
    var onActivate: (() -> Void)?
    var selectionSeparator = "\n\n"
    var maximumNumberOfLines: Int = 0 {
        didSet { textContainer?.maximumNumberOfLines = maximumNumberOfLines; invalidateIntrinsicContentSize() }
    }
    var lineBreakMode: NSLineBreakMode = .byWordWrapping {
        didSet { textContainer?.lineBreakMode = lineBreakMode; invalidateIntrinsicContentSize() }
    }
    var stringValue: String { get { string } set { string = newValue } }

    init(_ value: NSAttributedString) {
        let storage = NSTextStorage(attributedString: value)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false; isSelectable = true; drawsBackground = false
        textContainerInset = .zero; container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        isHorizontallyResizable = false; isVerticallyResizable = true
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize {
        guard let manager = layoutManager, let container = textContainer else { return NSSize(width: 80, height: 24) }
        let natural = min(800, max(1, ceil(textStorage?.size().width ?? 80) + 1))
        container.containerSize = NSSize(width: bounds.width > 1 ? bounds.width : natural, height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return NSSize(width: natural, height: max(20, ceil(manager.usedRect(for: container).height) + 3))
    }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if changed { invalidateIntrinsicContentSize() }
    }
    override func mouseDown(with event: NSEvent) {
        guard let selection = pageSelection else { super.mouseDown(with: event); return }
        selection.track(event, in: self)
    }
    override func copy(_ sender: Any?) {
        if let selection = pageSelection { selection.copy(to: .general) }
        else { super.copy(sender) }
    }
    override func selectAll(_ sender: Any?) {
        if let selection = pageSelection { selection.selectAll() }
        else { super.selectAll(sender) }
    }
    override func keyDown(with event: NSEvent) {
        if let selection = pageSelection {
            if event.modifierFlags.contains(.command) {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "a": selectAll(nil); return
                case "c": copy(nil); return
                default: break
                }
            }
            if [123, 124].contains(event.keyCode) {
                selection.move(forward: event.keyCode == 124, extending: event.modifierFlags.contains(.shift), toEdge: event.modifierFlags.contains(.command)); return
            }
            if event.keyCode == 53 { selection.clear(); return }
        }
        super.keyDown(with: event)
        pageSelection?.adoptSelection(from: self)
    }
    func activate(at index: Int) {
        if index < (string as NSString).length,
           let link = textStorage?.attribute(.link, at: index, effectiveRange: nil) {
            if let url = link as? URL { onOpenLink?(url); return }
            if let string = link as? String, let url = URL(string: string) { onOpenLink?(url); return }
        }
        onActivate?()
    }
}

// One UTF-16 selection across all visible, read-only page blocks. Editable
// controls and hidden disclosure contents never join the page text buffer.
final class ApsaPageSelection {
    struct Segment {
        let view: ApsaSelectableTextView
        let range: NSRange
    }
    private weak var root: NSView?
    private var highlighted: [ObjectIdentifier: NSRange] = [:]
    private(set) var segments: [Segment] = []
    private(set) var text = ""
    private(set) var anchor = 0
    private(set) var focus = 0
    var selectedRange: NSRange { NSRange(location: min(anchor, focus), length: abs(focus - anchor)) }
    var selectedText: String { (text as NSString).substring(with: selectedRange) }

    func attach(to root: NSView) {
        clear(); self.root = root; refresh()
    }
    func update() {
        clear(); refresh()
    }
    private func refresh() {
        guard let root else { return }
        var views: [ApsaSelectableTextView] = []
        func visit(_ view: NSView) {
            guard !view.isHiddenOrHasHiddenAncestor else { return }
            if let text = view as? ApsaSelectableTextView {
                text.pageSelection = self
                if !text.string.isEmpty { views.append(text) }
                return
            }
            for child in (view as? ApsaSelectionOrder)?.selectionSubviews ?? view.subviews { visit(child) }
        }
        visit(root)
        segments = []; text = ""
        var offset = 0
        for (index, view) in views.enumerated() {
            if index > 0 { let separator = views[index - 1].selectionSeparator; text += separator; offset += separator.utf16.count }
            let range = NSRange(location: offset, length: view.string.utf16.count)
            text += view.string; segments.append(Segment(view: view, range: range))
            offset += range.length
        }
        let count = (text as NSString).length
        anchor = min(anchor, count); focus = min(focus, count)
    }
    func clear() {
        for segment in segments {
            let range = NSRange(location: 0, length: (segment.view.string as NSString).length)
            segment.view.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            segment.view.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            segment.view.setSelectedRange(NSRange(location: 0, length: 0))
        }
        anchor = 0; focus = 0
        highlighted.removeAll()
    }
    // Also used by the native regression check; endpoints are insertion indices.
    func select(from start: Int, to end: Int) {
        let count = (text as NSString).length
        anchor = max(0, min(count, start)); focus = max(0, min(count, end))
        paint()
    }
    func selectAll() {
        refresh(); select(from: 0, to: (text as NSString).length)
    }
    private func paint() {
        let selected = selectedRange
        for segment in segments {
            let all = NSRange(location: 0, length: segment.range.length)
            let manager = segment.view.layoutManager
            let intersection = NSIntersectionRange(selected, segment.range)
            let local: NSRange
            if intersection.length > 0 { local = NSRange(location: intersection.location - segment.range.location, length: intersection.length) }
            else if selected.length == 0 && focus >= segment.range.location && focus <= NSMaxRange(segment.range) { local = NSRange(location: focus - segment.range.location, length: 0) }
            else { local = NSRange(location: 0, length: 0) }
            let id = ObjectIdentifier(segment.view)
            if highlighted[id] == local { continue }
            highlighted[id] = local
            manager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
            manager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
            segment.view.setSelectedRange(local)
            if local.length > 0 {
                manager?.addTemporaryAttribute(.backgroundColor, value: NSColor.selectedTextBackgroundColor, forCharacterRange: local)
                manager?.addTemporaryAttribute(.foregroundColor, value: NSColor.selectedTextColor, forCharacterRange: local)
            }
        }
    }
    func adoptSelection(from view: ApsaSelectableTextView) {
        guard let segment = segments.first(where: { $0.view === view }) else { return }
        let local = view.selectedRange()
        select(from: segment.range.location + local.location, to: segment.range.location + NSMaxRange(local))
    }
    private func position(at point: NSPoint, in root: NSView) -> Int {
        var best: (Segment, CGFloat)?
        for segment in segments {
            let rect = segment.view.convert(segment.view.bounds, to: root)
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            let distance = dx * dx + dy * dy
            if best == nil || distance < best!.1 { best = (segment, distance) }
        }
        guard let segment = best?.0 else { return 0 }
        let local = segment.view.convert(point, from: root)
        return segment.range.location + min(segment.range.length, segment.view.characterIndexForInsertion(at: local))
    }
    func track(_ event: NSEvent, in source: ApsaSelectableTextView) {
        guard let root, let window = source.window else { return }
        refresh()
        let start = position(at: root.convert(event.locationInWindow, from: nil), in: root)
        let extending = event.modifierFlags.contains(.shift)
        let oldAnchor = anchor
        clear()
        window.makeFirstResponder(source)
        var initial = NSRange(location: start, length: 0)
        if event.clickCount >= 2, let segment = segments.first(where: { $0.view === source }) {
            let local = min(segment.range.length, max(0, start - segment.range.location))
            let range = source.selectionRange(forProposedRange: NSRange(location: local, length: 0), granularity: event.clickCount >= 3 ? .selectByParagraph : .selectByWord)
            initial = NSRange(location: segment.range.location + range.location, length: range.length)
        }
        select(from: extending ? oldAnchor : initial.location, to: extending ? start : NSMaxRange(initial))
        var dragged = false
        var lastDrag: NSEvent?
        NSEvent.startPeriodicEvents(afterDelay: 0.15, withPeriod: 0.04)
        defer { NSEvent.stopPeriodicEvents() }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) {
            if next.type == .leftMouseUp { break }
            if next.type == .leftMouseDragged { dragged = true; lastDrag = next }
            guard let drag = lastDrag else { continue }
            _ = source.autoscroll(with: drag)
            let end = position(at: root.convert(drag.locationInWindow, from: nil), in: root)
            select(from: extending ? oldAnchor : (end < initial.location ? NSMaxRange(initial) : initial.location), to: end)
        }
        if !dragged && !extending && event.clickCount == 1 { source.activate(at: max(0, start - (segments.first { $0.view === source }?.range.location ?? start))) }
    }
    func move(forward: Bool, extending: Bool, toEdge: Bool) {
        let value = text as NSString
        var next = focus
        if toEdge { next = forward ? value.length : 0 }
        else if !extending && selectedRange.length > 0 { next = forward ? NSMaxRange(selectedRange) : selectedRange.location }
        else if forward && focus < value.length { next = NSMaxRange(value.rangeOfComposedCharacterSequence(at: focus)) }
        else if !forward && focus > 0 { next = value.rangeOfComposedCharacterSequence(at: focus - 1).location }
        select(from: extending ? anchor : next, to: next)
    }
    func copy(to pasteboard: NSPasteboard) {
        guard selectedRange.length > 0 else { return }
        pasteboard.clearContents()
        pasteboard.setString(selectedText, forType: .string)
    }
}
