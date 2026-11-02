import AppKit
import WebKit

// Runs with no window, no Dock icon and no focus. Real translation needs a downloaded
// language, so here a fake translator exercises everything around it.
final class Sink: NSObject, WKScriptMessageHandler {
    var items: [[String: Any]] = []
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any], let batch = body["items"] as? [[String: Any]] { items += batch }
    }
}

@main struct TranslationTests {
    static func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let runs = [ApsaTranslationRun(text: "Read the ", element: nil), ApsaTranslationRun(text: "full article", element: 1), ApsaTranslationRun(text: " today", element: nil)]
        precondition(ApsaTranslationText.runs(from: ApsaTranslationText.attributed(runs)) == runs, "links survive the round trip")
        precondition(ApsaTranslationText.plain(runs) == "Read the full article today")
        precondition(ApsaTranslationText.detectLanguage("Это обычный русский текст о том, как работает браузер и зачем он нужен людям.", declared: "en") == "ru")
        precondition(ApsaTranslationText.detectLanguage("", declared: "de-DE") == "de")
        precondition(ApsaTranslationText.targets.contains { $0.code == "ru" })

        let script = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let world = WKContentWorld.world(name: "apsa-translate")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let sink = Sink()
        configuration.userContentController.add(sink, contentWorld: world, name: "apsaTranslate")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: configuration)
        // Keep the view in a window that is never shown, so visibility checks are real.
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1000, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.loadHTMLString("""
        <!doctype html><html lang=en><title>t</title><body>
        <p id=a>Read the <a id=link href="/x">full article</a> today.</p>
        <h2 id=h>A heading here</h2><pre id=code>let keep = code</pre><p id=no translate=no>Do not translate</p>
        <ul><li id=li>First item</li></ul><input id=f value=secret><div id=far style="margin-top:9000px"><p id=low>Way down the page</p></div>
        </body></html>
        """, baseURL: URL(string: "https://example.org/"))
        spin(0.8)
        func call(_ code: String, in target: WKContentWorld = world, _ arguments: [String: Any] = [:]) -> Any? {
            var output: Any?, done = false
            view.callAsyncJavaScript(code, arguments: arguments, in: nil, in: target) { result in
                if case let .success(value) = result { output = value }
                done = true
            }
            while !done { spin(0.01) }
            return output
        }
        let start = call(script + "\nreturn globalThis.apsaTranslate.start();") as? [String: Any]
        precondition(start?["lang"] as? String == "en" && (start?["sample"] as? String ?? "").contains("A heading"))
        spin(1)
        let sent = sink.items
        func runsText(_ item: [String: Any]) -> String { (item["runs"] as? [[String: Any]] ?? []).compactMap { $0["t"] as? String }.joined() }
        let texts = sent.map(runsText)
        print("sent:", texts)
        precondition(texts.contains("Read the full article today."))
        precondition(texts.contains("A heading here") && texts.contains("First item"))
        precondition(!texts.contains { $0.contains("keep = code") }, "code stays")
        precondition(!texts.contains("Do not translate"), "translate=no is honored")
        precondition(!texts.joined().contains("secret"), "field values are not read")
        precondition(!texts.contains("Way down the page"), "only text near the screen is sent")
        let first = sent.first { runsText($0).hasPrefix("Read") }!
        let element = (first["runs"] as! [[String: Any]]).compactMap { $0["e"] as? Int }.first!
        // Word order changes, and the link must stay a link on the right words.
        precondition(call("return globalThis.apsaTranslate.apply(id, runs);", ["id": first["id"]!, "runs": [["t": "Сегодня читайте "], ["t": "всю статью", "e": element], ["t": "."]]]) as? Bool == true)
        precondition(call("return document.getElementById('a').textContent", in: .page) as? String == "Сегодня читайте всю статью.")
        precondition(call("const a = document.querySelector('#a a'); return a.getAttribute('href') + '|' + a.textContent", in: .page) as? String == "/x|всю статью")
        // The site's own scripts cannot see the translator.
        precondition(call("return typeof window.apsaTranslate", in: .page) as? String == "undefined")
        _ = call("const p = document.createElement('p'); p.id = 'late'; p.textContent = 'Added by the page later'; document.body.prepend(p); return 1", in: .page)
        spin(1.2)
        precondition(sink.items.map(runsText).contains("Added by the page later"), "new text is translated too")
        precondition(call("return globalThis.apsaTranslate.stop();") as? Bool == true)
        precondition(call("return document.getElementById('a').textContent", in: .page) as? String == "Read the full article today.", "the original comes back")
        precondition(call("return document.getElementById('link').textContent", in: .page) as? String == "full article", "the very same link element returns")
        _ = window
        print("Translation: collection, swap, links, late text, restore and isolation OK")
        exit(0)
    }
}
