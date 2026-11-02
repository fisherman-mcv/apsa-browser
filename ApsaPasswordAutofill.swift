import AppKit
import LocalAuthentication
import WebKit

// The page script runs in its own content world. The site's JavaScript cannot see
// its variables or its message handler, and it only ever receives a password when
// the person picks a login from the browser's own menu.
final class ApsaPasswordAutofill: NSObject, WKScriptMessageHandler {
    static let world = WKContentWorld.world(name: "apsa-passwords")
    private static let handlerName = "apsaPasswords"
    private static let pendingLifetime: TimeInterval = 30

    private struct Pending {
        let origin: ApsaPasswordOrigin
        let account: String
        let password: String
        let time: Date
    }

    private let store: ApsaPasswordStore
    private var pending: [ObjectIdentifier: Pending] = [:]
    private var lastAccount: [ApsaPasswordOrigin: String] = [:]
    // A sign-in spread over several pages should not ask for the finger on each.
    private static let authenticationReuse: TimeInterval = 60
    private var authentication: LAContext?
    lazy var authenticate: (String, @escaping (Bool) -> Void) -> Void = { [weak self] reason, done in
        guard let self else { return done(false) }
        let context = self.authentication ?? LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = Self.authenticationReuse
        self.authentication = context
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return done(false) }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            DispatchQueue.main.async { done(success) }
        }
    }
    var isActive: (WKWebView) -> Bool = { _ in false }
    var onShowManager: () -> Void = {}

    init(store: ApsaPasswordStore = .shared) {
        self.store = store
    }

    func install(on configuration: WKWebViewConfiguration) {
        configuration.userContentController.add(self, contentWorld: Self.world, name: Self.handlerName)
    }

    func addScript(to controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: Self.pageScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let webView = message.webView, let body = message.body as? [String: Any],
              let url = webView.url, let origin = ApsaPasswordOrigin(url: url),
              message.frameInfo.securityOrigin.host.lowercased() == origin.host else { return }
        switch body["event"] as? String {
        case "username":
            if let account = Self.bounded(body["username"]) { lastAccount[origin] = account }
        case "candidate":
            guard let password = Self.bounded(body["password"]) else { return }
            let account = Self.bounded(body["username"]) ?? lastAccount[origin] ?? ""
            pending[ObjectIdentifier(webView)] = Pending(origin: origin, account: account, password: password, time: Date())
        case "field":
            guard isActive(webView), let rect = body["rect"] as? [NSNumber], rect.count == 4 else { return }
            let zoom = webView.pageZoom
            showMenu(in: webView, at: NSPoint(x: rect[0].doubleValue * zoom, y: (rect[1].doubleValue + rect[3].doubleValue) * zoom + 4), origin: origin, onlyIfSaved: true)
        default:
            break
        }
    }

    private static func bounded(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 4_096 else { return nil }
        return text
    }

    // MARK: Filling

    func showMenu(in webView: WKWebView, at point: NSPoint, origin: ApsaPasswordOrigin? = nil, onlyIfSaved: Bool = false) {
        guard let origin = origin ?? webView.url.flatMap(ApsaPasswordOrigin.init(url:)) else { return }
        let saved = store.logins(for: origin)
        if saved.isEmpty, onlyIfSaved { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for login in saved {
            let item = NSMenuItem(title: login.account.isEmpty ? apsaText("No Username") : login.account, action: #selector(chooseLogin(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ChosenLogin(login: login, webView: webView)
            menu.addItem(item)
        }
        if saved.isEmpty {
            let empty = NSMenuItem(title: apsaText("No Passwords for This Site"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.addItem(.separator())
        let manage = NSMenuItem(title: apsaText("Manage Passwords…"), action: #selector(manage), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
        menu.popUp(positioning: nil, at: point, in: webView)
    }

    private final class ChosenLogin {
        let login: ApsaSavedLogin
        weak var webView: WKWebView?
        init(login: ApsaSavedLogin, webView: WKWebView) {
            self.login = login
            self.webView = webView
        }
    }

    @objc private func manage() { onShowManager() }

    @objc private func chooseLogin(_ sender: NSMenuItem) {
        guard let chosen = sender.representedObject as? ChosenLogin, let webView = chosen.webView else { return }
        fillAfterAuthentication(chosen.login, in: webView)
    }

    // The finger comes first; the Keychain is read only after it. The page may have
    // moved on during the prompt, so the origin is checked once more afterwards.
    func fillAfterAuthentication(_ login: ApsaSavedLogin, in webView: WKWebView, completion: ((Bool) -> Void)? = nil) {
        authenticate(apsaText("sign in to %@", login.origin.display)) { [weak self, weak webView] allowed in
            guard allowed, let self, let webView, let url = webView.url, ApsaPasswordOrigin(url: url) == login.origin,
                  let password = self.store.password(for: login) else { completion?(false); return }
            Self.fill(webView, account: login.account, password: password, completion: completion)
        }
    }

    static func fill(_ webView: WKWebView, account: String, password: String, completion: ((Bool) -> Void)? = nil) {
        webView.callAsyncJavaScript("return window.apsaPasswordFill(account, password);", arguments: ["account": account, "password": password], in: nil, in: world) { result in
            if case let .success(value) = result { completion?(value as? Bool ?? false) } else { completion?(false) }
        }
    }

    // MARK: Saving

    // Asked after the page moves on: a login that failed usually stays where it was.
    func pageChanged(_ webView: WKWebView, window: NSWindow?) {
        guard let item = pending.removeValue(forKey: ObjectIdentifier(webView)),
              Date().timeIntervalSince(item.time) <= Self.pendingLifetime, isActive(webView), let window else { return }
        let login = ApsaSavedLogin(origin: item.origin, account: item.account)
        let offer = store.offer(for: login, password: item.password)
        guard offer != .none else { return }
        let alert = NSAlert()
        alert.messageText = offer == .update ? apsaText("Update Password for %@?", item.origin.display) : apsaText("Save Password for %@?", item.origin.display)
        alert.informativeText = item.account.isEmpty ? apsaText("No username found on the page.") : apsaText("Username: %@", item.account)
        alert.addButton(withTitle: offer == .update ? apsaText("Update") : apsaText("Save"))
        alert.addButton(withTitle: apsaText("Not Now"))
        alert.addButton(withTitle: apsaText("Never for This Site"))
        alert.beginSheetModal(for: window) { [store] response in
            switch response {
            case .alertFirstButtonReturn: store.save(login, password: item.password)
            case .alertThirdButtonReturn: store.setNever(item.origin)
            default: break
            }
        }
    }

    func forget(_ webView: WKWebView) { pending[ObjectIdentifier(webView)] = nil }

    static let pageScript = """
    (() => {
      const post = message => window.webkit.messageHandlers.apsaPasswords.postMessage(message);
      const visible = field => {
        const rect = field.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0 && getComputedStyle(field).visibility !== 'hidden';
      };
      const passwordFields = root => [...root.querySelectorAll('input[type=password]')].filter(visible);
      const isNameField = field => {
        if (field.tagName !== 'INPUT' || !['text', 'email', 'tel', ''].includes(field.type)) return false;
        const hint = `${field.autocomplete} ${field.name} ${field.id} ${field.getAttribute('aria-label') || ''} ${field.placeholder}`.toLowerCase();
        return field.type === 'email' || /user|login|email|mail|account|phone|логин|почт|телефон/.test(hint);
      };
      const nameFieldFor = password => {
        const scope = password?.form || document;
        const fields = [...scope.querySelectorAll('input')].filter(field => visible(field) && isNameField(field));
        if (!password) return fields[0] || null;
        return fields.filter(field => field.compareDocumentPosition(password) & Node.DOCUMENT_POSITION_FOLLOWING).pop() || fields[0] || null;
      };
      const report = () => {
        const fields = passwordFields(document).filter(field => field.value);
        if (fields.length) {
          // On a change-password form the last field holds the new password.
          const password = fields[fields.length - 1];
          post({ event: 'candidate', username: nameFieldFor(fields[0])?.value || '', password: password.value });
        } else {
          const name = nameFieldFor(null);
          if (name?.value) post({ event: 'username', username: name.value });
        }
      };
      document.addEventListener('submit', report, true);
      document.addEventListener('click', event => {
        if (!event.isTrusted) return;
        if (event.target.closest?.('button, input[type=submit], input[type=button], [role=button], a')) report();
        const field = event.target;
        if (field.tagName === 'INPUT' && (field.type === 'password' || isNameField(field)) && field.autocomplete !== 'new-password') {
          const rect = field.getBoundingClientRect();
          post({ event: 'field', rect: [rect.x, rect.y, rect.width, rect.height] });
        }
      }, true);
      document.addEventListener('keydown', event => {
        if (event.isTrusted && event.key === 'Enter' && event.target.tagName === 'INPUT') report();
      }, true);
      const setValue = (field, value) => {
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(field, value);
        field.dispatchEvent(new Event('input', { bubbles: true }));
        field.dispatchEvent(new Event('change', { bubbles: true }));
      };
      window.apsaPasswordFill = (account, password) => {
        const target = passwordFields(document).find(field => field.autocomplete !== 'new-password') || null;
        const name = nameFieldFor(target);
        if (name && account) setValue(name, account);
        if (target) setValue(target, password);
        return Boolean(target || name);
      };
    })();
    """
}
