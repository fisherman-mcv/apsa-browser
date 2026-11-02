import AppKit

private func bookmarkIcon(_ bookmark: ApsaBookmark) -> NSImage? {
    guard let icon = bookmark.icon, let comma = icon.firstIndex(of: ","),
          let data = Data(base64Encoded: String(icon[icon.index(after: comma)...])) else { return nil }
    return NSImage(data: data)
}

func apsaAskForText(title: String, value: String, confirm: String, window: NSWindow?, done: @escaping (String) -> Void) {
    let alert = NSAlert()
    alert.messageText = title
    alert.addButton(withTitle: confirm)
    alert.addButton(withTitle: apsaText("Cancel"))
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    field.stringValue = value
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    let finish: (NSApplication.ModalResponse) -> Void = { response in
        if response == .alertFirstButtonReturn { done(field.stringValue) }
    }
    if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
    else { finish(alert.runModal()) }
}

// The same actions for a bookmark wherever it is shown.
final class ApsaBookmarkMenu: NSObject {
    private let id: UUID
    private let openInNewTab: (URL) -> Void
    private weak var window: NSWindow?
    private static var current: ApsaBookmarkMenu?

    private init(id: UUID, window: NSWindow?, openInNewTab: @escaping (URL) -> Void) {
        self.id = id
        self.window = window
        self.openInNewTab = openInNewTab
    }

