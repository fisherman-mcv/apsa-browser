import AppKit
import WebKit
import UniformTypeIdentifiers
import ImageIO

private let appName = "Apsa Browser"
private let homeURL = URL(string: "browser://home")!

private enum SurfaceKind: Equatable {
    case internalPage
    case web
}

private func surfaceKind(for url: URL) -> SurfaceKind? {
    switch url.scheme?.lowercased() {
    case "browser": return .internalPage
    case "http", "https", ApsaAllod.scheme: return .web
    case "file" where ["html", "htm", "xhtml"].contains(url.pathExtension.lowercased()): return .web
    default: return nil
    }
}

private let allodSchemeHandler = ApsaAllodSchemeHandler()

private func normalizedURL(_ rawValue: String) -> URL? {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    if value.hasPrefix("/") { return URL(fileURLWithPath: value) }
    if let url = URL(string: value), surfaceKind(for: url) != nil { return url }
    if !value.contains(" "), let url = URL(string: "https://\(value)"), url.host != nil { return url }
    var search = URLComponents(string: "https://duckduckgo.com/")
    search?.queryItems = [URLQueryItem(name: "q", value: value)]
    return search?.url
}

private final class ClosureButton: NSButton {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        target = self
        action = #selector(invoke)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
}

private final class TrafficLightButton: NSButton {
    enum Kind {
        case close, minimize, zoom

        var color: NSColor {
            switch self {
            case .close: return NSColor(srgbRed: 1.00, green: 0.37, blue: 0.34, alpha: 1)
            case .minimize: return NSColor(srgbRed: 1.00, green: 0.74, blue: 0.18, alpha: 1)
            case .zoom: return NSColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1)
            }
        }

        var symbol: String {
            switch self {
            case .close: return "xmark"
            case .minimize: return "minus"
            case .zoom: return "arrow.up.left.and.arrow.down.right"
            }
        }

        var label: String {
            switch self {
            case .close: return apsaText("Close Window")
            case .minimize: return apsaText("Minimize Window")
            case .zoom: return apsaText("Enter Full Screen")
            }
        }
    }

    private let kind: Kind
    private var windowActive = true
    private var glyphVisible = false

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setAccessibilityLabel(kind.label)
        toolTip = kind.label
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The system shows all three glyphs together when the pointer is over the group.
    func setGlyphVisible(_ visible: Bool) {
        glyphVisible = visible
        needsDisplay = true
    }

    func setWindowActive(_ active: Bool) {
        windowActive = active
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill = windowActive || glyphVisible ? kind.color : NSColor(calibratedWhite: 0.5, alpha: 0.55)
        let rim = windowActive || glyphVisible ? fill.blended(withFraction: 0.3, of: .black) ?? fill : NSColor.black.withAlphaComponent(0.35)
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.25, dy: 0.25))
        fill.setFill()
        circle.fill()
        rim.setStroke()
        circle.lineWidth = 0.5
        circle.stroke()
        if isHighlighted {
            NSColor.black.withAlphaComponent(0.2).setFill()
            circle.fill()
        }
        guard glyphVisible else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: kind == .zoom ? 7 : 8, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.black.withAlphaComponent(0.6)]))
        guard let glyph = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        glyph.draw(in: NSRect(x: (bounds.width - glyph.size.width) / 2, y: (bounds.height - glyph.size.height) / 2, width: glyph.size.width, height: glyph.size.height))
    }
}

private final class TrafficLightHoverArea: NSView {
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

private final class TabFolderRow: NSView {
    private let toggle: () -> Void
    private let showMenu: (NSView) -> Void

    init(folder: ApsaTabFolder, count: Int, toggle: @escaping () -> Void, menu: @escaping (NSView) -> Void) {
        self.toggle = toggle
        showMenu = menu
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let palette = ApsaThemeStore.shared.selected.palette
        let button = NSButton(title: "", target: self, action: #selector(activate))
        button.isBordered = false
        button.setAccessibilityLabel(folder.name)
        let chevron = NSImageView(image: NSImage(systemSymbolName: folder.collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil) ?? NSImage())
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        chevron.contentTintColor = palette.accent
        let name = NSTextField(labelWithString: folder.name)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.textColor = palette.text
        name.lineBreakMode = .byTruncatingTail
        let number = NSTextField(labelWithString: String(count))
        number.font = .systemFont(ofSize: 11)
        number.textColor = palette.secondary
        for view in [button, chevron, name, number] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            button.topAnchor.constraint(equalTo: topAnchor), button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor), button.trailingAnchor.constraint(equalTo: trailingAnchor),
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 18),
            name.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 6),
            name.trailingAnchor.constraint(lessThanOrEqualTo: number.leadingAnchor, constant: -6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            number.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            number.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func activate() { toggle() }
    override func rightMouseDown(with event: NSEvent) { showMenu(self) }
}

// In WebView mode the hidden native controls stay the source of truth, so every
// place that updates them reaches the interface without knowing it exists.
private final class MirroredTextField: NSTextField {
    var onChange: (() -> Void)?
    override var stringValue: String { didSet { onChange?() } }
    // The first click selects the whole address; later clicks place the caret.
    // The click sets the caret while the button is down, so select after release.
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, NSApp.currentEvent?.type == .leftMouseDown { selectAfterRelease() }
        return accepted
    }

    private func selectAfterRelease() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            if NSEvent.pressedMouseButtons != 0 { self?.selectAfterRelease() }
            else { self?.currentEditor()?.selectAll(nil) }
        }
    }
}

private final class MirroredButton: NSButton {
    var onChange: (() -> Void)?
    override var isEnabled: Bool { didSet { onChange?() } }
    override var toolTip: String? { didSet { onChange?() } }
}

private final class BrowserTab {
    let id: UUID
    // Kept detached when the tab is in the background: not rendered, throttled by
    // WebKit, and its audio keeps playing.
    var parked: WKWebView?
    var folder: UUID?
    var lastActive = Date()
    var url: URL
    var title: String
    var icon: NSImage? { didSet { cachedIconDataURL = nil } }
    private var cachedIconDataURL: String?
    var iconDataURL: String? {
        if cachedIconDataURL == nil, let icon { cachedIconDataURL = ApsaChromeController.faviconDataURL(icon) }
        return cachedIconDataURL
    }
    var history = ApsaNavigationHistory()

    init(url: URL, title: String? = nil, id: UUID = UUID()) {
        self.id = id
        self.url = url
        self.title = title ?? (url.scheme == "browser" ? apsaInternalPageTitle(url.host) : url.host ?? apsaText("New Tab"))
    }
}

func apsaInternalPageTitle(_ route: String?) -> String {
    switch route {
    case "about": return apsaText("About the Browser")
    case "history": return apsaText("History")
    case "bookmarks": return apsaText("Bookmarks")
    case "passwords": return apsaText("Passwords")
    default: return apsaText("New Tab")
    }
}

private final class VerticalTabRow: NSView {
    private let selectionButton: ClosureButton
    private let closeButton: ClosureButton
    private let showMenu: (NSView) -> Void

    override func rightMouseDown(with event: NSEvent) { showMenu(self) }

    init(tab: BrowserTab, selected: Bool, nested: Bool, select: @escaping () -> Void, close: @escaping () -> Void, menu: @escaping (NSView) -> Void) {
        showMenu = menu
        selectionButton = ClosureButton(title: "", handler: select)
        closeButton = ClosureButton(title: "", handler: close)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.backgroundColor = selected
            ? ApsaThemeStore.shared.selected.palette.accent.withAlphaComponent(0.14).cgColor
            : NSColor.clear.cgColor

        selectionButton.isBordered = false
        selectionButton.translatesAutoresizingMaskIntoConstraints = false
        selectionButton.setAccessibilityLabel(tab.title)
        selectionButton.setAccessibilityRole(.radioButton)
        selectionButton.setAccessibilityValue(selected ? "selected" : "")
        addSubview(selectionButton)

        let icon = NSImageView()
        icon.image = tab.icon ?? NSImage(systemSymbolName: tab.url.scheme == "browser" ? "house" : "globe", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let palette = ApsaThemeStore.shared.selected.palette
        // Website artwork keeps its original colors; system/template icons follow the theme.
        icon.contentTintColor = tab.icon == nil || tab.icon?.isTemplate == true
            ? (selected ? palette.accent : palette.secondary)
            : nil
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        let title = NSTextField(labelWithString: tab.title)
        title.font = NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .medium)
        title.textColor = ApsaThemeStore.shared.selected.palette.text
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        let detail = NSTextField(labelWithString: Self.detail(for: tab.url))
        detail.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        detail.textColor = ApsaThemeStore.shared.selected.palette.secondary
        detail.lineBreakMode = .byTruncatingMiddle
        detail.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detail)

        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: apsaText("Close Tab"))
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        closeButton.contentTintColor = ApsaThemeStore.shared.selected.palette.secondary
        closeButton.toolTip = apsaText("Close Tab")
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 52),
            selectionButton.topAnchor.constraint(equalTo: topAnchor),
            selectionButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            selectionButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            selectionButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: nested ? 23 : 11),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            title.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -5),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -5),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    fileprivate static func detail(for url: URL) -> String {
        if url.scheme == "browser" { return url.host == "home" ? apsaText("Start Page") : apsaText("Browser") }
        if url.isFileURL { return url.lastPathComponent }
        let host = url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
        return host
    }
}

private final class NativeApsaPage: NSView {
    private let pageSelection = ApsaPageSelection()
    private let accent = ApsaThemeStore.shared.selected.palette.accent
    private let ink = ApsaThemeStore.shared.selected.palette.text
    private let muted = ApsaThemeStore.shared.selected.palette.secondary
    private var historyView: ApsaHistoryView?
    private var bookmarksView: ApsaBookmarksView?
    private var passwordsView: ApsaPasswordsView?

    init(url: URL, navigate: @escaping (URL) -> Void, openInNewTab: @escaping (URL) -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let route = url.host?.lowercased() ?? "home"
        if route == "history" || route == "bookmarks" || route == "passwords" {
            let view: NSView
            if route == "history" {
                let page = ApsaHistoryView(navigate: navigate)
                historyView = page
                view = page
            } else if route == "passwords" {
                let page = ApsaPasswordsView(navigate: navigate)
                passwordsView = page
                view = page
            } else {
                let page = ApsaBookmarksView(navigate: navigate, openInNewTab: openInNewTab)
                bookmarksView = page
                view = page
            }
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor)
            ])
            return
        }
        let card = ApsaGlassView()
        card.material = .popover
        card.blendingMode = .withinWindow
        card.wantsLayer = true
        card.applyTint(ApsaThemeStore.shared.selected.glassTint, opacity: 0.38)
        card.layer?.cornerRadius = 28
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = ApsaThemeStore.shared.selected.palette.line.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        card.addSubview(stack)

        switch route {
        case "home", "":
            stack.addArrangedSubview(label(apsaText("Less browser.\nMore page."), size: 52, weight: .bold, color: ink))
            stack.addArrangedSubview(label(
                apsaText("System WebKit, with bookmarks, history and passwords on this Mac."),
                size: 20, color: muted
            ))

            let actions = NSStackView()
            actions.orientation = .horizontal
            actions.spacing = 12
            actions.distribution = .fillEqually
            actions.translatesAutoresizingMaskIntoConstraints = false
            actions.addArrangedSubview(action(apsaText("Open example.com  →")) {
                navigate(URL(string: "https://example.com/")!)
            })
            actions.addArrangedSubview(action(apsaText("About the Browser  →")) {
                navigate(URL(string: "browser://about")!)
            })
            stack.addArrangedSubview(actions)
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

            stack.addArrangedSubview(label(
                apsaText("⌘L — address or search"),
                size: 13, color: muted
            ))

        case "about":
            stack.addArrangedSubview(label("Apsa Browser", size: 32, weight: .medium, color: ink))
            stack.addArrangedSubview(label(
                apsaText("A browser on the system WebKit. Bookmarks, history and your session stay on this Mac, and passwords are kept in the macOS keychain."),
                size: 20, color: muted
            ))
            stack.addArrangedSubview(action(apsaText("Go to Start Page")) { navigate(homeURL) })

        default:
            stack.addArrangedSubview(label(apsaText("Page Not Found"), size: 32, weight: .medium, color: ink))
            stack.addArrangedSubview(label(url.absoluteString, size: 16, color: muted))
            stack.addArrangedSubview(action(apsaText("Go to Start Page")) { navigate(homeURL) })
        }

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 28),
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 920),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 42),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 42),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -42),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -38),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 820)
        ])
        pageSelection.attach(to: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func focusPageSearch() -> Bool {
        if let historyView { historyView.focusSearch(); return true }
        if let bookmarksView { bookmarksView.focusSearch(); return true }
        if let passwordsView { passwordsView.focusSearch(); return true }
        return false
    }

    private func label(
        _ value: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor,
        monospaced: Bool = false
    ) -> ApsaSelectableTextView {
        let field = ApsaSelectableTextView(NSAttributedString(string: value))
        field.font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func action(_ title: String, handler: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: title, handler: handler)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = accent.withAlphaComponent(0.92).cgColor
        button.layer?.cornerRadius = 13
        button.controlSize = .large
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: ApsaThemeStore.shared.selected.isLight ? NSColor.white : ApsaThemeStore.shared.selected.palette.background
        ])
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return button
    }


}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

// Favicons load with no cookies, so fetching one cannot identify the person to the site.
private let faviconSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    return URLSession(configuration: configuration)
}()

private let faviconCache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 128
    cache.totalCostLimit = 8 * 1_024 * 1_024
    return cache
}()

// A favicon is drawn at 18 points, whatever size the site serves.
private func downsampledFavicon(_ data: Data) -> NSImage? {
    let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64,
                   kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
    if let source = CGImageSourceCreateWithData(data as CFData, nil),
       let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) {
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
    return NSImage(data: data)
}

