import AppKit
import UniformTypeIdentifiers
import WebKit

// The optional WebView interface. BrowserWindowController stays the only owner
// of browser state: it pushes snapshots here and receives a closed set of typed
// commands back. Nothing in this file exists in memory while the mode is off.
enum ApsaChromeCommand {
    case back, forward, reload, toggleSidebar, settings, toggleReader, newTab
    case toggleBookmark, toggleBookmarksSection, toggleSiteBlocking, toggleTranslation, toggleAddressTools
    case selectTab(UUID), closeTab(UUID), openBookmark(UUID), bookmarkMenu(UUID)
    case tabMenu(UUID), toggleFolder(UUID), folderMenu(UUID)
    case address(String)

    init?(_ body: [String: Any]) {
        guard let name = body["command"] as? String else { return nil }
        switch name {
        case "back": self = .back
        case "forward": self = .forward
        case "reload": self = .reload
        case "toggleSidebar": self = .toggleSidebar
        case "settings": self = .settings
        case "toggleReader": self = .toggleReader
        case "newTab": self = .newTab
        case "toggleBookmark": self = .toggleBookmark
        case "toggleSiteBlocking": self = .toggleSiteBlocking
        case "toggleTranslation": self = .toggleTranslation
        case "toggleAddressTools": self = .toggleAddressTools
        case "toggleBookmarksSection": self = .toggleBookmarksSection
        case "selectTab", "closeTab", "openBookmark", "bookmarkMenu", "tabMenu", "toggleFolder", "folderMenu":
            guard let raw = body["id"] as? String, let id = UUID(uuidString: raw) else { return nil }
            switch name {
            case "selectTab": self = .selectTab(id)
            case "closeTab": self = .closeTab(id)
            case "openBookmark": self = .openBookmark(id)
            case "tabMenu": self = .tabMenu(id)
            case "toggleFolder": self = .toggleFolder(id)
            case "folderMenu": self = .folderMenu(id)
            default: self = .bookmarkMenu(id)
            }
        case "address":
            guard let value = body["value"] as? String, value.utf8.count <= 8_192 else { return nil }
            self = .address(value)
        default: return nil
        }
    }
}

// The view lies under the page surface, so AppKit could still deliver hover to
// it through tracking areas. Only the rectangles the interface reports are live;
// everything else falls through to the native toolbar, which keeps window drag,
// traffic lights and the page's own cursor behaving exactly as in native mode.
final class ApsaChromeWebView: WKWebView {
    var interactiveRegions: [CGRect] = []
    private var pointerInside = false

    private func isInteractive(_ local: NSPoint) -> Bool {
        let point = NSPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
        return interactiveRegions.contains { $0.contains(point) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, isInteractive(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    override func mouseMoved(with event: NSEvent) {
        let inside = isInteractive(convert(event.locationInWindow, from: nil))
        // One event past the edge clears :hover; the rest belong to the page.
        if inside || pointerInside { super.mouseMoved(with: event) }
        pointerInside = inside
    }
}

private final class WeakChromeHandler: NSObject, WKScriptMessageHandler {
    weak var owner: ApsaChromeController?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}

final class ApsaChromeController: NSObject, WKNavigationDelegate {
    private static let handlerName = "apsaChrome"
    private static let maximumStylesheetBytes = 1_048_576
    private static let maximumCrashReloads = 2

    let webView: ApsaChromeWebView
    var onCommand: ((ApsaChromeCommand) -> Void)?
    var onReady: (() -> Void)?
    var onFailure: (() -> Void)?
    var onNeedsState: (() -> Void)?

    private let page: URL
    private var lastState = ""
    private var loaded = false
    private var ready = false
    private var crashReloads = 0
    private var watchers: [DispatchSourceFileSystemObject] = []

    init?(bundle: Bundle = .main) {
        guard let page = bundle.url(forResource: "chrome", withExtension: "html", subdirectory: "chrome"),
              let script = bundle.url(forResource: "chrome", withExtension: "js", subdirectory: "chrome"),
              let source = try? String(contentsOf: script, encoding: .utf8) else { return nil }
        self.page = page
        let configuration = WKWebViewConfiguration()
        // Sharing nothing with browsing: no cookies, no cache, no site storage.
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = ApsaChromeWebView(frame: .zero, configuration: configuration)
        super.init()
        let handler = WeakChromeHandler()
        handler.owner = self
        configuration.userContentController.add(handler, name: Self.handlerName)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        if #available(macOS 13.3, *) { webView.isInspectable = true }
    }

    func start() {
        webView.loadFileURL(page, allowingReadAccessTo: page)
        watchStylesheet()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, !self.ready else { return }
            self.onFailure?()
        }
    }

    func stop() {
        watchers.forEach { $0.cancel() }
        watchers.removeAll()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        webView.stopLoading()
        webView.removeFromSuperview()
    }

    func push(_ state: [String: Any]) {
        guard loaded, JSONSerialization.isValidJSONObject(state),
              let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8), json != lastState else { return }
        lastState = json
        webView.evaluateJavaScript("apsaChrome.update(\(json))", completionHandler: nil)
    }

    func focusAddress() {
        webView.window?.makeFirstResponder(webView)
        webView.evaluateJavaScript("apsaChrome.focusAddress()", completionHandler: nil)
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.webView === webView, message.frameInfo.isMainFrame,
              message.frameInfo.request.url == page, let body = message.body as? [String: Any] else { return }
        switch body["event"] as? String {
        case "ready":
            guard !ready else { return }
            ready = true
            onReady?()
        case "regions":
            guard let values = body["rects"] as? [[NSNumber]], values.count <= 64 else { return }
            webView.interactiveRegions = values.compactMap { value in
                guard value.count == 4 else { return nil }
                return CGRect(x: value[0].doubleValue, y: value[1].doubleValue, width: value[2].doubleValue, height: value[3].doubleValue)
            }
        default:
            if let command = ApsaChromeCommand(body) { onCommand?(command) }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // The interface is one local file. It never becomes a browsing surface.
        decisionHandler(navigationAction.request.url == page ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        lastState = ""
        applyStyles()
        onNeedsState?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onFailure?() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { onFailure?() }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
        crashReloads += 1
        if crashReloads > Self.maximumCrashReloads { onFailure?() }
        else { webView.loadFileURL(page, allowingReadAccessTo: page) }
    }

    private func applyStyles() {
        let payload = [Self.symbolStylesheet, stylesheetText()]
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return }
        if ApsaLanguage.current != .english,
           let strings = try? JSONSerialization.data(withJSONObject: ApsaLanguage.current.table),
           let table = String(data: strings, encoding: .utf8) {
            webView.evaluateJavaScript("apsaChrome.setStrings('\(ApsaLanguage.current.rawValue)', \(table))", completionHandler: nil)
        }
        webView.evaluateJavaScript("apsaChrome.setStyles(\(json)[0], \(json)[1])", completionHandler: nil)
    }

    // MARK: chrome.css

    static var userStylesheetURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Apsa Browser", isDirectory: true)
            .appendingPathComponent("chrome.css")
    }

    private static var bundledStylesheetURL: URL? {
        Bundle.main.url(forResource: "chrome", withExtension: "css", subdirectory: "chrome")
    }

    // The user's file goes on top of the bundled sheet, so a copy made by an older
    // version does not leave newer elements unstyled.
    private func stylesheetText() -> String {
        [Self.bundledStylesheetURL, Self.userStylesheetURL].compactMap { url -> String? in
            guard let url, let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.maximumStylesheetBytes else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }.joined(separator: "\n")
    }

    static func revealUserStylesheet() {
        guard let url = userStylesheetURL else { return }
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path), let bundled = bundledStylesheetURL {
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? manager.copyItem(at: bundled, to: url)
        }
        guard manager.fileExists(atPath: url.path) else { return }
        // The system default for .css is often a browser, which cannot edit it.
        guard let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil { DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
        }
    }

