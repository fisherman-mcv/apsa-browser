import AppKit
import WebKit

// Loads each corpus page in WebKit with no window, no Dock icon and no focus, with
// the browser's real blocking rules on. Output stays local: it holds page text.
final class Capture: NSObject, WKNavigationDelegate {
    let view: WKWebView
    let entry: [String: Any]
    var finished = false
    init(entry: [String: Any], rules: WKContentRuleList?, script: String, readability: String) {
        self.entry = entry
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        if let rules { configuration.userContentController.add(rules) }
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: configuration)
        super.init()
        view.navigationDelegate = self
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finished = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finished = true }
}

@main struct Main {
    static func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    static func evaluate(_ view: WKWebView, _ script: String, arguments: [String: Any] = [:], timeout: TimeInterval = 25) -> Any? {
        var output: Any?, done = false
        view.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
            if case let .success(value) = result { output = value }
            done = true
        }
        let limit = Date().addingTimeInterval(timeout)
        while !done, Date() < limit { spin(0.02) }
        return output
    }
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments
        let corpus = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [[String: Any]]
        let extract = try! String(contentsOfFile: args[2], encoding: .utf8)
        let readability = try! String(contentsOfFile: args[3], encoding: .utf8)
        let rulesData = try! (Data(contentsOf: URL(fileURLWithPath: args[4])) as NSData).decompressed(using: .zlib) as Data
        let outDir = URL(fileURLWithPath: args[5])
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let storeDir = outDir.appendingPathComponent("rules-store")
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        var rules: WKContentRuleList?, ready = false
        WKContentRuleListStore(url: storeDir)!.compileContentRuleList(forIdentifier: "lab", encodedContentRuleList: String(data: rulesData, encoding: .utf8)!) { list, _ in rules = list; ready = true }
        while !ready { spin(0.05) }
        print("rules ready"); fflush(stdout)

        let labelScript = """
        const blocks = globalThis.__apsaReaderBlocks || [];
        const inGold = element => { if (!gold) return false; if (!element.closest(gold)) return false; return !(exclude && element.closest(exclude)); };
        let ld = "";
        const visit = v => { if (!v) return; if (Array.isArray(v)) return v.forEach(visit); if (typeof v === 'object') { if (typeof v.articleBody === 'string' && v.articleBody.length > ld.length) ld = v.articleBody; visit(v['@graph']); } };
        for (const s of document.querySelectorAll('script[type="application/ld+json"]')) { try { visit(JSON.parse(s.textContent)); } catch (_) {} }
        return JSON.stringify({ labels: blocks.map(b => inGold(b.element) ? 1 : 0), goldText: gold ? [...document.querySelectorAll(gold)].filter(e => !(exclude && e.closest(exclude)) && !e.parentElement?.closest(gold)).map(e => { const c = e.cloneNode(true); if (exclude) c.querySelectorAll(exclude).forEach(x => x.remove()); c.querySelectorAll('script,style,noscript').forEach(x => x.remove()); return c.textContent; }).join(' ') : '', ld, title: document.title, url: location.href });
        """
        let readabilityRun = """
        try {
          const article = new Readability(document.cloneNode(true), { charThreshold: 180 }).parse();
          return article ? article.textContent : "";
        } catch (e) { return ""; }
        """
        let oldReader = """
        const primary = document.querySelector('main') || document.querySelector('article');
        const selector = 'h1,h2,h3,h4,h5,h6,p,blockquote,pre,li,dd,dt';
        const nodes = [...document.querySelectorAll(selector)].filter(e => { const r = e.getBoundingClientRect(); return r.width >= 1 && r.height >= 1; });
        const kept = primary ? nodes.filter(e => primary.contains(e)) : nodes.filter(e => !e.closest('nav,header,footer'));
        return kept.slice(0, 180).map(e => e.innerText).join(' ');
        """

        var pending = corpus
        var active: [(capture: Capture, started: Date)] = []
        var index = 0
        let concurrency = 5
        let total = corpus.count
        func finish(_ capture: Capture) {
            index += 1
            let view = capture.view
            let entry = capture.entry
            let url = entry["url"] as! String
            _ = evaluate(view, "for (let y = 0; y < document.documentElement.scrollHeight && y < 15000; y += 1000) { scrollTo(0, y); await new Promise(r => setTimeout(r, 25)); } scrollTo(0, 0); await new Promise(r => setTimeout(r, 200)); return 1;", timeout: 6)
            let began = Date()
            var extracted: Any?, ok = false
            view.evaluateJavaScript("JSON.stringify(\(extract))") { value, error in
                extracted = value
                ok = true
                if let error { print("extract error", url, String(describing: error).prefix(240)); fflush(stdout) }
            }
            let limit = Date().addingTimeInterval(25)
            while !ok, Date() < limit { spin(0.02) }
            let extractMs = Date().timeIntervalSince(began) * 1000
            let blocks = extracted as? String ?? "[]"
            let labels = evaluate(view, labelScript, arguments: ["gold": entry["gold"] as? String ?? "", "exclude": entry["exclude"] as? String ?? ""]) as? String ?? "{}"
            let old = evaluate(view, oldReader) as? String ?? ""
            let readable = (evaluate(view, readability + "\n" + readabilityRun) as? String) ?? ""
            let row: [String: Any] = ["url": url, "category": entry["category"] ?? "", "refuse": entry["refuse"] ?? false, "extractMs": extractMs, "blocks": blocks, "meta": labels, "old": old, "readability": readable]
            let file = outDir.appendingPathComponent("\(UUID().uuidString).json")
            if let data = try? JSONSerialization.data(withJSONObject: row) { try? data.write(to: file) }
            print("[\(index)/\(total)]", url, "blocks:", (blocks.count), "ms:", Int(extractMs)); fflush(stdout)
        }
        while !pending.isEmpty || !active.isEmpty {
            while active.count < concurrency, !pending.isEmpty {
                let entry = pending.removeFirst()
                let capture = Capture(entry: entry, rules: rules, script: extract, readability: readability)
                capture.view.load(URLRequest(url: URL(string: (entry["url"] as! String).addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(CharacterSet(charactersIn: "%")))!)!, timeoutInterval: 30))
                active.append((capture, Date()))
            }
            spin(0.2)
            for (position, item) in active.enumerated().reversed() {
                let waited = Date().timeIntervalSince(item.started)
                // Client-rendered pages need time after the load event.
                if (item.capture.finished && waited > 7) || waited > 35 {
                    active.remove(at: position)
                    finish(item.capture)
                    item.capture.view.navigationDelegate = nil
                    item.capture.view.stopLoading()
                }
            }
        }
        print("done"); fflush(stdout)
        exit(0)
    }
}
