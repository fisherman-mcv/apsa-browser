import AppKit

struct ApsaPalette {
    let background: NSColor
    let surface: NSColor
    let text: NSColor
    let secondary: NSColor
    let accent: NSColor
    let warning: NSColor
    let line: NSColor
}

// Tint only the material, not its content. A normal translucent color layer
// keeps the system blur live without lowering text/control opacity.
private final class ApsaTintLayer: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

class ApsaGlassView: NSVisualEffectView {
    private let tint = ApsaTintLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        tint.frame = bounds
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.setAccessibilityElement(false)
        addSubview(tint)
    }
    required init?(coder: NSCoder) { fatalError() }
    func applyTint(_ color: NSColor, opacity: CGFloat) {
        state = .active
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        // Respect the user's system accessibility setting without changing it.
        let alpha: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : opacity
        tint.layer?.backgroundColor = color.withAlphaComponent(alpha).cgColor
    }
}

extension NSColor {
    convenience init(apsaHex: UInt32) {
        self.init(srgbRed: CGFloat((apsaHex >> 16) & 255) / 255, green: CGFloat((apsaHex >> 8) & 255) / 255, blue: CGFloat(apsaHex & 255) / 255, alpha: 1)
    }
    var apsaRGB: UInt32? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        let r = UInt32((max(0, min(1, rgb.redComponent)) * 255).rounded())
        let g = UInt32((max(0, min(1, rgb.greenComponent)) * 255).rounded())
        let b = UInt32((max(0, min(1, rgb.blueComponent)) * 255).rounded())
        return (r << 16) | (g << 8) | b
    }
}

enum ApsaTheme: String, CaseIterable {
    case nature, minimalist, fisherman, hacker, midnight, ocean, rose, graphite, sunset, gamer
    var title: String {
        switch self {
        case .nature: return "Nature 🌿"
        case .minimalist: return "Minimalist 🤍"
        case .fisherman: return "Fisherman 💎"
        case .hacker: return "Hacker 🔥"
        case .midnight: return "Midnight 🌙"
        case .ocean: return "Ocean 🌊"
        case .rose: return "Rose 🌸"
        case .graphite: return "Graphite 🪨"
        case .sunset: return "Sunset 🌅"
        case .gamer: return "Gamer 🎮"
        }
    }
    var caption: String {
        switch self {
        case .nature: return "Breathe."
        case .minimalist: return "Less is more."
        case .fisherman: return "Signature."
        case .hacker: return "Take control."
        case .midnight: return "Stay focused."
        case .ocean: return "Find your flow."
        case .rose: return "Feel inspired."
        case .graphite: return "Pure precision."
        case .sunset: return "Create freely."
        case .gamer: return "Your neon. Your game."
        }
    }
    var isLight: Bool { [.nature, .minimalist, .ocean, .rose, .sunset].contains(self) }
    var glassTint: NSColor {
        let p = palette
        return p.background.blended(withFraction: self == .gamer ? 0.2 : 0.12, of: p.accent) ?? p.background
    }
    var palette: ApsaPalette { palette(neon: ApsaThemeStore.shared.neonRGB) }
    func palette(neon: UInt32) -> ApsaPalette {
        let colors: (UInt32, UInt32, UInt32, UInt32, UInt32)
        switch self {
        case .nature: colors = (0xE8F0E5, 0xD8E5D3, 0x355840, 0x527759, 0x73986D)
        case .minimalist: colors = (0xF5F5F2, 0xE7E7E2, 0x353738, 0x686C6E, 0x696F72)
        case .fisherman: colors = (0x0F1726, 0x172740, 0xE2EDFF, 0x9EC5FF, 0x337BE7)
        case .hacker: colors = (0x09120F, 0x102D21, 0xA5F2C9, 0x6ADFA4, 0x36D989)
        case .midnight: colors = (0x171727, 0x24243D, 0xE2DFFA, 0xB8B5E9, 0x8179D2)
        case .ocean: colors = (0xDCEFF3, 0xC5E4ED, 0x245D71, 0x366F84, 0x438DA5)
        case .rose: colors = (0xF9E8EE, 0xF0D3DF, 0x82415C, 0x9F5470, 0xB9688A)
        case .graphite: colors = (0x26292D, 0x34383E, 0xE2E3E5, 0xB3BAC3, 0x98A2AF)
        case .sunset: colors = (0xFFF0DF, 0xFFE0BF, 0x8D4826, 0xA45A32, 0xD3763E)
        case .gamer: colors = (0x070A12, 0x111827, 0xE4EEFF, 0xA8B7D1, neon)
        }
        let accent = NSColor(apsaHex: colors.4)
        return ApsaPalette(background: NSColor(apsaHex: colors.0), surface: NSColor(apsaHex: colors.1), text: NSColor(apsaHex: colors.2), secondary: NSColor(apsaHex: colors.3), accent: accent, warning: NSColor(apsaHex: isLight ? 0xA5511B : 0xFFB76B), line: accent.withAlphaComponent(self == .gamer ? 0.7 : 0.24))
    }
}