    // Editors either write in place or swap the file atomically, so watch both
    // the file and its folder, and re-arm after every change.
    private func watchStylesheet() {
        watchers.forEach { $0.cancel() }
        watchers.removeAll()
        guard let url = Self.userStylesheetURL else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for path in [url.path, url.deletingLastPathComponent().path] {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                guard let self, self.loaded else { return }
                self.applyStyles()
                self.watchStylesheet()
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watchers.append(source)
        }
    }

    // MARK: Native assets

    // SF Symbols cannot be referenced from HTML. Rendering the same symbols into
    // CSS masks keeps the icons identical to native mode and still themeable.
    private static let symbolStylesheet: String = {
        let symbols: [(String, String, CGFloat, NSFont.Weight)] = [
            ("sidebar", "sidebar.left", 12, .semibold), ("back", "chevron.left", 12, .semibold),
            ("forward", "chevron.right", 12, .semibold), ("reload", "arrow.clockwise", 12, .semibold),
            ("settings", "gearshape", 12, .semibold), ("reader", "doc.plaintext", 12, .semibold),
            ("reader-on", "doc.plaintext.fill", 12, .semibold), ("new-tab", "plus", 12, .semibold),
            ("close", "xmark", 9, .semibold), ("tab-web", "globe", 14, .medium), ("tab-home", "house", 14, .medium),
            ("translate", "translate", 12, .semibold), ("tools-open", "chevron.left", 12, .semibold), ("tools-close", "chevron.right", 12, .semibold), ("shield", "shield.lefthalf.filled", 12, .semibold), ("shield-off", "shield.slash", 12, .semibold),
            ("star", "star", 12, .semibold), ("star-on", "star.fill", 12, .semibold),
            ("section-open", "chevron.down", 12, .semibold), ("section-closed", "chevron.right", 12, .semibold),
            ("bookmark-web", "globe", 12, .medium)
        ]
        let variables = symbols.compactMap { name, symbol, size, weight -> String? in
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight)),
                  let data = pngDataURL(image, size: image.size) else { return nil }
            return "--i-\(name):url(\"\(data)\");--i-\(name)-size:\(image.size.width)px \(image.size.height)px;"
        }
        return ":root{" + variables.joined() + "}"
    }()

    static func faviconDataURL(_ image: NSImage) -> String? {
        pngDataURL(image, size: NSSize(width: 18, height: 18))
    }

    private static func pngDataURL(_ image: NSImage, size: NSSize, scale: CGFloat = 2) -> String? {
        guard size.width > 0, size.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded(.up)), pixelsHigh: Int((size.height * scale).rounded(.up)),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + data.base64EncodedString()
    }

    static func cssColor(_ color: NSColor, alpha: CGFloat? = nil) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "transparent" }
        return "rgba(\(Int((rgb.redComponent * 255).rounded())),\(Int((rgb.greenComponent * 255).rounded())),\(Int((rgb.blueComponent * 255).rounded())),\(alpha ?? rgb.alphaComponent))"
    }
}
