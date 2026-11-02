import AppKit
import WebKit

// One find bar for both kinds of surface. WebKit searches its own page; native
// pages are searched across their text views in reading order.
final class ApsaFindBar: ApsaGlassView, NSSearchFieldDelegate {
    private let field = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let previous = NSButton()
    private let next = NSButton()
    private let close = NSButton()
    private var matches: [(view: ApsaSelectableTextView, range: NSRange)] = []
    private var matchIndex = -1
    private weak var highlighted: ApsaSelectableTextView?
    var webView: () -> WKWebView? = { nil }
    var nativeRoot: () -> NSView? = { nil }
    var onClose: () -> Void = {}

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover; blendingMode = .withinWindow; state = .active
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        wantsLayer = true; layer?.cornerRadius = 10; layer?.masksToBounds = true; layer?.borderWidth = 0.5
        field.placeholderString = apsaText("Find on Page")
        field.delegate = self; field.target = self; field.action = #selector(searchChanged)
        field.sendsSearchStringImmediately = true
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.setContentHuggingPriority(.required, for: .horizontal)
        for (button, symbol, action, help) in [
            (previous, "chevron.up", #selector(findPrevious), apsaText("Previous Match")),
            (next, "chevron.down", #selector(findNext), apsaText("Next Match")),
            (close, "xmark", #selector(closeBar), apsaText("Close Find"))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            button.isBordered = false; button.target = self; button.action = action; button.toolTip = help
            button.setAccessibilityLabel(help)
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        }
        let row = NSStackView(views: [field, status, previous, next, close])
        row.orientation = .horizontal; row.spacing = 6; row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 360), heightAnchor.constraint(equalToConstant: 38)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func applyTheme(_ theme: ApsaTheme) {
        applyTint(theme.glassTint, opacity: 0.5)
        layer?.borderColor = theme.palette.line.cgColor
        for button in [previous, next, close] { button.contentTintColor = theme.palette.accent }
    }

    func open() {
        isHidden = false
        window?.makeFirstResponder(field)
        (field.currentEditor() as? NSTextView)?.isAutomaticTextReplacementEnabled = false
        field.currentEditor()?.selectAll(nil)
        if !field.stringValue.isEmpty { search(forward: true, restart: true) }
    }

    func step(forward: Bool) {
        if isHidden || field.stringValue.isEmpty { open(); return }
        search(forward: forward, restart: false)
    }

    func pageChanged() {
        clearHighlight()
        matches = []; matchIndex = -1; status.stringValue = ""
    }

    private func clearHighlight() {
        highlighted?.setSelectedRange(NSRange(location: 0, length: 0))
        highlighted?.showFindIndicator(for: NSRange(location: 0, length: 0))
        highlighted = nil
    }

    @objc private func searchChanged() { search(forward: true, restart: true) }
    @objc private func findPrevious() { step(forward: false) }
    @objc private func findNext() { step(forward: true) }
    @objc private func closeBar() {
        isHidden = true
        pageChanged()
        onClose()
    }

    // A search is literal: system text replacements must not rewrite the query.
    func controlTextDidBeginEditing(_ notification: Notification) {
        (field.currentEditor() as? NSTextView)?.isAutomaticTextReplacementEnabled = false
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            step(forward: !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) { closeBar(); return true }
        return false
    }

    private func search(forward: Bool, restart: Bool) {
        let query = field.stringValue
        guard !query.isEmpty else { pageChanged(); return }
        if let webView = webView() {
            let configuration = WKFindConfiguration()
            configuration.backwards = !forward; configuration.wraps = true
            webView.find(query, configuration: configuration) { [weak self] result in
                self?.status.stringValue = result.matchFound ? "" : apsaText("Not found")
            }
            return
        }
        clearHighlight()
        if restart || matches.isEmpty { collect(query); matchIndex = -1 }
        guard !matches.isEmpty else { status.stringValue = apsaText("Not found"); return }
        matchIndex = matchIndex < 0 ? 0 : (matchIndex + (forward ? 1 : -1) + matches.count) % matches.count
        let match = matches[matchIndex]
        match.view.setSelectedRange(match.range)
        highlighted = match.view
        match.view.scrollRangeToVisible(match.range)
        match.view.showFindIndicator(for: match.range)
        status.stringValue = apsaText("%d of %d", matchIndex + 1, matches.count)
    }

    private func collect(_ query: String) {
        matches = []
        func walk(_ view: NSView) {
            guard matches.count < 2_000 else { return }
            if let text = view as? ApsaSelectableTextView {
                let string = text.string as NSString
                var from = NSRange(location: 0, length: string.length)
                while from.length > 0, matches.count < 2_000 {
                    let found = string.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: from)
                    guard found.location != NSNotFound else { break }
                    matches.append((text, found))
                    from = NSRange(location: NSMaxRange(found), length: string.length - NSMaxRange(found))
                }
            }
            view.subviews.forEach(walk)
        }
        if let root = nativeRoot() { walk(root) }
    }
}