final class ApsaThemeStore {
    static let shared = ApsaThemeStore()
    static let changed = Notification.Name("ApsaThemeChanged")
    static let chromeModeChanged = Notification.Name("ApsaChromeModeChanged")
    private let defaults: UserDefaults
    private(set) var selected: ApsaTheme
    private(set) var neonRGB: UInt32
    private(set) var chromeUsesWebView: Bool
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selected = ApsaTheme(rawValue: defaults.string(forKey: "apsa-browser-theme") ?? "") ?? .fisherman
        let value = defaults.object(forKey: "apsa-gamer-neon") as? NSNumber
        neonRGB = value.flatMap { $0.int64Value >= 0 && $0.int64Value <= 0xFFFFFF ? $0.uint32Value : nil } ?? 0x00E5FF
        chromeUsesWebView = defaults.bool(forKey: "apsa-browser-chrome-webview")
    }
    func select(_ theme: ApsaTheme) {
        guard selected != theme else { return }
        selected = theme; defaults.set(theme.rawValue, forKey: "apsa-browser-theme")
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
    func setChromeUsesWebView(_ enabled: Bool) {
        guard chromeUsesWebView != enabled else { return }
        chromeUsesWebView = enabled; defaults.set(enabled, forKey: "apsa-browser-chrome-webview")
        NotificationCenter.default.post(name: Self.chromeModeChanged, object: self)
    }
    func setNeon(_ color: NSColor) {
        guard let value = color.apsaRGB, value != neonRGB else { return }
        neonRGB = value; defaults.set(value, forKey: "apsa-gamer-neon")
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}

private final class ThemeCard: NSButton {
    let theme: ApsaTheme
    init(_ theme: ApsaTheme, target: AnyObject, action: Selector) {
        self.theme = theme
        super.init(frame: .zero)
        self.target = target; self.action = action
        title = theme.title; isBordered = false
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(theme.title + " · " + theme.caption)
        heightAnchor.constraint(equalToConstant: 114).isActive = true
        widthAnchor.constraint(equalToConstant: 222).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let p = theme.palette
        p.background.setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 14, yRadius: 14).fill()
        p.accent.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: NSRect(x: 17, y: 73, width: bounds.width - 34, height: 22), xRadius: 6, yRadius: 6).fill()
        p.text.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: 26, y: 82, width: 112, height: 4), xRadius: 2, yRadius: 2).fill()
        (theme.title as NSString).draw(at: NSPoint(x: 17, y: 43), withAttributes: [.font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: p.text])
        (theme.caption as NSString).draw(at: NSPoint(x: 17, y: 20), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: p.secondary])
        if ApsaThemeStore.shared.selected == theme {
            p.accent.setStroke(); let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 14, yRadius: 14)
            border.lineWidth = 2; border.stroke()
        }
    }
}

