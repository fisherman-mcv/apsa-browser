import AppKit
import WebKit

// Runs with no window, no Dock icon and no focus. Needs an allod server:
// AllodTests allod://localhost:PORT/
@main struct AllodTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let base = URL(string: CommandLine.arguments[1])!
        let defaults = UserDefaults(suiteName: "allod-tests-\(UUID().uuidString)")!

        let html = ApsaAllod.html(page: "# T <b>\n=> about.allod About\n* a\n* b\n```\n# kept\n```\nplain", url: base)
        precondition(html.contains("<h1>T &lt;b&gt;</h1>") && html.contains("<a href=\"about.allod\">About</a>"))
        precondition(html.contains("<ul><li>a</li><li>b</li></ul>") && html.contains("<pre># kept\n</pre>") && html.contains("<p>plain</p>"))

        func fetch(_ url: URL) -> Result<ApsaAllod.Response, Error> {
            var result: Result<ApsaAllod.Response, Error>?
            ApsaAllod.fetch(url, defaults: defaults) { result = $0 }
            let end = Date().addingTimeInterval(10)
            while result == nil, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return result!
        }
        let first = fetch(base)
        guard case .success(let index) = first, index.status == 20 else { fatalError("index loads: \(first)") }
        guard case .success(let folder) = fetch(base.appendingPathComponent("write")) else { fatalError("redirect") }
        precondition(folder.status == 20 && folder.url.absoluteString.hasSuffix("/write/"), "redirect followed")
        guard case .success(let missing) = fetch(base.appendingPathComponent("missing.allod")), missing.status == 44 else { fatalError("44") }

        var known = defaults.dictionary(forKey: ApsaAllod.knownHostsKey) as! [String: String]
        precondition(known.count == 1, "certificate remembered")
        known[known.keys.first!] = "AA"
        defaults.set(known, forKey: ApsaAllod.knownHostsKey)
        guard case .failure(let error) = fetch(base) else { fatalError("changed certificate refused") }
        precondition(error.localizedDescription.contains("changed"), error.localizedDescription)
        defaults.removeObject(forKey: ApsaAllod.knownHostsKey)

        // In a web view: the page renders, and a relative link opens the next page.
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(ApsaAllodSchemeHandler(), forURLScheme: ApsaAllod.scheme)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), configuration: configuration)
        func evaluate(_ script: String) -> String {
            var value: String?
            let end = Date().addingTimeInterval(15)
            while value == nil, Date() < end {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                if web.isLoading { continue }
                web.evaluateJavaScript(script) { result, _ in value = result as? String }
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            return value ?? "timeout"
        }
        web.load(URLRequest(url: base))
        let title = evaluate("document.title")
        precondition(title == "Allod", title)
        _ = evaluate("document.querySelector('a').click(); 'ok'")
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let next = evaluate("document.title + '|' + location.href")
        precondition(next.hasPrefix("How it works|") && next.hasSuffix("/about.allod"), next)
        print("Allod: rendering, fetch, redirect, certificate pinning and web view loading OK")
    }
}
