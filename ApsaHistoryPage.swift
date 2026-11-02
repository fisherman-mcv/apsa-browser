import AppKit

private final class HistoryDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class HistoryRow: NSView {
    private let open: () -> Void
    private let delete: () -> Void

    init(entry: ApsaHistoryEntry, time: String, palette: ApsaPalette, open: @escaping () -> Void, delete: @escaping () -> Void) {
        self.open = open
        self.delete = delete
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let host = URL(string: entry.url)?.host?.replacingOccurrences(of: "www.", with: "") ?? entry.url
        let main = NSButton(title: "", target: self, action: #selector(openEntry))
        main.isBordered = false
        main.translatesAutoresizingMaskIntoConstraints = false
        main.setAccessibilityLabel(entry.title.isEmpty ? entry.url : entry.title)
        main.toolTip = entry.url
        let clock = NSTextField(labelWithString: time)
        clock.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        clock.textColor = palette.secondary
        let title = NSTextField(labelWithString: entry.title.isEmpty ? host : entry.title)
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.textColor = palette.text
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: entry.url)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = palette.secondary
        detail.lineBreakMode = .byTruncatingMiddle
        let remove = NSButton(title: "", target: self, action: #selector(deleteEntry))
        remove.isBordered = false
        remove.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: apsaText("Remove from History"))
        remove.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        remove.contentTintColor = palette.secondary
        remove.toolTip = apsaText("Remove from History")
        remove.setAccessibilityLabel(apsaText("Remove from History"))
        for view in [main, clock, title, detail, remove] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),
            main.topAnchor.constraint(equalTo: topAnchor), main.bottomAnchor.constraint(equalTo: bottomAnchor),
            main.leadingAnchor.constraint(equalTo: leadingAnchor), main.trailingAnchor.constraint(equalTo: trailingAnchor),
            clock.leadingAnchor.constraint(equalTo: leadingAnchor),
            clock.centerYAnchor.constraint(equalTo: centerYAnchor),
            clock.widthAnchor.constraint(equalToConstant: 44),
            title.leadingAnchor.constraint(equalTo: clock.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: remove.leadingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: remove.leadingAnchor, constant: -10),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor),
            remove.centerYAnchor.constraint(equalTo: centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 26), remove.heightAnchor.constraint(equalToConstant: 26)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func openEntry() { open() }
    @objc private func deleteEntry() { delete() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

final class ApsaHistoryView: NSView, NSSearchFieldDelegate {
    private let navigate: (URL) -> Void
    private let store = ApsaHistoryStore.shared
    private let search = NSSearchField()
    private let list = NSStackView()
    private let scroll = NSScrollView()
    private var rebuildScheduled = false

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = ApsaLanguage.current.locale
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMMyyyy")
        return formatter
    }()
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = ApsaLanguage.current.locale
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    init(navigate: @escaping (URL) -> Void) {
        self.navigate = navigate
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let palette = ApsaThemeStore.shared.selected.palette
        let heading = NSTextField(labelWithString: apsaText("History"))
        heading.font = .systemFont(ofSize: 28, weight: .bold)
        heading.textColor = palette.text
        search.placeholderString = apsaText("Search History")
        search.delegate = self
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsSearchStringImmediately = true
        search.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let clear = NSButton(title: apsaText("Clear History…"), target: self, action: #selector(clearAll))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [heading, spacer, search, clear])
        header.orientation = .horizontal
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = HistoryDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        addSubview(header)
        addSubview(scroll)
        let wide = header.widthAnchor.constraint(equalTo: widthAnchor, constant: -56)
        wide.priority = .defaultHigh
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            header.centerXAnchor.constraint(equalTo: centerXAnchor),
            header.widthAnchor.constraint(lessThanOrEqualToConstant: 860),
            wide,
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -28),
            list.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: header.trailingAnchor)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(historyChanged), name: ApsaHistoryStore.changed, object: nil)
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    func focusSearch() {
        window?.makeFirstResponder(search)
        search.currentEditor()?.selectAll(nil)
    }

    @objc private func searchChanged() { rebuild() }

    @objc private func historyChanged() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.rebuildScheduled = false
            self?.rebuild()
        }
    }

    @objc private func clearAll() {
        guard let window else { return }
        ApsaHistoryView.confirmClear(for: window)
    }

    static func confirmClear(for window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = apsaText("Clear All History?")
        alert.informativeText = apsaText("Records of visited pages will be removed from this Mac. This can't be undone.")
        alert.addButton(withTitle: apsaText("Clear")).hasDestructiveAction = true
        alert.addButton(withTitle: apsaText("Cancel"))
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { ApsaHistoryStore.shared.clear() }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }

    private func rebuild() {
        let palette = ApsaThemeStore.shared.selected.palette
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let found = store.search(search.stringValue)
        guard !found.isEmpty else {
            let empty = NSTextField(labelWithString: store.entries.isEmpty ? apsaText("History is empty.") : apsaText("Nothing found."))
            empty.textColor = palette.secondary
            empty.font = .systemFont(ofSize: 14)
            list.addArrangedSubview(empty)
            return
        }
        let calendar = Calendar.current
        var day: Date?
        for entry in found {
            let start = calendar.startOfDay(for: entry.date)
            if start != day {
                day = start
                let title = calendar.isDateInToday(start) ? apsaText("Today") : calendar.isDateInYesterday(start) ? apsaText("Yesterday") : Self.dayFormatter.string(from: start)
                let label = NSTextField(labelWithString: title)
                label.font = .systemFont(ofSize: 13, weight: .semibold)
                label.textColor = palette.accent
                list.addArrangedSubview(label)
                list.setCustomSpacing(4, after: label)
                if list.arrangedSubviews.count > 1 { list.setCustomSpacing(16, after: list.arrangedSubviews[list.arrangedSubviews.count - 2]) }
            }
            let row = HistoryRow(entry: entry, time: Self.timeFormatter.string(from: entry.date), palette: palette, open: { [weak self] in
                if let url = URL(string: entry.url) { self?.navigate(url) }
            }, delete: { [weak self] in
                self?.store.remove(entry.id)
            })
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }
}
