import AppKit
import WebKit

// Blocks ads and trackers with the rule engine inside WebKit, which is the fastest
// place to do it: no script runs in the page, and blocked requests never start.
// Rules compile once, then load from WebKit's own store.
final class ApsaContentBlocker {
    static let shared = ApsaContentBlocker()
    static let changed = Notification.Name("ApsaContentBlockerChanged")
    // In userInfo when open pages must load again for a change to reach them.
    static let reloadPagesKey = "reloadPages"
    private static let enabledKey = "apsa-browser-blocking-enabled"
    private static let allowedKey = "apsa-browser-blocking-allowed-sites"
    private static let identifierPrefix = "apsa-browser-rules-"

    private let defaults: UserDefaults
    private let store: WKContentRuleListStore
    private let rulesURL: URL?
    private(set) var list: WKContentRuleList?
    // Rules from the privacy settings, kept apart from the large ad list so that changing
    // a setting recompiles only a handful of rules.
    private(set) var privacyList: WKContentRuleList?
    private static let privacyIdentifierPrefix = "apsa-browser-privacy-"
    private var started = false
    private var finished = false
    private var waiting: [() -> Void] = []

    init(defaults: UserDefaults = .standard, store: WKContentRuleListStore = .default(), rulesURL: URL? = Bundle.main.url(forResource: "rules.json", withExtension: "deflate", subdirectory: "adblock")) {
        self.defaults = defaults
        self.store = store
        self.rulesURL = rulesURL
    }

    var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
            NotificationCenter.default.post(name: Self.changed, object: self, userInfo: [Self.reloadPagesKey: true])
        }
    }

    private static func siteKey(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }

    // Allowing example.com also covers its subdomains.
    func isAllowed(host: String) -> Bool {
        let key = Self.siteKey(host)
        return (defaults.stringArray(forKey: Self.allowedKey) ?? []).contains { key == $0 || key.hasSuffix("." + $0) }
    }

    func setAllowed(_ allowed: Bool, host: String) {
        let key = Self.siteKey(host)
        var sites = defaults.stringArray(forKey: Self.allowedKey) ?? []
        sites.removeAll { $0 == key || key.hasSuffix("." + $0) }
        if allowed { sites.append(key) }
        defaults.set(sites, forKey: Self.allowedKey)
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    func blocks(url: URL?) -> Bool {
        guard isEnabled else { return false }
        guard let host = url?.host else { return true }
        return !isAllowed(host: host)
    }

    func start(completion: ((TimeInterval?, Error?) -> Void)? = nil) {
        guard !started else { return }
        started = true
        guard let rulesURL, let compressed = try? Data(contentsOf: rulesURL) else { finish(reloadPages: false); completion?(nil, nil); return }
        let identifier = Self.identifierPrefix + Self.fingerprint(compressed)
        store.lookUpContentRuleList(forIdentifier: identifier) { [weak self] found, _ in
            guard let self else { return }
            if let found {
                self.list = found
                self.finish(reloadPages: false)
                completion?(nil, nil)
                return
            }
            let began = Date()
            DispatchQueue.global(qos: .userInitiated).async {
                let json = (try? (compressed as NSData).decompressed(using: .zlib)).flatMap { String(data: $0 as Data, encoding: .utf8) }
                DispatchQueue.main.async {
                    guard let json else { self.finish(reloadPages: false); completion?(nil, nil); return }
                    self.store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                        self.list = list
                        self.removeOldLists(keeping: identifier)
                        // Pages that opened during the first compile raced the rules:
                        // a list only affects requests made after it is attached.
                        self.finish(reloadPages: list != nil)
                        completion?(Date().timeIntervalSince(began), error)
                    }
                }
            }
        }
    }

    private static func fingerprint(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }

    private func removeOldLists(keeping identifier: String) {
        store.getAvailableContentRuleListIdentifiers { [store] identifiers in
            for old in identifiers ?? [] where old.hasPrefix(Self.identifierPrefix) && old != identifier && !old.hasPrefix(Self.privacyIdentifierPrefix) {
                store.removeContentRuleList(forIdentifier: old) { _ in }
            }
        }
    }

    private func finish(reloadPages: Bool) {
        finished = true
        let pending = waiting
        waiting = []
        pending.forEach { $0() }
        NotificationCenter.default.post(name: Self.changed, object: self, userInfo: [Self.reloadPagesKey: reloadPages])
    }

    // Normally rules are ready in milliseconds. The first launch compiles them, and a
    // page should not wait that long, so it loads once this short limit passes.
    func whenReady(limit: TimeInterval = 0.5, _ action: @escaping () -> Void) {
        guard !finished else { action(); return }
        var done = false
        let once = {
            guard !done else { return }
            done = true
            action()
        }
        waiting.append(once)
        DispatchQueue.main.asyncAfter(deadline: .now() + limit, execute: once)
    }

    func updatePrivacyRules(_ json: String?, completion: (() -> Void)? = nil) {
        guard let json else {
            privacyList = nil
            completion?()
            return
        }
        let identifier = Self.privacyIdentifierPrefix + Self.fingerprint(Data(json.utf8))
        store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { [weak self] list, _ in
            self?.privacyList = list
            completion?()
        }
    }

    // A site exception switches off every rule for that site, not only the ad list.
    func apply(to view: WKWebView, for url: URL?) {
        let controller = view.configuration.userContentController
        controller.removeAllContentRuleLists()
        let exception = url?.host.map(isAllowed(host:)) ?? false
        if blocks(url: url), let list { controller.add(list) }
        if !exception, let privacyList { controller.add(privacyList) }
    }
}
