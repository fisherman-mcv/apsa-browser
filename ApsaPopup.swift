import WebKit

// A window a page opens with its own size, such as a sign-in form. It keeps its link
// to the opener, shares the opener's configuration, and shows its host as the title
// so a page cannot pass itself off as another site.
final class ApsaPopupWindow: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private static var open = Set<ApsaPopupWindow>()
    private let window: NSWindow
    let webView: WKWebView
    private var addressObserver: NSKeyValueObservation?

    init(configuration: WKWebViewConfiguration, features: WKWindowFeatures, parent: NSWindow?) {
        let size = NSSize(width: max(200, min(1600, features.width?.doubleValue ?? 500)),
                          height: max(150, min(1200, features.height?.doubleValue ?? 600)))
        webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        addressObserver = webView.observe(\.url, options: .initial) { [weak self] view, _ in
            self?.window.title = view.url?.host ?? ""
        }
        if let parent {
            window.setFrameTopLeftPoint(NSPoint(x: parent.frame.minX + 60, y: parent.frame.maxY - 60))
        } else {
            window.center()
        }
        Self.open.insert(self)
        window.makeKeyAndOrderFront(nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = action.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["http", "https", "about", "blob", "data"].contains(scheme) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        ApsaPopupWindow(configuration: configuration, features: windowFeatures, parent: window).webView
    }

    func webViewDidClose(_ webView: WKWebView) { window.close() }

    func windowWillClose(_ notification: Notification) { Self.open.remove(self) }
}