struct ApsaSettingsActions {
    let sidebarVisible: () -> Bool
    let setSidebarVisible: (Bool) -> Void
    let inset: () -> CGFloat
    let setInset: (CGFloat) -> Void
    let resetInset: () -> Void
    let showPasswords: () -> Void
    let clearSiteData: () -> Void
    let setFastFullscreen: (Bool) -> Void
}

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class SettingsCategoryRow: NSButton {
    init(title: String, symbol: String, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.title = title
        self.target = target; self.action = action
        isBordered = false; alignment = .left
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        imagePosition = .imageLeading; imageHugsTitle = true
        font = .systemFont(ofSize: 13, weight: .medium)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true; layer?.cornerRadius = 9
        heightAnchor.constraint(equalToConstant: 34).isActive = true
        widthAnchor.constraint(equalToConstant: 196).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func apply(selected: Bool, palette: ApsaPalette) {
        layer?.backgroundColor = selected ? palette.accent.withAlphaComponent(0.14).cgColor : NSColor.clear.cgColor
        contentTintColor = selected ? palette.accent : palette.secondary
        setAccessibilityValue(selected ? apsaText("Selected") : "")
    }
}

final class ApsaSettingsWindow: NSWindowController {
    private enum Category { case general, privacy, themes }
    private var category = Category.general
    private let actions: ApsaSettingsActions
    private var cards: [ThemeCard] = []
    private let neon = NSColorWell()
    private let neonLabel = NSTextField(labelWithString: "")
    private let sidebarSwitch = NSSwitch()
    private let insetStepper = NSStepper()
    private let insetLabel = NSTextField(labelWithString: "")
    private let restoreSwitch = NSSwitch()
    private let blockingSwitch = NSSwitch()
    private let translateTarget = NSPopUpButton()
    private let languagePicker = NSPopUpButton()
    private let fastFullscreenSwitch = NSSwitch()
    private let webViewSwitch = NSSwitch()
    private let scroll = NSScrollView()
    private let paneHost = SettingsDocumentView()
    private var generalPane: NSView?
    private var privacyPane: NSView?
    private var privacyRow: SettingsCategoryRow?
    private let levelPicker = NSSegmentedControl(labels: [apsaText("Standard"), apsaText("Strict"), apsaText("Maximum")], trackingMode: .selectOne, target: nil, action: nil)
    private let levelNote = NSTextField(wrappingLabelWithString: "")
    private let detailsButton = NSButton(title: apsaText("Detailed Settings"), target: nil, action: nil)
    private let details = NSStackView()
    private var switches: [(NSSwitch, WritableKeyPath<ApsaPrivacySettings, Bool>)] = []
    private let proxyHostField = NSTextField()
    private let proxyPortField = NSTextField()
    private let keepSitesField = NSTextField()
    private var themesPane: NSView?
    private var generalRow: SettingsCategoryRow?
    private var themesRow: SettingsCategoryRow?

    init(actions: ApsaSettingsActions) {
        self.actions = actions
        // Tall enough to show every setting without scrolling where the screen allows it.
        let height = min(860, (NSScreen.main?.visibleFrame.height ?? 860) - 24)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 954, height: height), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = apsaText("Settings"); panel.isReleasedWhenClosed = false
        panel.titlebarAppearsTransparent = true
        let glass = ApsaGlassView()
        glass.material = .popover; glass.blendingMode = .behindWindow
        panel.contentView = glass; panel.isOpaque = false
        super.init(window: panel)

        let general = SettingsCategoryRow(title: apsaText("General"), symbol: "slider.horizontal.3", target: self, action: #selector(showGeneral))
        let privacy = SettingsCategoryRow(title: apsaText("Privacy"), symbol: "hand.raised", target: self, action: #selector(showPrivacy))
        let themes = SettingsCategoryRow(title: apsaText("Themes"), symbol: "paintpalette", target: self, action: #selector(showThemes))
        generalRow = general; themesRow = themes; privacyRow = privacy
        let categories = NSStackView(views: [general, privacy, themes])
        categories.orientation = .vertical; categories.alignment = .leading; categories.spacing = 4
        categories.translatesAutoresizingMaskIntoConstraints = false

        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        paneHost.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = paneHost
        let content = panel.contentView!
        content.addSubview(categories); content.addSubview(scroll)
        NSLayoutConstraint.activate([
            categories.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            categories.topAnchor.constraint(equalTo: content.topAnchor, constant: 46),
            scroll.leadingAnchor.constraint(equalTo: categories.trailingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            paneHost.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        generalPane = makeGeneralPane()
        themesPane = makeThemesPane()
        privacyPane = makePrivacyPane()
        show(.general)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: ApsaThemeStore.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: ApsaPrivacyStore.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: ApsaThemeStore.chromeModeChanged, object: nil)
        refresh(); panel.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func pane(_ title: String) -> NSStackView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 23, weight: .bold); stack.addArrangedSubview(heading)
        return stack
    }

    private func settingRow(_ title: String, detail: String? = nil, controls: [NSView]) -> NSView {
        let labels = NSStackView(); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 3
        labels.addArrangedSubview(NSTextField(labelWithString: title))
        if let detail {
            let note = NSTextField(wrappingLabelWithString: detail)
            note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
            note.widthAnchor.constraint(equalToConstant: 500).isActive = true
            labels.addArrangedSubview(note)
        }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [labels, spacer] + controls); row.orientation = .horizontal; row.spacing = 10
        row.alignment = detail == nil ? .centerY : .top
        row.widthAnchor.constraint(equalToConstant: 686).isActive = true
        return row
    }

    private func makeGeneralPane() -> NSView {
        let stack = pane(apsaText("General"))
        languagePicker.addItems(withTitles: ApsaLanguage.allCases.map(\.name))
        languagePicker.target = self; languagePicker.action = #selector(changeLanguage(_:))
        languagePicker.setAccessibilityLabel(apsaText("Language"))
        stack.addArrangedSubview(settingRow(apsaText("Language"), controls: [languagePicker]))
        sidebarSwitch.target = self; sidebarSwitch.action = #selector(changeSidebar(_:))
        sidebarSwitch.setAccessibilityLabel(apsaText("Show Tab Sidebar"))
        stack.addArrangedSubview(settingRow(apsaText("Show Tab Sidebar"), controls: [sidebarSwitch]))
        insetStepper.minValue = 4; insetStepper.maxValue = 14; insetStepper.increment = 1
        insetStepper.target = self; insetStepper.action = #selector(changeInset(_:))
        insetStepper.setAccessibilityLabel(apsaText("Address Bar Inset"))
        let reset = NSButton(title: apsaText("Reset"), target: self, action: #selector(resetInset))
        stack.addArrangedSubview(settingRow(apsaText("Address Bar Inset"), controls: [insetLabel, insetStepper, reset]))
        blockingSwitch.target = self; blockingSwitch.action = #selector(changeBlocking(_:))
        blockingSwitch.setAccessibilityLabel(apsaText("Block Ads and Trackers"))
        stack.addArrangedSubview(settingRow(apsaText("Block Ads and Trackers"), detail: apsaText("EasyList and EasyPrivacy rules run inside WebKit. To turn blocking off for one site, use the shield in the address bar."), controls: [blockingSwitch]))
        translateTarget.addItems(withTitles: ApsaTranslationText.targets.map(\.name))
        translateTarget.target = self; translateTarget.action = #selector(changeTranslateTarget(_:))
        translateTarget.setAccessibilityLabel(apsaText("Page Translation Language"))
        stack.addArrangedSubview(settingRow(apsaText("Page Translation Language"), detail: apsaText("Translation runs on this Mac. Page text isn't sent anywhere."), controls: [translateTarget]))
        fastFullscreenSwitch.target = self; fastFullscreenSwitch.action = #selector(changeFastFullscreen(_:))
        fastFullscreenSwitch.setAccessibilityLabel(apsaText("Fast Full Screen for Video"))
        stack.addArrangedSubview(settingRow(apsaText("Fast Full Screen for Video"), detail: apsaText("YouTube videos fill the window at once, without a separate macOS space."), controls: [fastFullscreenSwitch]))
        restoreSwitch.target = self; restoreSwitch.action = #selector(changeRestore(_:))
        restoreSwitch.setAccessibilityLabel(apsaText("Restore Tabs on Launch"))
        stack.addArrangedSubview(settingRow(apsaText("Restore Tabs on Launch"), detail: apsaText("Open tab addresses and folders are kept on this Mac. Turning this off deletes the saved list."), controls: [restoreSwitch]))
        let passwords = NSButton(title: apsaText("Open Passwords"), target: self, action: #selector(openPasswords))
        stack.addArrangedSubview(settingRow(apsaText("Passwords"), detail: apsaText("Kept in the macOS keychain on this Mac."), controls: [passwords]))
        return stack
    }

    private func makeThemesPane() -> NSView {
        let stack = pane(apsaText("Themes"))
        for start in stride(from: 0, to: ApsaTheme.allCases.count, by: 3) {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 10
            for theme in ApsaTheme.allCases.dropFirst(start).prefix(3) {
                let card = ThemeCard(theme, target: self, action: #selector(choose(_:)))
                cards.append(card); row.addArrangedSubview(card)
            }
            stack.addArrangedSubview(row)
        }
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 12
        let label = NSTextField(labelWithString: apsaText("Gamer Neon"))
        neon.target = self; neon.action = #selector(changeNeon(_:))
        neon.setAccessibilityLabel(apsaText("Gamer Neon Color"))
        neon.widthAnchor.constraint(equalToConstant: 52).isActive = true
        row.addArrangedSubview(label); row.addArrangedSubview(neon); row.addArrangedSubview(neonLabel)
        stack.addArrangedSubview(row)
        let note = NSTextField(labelWithString: apsaText("The color is saved. Neon applies only to the Gamer theme."))
        note.font = .systemFont(ofSize: 12); stack.addArrangedSubview(note)

        let heading = NSTextField(labelWithString: apsaText("Interface Settings"))
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        stack.addArrangedSubview(heading)
        stack.setCustomSpacing(26, after: note)
        webViewSwitch.target = self; webViewSwitch.action = #selector(changeWebView(_:))
        webViewSwitch.setAccessibilityLabel(apsaText("WebView Interface"))
        stack.addArrangedSubview(settingRow(apsaText("WebView Interface"), detail: apsaText("The toolbar and tabs are drawn with HTML and CSS, so you can change them in chrome.css. Uses more memory than the standard interface."), controls: [webViewSwitch]))
        let open = NSButton(title: apsaText("Show chrome.css"), target: self, action: #selector(showStylesheet))
        stack.addArrangedSubview(open)
        return stack
    }

    private func show(_ next: Category) {
        category = next
        paneHost.subviews.forEach { $0.removeFromSuperview() }
        guard let pane = next == .general ? generalPane : next == .privacy ? privacyPane : themesPane else { return }
        paneHost.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: paneHost.leadingAnchor, constant: 20),
            pane.topAnchor.constraint(equalTo: paneHost.topAnchor, constant: 42),
            pane.bottomAnchor.constraint(equalTo: paneHost.bottomAnchor, constant: -24)
        ])
        refresh()
        scroll.contentView.scroll(to: .zero)
    }

    func refreshValues() { refresh() }

    @objc private func showGeneral() { show(.general) }
    @objc private func showThemes() { show(.themes) }
    @objc private func showPrivacy() { show(.privacy) }
    @objc private func chooseLevel(_ sender: NSSegmentedControl) {
        ApsaPrivacyStore.shared.choose([ApsaPrivacyLevel.standard, .strict, .maximum][sender.selectedSegment])
    }
    @objc private func toggleDetails() {
        details.isHidden.toggle()
        detailsButton.title = details.isHidden ? apsaText("Detailed Settings") : apsaText("Hide Detailed Settings")
    }
    @objc private func changePrivacySwitch(_ sender: NSSwitch) {
        guard let entry = switches.first(where: { $0.0 === sender }) else { return }
        ApsaPrivacyStore.shared.set(entry.1, sender.state == .on)
    }
    @objc private func changeProxy() {
        ApsaPrivacyStore.shared.update {
            $0.proxyHost = proxyHostField.stringValue.trimmingCharacters(in: .whitespaces)
            $0.proxyPort = proxyPortField.integerValue
        }
    }
    @objc private func changeKeepSites() {
        ApsaPrivacyStore.shared.update {
            $0.keepDataSites = keepSitesField.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        }
    }
    @objc private func clearData() { actions.clearSiteData() }

    private func makePrivacyPane() -> NSView {
        let stack = pane(apsaText("Privacy"))
        levelPicker.target = self
        levelPicker.action = #selector(chooseLevel(_:))
        levelPicker.setAccessibilityLabel(apsaText("Privacy Level"))
        stack.addArrangedSubview(levelPicker)
        levelNote.font = .systemFont(ofSize: 13)
        levelNote.textColor = .secondaryLabelColor
        levelNote.widthAnchor.constraint(equalToConstant: 686).isActive = true
        stack.addArrangedSubview(levelNote)
        let clear = NSButton(title: apsaText("Delete Site Data…"), target: self, action: #selector(clearData))
        detailsButton.target = self
        detailsButton.action = #selector(toggleDetails)
        let buttons = NSStackView(views: [detailsButton, clear])
        buttons.orientation = .horizontal
        stack.addArrangedSubview(buttons)

        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 10
        details.isHidden = true
        func section(_ title: String) {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 15, weight: .semibold)
            details.addArrangedSubview(label)
            if details.arrangedSubviews.count > 1 { details.setCustomSpacing(18, after: details.arrangedSubviews[details.arrangedSubviews.count - 2]) }
        }
        func toggle(_ title: String, _ detail: String, _ path: WritableKeyPath<ApsaPrivacySettings, Bool>) {
            let control = NSSwitch()
            control.target = self
            control.action = #selector(changePrivacySwitch(_:))
            control.setAccessibilityLabel(title)
            switches.append((control, path))
            details.addArrangedSubview(settingRow(title, detail: detail, controls: [control]))
        }
        section(apsaText("Tracking"))
        toggle(apsaText("Block Third-Party Cookies"), apsaText("Sites in ads and widgets don't get their cookies on other sites' pages."), \.blockThirdPartyCookies)
        toggle(apsaText("Remove Tracking Parameters from Addresses"), apsaText("Removes utm, fbclid, gclid and similar parameters before a page opens."), \.stripTrackingParameters)
        toggle(apsaText("Send Do-Not-Track Signal"), apsaText("Tells sites about Global Privacy Control. Through the page only: WebKit doesn't allow adding the request header."), \.sendGlobalPrivacyControl)
        toggle(apsaText("Fingerprinting Protection"), apsaText("Replaces screen, processor, canvas and audio values with common ones. Sites can notice this, and the protection isn't complete."), \.resistFingerprinting)
        toggle(apsaText("Disable WebRTC"), apsaText("Stops your real IP from leaking through WebRTC. Calls in the browser will stop working."), \.blockWebRTC)
        section(apsaText("Connection"))
        toggle(apsaText("HTTPS Only"), apsaText("Regular addresses open securely. If a site can't do that, the browser will ask."), \.httpsOnly)
        toggle(apsaText("Warn About Fraudulent Sites"), apsaText("The system checks addresses against Safe Browsing lists. Turning this off removes those requests and this protection."), \.fraudWarnings)
        proxyHostField.placeholderString = "127.0.0.1"
        proxyHostField.target = self
        proxyHostField.action = #selector(changeProxy)
        proxyHostField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        proxyHostField.setAccessibilityLabel(apsaText("Proxy Address"))
        proxyPortField.placeholderString = "9050"
        proxyPortField.target = self
        proxyPortField.action = #selector(changeProxy)
        proxyPortField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        proxyPortField.setAccessibilityLabel(apsaText("Proxy Port"))
        details.addArrangedSubview(settingRow(apsaText("SOCKS5 Proxy"), detail: apsaText("For example, Tor on 127.0.0.1, port 9050. Requires Tor to be running and macOS 14 or later. The browser fingerprint will still differ from Tor Browser's."), controls: [proxyHostField, proxyPortField]))
        section(apsaText("Third-Party Content"))
        toggle(apsaText("Block Third-Party Scripts"), apsaText("The strongest protection, but many sites will break."), \.blockThirdPartyScripts)
        toggle(apsaText("Block Third-Party Frames"), apsaText("Embedded videos, comments and sign-in buttons will stop loading."), \.blockThirdPartyFrames)
        toggle(apsaText("Block Third-Party Fonts"), apsaText("Fonts from other servers won't load, so text may look different."), \.blockThirdPartyFonts)
        section(apsaText("Page Features"))
        toggle(apsaText("Disable JavaScript"), apsaText("Most modern sites will stop working. You can turn it back on for a site with the shield in the address bar."), \.disableJavaScript)
        toggle(apsaText("Disable WebGL"), apsaText("Removes one source of fingerprinting. 3D, maps and some games won't work."), \.disableWebGL)
        toggle(apsaText("Disable WebAssembly"), apsaText("Heavy web apps and some video players won't work."), \.disableWebAssembly)
        toggle(apsaText("Disable Service Workers"), apsaText("Sites won't be able to work in the background or offline."), \.disableServiceWorkers)
        toggle(apsaText("Deny Camera and Microphone"), apsaText("Sites won't even be able to ask for permission."), \.denyCameraAndMicrophone)
        section(apsaText("Data"))
        toggle(apsaText("Keep History"), apsaText("Turning this off doesn't affect history already saved."), \.keepHistory)
        toggle(apsaText("Delete Data on Quit"), apsaText("Cookies, cache, history and open tabs are removed when you quit. You'll be signed out of your accounts."), \.clearDataOnQuit)
        keepSitesField.placeholderString = "google.com, github.com"
        keepSitesField.target = self
        keepSitesField.action = #selector(changeKeepSites)
        keepSitesField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        keepSitesField.setAccessibilityLabel(apsaText("Sites Whose Data to Keep"))
        details.addArrangedSubview(settingRow(apsaText("Keep Data for These Sites"), detail: apsaText("Separate with commas. This keeps you signed in when data is deleted."), controls: [keepSitesField]))
        stack.addArrangedSubview(details)
        return stack
    }
    @objc private func choose(_ sender: ThemeCard) { ApsaThemeStore.shared.select(sender.theme) }
    @objc private func changeNeon(_ sender: NSColorWell) { ApsaThemeStore.shared.setNeon(sender.color) }
    @objc private func changeSidebar(_ sender: NSSwitch) { actions.setSidebarVisible(sender.state == .on) }
    @objc private func changeInset(_ sender: NSStepper) { actions.setInset(CGFloat(sender.integerValue)); refresh() }
    @objc private func resetInset() { actions.resetInset(); refresh() }
    @objc private func openPasswords() { actions.showPasswords() }
    @objc private func changeLanguage(_ sender: NSPopUpButton) {
        guard ApsaLanguage.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        let chosen = ApsaLanguage.allCases[sender.indexOfSelectedItem]
        ApsaLanguage.saved = chosen
        guard chosen != ApsaLanguage.current else { return }
        // Written in the language being chosen: that is the one this person reads.
        let alert = NSAlert()
        alert.messageText = apsaText("Restart Apsa Browser to change the language?", in: chosen)
        alert.informativeText = apsaText("The browser will close and open again. Tabs come back if restoring tabs is on.", in: chosen)
        alert.addButton(withTitle: apsaText("Restart Now", in: chosen))
        alert.addButton(withTitle: apsaText("Later", in: chosen))
        if alert.runModal() == .alertFirstButtonReturn { ApsaLanguage.relaunch() }
    }
    @objc private func changeTranslateTarget(_ sender: NSPopUpButton) {
        guard ApsaTranslationText.targets.indices.contains(sender.indexOfSelectedItem) else { return }
        ApsaTranslationText.target = ApsaTranslationText.targets[sender.indexOfSelectedItem].code
    }
    @objc private func changeFastFullscreen(_ sender: NSSwitch) { actions.setFastFullscreen(sender.state == .on) }
    @objc private func changeBlocking(_ sender: NSSwitch) { ApsaContentBlocker.shared.isEnabled = sender.state == .on }
    @objc private func changeRestore(_ sender: NSSwitch) { ApsaSessionStore.shared.restoresTabs = sender.state == .on }
    @objc private func changeWebView(_ sender: NSSwitch) { ApsaThemeStore.shared.setChromeUsesWebView(sender.state == .on) }
    @objc private func showStylesheet() { ApsaChromeController.revealUserStylesheet() }
    @objc private func refresh() {
        let store = ApsaThemeStore.shared
        let palette = store.selected.palette
        window?.appearance = NSAppearance(named: store.selected.isLight ? .aqua : .darkAqua)
        window?.backgroundColor = .clear
        (window?.contentView as? ApsaGlassView)?.applyTint(store.selected.glassTint, opacity: 0.48)
        privacyRow?.apply(selected: category == .privacy, palette: palette)
        let privacy = ApsaPrivacyStore.shared.settings
        levelPicker.selectedSegment = [ApsaPrivacyLevel.standard, .strict, .maximum].firstIndex(of: privacy.level) ?? -1
        levelNote.stringValue = {
            switch privacy.level {
            case .standard: return apsaText("Protection that stays out of the way: blocks ads, trackers, third-party cookies and tracking parameters in addresses. Sites work as usual and you stay signed in.")
            case .strict: return apsaText("Stronger protection: fingerprinting protection, HTTPS only, no WebRTC. Cookies, cache, history and tabs are deleted when you quit, so you'll have to sign in again. Some sites may behave oddly.")
            case .maximum: return apsaText("For those who accept the cost. On top of Strict, third-party scripts, frames and fonts are blocked, and WebGL and WebAssembly are off. Many sites will break. You can fix a site with the shield in the address bar.")
            case .custom: return apsaText("Custom settings. Choose a level to go back to a preset.")
            }
        }()
        for (control, path) in switches { control.state = privacy[keyPath: path] ? .on : .off }
        if proxyHostField.currentEditor() == nil { proxyHostField.stringValue = privacy.proxyHost }
        if proxyPortField.currentEditor() == nil { proxyPortField.stringValue = privacy.proxyPort > 0 ? String(privacy.proxyPort) : "" }
        if keepSitesField.currentEditor() == nil { keepSitesField.stringValue = privacy.keepDataSites.joined(separator: ", ") }
        generalRow?.apply(selected: category == .general, palette: palette)
        themesRow?.apply(selected: category == .themes, palette: palette)
        for card in cards { card.needsDisplay = true; card.setAccessibilityValue(store.selected == card.theme ? apsaText("Selected") : "") }
        neon.color = NSColor(apsaHex: store.neonRGB)
        neonLabel.stringValue = String(format: "#%06X", store.neonRGB)
        sidebarSwitch.state = actions.sidebarVisible() ? .on : .off
        languagePicker.selectItem(at: ApsaLanguage.allCases.firstIndex(of: ApsaLanguage.saved) ?? 0)
        translateTarget.selectItem(at: ApsaTranslationText.targets.firstIndex { $0.code == ApsaTranslationText.target } ?? 0)
        fastFullscreenSwitch.state = ApsaFastFullscreen.isEnabled ? .on : .off
        blockingSwitch.state = ApsaContentBlocker.shared.isEnabled ? .on : .off
        restoreSwitch.state = ApsaSessionStore.shared.restoresTabs ? .on : .off
        insetStepper.integerValue = Int(actions.inset())
        insetLabel.stringValue = "\(Int(actions.inset())) pt"
        webViewSwitch.state = store.chromeUsesWebView ? .on : .off
    }
}
