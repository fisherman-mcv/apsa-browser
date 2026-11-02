import AppKit
import WebKit

// Runs with no window, no Dock icon and no focus.
@main struct LocalizationTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        precondition(ApsaLanguage.saved == .english && ApsaLanguage.current == .english, "English is the default")
        precondition(apsaText("New Tab") == "New Tab")
        precondition(apsaText("New Tab", in: .russian) == "Новая вкладка")
        precondition(apsaText("No such string", in: .russian) == "No such string")
        precondition(apsaText("%d of %d", 2, 5) == "2 of 5")
        precondition(ApsaLanguage.russian.table["%d of %d"] == "%d из %d")
        let specifier = try! NSRegularExpression(pattern: "%(\\.\\d+)?[@df]")
        let specifiers = { (text: String) in
            specifier.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) }
        }
        for (key, value) in ApsaLanguage.russian.table {
            precondition(specifiers(key) == specifiers(value), "format mismatch in \(key)")
            precondition(key != value, "untranslated \(key)")
        }

        // The WebView interface: English as written, Russian after setStrings.
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let page = try! String(contentsOf: directory.appendingPathComponent("chrome.html"), encoding: .utf8)
        let script = try! String(contentsOf: directory.appendingPathComponent("chrome.js"), encoding: .utf8)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let loaded = Waiter()
        let delegate = LoadDelegate { loaded.done = true }
        web.navigationDelegate = delegate
        web.loadHTMLString(page, baseURL: nil)
        loaded.wait()
        func run(_ source: String) -> Any? {
            let result = Waiter()
            var value: Any?
            web.evaluateJavaScript(source) { output, error in
                precondition(error == nil, "\(String(describing: error))")
                value = output
                result.done = true
            }
            result.wait()
            return value
        }
        _ = run(script + "; 1")
        let read = "[document.documentElement.lang, document.querySelector('#address').placeholder, document.querySelector('[data-command=back]').title, document.querySelector('.sidebar-title').textContent, document.querySelector('[data-command=newTab]').getAttribute('aria-label')].join('|')"
        precondition(run(read) as? String == "en|Address or search|Back|Bookmarks|New Tab")
        let table = String(data: try! JSONSerialization.data(withJSONObject: ApsaLanguage.russian.table), encoding: .utf8)!
        _ = run("apsaChrome.setStrings('ru', \(table)); 1")
        precondition(run(read) as? String == "ru|Адрес или поиск|Назад|Закладки|Новая вкладка")
        print("LocalizationTests passed")
    }
}

final class Waiter {
    var done = false
    func wait() {
        let deadline = Date().addingTimeInterval(20)
        while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(done, "timed out")
    }
}

final class LoadDelegate: NSObject, WKNavigationDelegate {
    let finished: () -> Void
    init(_ finished: @escaping () -> Void) { self.finished = finished }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished() }
}
