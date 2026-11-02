import AppKit
import WebKit

// Runs the real generated rules in WebKit with no window, no Dock icon and no focus.
@main struct AdblockTests {
    static func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "apsa.adblock.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WKContentRuleListStore(url: folder)!
        let blocker = ApsaContentBlocker(defaults: defaults, store: store, rulesURL: URL(fileURLWithPath: CommandLine.arguments[1]))

        precondition(blocker.isEnabled && !blocker.isAllowed(host: "example.com"))
        blocker.setAllowed(true, host: "www.Example.com")
        precondition(blocker.isAllowed(host: "example.com") && blocker.isAllowed(host: "news.example.com") && !blocker.isAllowed(host: "badexample.com"))
        precondition(!blocker.blocks(url: URL(string: "https://example.com/")) && blocker.blocks(url: URL(string: "https://other.example/")))
        blocker.setAllowed(false, host: "news.example.com")
        precondition(!blocker.isAllowed(host: "example.com"))
        blocker.isEnabled = false
        precondition(!blocker.blocks(url: URL(string: "https://other.example/")))
        blocker.isEnabled = true

        var compile: TimeInterval?, failure: Error?, finished = false
        blocker.start { compile = $0; failure = $1; finished = true }
        while !finished { spin(0.05) }
        if let failure { fatalError("compile failed: \(failure)") }
        precondition(blocker.list != nil, "rules must compile")
        print(String(format: "compile: %.1fs", compile ?? -1))

        // The second start finds the compiled list instead of compiling again.
        let again = ApsaContentBlocker(defaults: defaults, store: store, rulesURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        finished = false
        let began = Date()
        var recompiled: TimeInterval?
        again.start { value, _ in recompiled = value; finished = true }
        while !finished { spin(0.005) }
        precondition(recompiled == nil && again.list != nil)
        print(String(format: "load compiled: %.0fms", Date().timeIntervalSince(began) * 1000))

        func makeView(blocking: Bool) -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            if blocking { configuration.userContentController.add(blocker.list!) }
            return view
        }
        // A class taken from the generated rules, so the check follows list updates.
        let compressed = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let rules = try! JSONSerialization.jsonObject(with: (compressed as NSData).decompressed(using: .zlib) as Data) as! [[String: [String: Any]]]
        let generic = rules.filter { $0["action"]?["type"] as? String == "css-display-none" && $0["trigger"]?["if-domain"] == nil && $0["trigger"]?["unless-domain"] == nil }
        let selectors = generic.flatMap { ($0["action"]?["selector"] as? String ?? "").split(separator: ",") }
        let adClass = selectors.first { $0.hasPrefix(".") && $0.count > 1 && $0.dropFirst().allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } }!.dropFirst()
        print("rules:", rules.count, "ad class:", adClass)
        let page = """
        <!doctype html><title>t</title><div id=box class="\(adClass)" style="width:300px;height:100px"></div><div id=plain style="width:300px;height:100px">text</div>
        """
        func load(_ view: WKWebView, _ html: String, base: String) -> TimeInterval {
            let began = Date()
            view.loadHTMLString(html, baseURL: URL(string: base))
            while view.isLoading || view.url == nil { spin(0.005) }
            let elapsed = Date().timeIntervalSince(began)
            spin(0.1)
            return elapsed
        }
        func run(_ view: WKWebView, _ script: String) -> Any? {
            var output: Any?, done = false
            view.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                if case let .success(value) = result { output = value }
                done = true
            }
            let limit = Date().addingTimeInterval(20)
            while !done, Date() < limit { spin(0.01) }
            return output
        }
        // A request the blocker stops fails at once, before any network.
        let probe = "try { const c = new AbortController(); setTimeout(() => c.abort(), 6000); const s = performance.now(); await fetch(url, { mode: 'no-cors', signal: c.signal }); return 'loaded'; } catch (e) { return String(e.name + ': ' + e.message); }"
        func request(_ view: WKWebView, _ url: String) -> String {
            var output = "", done = false
            view.callAsyncJavaScript(probe, arguments: ["url": url], in: nil, in: .page) { result in
                if case let .success(value) = result { output = value as? String ?? "" } else { output = "script error" }
                done = true
            }
            while !done { spin(0.01) }
            return output
        }
        func display(_ view: WKWebView, _ id: String) -> String { run(view, "return getComputedStyle(document.getElementById('\(id)')).display") as? String ?? "?" }

        let blocking = makeView(blocking: true)
        let timeWith = (0..<5).map { _ in load(blocking, page, base: "https://example.org/") }.sorted()[2]
        let plain = makeView(blocking: false)
        let timeWithout = (0..<5).map { _ in load(plain, page, base: "https://example.org/") }.sorted()[2]
        print(String(format: "small page load, median: %.0fms with rules, %.0fms without", timeWith * 1000, timeWithout * 1000))

        // WebKit reports a blocked request as a plain load failure, so each address
        // is checked against a view with no rules, where it must load.
        for tracker in ["https://www.google-analytics.com/collect", "https://securepubads.g.doubleclick.net/tag/js/gpt.js", "https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js"] {
            let without = request(plain, tracker), with = request(blocking, tracker)
            print(tracker, "| without:", without, "| with:", with)
            precondition(without == "loaded", "the network must reach \(tracker) without rules")
            precondition(with != "loaded", "\(tracker) must be blocked")
        }
        for site in ["https://example.com/", "https://www.wikipedia.org/", "https://www.youtube.com/", "https://github.com/"] {
            let with = request(blocking, site)
            print(site, "| with:", with)
            precondition(with == "loaded", "\(site) must load")
        }
        precondition(display(blocking, "box") == "none", "a generic ad selector must hide the element")
        precondition(display(blocking, "plain") == "block" && display(plain, "box") == "block")

        // Turning blocking off for a site removes the rules from the next load.
        blocker.setAllowed(true, host: "example.org")
        blocker.apply(to: blocking, for: URL(string: "https://example.org/"))
        _ = load(blocking, page, base: "https://example.org/")
        precondition(display(blocking, "box") == "block")
        precondition(request(blocking, "https://www.google-analytics.com/collect") == "loaded")
        blocker.setAllowed(false, host: "example.org")
        blocker.apply(to: blocking, for: URL(string: "https://example.org/"))
        _ = load(blocking, page, base: "https://example.org/")
        precondition(display(blocking, "box") == "none")
        print("Adblock: rules compile, block, hide, leave ordinary sites, and honor site exceptions")
        exit(0)
    }
}
