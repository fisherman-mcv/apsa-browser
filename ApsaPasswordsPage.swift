import AppKit
import LocalAuthentication

private final class PasswordsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class PasswordRow: NSView {
    private let more: (NSView) -> Void

    init(login: ApsaSavedLogin, palette: ApsaPalette, more: @escaping (NSView) -> Void) {
        self.more = more
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let host = NSTextField(labelWithString: login.origin.display)
        host.font = .systemFont(ofSize: 14, weight: .medium)
        host.textColor = palette.text
        host.lineBreakMode = .byTruncatingTail
        let account = NSTextField(labelWithString: login.account.isEmpty ? apsaText("No Username") : login.account)
        account.font = .systemFont(ofSize: 11)
        account.textColor = palette.secondary
        account.lineBreakMode = .byTruncatingMiddle
        let actions = NSButton(title: "", target: self, action: #selector(showMore(_:)))
        actions.isBordered = false
        actions.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: apsaText("Password Actions"))
        actions.contentTintColor = palette.secondary
        actions.toolTip = apsaText("Password Actions")
        actions.setAccessibilityLabel(apsaText("Password Actions for %@", login.origin.display))
        for view in [host, account, actions] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -10),
            host.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            account.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            account.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -10),
            account.topAnchor.constraint(equalTo: host.bottomAnchor, constant: 1),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
            actions.widthAnchor.constraint(equalToConstant: 28), actions.heightAnchor.constraint(equalToConstant: 26)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func showMore(_ sender: NSView) { more(sender) }
    override func rightMouseDown(with event: NSEvent) { more(self) }
}

// browser://passwords. Seeing or copying a password asks for Touch ID or the Mac password.
final class ApsaPasswordsView: NSView, NSSearchFieldDelegate {
    private static let clipboardLifetime: TimeInterval = 60
    private let navigate: (URL) -> Void
    private let store = ApsaPasswordStore.shared
    private let search = NSSearchField()
    private let list = NSStackView()
    private var rebuildScheduled = false
    private var menuTarget: ApsaSavedLogin?

    init(navigate: @escaping (URL) -> Void) {
        self.navigate = navigate
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let palette = ApsaThemeStore.shared.selected.palette
        let heading = NSTextField(labelWithString: apsaText("Passwords"))
        heading.font = .systemFont(ofSize: 28, weight: .bold)
        heading.textColor = palette.text
        search.placeholderString = apsaText("Search Passwords")
        search.delegate = self
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsSearchStringImmediately = true
        search.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let add = NSButton(title: apsaText("Add…"), target: self, action: #selector(addLogin))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [heading, spacer, search, add])
        header.orientation = .horizontal
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = PasswordsDocumentView()
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
        NotificationCenter.default.addObserver(self, selector: #selector(passwordsChanged), name: ApsaPasswordStore.changed, object: nil)
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    func focusSearch() {
        window?.makeFirstResponder(search)
        search.currentEditor()?.selectAll(nil)
    }

    @objc private func searchChanged() { rebuild() }

    @objc private func passwordsChanged() {
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
            let empty = NSTextField(labelWithString: search.stringValue.isEmpty ? apsaText("No passwords yet. The browser will offer to save one after you sign in to a site.") : apsaText("Nothing found."))
            empty.textColor = palette.secondary
            empty.font = .systemFont(ofSize: 14)
            list.addArrangedSubview(empty)
            return
        }
        for login in found {
            let row = PasswordRow(login: login, palette: palette) { [weak self] view in self?.showMenu(for: login, in: view) }
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }

    private func showMenu(for login: ApsaSavedLogin, in view: NSView) {
        guard let window = view.window else { return }
        menuTarget = login
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, action) in [(apsaText("Open Site"), #selector(openSite)), (apsaText("Show Password…"), #selector(reveal)), (apsaText("Copy Username"), #selector(copyAccount)),
                                (apsaText("Copy Password…"), #selector(copyPassword)), (apsaText("Delete…"), #selector(removeLogin))] as [(String, Selector)] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: view.convert(window.mouseLocationOutsideOfEventStream, from: nil), in: view)
    }

    private func authenticated(_ reason: String, then action: @escaping () -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            showNotice(apsaText("Mac Protection Is Unavailable"), apsaText("To view passwords, set a login password on your Mac."))
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            if success { DispatchQueue.main.async(execute: action) }
        }
    }

    private func showNotice(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    @objc private func openSite() {
        if let url = menuTarget?.origin.url { navigate(url) }
    }

    @objc private func reveal() {
        guard let login = menuTarget else { return }
        authenticated(apsaText("show a saved password")) { [weak self] in
            guard let self, let password = self.store.password(for: login) else { return }
            self.showNotice(apsaText("Password for %@", login.origin.display), password)
        }
    }

    @objc private func copyAccount() {
        guard let login = menuTarget else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(login.account, forType: .string)
    }

    @objc private func copyPassword() {
        guard let login = menuTarget else { return }
        authenticated(apsaText("copy a saved password")) { [weak self] in
            guard let self, let password = self.store.password(for: login) else { return }
            let board = NSPasteboard.general
            board.clearContents()
            // Clipboard managers honor this marker and skip the value.
            board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            board.setString(password, forType: .string)
            let change = board.changeCount
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.clipboardLifetime) {
                if board.changeCount == change { board.clearContents() }
            }
        }
    }

    @objc private func removeLogin() {
        guard let login = menuTarget, let window else { return }
        let alert = NSAlert()
        alert.messageText = apsaText("Delete Password for %@?", login.origin.display)
        alert.informativeText = login.account
        alert.addButton(withTitle: apsaText("Delete")).hasDestructiveAction = true
        alert.addButton(withTitle: apsaText("Cancel"))
        alert.beginSheetModal(for: window) { [store] response in
            if response == .alertFirstButtonReturn { store.remove(login) }
        }
    }

    @objc private func addLogin() {
        guard let window else { return }
        let site = NSTextField(frame: NSRect(x: 0, y: 64, width: 300, height: 24))
        site.placeholderString = apsaText("Site, for example example.com")
        let account = NSTextField(frame: NSRect(x: 0, y: 32, width: 300, height: 24))
        account.placeholderString = apsaText("Username")
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        password.placeholderString = apsaText("Password")
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 88))
        [site, account, password].forEach(fields.addSubview)
        let alert = NSAlert()
        alert.messageText = apsaText("New Password")
        alert.accessoryView = fields
        alert.addButton(withTitle: apsaText("Save"))
        alert.addButton(withTitle: apsaText("Cancel"))
        alert.window.initialFirstResponder = site
        alert.beginSheetModal(for: window) { [store, weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let raw = site.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw.contains("://") ? raw : "https://\(raw)"), let origin = ApsaPasswordOrigin(url: url), !password.stringValue.isEmpty else {
                self?.showNotice(apsaText("Password Not Saved"), apsaText("You need an HTTPS site address and the password itself."))
                return
            }
            store.save(ApsaSavedLogin(origin: origin, account: account.stringValue), password: password.stringValue)
        }
    }
}