private let safariUserAgentSuffix: String = {
    let installed = Bundle(path: "/Applications/Safari.app")?.infoDictionary?["CFBundleShortVersionString"] as? String
    return "Version/\(installed ?? "18.0") Safari/605.1.15"
}()

private final class BrowserWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
    private let rootMaterial = ApsaGlassView()
    private let toolbar = ApsaGlassView()
    private let sidebar = ApsaGlassView()
    private let tabsScroll = NSScrollView()
    private let tabsDocument = FlippedDocumentView()
    private let tabStack = NSStackView()
    private let contentContainer = ApsaNavigationSurface()
    private let addressField = MirroredTextField()
    private let addressCapsule = ApsaGlassView()
    private let addressSlot = NSView()
    private let sidebarButton = NSButton()
    private let backButton = MirroredButton()
    private let forwardButton = MirroredButton()
    private let reloadButton = MirroredButton()
    private let readerButton = MirroredButton()
    private let settingsButton = NSButton()
    private let starButton = NSButton()
    private let shieldButton = NSButton()
    private let translateButton = NSButton()
    private let addressToolsToggle = NSButton()
    private let addressToolsStack = NSStackView()
    private static let addressToolsKey = "apsa-browser-address-tools-expanded"
    private static let addressToolsChanged = Notification.Name("ApsaAddressToolsChanged")
    private static var addressToolsExpanded: Bool { UserDefaults.standard.bool(forKey: addressToolsKey) }
    private var pageTranslatorStorage: AnyObject?
    @available(macOS 15.0, *)
    private var pageTranslator: ApsaPageTranslator? {
        if let existing = pageTranslatorStorage as? ApsaPageTranslator { return existing }
        guard let created = ApsaPageTranslator() else { return nil }
        created.engine.onFailure = { [weak self] error in self?.translationFailed(error) }
        pageTranslatorStorage = created
        return created
    }

    // The SwiftUI host joins the window only once someone actually translates.
    @available(macOS 15.0, *)
    private func attachTranslationHost(_ translator: ApsaPageTranslator) {
        guard translator.hostView.superview == nil else { return }
        translator.hostView.translatesAutoresizingMaskIntoConstraints = false
        rootMaterial.addSubview(translator.hostView)
        NSLayoutConstraint.activate([
            translator.hostView.widthAnchor.constraint(equalToConstant: 1), translator.hostView.heightAnchor.constraint(equalToConstant: 1),
            translator.hostView.topAnchor.constraint(equalTo: contentContainer.topAnchor), translator.hostView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor)
        ])
    }
    private let bookmarksSection = ApsaBookmarksSection()
    private var settingsWindow: ApsaSettingsWindow?
    private var chrome: ApsaChromeController?
    private var webChromeVisible = false
    private var chromeSyncScheduled = false
    private var controlsView: NSView?
    private var tabFolders: [ApsaTabFolder] = []
    private var menuTabID: UUID?
    private var menuFolderID: UUID?
    var onSessionChange: (() -> Void)?
    private var tabsRenderScheduled = false
    private var lastTabsSnapshot = ""
    private let findBar = ApsaFindBar()
    private let passwordAutofill = ApsaPasswordAutofill()
    private var upgradedToHTTPS: [ObjectIdentifier: URL] = [:]
    private var insecureAllowedHosts = Set<String>()
    private let fastFullscreenHandler = ApsaFastFullscreenHandler()
    private var fullscreenTransitioning = false
    private var fullscreenGeneration = 0
    private var frameBeforeFullscreen: NSRect?
    private weak var fastFullscreenView: WKWebView?
    private var fastFullscreenFrame: NSRect?
    private var toolbarTopConstraint: NSLayoutConstraint?
    private var toolbarVisible = true
    private var sidebarBeforeHidingToolbar = true
    private var closedTabURLs: [URL] = []
    private var pageZoom = ApsaPageZoom.saved()
    var onBecameActive: ((BrowserWindowController) -> Void)?
    var onClosed: ((BrowserWindowController) -> Void)?
    private var tabsTitleLabel: NSView?
    private let newTabButton = NSButton()
    private let closeTrafficLight = TrafficLightButton(kind: .close)
    private let minimizeTrafficLight = TrafficLightButton(kind: .minimize)
    private let zoomTrafficLight = TrafficLightButton(kind: .zoom)
    private let progress = ApsaProgressBar()
    private var addressTopConstraint: NSLayoutConstraint?
    private var addressBottomConstraint: NSLayoutConstraint?
    private var controlsTrailingConstraint: NSLayoutConstraint?
    private var transparentTitlebarOffset: CGFloat = 0
    private var trafficLightsConfigured = false
    private let trafficLightHover = TrafficLightHoverArea()
    // NSWindow's visible right stroke sits one point outside contentView.
    // Keep this separate from the user-controlled optical inset.
    private let windowRightStrokeCompensation: CGFloat = 1
    private var chromeInset = CGFloat(max(4, min(14, UserDefaults.standard.double(forKey: "apsa-browser-chrome-inset") == 0
        ? 6 : UserDefaults.standard.double(forKey: "apsa-browser-chrome-inset"))))
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var sidebarVisible = true
    private var tabs: [BrowserTab] = []
    private var activeTabID: UUID?
    private var faviconTask: URLSessionDataTask?
    private var nativePage: NativeApsaPage?
    private var readerPage: ApsaReaderPage?
    private var readerSourceURL: URL?
    private var webView: WKWebView?
    private var observations: [NSKeyValueObservation] = []
    private var currentURL = homeURL
    private var compiling = false
    private var readerResources: ApsaReaderResources?

    let isPrivate: Bool
    // A private window has its own store in memory, gone when the window closes.
    private lazy var privateDataStore = WKWebsiteDataStore.nonPersistent()

    init(initialURL: URL, cascadingFrom previousFrame: NSRect? = nil, restoring saved: ApsaSavedWindow? = nil, isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = appName
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 560, height: 460)
        window.center()
        if let previousFrame { window.setFrameTopLeftPoint(NSPoint(x: previousFrame.minX + 28, y: previousFrame.maxY - 28)) }
        super.init(window: window)
        window.delegate = self

        configureInterface()
        contentContainer.canGoBack = { [weak self] in self?.activeTab?.history.canGoBack ?? false }
        contentContainer.canGoForward = { [weak self] in self?.activeTab?.history.canGoForward ?? false }
        contentContainer.webKitCanNavigate = { [weak self] offset in
            offset < 0 ? (self?.webView?.canGoBack ?? false) : (self?.webView?.canGoForward ?? false)
        }
        contentContainer.navigate = { [weak self] offset in self?.navigateHistory(offset) }
        NotificationCenter.default.addObserver(self, selector: #selector(applyBrowserTheme), name: ApsaThemeStore.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applyChromeMode), name: ApsaThemeStore.chromeModeChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(bookmarksChanged), name: ApsaBookmarkStore.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(blockingChanged(_:)), name: ApsaContentBlocker.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(privacyChanged), name: ApsaPrivacyStore.changed, object: nil)
        applyBrowserTheme()
        bookmarksSection.refresh()
        if let saved, restore(saved, in: window) {
            applyChromeMode()
        } else {
            let firstTab = BrowserTab(url: initialURL)
            tabs = [firstTab]
            activeTabID = firstTab.id
            renderTabs()
            navigate(to: initialURL)
            applyChromeMode()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureInterface() {
        guard let window, let content = window.contentView else { return }
        // AppKit's content coordinates begin below the traffic-light strip even
        // with a transparent titlebar. Pull the material upward by that exact
        // system-owned height so our controls share the traffic lights' axis.
        let titlebarOverlap = max(0, window.frame.height - window.contentLayoutRect.height)
        let titlebarControlOffset = titlebarOverlap / 2
        transparentTitlebarOffset = titlebarControlOffset
        rootMaterial.material = .underWindowBackground
        rootMaterial.blendingMode = .behindWindow
        rootMaterial.state = .active
        rootMaterial.translatesAutoresizingMaskIntoConstraints = false

        toolbar.material = .headerView
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        sidebar.material = .sidebar
        sidebar.blendingMode = .withinWindow
        sidebar.state = .active
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.wantsLayer = true
        sidebar.layer?.shadowColor = NSColor.black.cgColor
        sidebar.layer?.shadowOpacity = 0.10
        sidebar.layer?.shadowRadius = 14
        sidebar.layer?.shadowOffset = NSSize(width: 4, height: 0)

        configureButton(sidebarButton, symbol: "sidebar.left", action: #selector(toggleSidebar), help: apsaText("Show or Hide Tabs"))
        configureButton(backButton, symbol: "chevron.left", action: #selector(goBack), help: apsaText("Back"))
        configureButton(forwardButton, symbol: "chevron.right", action: #selector(goForward), help: apsaText("Forward"))
        configureButton(reloadButton, symbol: "arrow.clockwise", action: #selector(reload), help: apsaText("Reload"))
        configureButton(readerButton, symbol: "doc.plaintext", action: #selector(toggleReader), help: apsaText("Reader Mode"))
        readerButton.contentTintColor = ApsaThemeStore.shared.selected.palette.accent
        readerButton.isEnabled = false
        configureButton(newTabButton, symbol: "plus", action: #selector(newTab), help: apsaText("New Tab"))
        configureButton(settingsButton, symbol: "gearshape", action: #selector(showSettings), help: apsaText("Settings"))
        configureButton(starButton, symbol: "star", action: #selector(toggleBookmark), help: apsaText("Add Bookmark"))
        configureButton(translateButton, symbol: "translate", action: #selector(toggleTranslation), help: apsaText("Translate Page"))
        translateButton.isHidden = !Self.translationAvailable
        configureButton(shieldButton, symbol: "shield.lefthalf.filled", action: #selector(toggleSiteBlocking), help: apsaText("Ad Blocking on This Site"))
        bookmarksSection.open = { [weak self] in self?.navigate(to: $0) }
        bookmarksSection.openInNewTab = { [weak self] in self?.openInNewTab($0) }
        addressField.onChange = { [weak self] in self?.scheduleChromeSync() }
        for button in [backButton, forwardButton, reloadButton, readerButton] { button.onChange = { [weak self] in self?.scheduleChromeSync() } }

        addressField.placeholderString = isPrivate ? apsaText("Private window · address or search") : apsaText("Address or search")
        addressField.font = NSFont.systemFont(ofSize: 13.5, weight: .medium)
        addressField.isBezeled = false
        addressField.drawsBackground = false
        addressField.focusRingType = .none
        addressField.target = self
        addressField.action = #selector(openAddress)
        addressField.delegate = self

        addressCapsule.material = .popover
        addressCapsule.blendingMode = .withinWindow
        addressCapsule.state = .active
        addressCapsule.translatesAutoresizingMaskIntoConstraints = false
        addressCapsule.wantsLayer = true
        addressCapsule.layer?.cornerRadius = 12
        addressCapsule.layer?.masksToBounds = true
        addressCapsule.layer?.borderWidth = 0.5
        addressCapsule.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressCapsule.addSubview(addressField)
        configureButton(addressToolsToggle, symbol: "chevron.left", action: #selector(toggleAddressTools), help: apsaText("Show Buttons"))
        addressToolsStack.orientation = .horizontal
        addressToolsStack.spacing = 0
        for button in [translateButton, shieldButton, starButton, readerButton] { addressToolsStack.addArrangedSubview(button) }
        let addressTools = NSStackView(views: [addressToolsStack, addressToolsToggle])
        addressTools.orientation = .horizontal
        addressTools.spacing = 0
        addressTools.setContentHuggingPriority(.required, for: .horizontal)
        addressTools.translatesAutoresizingMaskIntoConstraints = false
        addressCapsule.addSubview(addressTools)
        applyAddressToolsState(animated: false)
        NotificationCenter.default.addObserver(self, selector: #selector(addressToolsChanged), name: Self.addressToolsChanged, object: nil)
        addressSlot.translatesAutoresizingMaskIntoConstraints = false
        addressSlot.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addressSlot.addSubview(addressCapsule)

        let tabsTitle = NSTextField(labelWithString: apsaText("Tabs"))
        tabsTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        tabsTitle.textColor = .secondaryLabelColor
        tabsTitle.translatesAutoresizingMaskIntoConstraints = false
        tabStack.orientation = .vertical
        tabStack.alignment = .leading
        tabStack.spacing = 4
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        tabsScroll.drawsBackground = false
        tabsScroll.hasVerticalScroller = true
        tabsScroll.autohidesScrollers = true
        tabsScroll.translatesAutoresizingMaskIntoConstraints = false
        tabsDocument.translatesAutoresizingMaskIntoConstraints = false
        tabsScroll.documentView = tabsDocument
        tabsDocument.addSubview(tabStack)
        sidebar.addSubview(bookmarksSection)
        sidebar.addSubview(tabsTitle)
        sidebar.addSubview(newTabButton)
        sidebar.addSubview(tabsScroll)

        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.isHidden = true

        let controls = NSStackView(views: [sidebarButton, backButton, forwardButton, reloadButton, settingsButton, addressSlot])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        controlsView = controls
        tabsTitleLabel = tabsTitle
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = NSColor.clear.cgColor

        content.addSubview(rootMaterial)
        rootMaterial.addSubview(toolbar)
        toolbar.addSubview(controls)
        toolbar.addSubview(progress)
        rootMaterial.addSubview(contentContainer)
        rootMaterial.addSubview(sidebar)
        rootMaterial.addSubview(findBar)

        let sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: 238)
        let contentLeading = contentContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor)
        let addressTop = addressCapsule.topAnchor.constraint(
            equalTo: toolbar.topAnchor,
            constant: transparentTitlebarOffset + chromeInset
        )
        let addressBottom = addressCapsule.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -chromeInset)
        let controlsTrailing = controls.trailingAnchor.constraint(
            equalTo: toolbar.trailingAnchor,
            constant: -(chromeInset + windowRightStrokeCompensation)
        )
        let toolbarTop = toolbar.topAnchor.constraint(equalTo: rootMaterial.topAnchor)
        toolbarTopConstraint = toolbarTop
        fastFullscreenHandler.onRequest = { [weak self] in self?.toggleFastFullscreen(for: $0) }
        passwordAutofill.isActive = { [weak self] in $0 === self?.webView }
        passwordAutofill.onShowManager = { [weak self] in self?.showPasswords() }
        findBar.webView = { [weak self] in self?.readerPage == nil ? self?.webView : nil }
        findBar.nativeRoot = { [weak self] in self?.contentContainer }
        findBar.onClose = { [weak self] in self?.window?.makeFirstResponder(self?.readerPage ?? self?.webView ?? self?.nativePage) }
        sidebarWidthConstraint = sidebarWidth
        addressTopConstraint = addressTop
        addressBottomConstraint = addressBottom
        controlsTrailingConstraint = controlsTrailing

        NSLayoutConstraint.activate([
            rootMaterial.topAnchor.constraint(equalTo: content.topAnchor, constant: -titlebarControlOffset),
            rootMaterial.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rootMaterial.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rootMaterial.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            toolbarTop,
            findBar.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 10),
            findBar.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -12),
            toolbar.leadingAnchor.constraint(equalTo: rootMaterial.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: rootMaterial.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 64),
            controls.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 78),
            controlsTrailing,
            controls.centerYAnchor.constraint(equalTo: addressCapsule.centerYAnchor),
            addressSlot.heightAnchor.constraint(equalToConstant: 24),
            addressSlot.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            addressCapsule.leadingAnchor.constraint(equalTo: addressSlot.leadingAnchor),
            addressCapsule.trailingAnchor.constraint(equalTo: addressSlot.trailingAnchor),
            addressTop,
            addressBottom,
            addressField.leadingAnchor.constraint(equalTo: addressCapsule.leadingAnchor, constant: 13),
            addressField.centerYAnchor.constraint(equalTo: addressCapsule.centerYAnchor),
            addressField.trailingAnchor.constraint(equalTo: addressTools.leadingAnchor, constant: -4),
            addressTools.trailingAnchor.constraint(equalTo: addressCapsule.trailingAnchor, constant: -5),
            addressTools.centerYAnchor.constraint(equalTo: addressCapsule.centerYAnchor),
            progress.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            progress.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),
            contentContainer.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            contentLeading,
            contentContainer.trailingAnchor.constraint(equalTo: rootMaterial.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: rootMaterial.bottomAnchor),
            sidebar.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: rootMaterial.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: rootMaterial.bottomAnchor),
            sidebarWidth,
            bookmarksSection.topAnchor.constraint(equalTo: sidebar.topAnchor),
            bookmarksSection.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            bookmarksSection.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            tabsTitle.topAnchor.constraint(equalTo: bookmarksSection.bottomAnchor, constant: 17),
            tabsTitle.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 15),
            newTabButton.centerYAnchor.constraint(equalTo: tabsTitle.centerYAnchor),
            newTabButton.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            tabsScroll.topAnchor.constraint(equalTo: tabsTitle.bottomAnchor, constant: 9),
            tabsScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            tabsScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            tabsScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -8),
            tabsDocument.widthAnchor.constraint(equalTo: tabsScroll.contentView.widthAnchor),
            tabStack.topAnchor.constraint(equalTo: tabsDocument.topAnchor, constant: 4),
            tabStack.leadingAnchor.constraint(equalTo: tabsDocument.leadingAnchor, constant: 8),
            tabStack.trailingAnchor.constraint(equalTo: tabsDocument.trailingAnchor, constant: -8),
            tabStack.bottomAnchor.constraint(equalTo: tabsDocument.bottomAnchor, constant: -8)
        ])
        updateResponsiveLayout(animated: false)
        configureTrafficLights()
    }

    private func configureTrafficLights() {
        guard let window else { return }
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = true
        }
        guard !trafficLightsConfigured else { return }
        closeTrafficLight.target = self
        closeTrafficLight.action = #selector(closeWindow)
        minimizeTrafficLight.target = self
        minimizeTrafficLight.action = #selector(minimizeWindow)
        zoomTrafficLight.target = self
        zoomTrafficLight.action = #selector(zoomWindow)
        for button in [closeTrafficLight, minimizeTrafficLight, zoomTrafficLight] { toolbar.addSubview(button) }
        trafficLightHover.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(trafficLightHover)
        trafficLightHover.onHover = { [weak self] hovering in
            guard let self else { return }
            for button in [self.closeTrafficLight, self.minimizeTrafficLight, self.zoomTrafficLight] { button.setGlyphVisible(hovering) }
        }
        // Same size and spacing as this system's own window buttons.
        NSLayoutConstraint.activate([
            trafficLightHover.leadingAnchor.constraint(equalTo: closeTrafficLight.leadingAnchor, constant: -2),
            trafficLightHover.trailingAnchor.constraint(equalTo: zoomTrafficLight.trailingAnchor, constant: 2),
            trafficLightHover.topAnchor.constraint(equalTo: closeTrafficLight.topAnchor, constant: -2),
            trafficLightHover.bottomAnchor.constraint(equalTo: closeTrafficLight.bottomAnchor, constant: 2),
            closeTrafficLight.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 9),
            closeTrafficLight.centerYAnchor.constraint(equalTo: addressCapsule.centerYAnchor),
            closeTrafficLight.widthAnchor.constraint(equalToConstant: 14),
            closeTrafficLight.heightAnchor.constraint(equalToConstant: 14),
            minimizeTrafficLight.leadingAnchor.constraint(equalTo: closeTrafficLight.trailingAnchor, constant: 9),
            minimizeTrafficLight.centerYAnchor.constraint(equalTo: addressCapsule.centerYAnchor),
            minimizeTrafficLight.widthAnchor.constraint(equalToConstant: 14),
            minimizeTrafficLight.heightAnchor.constraint(equalToConstant: 14),
            zoomTrafficLight.leadingAnchor.constraint(equalTo: minimizeTrafficLight.trailingAnchor, constant: 9),
            zoomTrafficLight.centerYAnchor.constraint(equalTo: addressCapsule.centerYAnchor),
            zoomTrafficLight.widthAnchor.constraint(equalToConstant: 14),
            zoomTrafficLight.heightAnchor.constraint(equalToConstant: 14)
        ])
        trafficLightsConfigured = true
        setTrafficLightsActive(window.isKeyWindow)
    }

    private func setTrafficLightsActive(_ active: Bool) {
        closeTrafficLight.setWindowActive(active)
        minimizeTrafficLight.setWindowActive(active)
        zoomTrafficLight.setWindowActive(active)
    }

    @objc private func closeWindow() { window?.performClose(nil) }
    @objc private func minimizeWindow() { window?.miniaturize(nil) }
    @objc private func zoomWindow() {
        if NSEvent.modifierFlags.contains(.option) { window?.zoom(nil) }
        else { toggleFullscreen() }
    }

    private func configureButton(_ button: NSButton, symbol: String, action: Selector, help: String) {
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    private var activeTab: BrowserTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    // Title, URL and progress changes arrive in bursts during one navigation.
    // They collapse into one pass, and an unchanged list is not rebuilt at all.
    private func renderTabs() {
        onSessionChange?()
        if webChromeVisible { scheduleChromeSync(); return }
        guard !tabsRenderScheduled else { return }
        tabsRenderScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tabsRenderScheduled = false
            self.drawTabs()
        }
    }

    private func drawTabs() {
        let store = ApsaThemeStore.shared
        let snapshot = "\(store.selected.rawValue):\(store.neonRGB)|\(tabFolders)|" + tabs.map { tab in
            "\(tab.id):\(tab.title):\(tab.url.absoluteString):\(tab.folder?.uuidString ?? ""):\(tab.id == activeTabID):\(tab.icon.map { ObjectIdentifier($0).hashValue } ?? 0)"
        }.joined(separator: "|")
        guard !webChromeVisible, snapshot != lastTabsSnapshot else { return }
        lastTabsSnapshot = snapshot
        for view in tabStack.arrangedSubviews {
            tabStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for entry in tabLayout {
            let row: NSView
            switch entry {
            case let .folder(folder, count):
                row = TabFolderRow(folder: folder, count: count,
                                   toggle: { [weak self] in self?.toggleFolder(folder.id) },
                                   menu: { [weak self] in self?.showFolderMenu(folder.id, in: $0) })
            case let .tab(id, nested):
                guard let tab = tabs.first(where: { $0.id == id }) else { continue }
                row = VerticalTabRow(
                    tab: tab,
                    selected: tab.id == activeTabID,
                    nested: nested,
                    select: { [weak self] in self?.selectTab(tab.id) },
                    close: { [weak self] in self?.closeTab(tab.id) },
                    menu: { [weak self] in self?.showTabMenu(tab.id, in: $0) }
                )
            }
            tabStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: tabStack.widthAnchor).isActive = true
        }
    }

    @objc private func bookmarksChanged() {
        if !webChromeVisible { bookmarksSection.refresh() }
        updateBookmarkControls()
    }

    private func updateBookmarkControls() {
        updateShieldButton()
        let saved = ApsaBookmarkStore.shared.bookmark(for: currentURL) != nil
        starButton.isEnabled = ApsaBookmarkStore.canBookmark(currentURL)
        starButton.image = NSImage(systemSymbolName: saved ? "star.fill" : "star", accessibilityDescription: nil)
        let help = saved ? apsaText("Remove Bookmark") : apsaText("Add Bookmark")
        starButton.toolTip = help
        starButton.setAccessibilityLabel(help)
        scheduleChromeSync()
    }

    private func recordVisit(_ url: URL) {
        guard !isPrivate, ApsaPrivacyStore.shared.settings.keepHistory else { return }
        ApsaHistoryStore.shared.visit(url)
    }

    private var pageHost: String? {
        currentURL.scheme == "http" || currentURL.scheme == "https" ? currentURL.host : nil
    }

    // MARK: Address bar buttons

    // Collapsed by default. The choice is remembered and shared by all windows.
    @objc func toggleAddressTools() {
        UserDefaults.standard.set(!Self.addressToolsExpanded, forKey: Self.addressToolsKey)
        NotificationCenter.default.post(name: Self.addressToolsChanged, object: nil)
    }

    @objc private func addressToolsChanged() { applyAddressToolsState(animated: true) }

    private func applyAddressToolsState(animated: Bool) {
        let expanded = Self.addressToolsExpanded
        let help = expanded ? apsaText("Hide Buttons") : apsaText("Show Buttons")
        addressToolsToggle.image = NSImage(systemSymbolName: expanded ? "chevron.right" : "chevron.left", accessibilityDescription: help)
        addressToolsToggle.toolTip = help
        addressToolsToggle.setAccessibilityLabel(help)
        scheduleChromeSync()
        guard animated else {
            addressToolsStack.isHidden = !expanded
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.allowsImplicitAnimation = true
            addressToolsStack.isHidden = !expanded
            addressCapsule.layoutSubtreeIfNeeded()
        }
    }

    // MARK: Translation

    private static var translationAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    private var pageIsTranslated: Bool {
        if readerPage?.isTranslated == true { return true }
        guard #available(macOS 15.0, *), let webView, let translator = pageTranslatorStorage as? ApsaPageTranslator else { return false }
        return translator.isTranslating(webView)
    }

    private func updateTranslateButton() {
        let on = pageIsTranslated
        translateButton.isEnabled = webView != nil || readerPage != nil
        translateButton.contentTintColor = on ? ApsaThemeStore.shared.selected.palette.accent : ApsaThemeStore.shared.selected.palette.secondary
        let help = on ? apsaText("Show Original") : apsaText("Translate Page")
        translateButton.toolTip = help
        translateButton.setAccessibilityLabel(help)
    }

    @objc func toggleTranslation() {
        guard #available(macOS 15.0, *), let translator = pageTranslator else { return }
        attachTranslationHost(translator)
        if let page = readerPage {
            if page.isTranslated {
                translator.stop()
                page.showOriginal()
            } else {
                translateReader(page, with: translator)
            }
        } else if let webView {
            if translator.isTranslating(webView) { translator.stop(in: webView) }
            else { translator.start(in: webView) { [weak self] in self?.showTranslationNotice(apsaText("This page is already in this language")) } }
        }
        updateBookmarkControls()
    }

    @available(macOS 15.0, *)
    private func translateReader(_ page: ApsaReaderPage, with translator: ApsaPageTranslator) {
        let target = ApsaTranslationText.target
        let source = ApsaTranslationText.detectLanguage(page.sampleText, declared: "")
        guard source != target else { showTranslationNotice(apsaText("This page is already in this language")); return }
        translator.engine.start(source: source, target: target)
        translator.engine.translate(page.translationItems()) { [weak self, weak page] results in
            page?.showTranslation(results)
            self?.updateBookmarkControls()
        }
    }

    private func translationFailed(_ error: Error) {
        showTranslationNotice(apsaText("Couldn't translate this page"), detail: apsaText("This language pair may be unavailable, or the language model couldn't be downloaded."))
        if #available(macOS 15.0, *), let translator = pageTranslatorStorage as? ApsaPageTranslator { translator.stop() }
        updateBookmarkControls()
    }

    private func showTranslationNotice(_ message: String, detail: String = "") {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.beginSheetModal(for: window)
        updateBookmarkControls()
    }

    private func updateShieldButton() {
        updateTranslateButton()
        let blocker = ApsaContentBlocker.shared
        let on = blocker.blocks(url: currentURL)
        shieldButton.isEnabled = blocker.isEnabled && pageHost != nil
        shieldButton.image = NSImage(systemSymbolName: on ? "shield.lefthalf.filled" : "shield.slash", accessibilityDescription: nil)
        let help = !blocker.isEnabled ? apsaText("Blocking is off in Settings") : on ? apsaText("Turn Off Blocking on This Site") : apsaText("Turn On Blocking on This Site")
        shieldButton.toolTip = help
        shieldButton.setAccessibilityLabel(help)
    }

    @objc private func blockingChanged(_ notification: Notification) {
        updateBookmarkControls()
        let blocker = ApsaContentBlocker.shared
        let reload = notification.userInfo?[ApsaContentBlocker.reloadPagesKey] as? Bool == true
        let views = [webView].compactMap { $0 } + tabs.compactMap(\.parked)
        for view in views {
            blocker.apply(to: view, for: view.url)
            if reload, view.url?.scheme == "http" || view.url?.scheme == "https" { view.reload() }
        }
    }

    // Rules change what the next load fetches, so the page reloads to show the result.
    @objc func toggleSiteBlocking() {
        guard let host = pageHost else { return }
        let blocker = ApsaContentBlocker.shared
        blocker.setAllowed(!blocker.isAllowed(host: host), host: host)
        hideReader()
        webView?.reload()
    }

    @objc func toggleBookmark() {
        // The tab can still carry the previous page's title while this one loads.
        let title = webView?.title.flatMap { $0.isEmpty ? nil : $0 } ?? activeTab?.title ?? ""
        ApsaBookmarkStore.shared.toggle(url: currentURL, title: title, icon: activeTab?.iconDataURL)
    }

    func toggleBookmarksSection() { ApsaBookmarkStore.shared.collapsed.toggle() }

    func openInNewTab(_ url: URL) {
        faviconTask?.cancel()
        parkActiveSurface()
        let tab = BrowserTab(url: url)
        tabs.append(tab)
        activeTabID = tab.id
        renderTabs()
        navigate(to: url)
    }

    private var tabLayout: [ApsaTabRow] {
        apsaTabRows(tabs.map { (id: $0.id, folder: $0.folder) }, folders: tabFolders)
    }

    // MARK: Tab folders

    private func reorderTabs(_ order: [UUID]) {
        tabs = order.compactMap { id in tabs.first { $0.id == id } }
    }

    private func moveTab(_ id: UUID, toFolder folder: UUID?) {
        guard let tab = tabs.first(where: { $0.id == id }), tab.folder != folder else { return }
        reorderTabs(apsaTabOrder(tabs.map { (id: $0.id, folder: $0.folder) }, moving: id, to: folder))
        tab.folder = folder
        pruneFolders()
        renderTabs()
    }

    private func pruneFolders() {
        let used = Set(tabs.compactMap(\.folder))
        tabFolders.removeAll { !used.contains($0.id) }
    }

    private func createFolder(with id: UUID) {
        apsaAskForText(title: apsaText("New Folder"), value: "", confirm: apsaText("Create"), window: window) { [weak self] raw in
            guard let self else { return }
            let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
            guard !name.isEmpty else { return }
            let folder = ApsaTabFolder(id: UUID(), name: name, collapsed: false)
            self.tabFolders.append(folder)
            guard let tab = self.tabs.first(where: { $0.id == id }) else { return }
            tab.folder = folder.id
            self.pruneFolders()
            self.renderTabs()
        }
    }

    func createFolderForActiveTab() {
        if let activeTabID { createFolder(with: activeTabID) }
    }

    private func toggleFolder(_ id: UUID) {
        guard let index = tabFolders.firstIndex(where: { $0.id == id }) else { return }
        tabFolders[index].collapsed.toggle()
        renderTabs()
    }

    private func expandFolder(of tab: BrowserTab) {
        guard let index = tabFolders.firstIndex(where: { $0.id == tab.folder }), tabFolders[index].collapsed else { return }
        tabFolders[index].collapsed = false
    }

    private func popUpMenu(_ menu: NSMenu, in view: NSView) {
        guard let window = view.window else { return }
        menu.popUp(positioning: nil, at: view.convert(window.mouseLocationOutsideOfEventStream, from: nil), in: view)
    }

    private func menuItem(_ title: String, _ action: Selector, _ value: Any? = nil, on: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        item.state = on ? .on : .off
        return item
    }

    private func showTabMenu(_ id: UUID, in view: NSView) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        menuTabID = id
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(menuItem(apsaText("New Folder with This Tab…"), #selector(newFolderFromMenu)))
        let move = NSMenu()
        move.autoenablesItems = false
        move.addItem(menuItem(apsaText("No Folder"), #selector(moveTabFromMenu(_:)), nil, on: tab.folder == nil))
        for folder in tabFolders { move.addItem(menuItem(folder.name, #selector(moveTabFromMenu(_:)), folder.id, on: tab.folder == folder.id)) }
        let moveItem = NSMenuItem(title: apsaText("Move to Folder"), action: nil, keyEquivalent: "")
        moveItem.submenu = move
        menu.addItem(moveItem)
        menu.addItem(.separator())
        menu.addItem(menuItem(apsaText("Close Tab"), #selector(closeTabFromMenu)))
        popUpMenu(menu, in: view)
    }

    private func showFolderMenu(_ id: UUID, in view: NSView) {
        menuFolderID = id
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(menuItem(apsaText("Rename…"), #selector(renameFolderFromMenu)))
        menu.addItem(menuItem(apsaText("Save to Bookmarks…"), #selector(saveFolderToBookmarks)))
        menu.addItem(.separator())
        menu.addItem(menuItem(apsaText("Remove Folder, Keep Tabs"), #selector(ungroupFolder)))
        menu.addItem(menuItem(apsaText("Close All Tabs in Folder"), #selector(closeFolderTabs)))
        popUpMenu(menu, in: view)
    }

    @objc private func newFolderFromMenu() { if let menuTabID { createFolder(with: menuTabID) } }
    @objc private func moveTabFromMenu(_ sender: NSMenuItem) { if let menuTabID { moveTab(menuTabID, toFolder: sender.representedObject as? UUID) } }
    @objc private func closeTabFromMenu() { if let menuTabID { closeTab(menuTabID) } }
    @objc private func renameFolderFromMenu() {
        guard let id = menuFolderID, let folder = tabFolders.first(where: { $0.id == id }) else { return }
        apsaAskForText(title: apsaText("Folder Name"), value: folder.name, confirm: apsaText("Save"), window: window) { [weak self] raw in
            let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
            guard let self, !name.isEmpty, let index = self.tabFolders.firstIndex(where: { $0.id == id }) else { return }
            self.tabFolders[index].name = name
            self.renderTabs()
        }
    }
    @objc private func ungroupFolder() {
        guard let id = menuFolderID else { return }
        tabs.filter { $0.folder == id }.forEach { $0.folder = nil }
        pruneFolders()
        renderTabs()
    }
    @objc private func closeFolderTabs() {
        guard let id = menuFolderID else { return }
        tabs.filter { $0.folder == id }.map(\.id).forEach(closeTab)
    }
    @objc private func saveFolderToBookmarks() {
        guard let id = menuFolderID, let folder = tabFolders.first(where: { $0.id == id }) else { return }
        saveToBookmarks(tabs.filter { $0.folder == id }, defaultName: folder.name)
    }

    func saveAllTabsToBookmarks() {
        let formatter = DateFormatter()
        formatter.locale = ApsaLanguage.current.locale
        formatter.setLocalizedDateFormatFromTemplate("dMMMM")
        saveToBookmarks(tabs, defaultName: apsaText("Tabs %@", formatter.string(from: Date())))
    }

    private func saveToBookmarks(_ source: [BrowserTab], defaultName: String) {
        let pages = source.map { (url: $0.url, title: $0.title, icon: $0.iconDataURL) }
        apsaAskForText(title: apsaText("Save Tabs to a Bookmark Folder"), value: defaultName, confirm: apsaText("Save"), window: window) { name in
            ApsaBookmarkStore.shared.saveAll(pages, toFolder: name)
        }
    }

    // MARK: Session

    var savedState: ApsaSavedWindow {
        let frame = window?.frame ?? .zero
        return ApsaSavedWindow(
            tabs: tabs.map { ApsaSavedTab(id: $0.id, url: $0.url.absoluteString, title: $0.title, folder: $0.folder, icon: $0.iconDataURL) },
            folders: tabFolders, activeTab: activeTabID, sidebarVisible: sidebarVisible || sidebarBeforeHidingToolbar && !toolbarVisible,
            frame: [frame.minX, frame.minY, frame.width, frame.height])
    }

    private func restore(_ saved: ApsaSavedWindow, in window: NSWindow) -> Bool {
        let restored = saved.tabs.compactMap { item -> BrowserTab? in
            // Tabs saved while internal pages used the old address.
            let address = item.url.hasPrefix("apsa://") ? "browser://" + item.url.dropFirst("apsa://".count) : item.url
            guard let url = URL(string: address), surfaceKind(for: url) != nil else { return nil }
            let tab = BrowserTab(url: url, title: url.scheme == "browser" ? apsaInternalPageTitle(url.host) : item.title, id: item.id)
            tab.folder = item.folder
            if let icon = item.icon, let comma = icon.firstIndex(of: ","), let data = Data(base64Encoded: String(icon[icon.index(after: comma)...])) { tab.icon = NSImage(data: data) }
            return tab
        }
        guard !restored.isEmpty else { return false }
        tabs = restored
        tabFolders = saved.folders
        pruneFolders()
        let active = tabs.first { $0.id == saved.activeTab } ?? tabs[tabs.count - 1]
        activeTabID = active.id
        expandFolder(of: active)
        if let frame = saved.frame, frame.count == 4 {
            let rect = NSRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3])
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) { window.setFrame(rect, display: false) }
        }
        sidebarVisible = saved.sidebarVisible
        updateResponsiveLayout(animated: false)
        renderTabs()
        navigate(to: active.url, countsAsVisit: false)
        return true
    }

    private func updateActiveTab(url: URL? = nil, title: String? = nil, icon: NSImage? = nil) {
        guard let tab = activeTab else { return }
        defer { updateBookmarkControls() }
        if let url { tab.url = url }
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tab.title = title
            if !isPrivate { ApsaHistoryStore.shared.updateTitle(title, for: tab.url) }
        }
        if let icon { tab.icon = icon }
        renderTabs()
    }

    private func selectTab(_ id: UUID) {
        guard id != activeTabID, let tab = tabs.first(where: { $0.id == id }) else { return }
        faviconTask?.cancel()
        parkActiveSurface()
        activeTabID = id
        expandFolder(of: tab)
        renderTabs()
        show(tab)
        hibernateBackgroundTabs(olderThan: 15 * 60)
        if (window?.frame.width ?? 1000) < 820 { setSidebarVisible(false, animated: true) }
    }

    @objc private func newTab() {
        faviconTask?.cancel()
        parkActiveSurface()
        let tab = BrowserTab(url: homeURL, title: apsaText("New Tab"))
        tabs.append(tab)
        activeTabID = tab.id
        renderTabs()
        navigate(to: homeURL)
        focusAddress()
    }

    private func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = id == activeTabID
        closedTabURLs.append(tabs[index].url)
        releaseParked(tabs[index])
        defer { pruneFolders(); renderTabs() }
        if closedTabURLs.count > 25 { closedTabURLs.removeFirst() }
        tabs.remove(at: index)
        if tabs.isEmpty {
            let replacement = BrowserTab(url: homeURL, title: apsaText("New Tab"))
            tabs = [replacement]
            activeTabID = replacement.id
        } else if wasActive {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
        renderTabs()
        if wasActive, let tab = activeTab {
            faviconTask?.cancel()
            releaseWebSurface()
            clearActiveSurface()
            show(tab)
        }
    }

    // MARK: Background tabs

    private func parkActiveSurface() {
        observations.forEach { $0.invalidate() }
        observations.removeAll(keepingCapacity: false)
        guard let tab = activeTab else { releaseWebSurface(); return }
        tab.lastActive = Date()
        if #available(macOS 15.0, *), let webView, let translator = pageTranslatorStorage as? ApsaPageTranslator { translator.forget(webView) }
        stopFastFullscreen()
        hideReader()
        if let webView {
            if let url = webView.url { tab.url = url }
            webView.removeFromSuperview()
            tab.parked = webView
            self.webView = nil
            contentContainer.usesWebKitGestures = false
        }
        clearActiveSurface()
    }

    private func clearActiveSurface() {
        readerPage?.removeFromSuperview(); readerPage = nil
        readerSourceURL = nil
        nativePage?.removeFromSuperview(); nativePage = nil
        findBar.pageChanged()
    }

    private func pin(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
    }

    // Bring a tab back as it was left, or load it if it has nothing kept.
    private func show(_ tab: BrowserTab) {
        guard let view = tab.parked else {
            navigate(to: tab.url, countsAsVisit: false)
            return
        }
        tab.parked = nil
        tab.lastActive = Date()
        currentURL = view.url ?? tab.url
        tab.url = currentURL
        webView = view
        contentContainer.usesWebKitGestures = true
        pin(view)
        view.pageZoom = pageZoom
        observeWebView(view)
        if let title = view.title, !title.isEmpty { tab.title = title }
        window?.title = "\(tab.title) — \(appName)"
        updateReaderButton()
        progress.doubleValue = view.estimatedProgress
        progress.isHidden = !view.isLoading
        window?.makeFirstResponder(view)
        reloadButton.isEnabled = true
        addressField.stringValue = displayAddress(for: currentURL)
        updateNavigationButtons()
        updateBookmarkControls()
    }

    private func releaseParked(_ tab: BrowserTab) {
        if let view = tab.parked {
            stopMedia(in: view)
            view.stopLoading()
            view.navigationDelegate = nil
            view.uiDelegate = nil
            view.removeFromSuperview()
        }
        tab.parked = nil
    }

    // A page with sound or unsent input is not safe to discard, whatever its age.
    private static let hibernationProbe = """
    [...document.querySelectorAll('video,audio')].some(m => !m.paused && !m.muted && !m.ended) ||
    [...document.querySelectorAll('textarea,input:not([type=hidden]):not([type=checkbox]):not([type=radio])')].some(f => f.value !== f.defaultValue)
    """

    func hibernateBackgroundTabs(olderThan age: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-age)
        for tab in tabs where tab.id != activeTabID && tab.lastActive <= cutoff {
            guard let view = tab.parked else { continue }
            view.evaluateJavaScript(Self.hibernationProbe) { [weak self, weak tab] value, _ in
                guard let self, let tab, tab.id != self.activeTabID, value as? Bool != true, tab.parked === view else { return }
                self.releaseParked(tab)
            }
        }
    }

    @objc private func toggleSidebar() { setSidebarVisible(!sidebarVisible, animated: true) }

    private func setSidebarVisible(_ visible: Bool, animated: Bool) {
        sidebarVisible = visible
        updateResponsiveLayout(animated: animated)
    }

    private func updateResponsiveLayout(animated: Bool) {
        let width: CGFloat = sidebarVisible ? 238 : 0
        rootMaterial.layoutSubtreeIfNeeded()
        if sidebarVisible { sidebar.isHidden = false }
        sidebar.setAccessibilityHidden(!sidebarVisible)
        sidebarWidthConstraint?.constant = width
        sidebarButton.contentTintColor = ApsaThemeStore.shared.selected.palette.accent
        scheduleChromeSync()
        settingsWindow?.refreshValues()
        guard animated else {
            sidebar.alphaValue = sidebarVisible ? 1 : 0
            sidebar.isHidden = !sidebarVisible
            rootMaterial.layoutSubtreeIfNeeded()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.sidebar.animator().alphaValue = self.sidebarVisible ? 1 : 0
            self.rootMaterial.layoutSubtreeIfNeeded()
        } completionHandler: {
            if !self.sidebarVisible { self.sidebar.isHidden = true }
        }
    }

    func windowDidResize(_ notification: Notification) {
        updateResponsiveLayout(animated: true)
    }

    func windowWillClose(_ notification: Notification) {
        releaseWebSurface()
        tabs.forEach(releaseParked)
        stopWebChrome()
        onClosed?(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onBecameActive?(self)
        configureTrafficLights()
        setTrafficLightsActive(true)
    }

    func windowDidResignKey(_ notification: Notification) { setTrafficLightsActive(false) }

    // In full screen the system moves window buttons into the menu bar.
    // MARK: Fullscreen

    // AppKit queues another toggle during a transition: a double click would enter
    // and leave at once, sometimes leaving WebKit mid-resize. The timer is only a way
    // out if a transition is refused and no notification ever comes.
    func toggleFullscreen() {
        guard !fullscreenTransitioning else { return }
        fullscreenTransitioning = true
        fullscreenGeneration += 1
        let generation = fullscreenGeneration
        if window?.styleMask.contains(.fullScreen) == false {
            // Commit pending layout now, so the viewport change has nothing to catch up on.
            window?.contentView?.layoutSubtreeIfNeeded()
            webView?.evaluateJavaScript("document.documentElement?.getBoundingClientRect(); document.body?.offsetHeight") { _, _ in }
        }
        window?.toggleFullScreen(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.fullscreenGeneration == generation else { return }
            self.fullscreenTransitioning = false
        }
    }

    private func fullscreenFinished() {
        fullscreenGeneration += 1
        fullscreenTransitioning = false
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    // Supplying our own "animation" makes the change immediate: no slide to a new Space.
    func customWindowsToEnterFullScreen(for window: NSWindow) -> [NSWindow]? { [window] }
    func customWindowsToExitFullScreen(for window: NSWindow) -> [NSWindow]? { [window] }

    func window(_ window: NSWindow, startCustomAnimationToEnterFullScreenWithDuration duration: TimeInterval) {
        guard let screen = window.screen else { return }
        window.setFrame(screen.frame, display: true)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func window(_ window: NSWindow, startCustomAnimationToExitFullScreenWithDuration duration: TimeInterval) {
        guard let frame = frameBeforeFullscreen else { return }
        window.setFrame(frame, display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        frameBeforeFullscreen = nil
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        frameBeforeFullscreen = window?.frame
        setTrafficLightsHidden(true)
    }
    func windowDidEnterFullScreen(_ notification: Notification) { fullscreenFinished() }
    func windowDidExitFullScreen(_ notification: Notification) {
        setTrafficLightsHidden(false)
        fullscreenFinished()
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        setTrafficLightsHidden(false)
        fullscreenFinished()
    }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { fullscreenFinished() }

    // MARK: Fast fullscreen for video

    private func toggleFastFullscreen(for view: WKWebView) {
        guard ApsaFastFullscreen.isEnabled, view === webView else { return }
        if fastFullscreenView === view { stopFastFullscreen(); return }
        stopFastFullscreen()
        view.evaluateJavaScript(ApsaFastFullscreen.enterScript) { [weak self, weak view] result, _ in
            guard let self, let view, result as? Bool == true, view === self.webView, let window = self.window else { return }
            if self.fastFullscreenFrame == nil, let screen = window.screen ?? NSScreen.main {
                self.fastFullscreenFrame = window.frame
                window.setFrame(screen.visibleFrame, display: true, animate: false)
            }
            self.fastFullscreenView = view
        }
    }

    private func stopFastFullscreen() {
        guard let view = fastFullscreenView else { return }
        view.evaluateJavaScript(ApsaFastFullscreen.exitScript) { _, _ in }
        if let frame = fastFullscreenFrame { window?.setFrame(frame, display: true, animate: false) }
        fastFullscreenFrame = nil
        fastFullscreenView = nil
    }

    private func setFastFullscreen(_ enabled: Bool) {
        ApsaFastFullscreen.isEnabled = enabled
        if !enabled { stopFastFullscreen() }
        if let webView { ApsaFastFullscreen.apply(to: webView) }
        for tab in tabs { if let view = tab.parked { ApsaFastFullscreen.apply(to: view) } }
    }

    // MARK: Performance counters

    func showPerformanceStats() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let memory = result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
        let background = tabs.filter { $0.id != activeTabID && $0.parked != nil }.count
        let sleeping = tabs.filter { $0.id != activeTabID && $0.parked == nil && $0.url.scheme != "browser" }.count
        let alert = NSAlert()
        alert.messageText = apsaText("Browser Stats")
        alert.informativeText = apsaText("Browser itself: %.0f MB. Pages run in separate WebKit processes and aren't counted here.\nTabs: %d, live in background: %d, sleeping: %d.", memory, tabs.count, background, sleeping)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private func setTrafficLightsHidden(_ hidden: Bool) {
        for button in [closeTrafficLight, minimizeTrafficLight, zoomTrafficLight] { button.isHidden = hidden }
    }

    private func displayAddress(for url: URL) -> String {
        if url.scheme == "browser" {
            return ["history": apsaText("History"), "bookmarks": apsaText("Bookmarks"), "passwords": apsaText("Passwords"), "about": apsaText("About the Browser")][url.host ?? ""] ?? ""
        }
        if url.isFileURL { return url.path }
        guard let host = url.host?.replacingOccurrences(of: "www.", with: "") else { return url.absoluteString }
        let path = url.path == "/" ? "" : url.path
        return path.isEmpty ? host : "\(host)  ›  \(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
    }

    // Moving the caret inside the short form switches to the full URL. This cannot
    // happen when editing begins: that fires before the first character goes in,
    // and replacing the text then leaves the typed character over a stale range.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let moves: [Selector] = [#selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveToBeginningOfLine(_:)), #selector(NSResponder.moveToEndOfLine(_:))]
        if control === addressField, moves.contains(selector), textView.string.contains("  ›  ") {
            textView.string = currentURL.absoluteString
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // Return ends editing before dispatching the address action. Replacing
        // the value here would navigate the old display label instead of the
        // address the user just entered. Navigation formats the committed URL.
    }

    private func animateIn(_ view: NSView) {
        view.alphaValue = 1
    }

    // Switching back to an open tab reloads it but is not a new visit.
    func navigate(to url: URL, recordingHistory: Bool = true, countsAsVisit: Bool = true) {
        guard let kind = surfaceKind(for: url) else { return }
        if countsAsVisit { recordVisit(url) }
        if recordingHistory { activeTab?.history.record(url) }
        defer { updateNavigationButtons() }
        currentURL = url
        findBar.pageChanged()
        updateActiveTab(url: url)
        switch kind {
        case .internalPage: showNativePage(url)
        case .web: showWebPage(url)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = ApsaSettingsWindow(actions: ApsaSettingsActions(
                sidebarVisible: { [weak self] in self?.sidebarVisible ?? true },
                setSidebarVisible: { [weak self] in self?.setSidebarVisible($0, animated: true) },
                inset: { [weak self] in self?.chromeInset ?? 6 },
                setInset: { [weak self] value in
                    self?.chromeInset = max(4, min(14, value))
                    self?.saveAndApplyChromeInset()
                },
                resetInset: { [weak self] in self?.resetChromeInset() },
                showPasswords: { [weak self] in self?.showPasswords() },
                clearSiteData: { [weak self] in self?.confirmClearSiteData() },
                setFastFullscreen: { [weak self] in self?.setFastFullscreen($0) }
            ))
        }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: WebView interface

    @objc private func applyChromeMode() {
        if ApsaThemeStore.shared.chromeUsesWebView { startWebChrome() } else { stopWebChrome() }
    }

    private func startWebChrome() {
        guard chrome == nil else { return }
        guard let controller = ApsaChromeController() else { webChromeFailed(); return }
        chrome = controller
        controller.onCommand = { [weak self] in self?.perform($0) }
        controller.onNeedsState = { [weak self] in self?.syncChrome() }
        controller.onReady = { [weak self] in self?.showWebChrome() }
        controller.onFailure = { [weak self] in self?.webChromeFailed() }
        // The native controls stay on screen until the first real frame is ready.
        let view = controller.webView
        view.alphaValue = 0
        view.translatesAutoresizingMaskIntoConstraints = false
        rootMaterial.addSubview(view, positioned: .below, relativeTo: contentContainer)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: rootMaterial.topAnchor),
            view.leadingAnchor.constraint(equalTo: rootMaterial.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: rootMaterial.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: rootMaterial.bottomAnchor)
        ])
        controller.start()
    }

    private func showWebChrome() {
        guard let chrome else { return }
        webChromeVisible = true
        let addressHadFocus = addressField.currentEditor() != nil && window?.firstResponder === addressField.currentEditor()
        setNativeChromeHidden(true)
        chrome.webView.alphaValue = 1
        syncChrome()
        if addressHadFocus { chrome.focusAddress() }
    }

    private func stopWebChrome() {
        guard let chrome else { return }
        self.chrome = nil
        webChromeVisible = false
        chrome.stop()
        setNativeChromeHidden(false)
        renderTabs()
        bookmarksSection.refresh()
    }

    private func webChromeFailed() {
        ApsaThemeStore.shared.setChromeUsesWebView(false)
        stopWebChrome()
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = apsaText("The WebView interface didn't start")
        alert.informativeText = apsaText("The browser went back to the standard interface.")
        alert.beginSheetModal(for: window)
    }

    private func setNativeChromeHidden(_ hidden: Bool) {
        controlsView?.isHidden = hidden
        tabsTitleLabel?.isHidden = hidden
        newTabButton.isHidden = hidden
        tabsScroll.isHidden = hidden
        bookmarksSection.isHidden = hidden
        // The page view must lie above the sidebar glass and below the page surface.
        if hidden { rootMaterial.addSubview(sidebar, positioned: .below, relativeTo: chrome?.webView) }
        else { rootMaterial.addSubview(sidebar, positioned: .above, relativeTo: contentContainer) }
    }

    private func perform(_ command: ApsaChromeCommand) {
        switch command {
        case .back: goBack()
        case .forward: goForward()
        case .reload: reload()
        case .toggleSidebar: toggleSidebar()
        case .settings: showSettings()
        case .toggleReader: toggleReader()
        case .newTab: newTab()
        case .toggleBookmark: toggleBookmark()
        case .toggleSiteBlocking: toggleSiteBlocking()
        case .toggleAddressTools: toggleAddressTools()
        case .toggleTranslation: toggleTranslation()
        case .toggleBookmarksSection: toggleBookmarksSection()
        case let .openBookmark(id):
            if let raw = ApsaBookmarkStore.shared.bookmark(id: id)?.url, let url = URL(string: raw) { navigate(to: url) }
        case let .toggleFolder(id): toggleFolder(id)
        case let .tabMenu(id):
            if let view = window?.contentView { showTabMenu(id, in: view) }
        case let .folderMenu(id):
            if let view = window?.contentView { showFolderMenu(id, in: view) }
        case let .bookmarkMenu(id):
            guard let view = window?.contentView else { return }
            ApsaBookmarkMenu.show(for: id, in: view) { [weak self] in self?.openInNewTab($0) }
        case let .selectTab(id): selectTab(id)
        case let .closeTab(id): closeTab(id)
        case let .address(value):
            addressField.stringValue = value
            openAddress()
        }
    }

    private func scheduleChromeSync() {
        guard chrome != nil, !chromeSyncScheduled else { return }
        chromeSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.chromeSyncScheduled = false
            self?.syncChrome()
        }
    }

    private func syncChrome() {
        guard let chrome else { return }
        let theme = ApsaThemeStore.shared.selected
        let palette = theme.palette
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        chrome.push([
            "address": addressField.stringValue,
            "url": currentURL.absoluteString,
            "enabled": ["back": backButton.isEnabled, "forward": forwardButton.isEnabled, "reload": reloadButton.isEnabled],
            "reader": ["enabled": readerButton.isEnabled, "tip": readerButton.toolTip ?? "", "on": readerPage != nil] as [String: Any],
            "sidebarVisible": sidebarVisible,
            "toolbarVisible": toolbarVisible,
            "placeholder": addressField.placeholderString ?? "",
            "addressTools": ["expanded": Self.addressToolsExpanded, "tip": addressToolsToggle.toolTip ?? ""] as [String: Any],
            "translation": ["available": Self.translationAvailable, "enabled": translateButton.isEnabled, "on": pageIsTranslated, "tip": translateButton.toolTip ?? apsaText("Translate Page")] as [String: Any],
            "shield": ["enabled": shieldButton.isEnabled, "on": ApsaContentBlocker.shared.blocks(url: currentURL), "tip": shieldButton.toolTip ?? ""] as [String: Any],
            "star": ["enabled": starButton.isEnabled, "on": ApsaBookmarkStore.shared.bookmark(for: currentURL) != nil],
            "bookmarksCollapsed": ApsaBookmarkStore.shared.collapsed,
            "bookmarks": ApsaBookmarkStore.shared.grouped.flatMap(\.items).prefix(ApsaBookmarksSection.maximumRows).map { bookmark -> [String: Any] in
                var row: [String: Any] = ["id": bookmark.id.uuidString, "title": bookmark.title, "url": bookmark.url]
                if let folder = bookmark.folder { row["folder"] = folder }
                if let icon = bookmark.icon { row["icon"] = icon }
                return row
            },
            "inset": Double(chromeInset),
            "titlebarOffset": Double(transparentTitlebarOffset),
            "theme": [
                "name": theme.rawValue,
                "light": theme.isLight,
                "tokens": [
                    "background": ApsaChromeController.cssColor(palette.background),
                    "surface": ApsaChromeController.cssColor(palette.surface),
                    "text": ApsaChromeController.cssColor(palette.text),
                    "secondary": ApsaChromeController.cssColor(palette.secondary),
                    "accent": ApsaChromeController.cssColor(palette.accent),
                    "warning": ApsaChromeController.cssColor(palette.warning),
                    "line": ApsaChromeController.cssColor(palette.line),
                    "glass-tint": ApsaChromeController.cssColor(theme.glassTint),
                    "capsule-tint": ApsaChromeController.cssColor(theme.glassTint, alpha: reduceTransparency ? 1 : 0.28)
                ]
            ] as [String: Any],
            "tabs": tabLayout.compactMap { entry -> [String: Any]? in
                switch entry {
                case let .folder(folder, count):
                    return ["kind": "folder", "id": folder.id.uuidString, "name": folder.name, "count": count, "collapsed": folder.collapsed]
                case let .tab(id, nested):
                    guard let tab = tabs.first(where: { $0.id == id }) else { return nil }
                    var row: [String: Any] = [
                        "id": tab.id.uuidString,
                        "title": tab.title,
                        "detail": VerticalTabRow.detail(for: tab.url),
                        "active": tab.id == activeTabID,
                        "symbol": tab.url.scheme == "browser" ? "home" : "web",
                        "nested": nested
                    ]
                    if let icon = tab.iconDataURL { row["icon"] = icon }
                    return row
                }
            }
        ])
    }

    @objc private func applyBrowserTheme() {
        let theme = ApsaThemeStore.shared.selected
        let palette = theme.palette
        window?.appearance = NSAppearance(named: theme.isLight ? .aqua : .darkAqua)
        window?.isOpaque = false
        window?.backgroundColor = .clear
        rootMaterial.applyTint(theme.glassTint, opacity: theme.isLight ? 0.34 : 0.48)
        toolbar.applyTint(theme.glassTint, opacity: 0.24)
        sidebar.applyTint(theme.glassTint, opacity: 0.2)
        addressCapsule.applyTint(theme.glassTint, opacity: 0.28)
        findBar.applyTheme(theme)
        progress.color = palette.accent
        for label in sidebar.subviews.compactMap({ $0 as? NSTextField }) { label.textColor = palette.secondary }
        contentContainer.layer?.backgroundColor = NSColor.clear.cgColor
        addressField.textColor = palette.text
        (addressField.currentEditor() as? NSTextView)?.insertionPointColor = palette.accent
        addressCapsule.layer?.borderColor = palette.line.cgColor
        addressCapsule.layer?.borderWidth = theme == .gamer ? 1.5 : 0.5
        // A static neon edge: no animation, timer or extra rendering process.
        addressSlot.wantsLayer = true
        addressSlot.layer?.shadowColor = palette.accent.cgColor
        addressSlot.layer?.shadowRadius = theme == .gamer ? 9 : 0
        addressSlot.layer?.shadowOpacity = theme == .gamer ? 0.6 : 0
        addressSlot.layer?.shadowOffset = .zero
        for button in [sidebarButton, backButton, forwardButton, reloadButton, readerButton, newTabButton, settingsButton, starButton, shieldButton, addressToolsToggle] { button.contentTintColor = palette.accent }
        bookmarksSection.refresh()
        renderTabs()
        readerPage?.applyBrowserTheme()
        if currentURL.scheme == "browser", nativePage != nil { showNativePage(currentURL) }
        scheduleChromeSync()
    }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.html]
        panel.title = apsaText("Open HTML File")
        if panel.runModal() == .OK, let url = panel.url { navigate(to: url) }
    }

    func focusAddress() {
        if !toolbarVisible { setToolbarVisible(true) }
        if webChromeVisible { chrome?.focusAddress(); return }
        window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    func reloadCurrentPage() { reload() }

    func reloadFromOrigin() {
        if let webView { webView.reloadFromOrigin() } else { reload() }
    }

    func stopLoading() {
        webView?.stopLoading()
    }

    func goHome() { navigate(to: homeURL) }
    func goBackInHistory() { goBack() }
    func goForwardInHistory() { goForward() }

    func selectTab(shortcut number: Int) {
        guard let index = apsaTabIndex(forShortcut: number, tabCount: tabs.count) else { return }
        selectTab(tabs[index].id)
    }

    func selectAdjacentTab(_ offset: Int) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        selectTab(tabs[(index + offset + tabs.count) % tabs.count].id)
    }

    func reopenClosedTab() {
        guard let url = closedTabURLs.popLast() else { return }
        faviconTask?.cancel()
        parkActiveSurface()
        let tab = BrowserTab(url: url)
        tabs.append(tab)
        activeTabID = tab.id
        renderTabs()
        navigate(to: url)
    }

    func toggleToolbarVisibility() { setToolbarVisible(!toolbarVisible) }

    // Nothing but the page: the sidebar goes with the toolbar and comes back with it.
    private func setToolbarVisible(_ visible: Bool) {
        guard toolbarVisible != visible else { return }
        if visible { sidebarVisible = sidebarVisible || sidebarBeforeHidingToolbar }
        else { sidebarBeforeHidingToolbar = sidebarVisible; sidebarVisible = false }
        toolbarVisible = visible
        toolbar.isHidden = !visible
        // The bar stays laid out above the window, so the page rises to the top edge.
        toolbarTopConstraint?.constant = visible ? 0 : transparentTitlebarOffset - 64
        updateResponsiveLayout(animated: false)
        scheduleChromeSync()
    }

    func findInPage() {
        if nativePage?.focusPageSearch() == true { return }
        findBar.open()
    }

    private func confirmClearSiteData() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = apsaText("Delete Data for All Sites?")
        alert.informativeText = apsaText("Cookies, storage and cache will be deleted, except for sites on your exceptions list. You'll be signed out of these sites.")
        alert.addButton(withTitle: apsaText("Delete")).hasDestructiveAction = true
        alert.addButton(withTitle: apsaText("Cancel"))
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { ApsaPrivacyStore.shared.clearWebData {} }
        }
    }

    func showHistory() { showSystemPage(URL(string: "browser://history")!) }
    func showBookmarks() { showSystemPage(URL(string: "browser://bookmarks")!) }
    func showPasswords() { showSystemPage(URL(string: "browser://passwords")!) }
    func fillPassword() {
        guard let webView else { showPasswords(); return }
        passwordAutofill.showMenu(in: webView, at: NSPoint(x: 12, y: 12))
    }
    func openBookmarkEntry(_ url: URL) { navigate(to: url) }

    // One copy of a system page per window: reuse an open one, or an empty start tab.
    private func showSystemPage(_ url: URL) {
        if let open = tabs.first(where: { $0.url == url }) {
            selectTab(open.id)
        } else if activeTab?.url == homeURL {
            navigate(to: url)
        } else {
            openInNewTab(url)
        }
        if !toolbarVisible { setToolbarVisible(true) }
    }

    func clearHistory() { ApsaHistoryView.confirmClear(for: window) }
    func openHistoryEntry(_ url: URL) { navigate(to: url) }
    func findStep(forward: Bool) { findBar.step(forward: forward) }

    func zoomIn() { setPageZoom(pageZoom * 1.1) }
    func zoomOut() { setPageZoom(pageZoom / 1.1) }
    func resetZoom() { setPageZoom(1) }

    private func setPageZoom(_ value: CGFloat) {
        pageZoom = ApsaPageZoom.limited(value)
        if !isPrivate { ApsaPageZoom.save(pageZoom) }
        applyPageZoom()
    }

    private func applyPageZoom() {
        if readerPage == nil, let webView { webView.pageZoom = pageZoom; return }
        func firstScrollView(in view: NSView) -> NSScrollView? {
            for child in view.subviews {
                if let scroll = child as? NSScrollView { return scroll }
                if let found = firstScrollView(in: child) { return found }
            }
            return nil
        }
        guard let root = readerPage, let scroll = firstScrollView(in: root) else { return }
        scroll.allowsMagnification = true
        scroll.maxMagnification = 3
        scroll.minMagnification = 0.5
        scroll.magnification = pageZoom
        // Magnifying keeps the centre in place; a page reads from its left edge.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.origin.y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func printPage() {
        guard let window else { return }
        let operation: NSPrintOperation?
        if readerPage == nil, let webView { operation = webView.printOperation(with: .shared) }
        else if let page = readerPage ?? nativePage { operation = NSPrintOperation(view: page) }
        else { operation = nil }
        operation?.view?.frame = NSRect(x: 0, y: 0, width: NSPrintInfo.shared.paperSize.width, height: NSPrintInfo.shared.paperSize.height)
        operation?.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
    func openNewTab() { newTab() }
    func closeCurrentTab() { if let activeTabID { closeTab(activeTabID) } }
    func toggleSidebarVisibility() { toggleSidebar() }
    func toggleReaderMode() { toggleReader() }
    func decreaseChromeInset() { changeChromeInset(by: -1) }
    func increaseChromeInset() { changeChromeInset(by: 1) }
    func resetChromeInset() {
        chromeInset = 6
        saveAndApplyChromeInset()
    }

    private func changeChromeInset(by delta: CGFloat) {
        let updated = max(4, min(14, chromeInset + delta))
        guard updated != chromeInset else { return }
        chromeInset = updated
        saveAndApplyChromeInset()
    }

    private func saveAndApplyChromeInset() {
        UserDefaults.standard.set(Double(chromeInset), forKey: "apsa-browser-chrome-inset")
        scheduleChromeSync()
        settingsWindow?.refreshValues()
        addressTopConstraint?.constant = transparentTitlebarOffset + chromeInset
        addressBottomConstraint?.constant = -chromeInset
        controlsTrailingConstraint?.constant = -(chromeInset + windowRightStrokeCompensation)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            rootMaterial.layoutSubtreeIfNeeded()
        }
    }

    private func showNativePage(_ url: URL) {
        releaseWebSurface()
        clearActiveSurface()
        let page = NativeApsaPage(url: url, navigate: { [weak self] target in self?.navigate(to: target) },
                                  openInNewTab: { [weak self] target in self?.openInNewTab(target) })
        nativePage = page
        pin(page)
        addressField.stringValue = displayAddress(for: url)
        let route = url.host?.lowercased() ?? "home"
        let pageTitle = apsaInternalPageTitle(route)
        window?.title = route == "home" ? appName : "\(pageTitle) — \(appName)"
        updateActiveTab(title: pageTitle)
        updateNavigationButtons()
        reloadButton.isEnabled = true
        updateReaderButton()
        progress.isHidden = true
    }

    private func showWebPage(_ url: URL) {
        releaseWebSurface()
        clearActiveSurface()
        let webView = ensureWebSurface()
        addressField.stringValue = displayAddress(for: url)
        updateReaderButton()
        progress.doubleValue = 0.1
        progress.isHidden = false
        ApsaContentBlocker.shared.whenReady { [weak self, weak webView] in
            guard let self, let webView, self.webView === webView, self.currentURL == url else { return }
            ApsaContentBlocker.shared.apply(to: webView, for: url)
            if url.isFileURL { webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
            else { webView.load(URLRequest(url: url)) }
        }
    }

    // MARK: Reader

    private func updateReaderButton() {
        let reading = readerPage != nil
        readerButton.image = NSImage(systemSymbolName: reading ? "doc.plaintext.fill" : "doc.plaintext", accessibilityDescription: apsaText("Reader Mode"))
        readerButton.isEnabled = reading || (webView != nil && webView?.isLoading == false && !compiling)
        readerButton.toolTip = reading ? apsaText("Close Reader Mode") : apsaText("Reader Mode")
        scheduleChromeSync()
    }

    // The page stays loaded behind the reader, so leaving it is instant.
    private func showReader(_ document: ApsaReaderDocument) {
        readerPage?.removeFromSuperview()
        let page = ApsaReaderPage(document: document) { [weak self] target in self?.navigate(to: target) }
        readerPage = page
        readerSourceURL = document.url
        webView?.isHidden = true
        pin(page)
        applyPageZoom()
        window?.makeFirstResponder(page)
        updateReaderButton()
    }

    private func hideReader() {
        guard let page = readerPage else { return }
        page.removeFromSuperview()
        readerPage = nil
        readerSourceURL = nil
        webView?.isHidden = false
        if let webView { window?.makeFirstResponder(webView) }
        updateReaderButton()
    }

    private func openReader() {
        guard !compiling, let webView, !webView.isLoading else { return }
        if readerResources == nil { readerResources = ApsaReaderResources() }
        guard let readerResources else { return }
        compiling = true
        updateReaderButton()
        ApsaReader.extract(from: webView, resources: readerResources) { [weak self, weak webView] document in
            guard let self else { return }
            self.compiling = false
            guard let webView, self.webView === webView else { self.updateReaderButton(); return }
            guard let document else {
                self.updateReaderButton()
                self.showReaderRefusal()
                return
            }
            self.showReader(document)
        }
    }

    private func showReaderRefusal() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = apsaText("There's no article to read on this page")
        alert.informativeText = apsaText("Reader Mode doesn't open pages where it finds no connected text, so it never silently loses anything.")
        alert.beginSheetModal(for: window)
    }

    // Page scripts depend on the site's exception, so they are set again per navigation.
    private func installScripts(on controller: WKUserContentController, for url: URL?) {
        controller.removeAllUserScripts()
        passwordAutofill.addScript(to: controller)
        controller.addUserScript(WKUserScript(source: ApsaFastFullscreen.controllerScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let store = ApsaPrivacyStore.shared
        let exception = url?.host.map(ApsaContentBlocker.shared.isAllowed(host:)) ?? false
        if store.settings.usesScript, !exception {
            controller.addUserScript(WKUserScript(source: ApsaPrivacy.script(store.settings, seed: store.seed), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
    }

    @objc private func privacyChanged() {
        let settings = ApsaPrivacyStore.shared.settings
        let views = [webView].compactMap { $0 } + tabs.compactMap(\.parked)
        for view in views {
            if #available(macOS 14.0, *) { view.configuration.websiteDataStore.proxyConfigurations = ApsaPrivacy.proxyConfigurations(settings) }
            view.configuration.preferences.isFraudulentWebsiteWarningEnabled = settings.fraudWarnings
        }
        ApsaContentBlocker.shared.updatePrivacyRules(ApsaPrivacy.ruleListJSON(settings)) { [weak self] in
            guard let self else { return }
            for view in views {
                ApsaContentBlocker.shared.apply(to: view, for: view.url)
                self.installScripts(on: view.configuration.userContentController, for: view.url)
                if view.url?.scheme == "http" || view.url?.scheme == "https" { view.reload() }
            }
        }
    }

    private func ensureWebSurface() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        let dataStore = isPrivate ? privateDataStore : WKWebsiteDataStore.default()
        if #available(macOS 14.0, *) { dataStore.proxyConfigurations = ApsaPrivacy.proxyConfigurations(ApsaPrivacyStore.shared.settings) }
        configuration.websiteDataStore = dataStore
        configuration.setURLSchemeHandler(allodSchemeHandler, forURLScheme: ApsaAllod.scheme)
        configuration.preferences.isFraudulentWebsiteWarningEnabled = ApsaPrivacyStore.shared.settings.fraudWarnings
        // Without this WKWebView's user agent has no Safari token, and sites
        // such as YouTube and Google treat it as an unknown, older browser.
        configuration.applicationNameForUserAgent = safariUserAgentSuffix
        passwordAutofill.install(on: configuration)
        if #available(macOS 15.0, *) { pageTranslator?.install(on: configuration) }
        configuration.preferences.isElementFullscreenEnabled = !ApsaFastFullscreen.isEnabled
        configuration.userContentController.add(fastFullscreenHandler, name: ApsaFastFullscreen.handlerName)
        installScripts(on: configuration.userContentController, for: currentURL)
        if !isPrivate { ApsaExtensions.install(on: configuration.userContentController) }
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        if #available(macOS 13.3, *) { view.isInspectable = true }
        view.allowsBackForwardNavigationGestures = true
        view.underPageBackgroundColor = .clear
        contentContainer.usesWebKitGestures = true
        view.navigationDelegate = self
        view.uiDelegate = self
        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
        webView = view
        view.pageZoom = pageZoom
        observeWebView(view)
        animateIn(view)
        return view
    }

    // A page being thrown away must fall silent and stop decoding at once, not
    // whenever its process happens to exit.
    private func stopMedia(in view: WKWebView) {
        view.evaluateJavaScript("document.querySelectorAll('audio,video').forEach(m => { try { m.pause(); m.srcObject = null; } catch (_) {} })") { _, _ in }
        view.setAllMediaPlaybackSuspended(true, completionHandler: nil)
    }

    private func releaseWebSurface() {
        if #available(macOS 15.0, *), let webView, let translator = pageTranslatorStorage as? ApsaPageTranslator { translator.forget(webView) }
        observations.forEach { $0.invalidate() }
        observations.removeAll(keepingCapacity: false)
        if let webView { stopMedia(in: webView) }
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        contentContainer.usesWebKitGestures = false
    }

    private func observeWebView(_ view: WKWebView) {
        observations = [
            view.observe(\.url, options: [.new]) { [weak self] view, _ in
                guard let self, let url = view.url else { return }
                self.currentURL = url
                self.activeTab?.history.replaceCurrent(url)
                self.recordVisit(url)
                if !self.isPrivate { self.passwordAutofill.pageChanged(view, window: self.window) }
                if self.webChromeVisible || self.window?.firstResponder !== self.addressField.currentEditor() {
                    self.addressField.stringValue = self.displayAddress(for: url)
                }
                self.updateActiveTab(url: url)
            },
            view.observe(\.title, options: [.new]) { [weak self] view, _ in
                guard let self else { return }
                self.window?.title = view.title.map { "\($0) — \(appName)" } ?? appName
                if let title = view.title { self.updateActiveTab(title: title) }
            },
            view.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.updateNavigationButtons() },
            view.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in self?.updateNavigationButtons() },
            view.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                self?.progress.doubleValue = view.estimatedProgress
                self?.progress.isHidden = view.estimatedProgress >= 1
            }
        ]
    }

    private func loadFavicon(from webView: WKWebView) {
        let script = """
        (() => {
          const icon = document.querySelector('link[rel~="icon"]');
          return icon?.href || new URL('/favicon.ico', location.href).href;
        })()
        """
        let tabID = activeTabID
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self, let raw = value as? String, let url = URL(string: raw),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            self.faviconTask?.cancel()
            let key = url.absoluteString as NSString
            if let cached = faviconCache.object(forKey: key), let tabID, let tab = self.tabs.first(where: { $0.id == tabID }) {
                tab.icon = cached
                if let icon = tab.iconDataURL { ApsaBookmarkStore.shared.setIcon(icon, for: tab.url) }
                self.renderTabs()
                return
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            // A private window, or a proxy, must not be undone by a request of the browser's own.
            guard !self.isPrivate, ApsaPrivacyStore.shared.settings.proxyHost.isEmpty else { return }
            self.faviconTask = faviconSession.dataTask(with: request) { [weak self] data, response, _ in
                guard let self, let data, data.count <= 1_048_576,
                      let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                      let image = downsampledFavicon(data) else { return }
                faviconCache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height) * 4)
                DispatchQueue.main.async {
                    guard let tabID, let tab = self.tabs.first(where: { $0.id == tabID }) else { return }
                    tab.icon = image
                    if let icon = tab.iconDataURL { ApsaBookmarkStore.shared.setIcon(icon, for: tab.url) }
                    self.renderTabs()
                }
            }
            self.faviconTask?.resume()
        }
    }

    private func updateNavigationButtons() {
        backButton.isEnabled = (webView?.canGoBack ?? false) || (activeTab?.history.canGoBack ?? false)
        forwardButton.isEnabled = (webView?.canGoForward ?? false) || (activeTab?.history.canGoForward ?? false)
    }

    private func navigateHistory(_ offset: Int) {
        guard let url = activeTab?.history.move(offset) else { return }
        navigate(to: url, recordingHistory: false)
    }

    @objc private func goBack() {
        if let webView, webView.canGoBack { webView.goBack() }
        else { navigateHistory(-1) }
    }
    @objc private func goForward() {
        if let webView, webView.canGoForward { webView.goForward() }
        else { navigateHistory(1) }
    }
    @objc private func reload() {
        hideReader()
        if let webView {
            if webView.isLoading { webView.stopLoading() }
            else { webView.reload() }
        } else {
            showNativePage(currentURL)
        }
    }
    @objc private func toggleReader() {
        if readerPage != nil { hideReader() } else { openReader() }
    }
    @objc private func openAddress() {
        let unchanged = addressField.stringValue == displayAddress(for: currentURL)
        guard let url = unchanged ? currentURL : normalizedURL(addressField.stringValue) else { return }
        navigate(to: url)
        window?.makeFirstResponder(webView ?? nativePage)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // A size means a real popup; a plain target=_blank link stays in the tab as before.
        if windowFeatures.width != nil || windowFeatures.height != nil {
            return ApsaPopupWindow(configuration: configuration, features: windowFeatures, parent: window).webView
        }
        if webView === self.webView, navigationAction.targetFrame == nil, let url = navigationAction.request.url { navigate(to: url) }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let url = navigationAction.request.url, let kind = surfaceKind(for: url) else {
            decisionHandler(.cancel, preferences)
            return
        }
        if kind == .internalPage {
            decisionHandler(.cancel, preferences)
            guard webView === self.webView else { return }
            DispatchQueue.main.async { [weak self] in self?.navigate(to: url) }
            return
        }
        let settings = ApsaPrivacyStore.shared.settings
        if navigationAction.targetFrame?.isMainFrame == true {
            let exception = url.host.map(ApsaContentBlocker.shared.isAllowed(host:)) ?? false
            if !exception {
                // Rewritten addresses load as a fresh request; the original never goes out.
                var rewritten = settings.stripTrackingParameters ? ApsaPrivacy.cleaned(url) : nil
                if settings.httpsOnly, !insecureAllowedHosts.contains(url.host?.lowercased() ?? ""), let secure = ApsaPrivacy.httpsVersion(of: rewritten ?? url) {
                    rewritten = secure
                    upgradedToHTTPS[ObjectIdentifier(webView)] = url
                }
                if let rewritten {
                    decisionHandler(.cancel, preferences)
                    DispatchQueue.main.async { webView.load(URLRequest(url: rewritten)) }
                    return
                }
            }
            // Each site's exception must be in force before its page starts to load.
            ApsaContentBlocker.shared.apply(to: webView, for: url)
            installScripts(on: webView.configuration.userContentController, for: url)
            preferences.allowsContentJavaScript = !settings.disableJavaScript || exception
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(ApsaPrivacyStore.shared.settings.denyCameraAndMicrophone && !ApsaContentBlocker.shared.isAllowed(host: origin.host) ? .deny : .prompt)
    }

    // In HTTPS-only mode a site that has no secure version asks before it opens.
    private func offerInsecure(_ original: URL, in view: WKWebView) {
        guard let window, let host = original.host?.lowercased() else { return }
        let alert = NSAlert()
        alert.messageText = apsaText("%@ can't be opened over a secure connection", host)
        alert.informativeText = apsaText("Without encryption, anyone on the network can read or change this page and what you type into it.")
        alert.addButton(withTitle: apsaText("Don't Open"))
        alert.addButton(withTitle: apsaText("Open Without Encryption"))
        alert.beginSheetModal(for: window) { [weak self, weak view] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.insecureAllowedHosts.insert(host)
            view?.load(URLRequest(url: original))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { showFailure(error) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if let original = upgradedToHTTPS.removeValue(forKey: ObjectIdentifier(webView)), (error as NSError).code != NSURLErrorCancelled {
            offerInsecure(original, in: webView)
        }
        if webView === self.webView { showFailure(error) }
    }
    // A background page whose process died is loaded again when its tab is selected.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === self.webView { webView.reload(); return }
        for tab in tabs {
            if tab.parked === webView { releaseParked(tab) }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        upgradedToHTTPS[ObjectIdentifier(webView)] = nil
        ApsaFastFullscreen.apply(to: webView)
        guard webView === self.webView else { return }
        if !isPrivate { passwordAutofill.pageChanged(webView, window: window) }
        updateReaderButton()
        loadFavicon(from: webView)
    }

    private func showFailure(_ error: Error) {
        progress.isHidden = true
        updateReaderButton()
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let recentHistoryTag = 7_001
    private static let recentHistoryCount = 15
    private lazy var resourcePressure = ApsaResourcePressure(
        hibernate: { [weak self] age in self?.windows.forEach { $0.hibernateBackgroundTabs(olderThan: age) } },
        purge: { faviconCache.removeAllObjects() }
    )
    private var sessionSaveScheduled = false
    private var historyMenu: NSMenu?
    private var bookmarksMenu: NSMenu?
    private var windows: [BrowserWindowController] = []
    private var active: BrowserWindowController?
    private var pendingURL: URL?
    private var browser: BrowserWindowController? { active ?? windows.last }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let argumentURL = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }.compactMap { normalizedURL($0) }.first
        let requested = pendingURL ?? argumentURL
        // WebKit has its own cache for pages. This one bounds the browser's own
        // requests, such as favicons, so they are not fetched twice.
        URLCache.shared = URLCache(memoryCapacity: 64 * 1_024 * 1_024, diskCapacity: 512 * 1_024 * 1_024)
        ApsaContentBlocker.shared.updatePrivacyRules(ApsaPrivacy.ruleListJSON(ApsaPrivacyStore.shared.settings)) {
            NotificationCenter.default.post(name: ApsaContentBlocker.changed, object: nil)
        }
        ApsaContentBlocker.shared.start()
        let savedWindows = ApsaSessionStore.shared.load()
        if savedWindows.isEmpty {
            openWindow(requested ?? homeURL)
        } else {
            savedWindows.forEach { openWindow(homeURL, restoring: $0) }
            if let requested { browser?.openInNewTab(requested) }
        }
        NSApp.activate(ignoringOtherApps: true)
        buildMenu()
        resourcePressure.start()
        // WebKit keeps Control-Tab for its own focus handling before the menu sees it.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == 48, modifiers.contains(.control), !modifiers.contains(.command) else { return event }
            self?.browser?.selectAdjacentTab(modifiers.contains(.shift) ? -1 : 1)
            return nil
        }
    }

    private func openWindow(_ url: URL, restoring saved: ApsaSavedWindow? = nil, isPrivate: Bool = false) {
        let controller = BrowserWindowController(initialURL: url, cascadingFrom: browser?.window?.frame, restoring: saved, isPrivate: isPrivate)
        controller.onBecameActive = { [weak self] in self?.active = $0 }
        controller.onSessionChange = { [weak self] in self?.saveSession() }
        controller.onClosed = { [weak self] closed in
            guard let self else { return }
            // The last window closing quits the app and is what the next launch restores.
            guard self.windows.count > 1 else { return }
            self.windows.removeAll { $0 === closed }
            if self.active === closed { self.active = self.windows.last }
            self.saveSession()
        }
        windows.append(controller)
        saveSession()
        active = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, surfaceKind(for: url) != nil else { return }
        if let browser { browser.navigate(to: url) } else { pendingURL = url }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    private func saveSession() {
        guard !sessionSaveScheduled else { return }
        sessionSaveScheduled = true
        // Tab changes arrive in bursts; the snapshot is taken once, after them.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sessionSaveScheduled = false
            ApsaSessionStore.shared.save(self.windows.filter { !$0.isPrivate }.map(\.savedState))
        }
    }

    // Clearing is asynchronous, so quitting waits for it, but never for long.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ApsaPrivacyStore.shared.settings.clearDataOnQuit else { return .terminateNow }
        var answered = false
        let answer = {
            guard !answered else { return }
            answered = true
            ApsaHistoryStore.shared.clear()
            ApsaSessionStore.shared.restoresTabs = false
            ApsaSessionStore.shared.restoresTabs = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        ApsaPrivacyStore.shared.clearWebData(completion: answer)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: answer)
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !ApsaPrivacyStore.shared.settings.clearDataOnQuit {
            ApsaSessionStore.shared.save(windows.filter { !$0.isPrivate }.map(\.savedState))
        }
        ApsaSessionStore.shared.saveNow()
        ApsaHistoryStore.shared.saveNow()
        ApsaBookmarkStore.shared.saveNow()
    }

    // Recent pages are read when the menu opens, so visits cost the menu nothing.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === bookmarksMenu {
            menu.items.filter { $0.tag == Self.recentHistoryTag }.forEach(menu.removeItem)
            let saved = ApsaBookmarkStore.shared.bookmarks.prefix(25)
            if !saved.isEmpty {
                let separator = NSMenuItem.separator()
                separator.tag = Self.recentHistoryTag
                menu.addItem(separator)
            }
            for bookmark in saved {
                guard let url = URL(string: bookmark.url) else { continue }
                let title = bookmark.title.count > 60 ? String(bookmark.title.prefix(59)) + "…" : bookmark.title
                let item = NSMenuItem(title: title, action: #selector(openSavedBookmark(_:)), keyEquivalent: "")
                item.representedObject = url
                item.tag = Self.recentHistoryTag
                item.toolTip = bookmark.url
                menu.addItem(item)
            }
            return
        }
        guard menu === historyMenu else { return }
        menu.items.filter { $0.tag == Self.recentHistoryTag }.forEach(menu.removeItem)
        guard var index = menu.items.firstIndex(where: { $0.action == #selector(clearHistory) }) else { return }
        for entry in ApsaHistoryStore.shared.entries.prefix(Self.recentHistoryCount) {
            guard let url = URL(string: entry.url) else { continue }
            let title = entry.title.isEmpty ? (url.host ?? entry.url) : entry.title
            let item = NSMenuItem(title: title.count > 60 ? String(title.prefix(59)) + "…" : title, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.tag = Self.recentHistoryTag
            item.toolTip = entry.url
            menu.insertItem(item, at: index)
            index += 1
        }
        if menu.items.contains(where: { $0.tag == Self.recentHistoryTag }) {
            let separator = NSMenuItem.separator()
            separator.tag = Self.recentHistoryTag
            menu.insertItem(separator, at: index)
        }
    }

    private func buildMenu() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            main.addItem(item)
            let menu = NSMenu(title: apsaText(title))
            item.submenu = menu
            return menu
        }
        @discardableResult
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let item = menu.addItem(withTitle: apsaText(title), action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = tag
            return item
        }
        // Second spellings of a shortcut work without taking a line in the menu.
        func addHidden(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) {
            let item = add(menu, title, action, key, modifiers)
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
        }
        func arrow(_ code: Int) -> String { String(UnicodeScalar(code)!) }

        let app = submenu(appName)
        add(app, "Settings…", #selector(showSettings), ",")
        app.addItem(.separator())
        add(app, apsaText("Hide %@", appName), #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, apsaText("Quit %@", appName), #selector(NSApplication.terminate(_:)), "q")

        let file = submenu("File")
        add(file, "New Window", #selector(newWindow), "n")
        add(file, "New Private Window", #selector(newPrivateWindow), "n", [.command, .shift])
        add(file, "New Tab", #selector(newTab), "t")
        add(file, "Reopen Closed Tab", #selector(reopenTab), "t", [.command, .shift])
        add(file, "Open File…", #selector(openDocument), "o")
        add(file, "Open Location", #selector(focusAddress), "l")
        file.addItem(.separator())
        add(file, "Close Tab", #selector(closeTab), "w")
        add(file, "Close Window", #selector(closeWindow), "w", [.command, .shift])
        file.addItem(.separator())
        add(file, "Print…", #selector(printPage), "p")
        file.addItem(.separator())
        add(file, "Fill Password…", #selector(fillPassword), "l", [.command, .shift])
        add(file, "Show Passwords", #selector(showPasswords), "p", [.command, .option])

        let edit = submenu("Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        add(edit, "Find on Page…", #selector(findInPage), "f")
        add(edit, "Find Next", #selector(findNext), "g")
        add(edit, "Find Previous", #selector(findPrevious), "g", [.command, .shift])

        let view = submenu("View")
        add(view, "Show or Hide Tabs", #selector(toggleSidebar), "e")
        add(view, "Show or Hide Toolbar", #selector(toggleToolbar), "m", [.command, .shift])
        add(view, "Enter Full Screen", #selector(toggleFullscreen), "f", [.command, .control])
        add(view, "Browser Stats", #selector(showPerformanceStats))
        view.addItem(.separator())
        add(view, "Reload", #selector(reloadPage), "r")
        add(view, "Reload Without Cache", #selector(reloadFromOrigin), "r", [.command, .option])
        add(view, "Stop", #selector(stopLoading), ".")
        add(view, "Reader Mode", #selector(toggleReader), "r", [.command, .shift])
        add(view, "Translate Page or Show Original", #selector(toggleTranslation), "t", [.command, .option])
        add(view, "Ad Blocking on This Site", #selector(toggleSiteBlocking), "a", [.command, .option])
        view.addItem(.separator())
        add(view, "Zoom In", #selector(zoomIn), "=")
        addHidden(view, "Zoom In", #selector(zoomIn), "+", .command)
        add(view, "Zoom Out", #selector(zoomOut), "-")
        add(view, "Actual Size", #selector(resetZoom), "0")
        view.addItem(.separator())
        add(view, "Decrease URL Bar Inset", #selector(decreaseChromeInset), "[", [.command, .option])
        add(view, "Increase URL Bar Inset", #selector(increaseChromeInset), "]", [.command, .option])
        add(view, "Reset URL Bar Inset", #selector(resetChromeInset))

        let history = submenu("History")
        add(history, "Back", #selector(goBack), "[")
        add(history, "Forward", #selector(goForward), "]")
        add(history, "Home", #selector(goHome), "h", [.command, .shift])
        history.addItem(.separator())
        add(history, "Show All History", #selector(showHistory), "y")
        history.addItem(.separator())
        add(history, "Clear History…", #selector(clearHistory))
        history.delegate = self
        historyMenu = history

        let bookmarks = submenu("Bookmarks")
        add(bookmarks, "Add or Remove Bookmark", #selector(toggleBookmark), "d")
        add(bookmarks, "Save All Tabs to Bookmarks…", #selector(saveAllTabs), "d", [.command, .shift])
        add(bookmarks, "Show All Bookmarks", #selector(showBookmarks), "b", [.command, .option])
        add(bookmarks, "Collapse or Expand Bookmarks", #selector(toggleBookmarksSection), "b", [.command, .shift])
        bookmarks.delegate = self
        bookmarksMenu = bookmarks

        let tabs = submenu("Tabs")
        add(tabs, "Next Tab", #selector(nextTab), "\t", .control)
        add(tabs, "Previous Tab", #selector(previousTab), "\t", [.control, .shift])
        addHidden(tabs, "Next Tab", #selector(nextTab), "]", [.command, .shift])
        addHidden(tabs, "Previous Tab", #selector(previousTab), "[", [.command, .shift])
        addHidden(tabs, "Next Tab", #selector(nextTab), arrow(NSRightArrowFunctionKey), [.command, .option])
        addHidden(tabs, "Previous Tab", #selector(previousTab), arrow(NSLeftArrowFunctionKey), [.command, .option])
        tabs.addItem(.separator())
        add(tabs, "New Folder with This Tab…", #selector(newTabFolder), "n", [.command, .option])
        tabs.addItem(.separator())
        for number in 1...8 { add(tabs, apsaText("Tab %d", number), #selector(selectNumberedTab(_:)), String(number), tag: number) }
        add(tabs, "Last Tab", #selector(selectNumberedTab(_:)), "9", tag: 9)

        let window = submenu("Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }

    @objc private func showSettings() { browser?.showSettings() }
    @objc private func newWindow() { openWindow(homeURL) }
    @objc private func newPrivateWindow() { openWindow(homeURL, isPrivate: true) }
    @objc private func openDocument() { browser?.openDocument() }
    @objc private func newTab() { browser?.openNewTab() }
    @objc private func reopenTab() { browser?.reopenClosedTab() }
    // Command-W belongs to whatever window is in front, including Settings.
    @objc private func closeTab() {
        if let key = NSApp.keyWindow, key.windowController !== browser { key.performClose(nil); return }
        browser?.closeCurrentTab()
    }
    @objc private func closeWindow() { NSApp.keyWindow?.performClose(nil) }
    @objc private func printPage() { browser?.printPage() }
    @objc private func focusAddress() { browser?.focusAddress() }
    @objc private func reloadPage() { browser?.reloadCurrentPage() }
    @objc private func reloadFromOrigin() { browser?.reloadFromOrigin() }
    @objc private func stopLoading() { browser?.stopLoading() }
    @objc private func goBack() { browser?.goBackInHistory() }
    @objc private func goForward() { browser?.goForwardInHistory() }
    @objc private func goHome() { browser?.goHome() }
    @objc private func showHistory() { browser?.showHistory() }
    @objc private func toggleBookmark() { browser?.toggleBookmark() }
    @objc private func toggleFullscreen() { browser?.toggleFullscreen() }
    @objc private func showPerformanceStats() { browser?.showPerformanceStats() }
    @objc private func toggleSiteBlocking() { browser?.toggleSiteBlocking() }
    @objc private func toggleTranslation() { browser?.toggleTranslation() }
    @objc private func saveAllTabs() { browser?.saveAllTabsToBookmarks() }
    @objc private func newTabFolder() { browser?.createFolderForActiveTab() }
    @objc private func showBookmarks() { browser?.showBookmarks() }
    @objc private func showPasswords() { browser?.showPasswords() }
    @objc private func fillPassword() { browser?.fillPassword() }
    @objc private func toggleBookmarksSection() { browser?.toggleBookmarksSection() }
    @objc private func openSavedBookmark(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { browser?.openBookmarkEntry(url) }
    }
    @objc private func clearHistory() { browser?.clearHistory() }
    @objc private func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { browser?.openHistoryEntry(url) }
    }
    @objc private func toggleSidebar() { browser?.toggleSidebarVisibility() }
    @objc private func toggleToolbar() { browser?.toggleToolbarVisibility() }
    @objc private func toggleReader() { browser?.toggleReaderMode() }
    @objc private func findInPage() { browser?.findInPage() }
    @objc private func findNext() { browser?.findStep(forward: true) }
    @objc private func findPrevious() { browser?.findStep(forward: false) }
    @objc private func zoomIn() { browser?.zoomIn() }
    @objc private func zoomOut() { browser?.zoomOut() }
    @objc private func resetZoom() { browser?.resetZoom() }
    @objc private func nextTab() { browser?.selectAdjacentTab(1) }
    @objc private func previousTab() { browser?.selectAdjacentTab(-1) }
    @objc private func selectNumberedTab(_ sender: NSMenuItem) { browser?.selectTab(shortcut: sender.tag) }
    @objc private func decreaseChromeInset() { browser?.decreaseChromeInset() }
    @objc private func increaseChromeInset() { browser?.increaseChromeInset() }
    @objc private func resetChromeInset() { browser?.resetChromeInset() }
}

@main
struct ApsaBrowserMain {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            let checks: [(String, String, SurfaceKind)] = [
                ("browser://about", "browser://about", .internalPage),
                ("example.com", "https://example.com", .web),
                ("hello world", "https://duckduckgo.com/?q=hello%20world", .web),
                ("/tmp/page.html", "file:///tmp/page.html", .web),
                ("allod://localhost/", "allod://localhost/", .web)
            ]
            for (input, expected, kind) in checks {
                guard let url = normalizedURL(input), url.absoluteString == expected, surfaceKind(for: url) == kind else {
                    fputs("self-test failed for \(input)\n", stderr)
                    exit(1)
                }
            }
            print("Apsa Browser self-test: native/web routing OK")
            exit(0)
        }
        
        ApsaLanguage.applyToSystemStrings()
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
