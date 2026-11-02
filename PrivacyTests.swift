import AppKit
import Network
import WebKit

// Runs with no window, no Dock icon and no focus.
@main struct PrivacyTests {
    static func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    static func view(_ settings: ApsaPrivacySettings, seed: UInt32, rules: WKContentRuleList? = nil) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source: ApsaPrivacy.script(settings, seed: seed), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if let rules { configuration.userContentController.add(rules) }
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
    }
    static func load(_ view: WKWebView, base: String) {
        view.loadHTMLString("<!doctype html><title>t</title><body><canvas id=c width=64 height=32></canvas></body>", baseURL: URL(string: base))
        spin(0.6)
    }
    static func run(_ view: WKWebView, _ script: String) -> Any? {
        var output: Any?, done = false
        view.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
            if case let .success(value) = result { output = value }
            done = true
        }
        let limit = Date().addingTimeInterval(15)
        while !done, Date() < limit { spin(0.01) }
        return output
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        // Levels only add protection, and keep what the person typed in.
        var mine = ApsaPrivacySettings()
        mine.proxyHost = "127.0.0.1"; mine.proxyPort = 9050; mine.keepDataSites = ["google.com"]
        let standard = ApsaPrivacySettings(), strict = ApsaPrivacySettings.preset(.strict, from: mine), maximum = ApsaPrivacySettings.preset(.maximum, from: mine)
        precondition(standard.level == .standard && standard.keepHistory && !standard.clearDataOnQuit && !standard.resistFingerprinting)
        precondition(strict.resistFingerprinting && strict.clearDataOnQuit && strict.httpsOnly && strict.blockWebRTC && !strict.blockThirdPartyScripts)
        precondition(maximum.blockThirdPartyScripts && maximum.disableWebGL && maximum.disableWebAssembly && !maximum.disableJavaScript, "turning JavaScript off stays a separate decision")
        precondition(strict.proxyPort == 9050 && maximum.keepDataSites == ["google.com"])
        precondition(mine.keepsData(for: "accounts.google.com") && mine.keepsData(for: "google.com") && !mine.keepsData(for: "badgoogle.com"))

        let suite = "apsa.privacy.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ApsaPrivacyStore(defaults: defaults)
        store.choose(.strict)
        store.set(\.blockWebRTC, false)
        precondition(store.settings.level == .custom && !store.settings.blockWebRTC && store.settings.clearDataOnQuit)
        precondition(ApsaPrivacyStore(defaults: defaults).settings == store.settings, "settings persist")

        // Addresses.
        precondition(ApsaPrivacy.cleaned(URL(string: "https://a.com/p?id=7&utm_source=x&fbclid=y")!)?.absoluteString == "https://a.com/p?id=7")
        precondition(ApsaPrivacy.cleaned(URL(string: "https://a.com/p?UTM_medium=x")!)?.absoluteString == "https://a.com/p")
        precondition(ApsaPrivacy.cleaned(URL(string: "https://a.com/p?id=7&q=utm_source")!) == nil, "ordinary addresses stay as they are")
        precondition(ApsaPrivacy.cleaned(URL(string: "https://a.com/")!) == nil)
        precondition(ApsaPrivacy.httpsVersion(of: URL(string: "http://a.com/x?y=1")!)?.absoluteString == "https://a.com/x?y=1")
        precondition(ApsaPrivacy.httpsVersion(of: URL(string: "https://a.com/")!) == nil)
        precondition(ApsaPrivacy.httpsVersion(of: URL(string: "http://localhost:8080/")!) == nil && ApsaPrivacy.httpsVersion(of: URL(string: "http://127.0.0.1/")!) == nil)

        // Every level's rules must compile in the real engine.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ruleStore = WKContentRuleListStore(url: folder)!
        var lists: [ApsaPrivacyLevel: WKContentRuleList] = [:]
        for level in [ApsaPrivacyLevel.standard, .strict, .maximum] {
            var failure: Error?, done = false
            ruleStore.compileContentRuleList(forIdentifier: level.rawValue, encodedContentRuleList: ApsaPrivacy.ruleListJSON(.preset(level))!) { list, error in
                lists[level] = list; failure = error; done = true
            }
            while !done { spin(0.01) }
            if let failure { fatalError("\(level) rules: \(failure)") }
        }

        // What pages can see. With nothing on, the page is untouched.
        var nothing = ApsaPrivacySettings(); nothing.sendGlobalPrivacyControl = false
        let plain = view(nothing, seed: 1)
        load(plain, base: "https://example.org/")
        precondition(run(plain, "return typeof RTCPeerConnection") as? String == "function")
        precondition(run(plain, "return navigator.globalPrivacyControl") as? Bool == false)
        let drawing = "const c = document.getElementById('c'); const x = c.getContext('2d'); x.fillStyle = '#123456'; x.fillRect(0, 0, 64, 32); x.fillStyle = '#abcdef'; x.fillText('apsa', 2, 12); return c.toDataURL();"
        let plainHash = run(plain, drawing) as? String

        let hard = view(.preset(.maximum), seed: 42)
        load(hard, base: "https://example.org/")
        precondition(run(hard, "return navigator.globalPrivacyControl") as? Bool == true)
        precondition(run(hard, "return typeof RTCPeerConnection") as? String == "undefined", "WebRTC is gone")
        precondition(run(hard, "return typeof WebAssembly") as? String == "undefined")
        precondition(run(hard, "return document.createElement('canvas').getContext('webgl') === null") as? Bool == true)
        precondition(run(hard, "return navigator.serviceWorker === undefined") as? Bool == true)
        precondition(run(hard, "return [navigator.hardwareConcurrency, screen.width, screen.height, devicePixelRatio, navigator.plugins.length].join()") as? String == "8,1920,1080,2,0")

        let strictView = view(.preset(.strict), seed: 42)
        load(strictView, base: "https://example.org/")
        precondition(run(strictView, "return typeof WebAssembly") as? String == "object", "strict keeps sites working")
        let first = run(strictView, drawing) as? String
        let again = run(strictView, drawing) as? String
        precondition(first != nil && first == again, "a site sees a stable canvas")
        precondition(first != plainHash, "but not the machine's own")
        load(strictView, base: "https://other.example/")
        precondition(run(strictView, drawing) as? String != first, "another site sees a different one")
        precondition(run(strictView, "const t = performance.now(); return Math.abs(t / 16.67 - Math.round(t / 16.67)) < 1e-6") as? Bool == true, "clocks are coarse")

        // Third-party scripts stop only at the maximum level.
        let probe = "try { const c = new AbortController(); setTimeout(() => c.abort(), 6000); await fetch('https://example.com/', { mode: 'no-cors', signal: c.signal }); return 'loaded'; } catch (e) { return 'failed'; }"
        let blockedScript = view(.preset(.maximum), seed: 1, rules: lists[.maximum])
        blockedScript.loadHTMLString("<!doctype html><title>t</title><script>window.ran = false</script><script src='https://code.jquery.com/jquery-3.7.1.min.js'></script>", baseURL: URL(string: "https://example.org/"))
        spin(3)
        precondition(run(blockedScript, "return typeof window.jQuery") as? String == "undefined", "a third-party script is blocked")
        let allowedScript = view(.preset(.strict), seed: 1, rules: lists[.strict])
        allowedScript.loadHTMLString("<!doctype html><title>t</title><script src='https://code.jquery.com/jquery-3.7.1.min.js'></script>", baseURL: URL(string: "https://example.org/"))
        spin(3)
        precondition(run(allowedScript, "return typeof window.jQuery") as? String == "function", "strict lets it run")
        _ = probe

        // The proxy really is used: a local listener must receive the SOCKS5 greeting.
        if #available(macOS 14.0, *) {
            var proxied = false
            let listener = try! NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16) { data, _, _, _ in
                    if data?.first == 0x05 { proxied = true }
                    connection.cancel()
                }
            }
            var port: UInt16 = 0
            listener.stateUpdateHandler = { state in if case .ready = state { port = listener.port?.rawValue ?? 0 } }
            listener.start(queue: .main)
            while port == 0 { spin(0.01) }
            var settings = ApsaPrivacySettings(); settings.proxyHost = "127.0.0.1"; settings.proxyPort = Int(port)
            let configuration = WKWebViewConfiguration()
            let data = WKWebsiteDataStore.nonPersistent()
            data.proxyConfigurations = ApsaPrivacy.proxyConfigurations(settings)
            configuration.websiteDataStore = data
            let through = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
            through.load(URLRequest(url: URL(string: "https://example.com/")!))
            let limit = Date().addingTimeInterval(8)
            while !proxied, Date() < limit { spin(0.05) }
            precondition(proxied, "traffic must go through the proxy")
            print("proxy: SOCKS5 greeting received")
        }
        print("Privacy: levels, addresses, rules, page values, third-party blocking and proxy OK")
        exit(0)
    }
}
