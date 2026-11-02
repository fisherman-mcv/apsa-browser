import AppKit
import WebKit

// Runs with no window, no Dock icon and no focus.
@main struct ExtensionTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let all = ApsaExtensions.all(in: [folder])
        precondition(all.count == 22, "every built-in extension loads")
        func matches(_ pattern: String, _ url: String) -> Bool {
            url.range(of: ApsaExtensions.patternRegex(pattern), options: .regularExpression) != nil
        }
        precondition(matches("*://*.youtube.com/*", "https://www.youtube.com/watch?v=1") && matches("*://*.youtube.com/*", "https://youtube.com/"))
        precondition(!matches("*://*.youtube.com/*", "https://notyoutube.com/") && !matches("*://*.youtube.com/*", "https://youtube.com.evil.org/"))
        precondition(matches("<all_urls>", "http://a.b/") && !matches("<all_urls>", "file:///etc/hosts"))
        precondition(!matches("broken", "https://a.b/"))

        // One script and one style on a page: they run, and page JavaScript stays out of reach.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try! #"{"format":1,"id":"t","name":"T","description":"","version":"1","matches":["*://example.org/*"],"excludeMatches":["*://example.org/skip*"],"scripts":["a.js","../escape.js"],"styles":["a.css"]}"#.write(to: temp.appendingPathComponent("extension.json"), atomically: true, encoding: .utf8)
        try! "document.body.dataset.ext = typeof secret;".write(to: temp.appendingPathComponent("a.js"), atomically: true, encoding: .utf8)
        try! "p { color: rgb(1, 2, 3) }".write(to: temp.appendingPathComponent("a.css"), atomically: true, encoding: .utf8)
        var ext = try! JSONDecoder().decode(ApsaExtension.self, from: Data(contentsOf: temp.appendingPathComponent("extension.json")))
        ext.folder = temp
        func page(_ url: String) -> String {
            let configuration = WKWebViewConfiguration()
            ApsaExtensions.userScripts(for: ext).forEach(configuration.userContentController.addUserScript)
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 300), configuration: configuration)
            web.loadHTMLString("<script>var secret = 1</script><p>x</p>", baseURL: URL(string: url))
            var result: String?
            let end = Date().addingTimeInterval(15)
            while result == nil, Date() < end {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                if web.isLoading { continue }
                web.evaluateJavaScript("(document.body.dataset.ext || 'none') + '|' + getComputedStyle(document.querySelector('p')).color") { value, _ in result = value as? String }
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            return result ?? "timeout"
        }
        precondition(page("https://example.org/a") == "undefined|rgb(1, 2, 3)", page("https://example.org/a"))
        precondition(page("https://example.com/a") == "none|rgb(0, 0, 0)")
        precondition(page("https://example.org/skip") == "none|rgb(0, 0, 0)", "excluded pages are left alone")
        print("Extensions: format, matching, injection, isolation and path safety OK")
    }
}
