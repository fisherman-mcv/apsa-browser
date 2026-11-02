import AppKit
import WebKit

// Runs with no window, no Dock icon and no focus.
private final class MemoryPasswords: ApsaPasswordBackend {
    var items: [ApsaSavedLogin: String] = [:]
    func logins() -> [ApsaSavedLogin] { Array(items.keys) }
    func password(for login: ApsaSavedLogin) -> String? { items[login] }
    func save(_ login: ApsaSavedLogin, password: String) -> Bool { items[login] = password; return true }
    func remove(_ login: ApsaSavedLogin) -> Bool { items[login] = nil; return true }
}

private final class Recorder: NSObject, WKScriptMessageHandler {
    var messages: [[String: Any]] = []
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { messages.append(body) }
    }
}

@main struct PasswordTests {
    static func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        testOriginsAndStore()
        testKeychainRoundTrip()
        testPageScript()
        testFillNeedsAuthentication()
        print("Passwords: origins, offers, Keychain, capture, fill and isolation OK")
        exit(0)
    }

    static func testOriginsAndStore() {
        precondition(ApsaPasswordOrigin(url: URL(string: "http://example.com/")!) == nil)
        precondition(ApsaPasswordOrigin(url: URL(string: "http://127.0.0.1:4599/")!) != nil)
        let site = ApsaPasswordOrigin(url: URL(string: "https://Example.com/login")!)!
        precondition(site != ApsaPasswordOrigin(url: URL(string: "https://evil-example.com/")!))
        precondition(site != ApsaPasswordOrigin(url: URL(string: "https://sub.example.com/")!))
        let suite = "apsa.password.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ApsaPasswordStore(backend: MemoryPasswords(), defaults: defaults)
        let login = ApsaSavedLogin(origin: site, account: "user")
        let word = UUID().uuidString
        precondition(store.offer(for: login, password: word) == .save)
        precondition(store.save(login, password: word) && !store.save(login, password: ""))
        precondition(store.offer(for: login, password: word) == .none)
        precondition(store.offer(for: login, password: word + "x") == .update)
        precondition(store.logins(for: site) == [login] && store.search("exam") == [login] && store.search("нет").isEmpty)
        store.setNever(site)
        precondition(store.offer(for: ApsaSavedLogin(origin: site, account: "other"), password: word) == .none)
        precondition(store.remove(login) && store.logins.isEmpty)
    }

    static func testKeychainRoundTrip() {
        let keychain = ApsaKeychainPasswords()
        let login = ApsaSavedLogin(origin: ApsaPasswordOrigin(scheme: "https", host: "apsa-test-\(UUID().uuidString.lowercased()).invalid", port: 8443), account: "tester")
        let word = UUID().uuidString
        defer { _ = keychain.remove(login) }
        precondition(keychain.save(login, password: word))
        precondition(keychain.password(for: login) == word)
        precondition(keychain.logins().contains(login))
        precondition(keychain.save(login, password: word + "2") && keychain.password(for: login) == word + "2")
        precondition(keychain.remove(login) && keychain.password(for: login) == nil)
    }

    static func testFillNeedsAuthentication() {
        let suite = "apsa.password.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = MemoryPasswords()
        let store = ApsaPasswordStore(backend: backend, defaults: defaults)
        let origin = ApsaPasswordOrigin(url: URL(string: "https://example.com/")!)!
        let login = ApsaSavedLogin(origin: origin, account: "user@example.com")
        let word = UUID().uuidString
        store.save(login, password: word)
        let autofill = ApsaPasswordAutofill(store: store)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source: ApsaPasswordAutofill.pageScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: ApsaPasswordAutofill.world))
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        func load(_ base: String) {
            view.loadHTMLString("<!doctype html><form><input id=u type=email><input id=p type=password></form>", baseURL: URL(string: base))
            spin(1)
        }
        func value() -> String? {
            var output: String?, finished = false
            view.evaluateJavaScript("document.getElementById('p').value") { result, _ in output = result as? String; finished = true }
            while !finished { spin(0.02) }
            return output
        }
        func attempt() -> Bool {
            var outcome = false, finished = false
            autofill.fillAfterAuthentication(login, in: view) { outcome = $0; finished = true }
            while !finished { spin(0.02) }
            return outcome
        }
        load("https://example.com/")
        var asked = 0
        autofill.authenticate = { _, done in asked += 1; done(false) }
        precondition(!attempt() && value() == "" && asked == 1, "a refused finger fills nothing")
        autofill.authenticate = { _, done in asked += 1; done(true) }
        precondition(attempt() && value() == word && asked == 2)
        load("https://evil-example.com/")
        precondition(!attempt() && value() == "", "a page on another site never receives the password")
    }

    static func testPageScript() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let recorder = Recorder()
        let world = ApsaPasswordAutofill.world
        configuration.userContentController.addUserScript(WKUserScript(source: ApsaPasswordAutofill.pageScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        configuration.userContentController.add(recorder, contentWorld: world, name: "apsaPasswords")
        // Never added to a window. Layout still works because of the frame.
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        view.loadHTMLString("""
        <!doctype html><title>t</title><form onsubmit="return false">
        <input id=u type=email name=email><input id=p type=password><button>Go</button></form>
        <script>window.pageSaw=[];document.getElementById('p').addEventListener('input',()=>window.pageSaw.push('input'));</script>
        """, baseURL: URL(string: "https://example.com/"))
        spin(1.5)
        func page(_ script: String) -> Any? {
            var output: Any?, finished = false
            view.evaluateJavaScript(script) { value, _ in output = value; finished = true }
            while !finished { spin(0.02) }
            return output
        }
        var filled = false, finished = false
        let word = UUID().uuidString
        ApsaPasswordAutofill.fill(view, account: "user@example.com", password: word) { filled = $0; finished = true }
        while !finished { spin(0.02) }
        precondition(filled)
        precondition(page("document.getElementById('u').value") as? String == "user@example.com")
        precondition(page("document.getElementById('p').value") as? String == word)
        precondition(page("window.pageSaw.length") as? Int == 1, "the site's own handler must see the fill")
        // The site's JavaScript cannot reach the script's function or its handler.
        precondition(page("typeof window.apsaPasswordFill") as? String == "undefined")
        precondition(page("typeof (window.webkit?.messageHandlers?.apsaPasswords)") as? String == "undefined")

        _ = page("document.querySelector('form').requestSubmit(); 1")
        spin(0.4)
        let candidate = recorder.messages.last { $0["event"] as? String == "candidate" }
        precondition(candidate?["username"] as? String == "user@example.com" && candidate?["password"] as? String == word)

        // A script's synthetic click must not open the browser's login menu.
        recorder.messages.removeAll()
        _ = page("document.getElementById('p').click(); 1")
        spin(0.3)
        precondition(!recorder.messages.contains { $0["event"] as? String == "field" })
    }
}