    static func show(for id: UUID, in view: NSView, openInNewTab: @escaping (URL) -> Void) {
        guard let window = view.window, ApsaBookmarkStore.shared.bookmark(id: id) != nil else { return }
        let owner = ApsaBookmarkMenu(id: id, window: window, openInNewTab: openInNewTab)
        current = owner
        let location = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        owner.makeMenu().popUp(positioning: nil, at: location, in: view)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let store = ApsaBookmarkStore.shared
        func item(_ title: String, _ action: Selector, _ folder: String? = nil, on: Bool = false) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.representedObject = folder
            entry.state = on ? .on : .off
            return entry
        }
        menu.addItem(item(apsaText("Open in New Tab"), #selector(openTab)))
        menu.addItem(item(apsaText("Rename…"), #selector(rename)))
        let current = store.bookmark(id: id)?.folder
        let folders = NSMenu()
        folders.autoenablesItems = false
        folders.addItem(item(apsaText("No Folder"), #selector(moveToFolder(_:)), nil, on: current == nil))
        for folder in store.folders { folders.addItem(item(folder, #selector(moveToFolder(_:)), folder, on: folder == current)) }
        folders.addItem(.separator())
        folders.addItem(item(apsaText("New Folder…"), #selector(newFolder)))
        let move = NSMenuItem(title: apsaText("Move to Folder"), action: nil, keyEquivalent: "")
        move.submenu = folders
        menu.addItem(move)
        menu.addItem(.separator())
        menu.addItem(item(apsaText("Remove Bookmark"), #selector(remove)))
        return menu
    }

    @objc private func openTab() {
        if let raw = ApsaBookmarkStore.shared.bookmark(id: id)?.url, let url = URL(string: raw) { openInNewTab(url) }
    }
    @objc private func remove() { ApsaBookmarkStore.shared.remove(id) }
    @objc private func moveToFolder(_ sender: NSMenuItem) { ApsaBookmarkStore.shared.move(id, toFolder: sender.representedObject as? String) }
    @objc private func rename() {
        let id = self.id
        apsaAskForText(title: apsaText("Bookmark Name"), value: ApsaBookmarkStore.shared.bookmark(id: id)?.title ?? "", confirm: apsaText("Save"), window: window) {
            ApsaBookmarkStore.shared.rename(id, to: $0)
        }
    }
    @objc private func newFolder() {
        let id = self.id
        apsaAskForText(title: apsaText("New Folder"), value: "", confirm: apsaText("Create"), window: window) {
            ApsaBookmarkStore.shared.move(id, toFolder: $0)
        }
    }
}

private final class FlippedBookmarkDocument: NSView {
    override var isFlipped: Bool { true }
}

// A compact row in the sidebar: left click opens, right click shows the actions.
private final class SidebarBookmarkRow: NSView {
    private let open: () -> Void
    private let menuAction: (NSView) -> Void

    init(bookmark: ApsaBookmark, palette: ApsaPalette, open: @escaping () -> Void, menu: @escaping (NSView) -> Void) {
        self.open = open
        self.menuAction = menu
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let button = NSButton(title: "", target: self, action: #selector(activate))
        button.isBordered = false
        button.setAccessibilityLabel(bookmark.title)
        button.toolTip = bookmark.url
        let icon = NSImageView()
        if let image = bookmarkIcon(bookmark) {
            icon.image = image
        } else {
            icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            icon.contentTintColor = palette.secondary
        }
        icon.imageScaling = .scaleProportionallyDown
        let title = NSTextField(labelWithString: bookmark.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = palette.text
        title.lineBreakMode = .byTruncatingTail
        for view in [button, icon, title] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: ApsaBookmarksSection.rowHeight),
            button.topAnchor.constraint(equalTo: topAnchor), button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor), button.trailingAnchor.constraint(equalTo: trailingAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 11),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func activate() { open() }
    override func rightMouseDown(with event: NSEvent) { menuAction(self) }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

// The block above the tabs. It takes no room at all until there is a bookmark.
final class ApsaBookmarksSection: NSView {
    static let rowHeight: CGFloat = 30
    static let folderHeight: CGFloat = 22
    static let maximumListHeight: CGFloat = 240
    static let maximumRows = 200

    var open: (URL) -> Void = { _ in }
    var openInNewTab: (URL) -> Void = { _ in }
    private let store = ApsaBookmarkStore.shared
    private let title = NSTextField(labelWithString: apsaText("Bookmarks"))
    private let toggle = NSButton()
    private let scroll = NSScrollView()
    private let list = NSStackView()
    private var heightConstraint: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        toggle.isBordered = false
        toggle.target = self
        toggle.action = #selector(toggleCollapsed)
        toggle.toolTip = apsaText("Collapse or Expand Bookmarks")
        toggle.setAccessibilityLabel(apsaText("Collapse or Expand Bookmarks"))
        toggle.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedBookmarkDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        addSubview(title)
        addSubview(toggle)
        addSubview(scroll)
        let height = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint = height
        // Collapsed, the list has no room; it must not push the title out of place.
        let listBottom = scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        listBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            height,
            title.topAnchor.constraint(equalTo: topAnchor, constant: 17),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            toggle.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            toggle.widthAnchor.constraint(equalToConstant: 24), toggle.heightAnchor.constraint(equalToConstant: 24),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 9),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            listBottom,
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggleCollapsed() { store.collapsed.toggle() }

    func refresh() {
        let palette = ApsaThemeStore.shared.selected.palette
        title.textColor = palette.secondary
        toggle.contentTintColor = palette.accent
        toggle.image = NSImage(systemSymbolName: store.collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !store.bookmarks.isEmpty else { heightConstraint?.constant = 0; return }
        var used: CGFloat = 0
        var rows = 0
        for group in store.grouped where rows < Self.maximumRows {
            if let folder = group.folder {
                let label = NSTextField(labelWithString: folder)
                label.font = .systemFont(ofSize: 11, weight: .semibold)
                label.textColor = palette.secondary
                label.lineBreakMode = .byTruncatingTail
                label.heightAnchor.constraint(equalToConstant: Self.folderHeight - 2).isActive = true
                list.addArrangedSubview(label)
                used += Self.folderHeight
            }
            for bookmark in group.items.prefix(Self.maximumRows - rows) {
                let id = bookmark.id
                let row = SidebarBookmarkRow(bookmark: bookmark, palette: palette, open: { [weak self] in
                    if let url = URL(string: bookmark.url) { self?.open(url) }
                }, menu: { [weak self] view in
                    ApsaBookmarkMenu.show(for: id, in: view) { self?.openInNewTab($0) }
                })
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
                used += Self.rowHeight + 2
                rows += 1
            }
        }
        scroll.isHidden = store.collapsed
        heightConstraint?.constant = store.collapsed ? 17 + 15 : 17 + 15 + 9 + min(used, Self.maximumListHeight)
    }
}

// browser://bookmarks
private final class BookmarkPageRow: NSView {
    private let open: () -> Void
    private let more: (NSView) -> Void

    init(bookmark: ApsaBookmark, palette: ApsaPalette, open: @escaping () -> Void, more: @escaping (NSView) -> Void) {
        self.open = open
        self.more = more
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let main = NSButton(title: "", target: self, action: #selector(activate))
        main.isBordered = false
        main.setAccessibilityLabel(bookmark.title)
        main.toolTip = bookmark.url
        let icon = NSImageView()
        if let image = bookmarkIcon(bookmark) {
            icon.image = image
        } else {
            icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            icon.contentTintColor = palette.secondary
        }
        icon.imageScaling = .scaleProportionallyDown
        let title = NSTextField(labelWithString: bookmark.title)
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.textColor = palette.text
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: bookmark.url)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = palette.secondary
        detail.lineBreakMode = .byTruncatingMiddle
        let actions = NSButton(title: "", target: self, action: #selector(showMore(_:)))
        actions.isBordered = false
        actions.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: apsaText("Bookmark Actions"))
        actions.contentTintColor = palette.secondary
        actions.toolTip = apsaText("Bookmark Actions")
        actions.setAccessibilityLabel(apsaText("Bookmark Actions"))
        for view in [main, icon, title, detail, actions] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),
            main.topAnchor.constraint(equalTo: topAnchor), main.bottomAnchor.constraint(equalTo: bottomAnchor),
            main.leadingAnchor.constraint(equalTo: leadingAnchor), main.trailingAnchor.constraint(equalTo: trailingAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -10),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
            actions.widthAnchor.constraint(equalToConstant: 28), actions.heightAnchor.constraint(equalToConstant: 26)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func activate() { open() }
    @objc private func showMore(_ sender: NSView) { more(sender) }
    override func rightMouseDown(with event: NSEvent) { more(self) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

final class ApsaBookmarksView: NSView, NSSearchFieldDelegate {
    private let navigate: (URL) -> Void
    private let openInNewTab: (URL) -> Void
    private let store = ApsaBookmarkStore.shared
    private let search = NSSearchField()
    private let list = NSStackView()
    private var rebuildScheduled = false

    init(navigate: @escaping (URL) -> Void, openInNewTab: @escaping (URL) -> Void) {
        self.navigate = navigate
        self.openInNewTab = openInNewTab
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let palette = ApsaThemeStore.shared.selected.palette
        let heading = NSTextField(labelWithString: apsaText("Bookmarks"))
        heading.font = .systemFont(ofSize: 28, weight: .bold)
        heading.textColor = palette.text
        search.placeholderString = apsaText("Search Bookmarks")
        search.delegate = self
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsSearchStringImmediately = true
        search.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [heading, spacer, search])
        header.orientation = .horizontal
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedBookmarkDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        let scroll = NSScrollView()
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
        NotificationCenter.default.addObserver(self, selector: #selector(bookmarksChanged), name: ApsaBookmarkStore.changed, object: nil)
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    func focusSearch() {
        window?.makeFirstResponder(search)
        search.currentEditor()?.selectAll(nil)
    }

    @objc private func searchChanged() { rebuild() }

    @objc private func bookmarksChanged() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.rebuildScheduled = false
            self?.rebuild()
        }
    }

    private func rebuild() {
        let palette = ApsaThemeStore.shared.selected.palette
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let found = store.search(search.stringValue)
        guard !found.isEmpty else {
            let empty = NSTextField(labelWithString: store.bookmarks.isEmpty ? apsaText("No bookmarks yet. Press ⌘D or click the star in the address bar.") : apsaText("Nothing found."))
            empty.textColor = palette.secondary
            empty.font = .systemFont(ofSize: 14)
            list.addArrangedSubview(empty)
            return
        }
        let ids = Set(found.map(\.id))
        for group in store.grouped {
            let items = group.items.filter { ids.contains($0.id) }
            guard !items.isEmpty else { continue }
            if let folder = group.folder {
                if let last = list.arrangedSubviews.last { list.setCustomSpacing(16, after: last) }
                let label = NSTextField(labelWithString: folder)
                label.font = .systemFont(ofSize: 13, weight: .semibold)
                label.textColor = palette.accent
                list.addArrangedSubview(label)
                list.setCustomSpacing(4, after: label)
            }
            for bookmark in items {
                let id = bookmark.id
                let row = BookmarkPageRow(bookmark: bookmark, palette: palette, open: { [weak self] in
                    if let url = URL(string: bookmark.url) { self?.navigate(url) }
                }, more: { [weak self] view in
                    ApsaBookmarkMenu.show(for: id, in: view) { self?.openInNewTab($0) }
                })
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
        }
    }
}
