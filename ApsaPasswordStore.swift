import Foundation
import Security

// A saved login is tied to one exact origin. Only the origin and the account are
// ever kept in memory; the password is read from the store when it is needed.
struct ApsaPasswordOrigin: Hashable {
    let scheme: String
    let host: String
    let port: Int?

    // Passwords are only handled on HTTPS, or plain HTTP on this machine.
    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let local = host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".localhost")
        guard scheme == "https" || (scheme == "http" && local) else { return nil }
        self.init(scheme: scheme, host: host, port: url.port)
    }

    init(scheme: String, host: String, port: Int?) {
        self.scheme = scheme
        self.host = host
        self.port = port
    }

    var display: String { port.map { "\(host):\($0)" } ?? host }
    var url: URL? { URL(string: "\(scheme)://\(display)/") }
}

struct ApsaSavedLogin: Hashable {
    let origin: ApsaPasswordOrigin
    let account: String
}

protocol ApsaPasswordBackend {
    func logins() -> [ApsaSavedLogin]
    func password(for login: ApsaSavedLogin) -> String?
    func save(_ login: ApsaSavedLogin, password: String) -> Bool
    func remove(_ login: ApsaSavedLogin) -> Bool
}

// macOS Keychain, which encrypts the items and locks them with the login. The
// description marks our items, so listing them does not touch those of other apps.
struct ApsaKeychainPasswords: ApsaPasswordBackend {
    private static let marker = "Apsa Browser password"

    private func query(_ login: ApsaSavedLogin) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrDescription as String: Self.marker,
            kSecAttrServer as String: login.origin.host,
            kSecAttrAccount as String: login.account,
            kSecAttrProtocol as String: login.origin.scheme == "https" ? kSecAttrProtocolHTTPS : kSecAttrProtocolHTTP
        ]
        if let port = login.origin.port { query[kSecAttrPort as String] = port }
        return query
    }

    func logins() -> [ApsaSavedLogin] {
        let search: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrDescription as String: Self.marker,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let host = item[kSecAttrServer as String] as? String,
                  let account = item[kSecAttrAccount as String] as? String else { return nil }
            let scheme = (item[kSecAttrProtocol as String] as? String) == (kSecAttrProtocolHTTP as String) ? "http" : "https"
            let port = (item[kSecAttrPort as String] as? Int).flatMap { $0 == 0 ? nil : $0 }
            return ApsaSavedLogin(origin: ApsaPasswordOrigin(scheme: scheme, host: host, port: port), account: account)
        }
    }

    func password(for login: ApsaSavedLogin) -> String? {
        var search = query(login)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ login: ApsaSavedLogin, password: String) -> Bool {
        let data = Data(password.utf8)
        let existing = query(login)
        let updated = SecItemUpdate(existing as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var item = existing
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "\(login.origin.display) (Apsa Browser)"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func remove(_ login: ApsaSavedLogin) -> Bool {
        let status = SecItemDelete(query(login) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

final class ApsaPasswordStore {
    static let shared = ApsaPasswordStore(backend: ApsaKeychainPasswords(), defaults: .standard)
    static let changed = Notification.Name("ApsaPasswordsChanged")
    private static let neverKey = "apsa-browser-password-never-hosts"

    private let backend: ApsaPasswordBackend
    private let defaults: UserDefaults

    init(backend: ApsaPasswordBackend, defaults: UserDefaults) {
        self.backend = backend
        self.defaults = defaults
    }

    var logins: [ApsaSavedLogin] {
        backend.logins().sorted { ($0.origin.host, $0.account) < ($1.origin.host, $1.account) }
    }

    func logins(for origin: ApsaPasswordOrigin) -> [ApsaSavedLogin] {
        logins.filter { $0.origin == origin }
    }

    func search(_ query: String) -> [ApsaSavedLogin] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return logins }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return logins.filter { $0.origin.host.range(of: needle, options: options) != nil || $0.account.range(of: needle, options: options) != nil }
    }

    func password(for login: ApsaSavedLogin) -> String? { backend.password(for: login) }

    @discardableResult
    func save(_ login: ApsaSavedLogin, password: String) -> Bool {
        guard !password.isEmpty, backend.save(login, password: password) else { return false }
        NotificationCenter.default.post(name: Self.changed, object: self)
        return true
    }

    @discardableResult
    func remove(_ login: ApsaSavedLogin) -> Bool {
        guard backend.remove(login) else { return false }
        NotificationCenter.default.post(name: Self.changed, object: self)
        return true
    }

    func isNever(_ origin: ApsaPasswordOrigin) -> Bool {
        (defaults.stringArray(forKey: Self.neverKey) ?? []).contains(origin.display)
    }

    func setNever(_ origin: ApsaPasswordOrigin) {
        var hosts = defaults.stringArray(forKey: Self.neverKey) ?? []
        guard !hosts.contains(origin.display) else { return }
        hosts.append(origin.display)
        defaults.set(hosts, forKey: Self.neverKey)
    }

    // What a submitted form should do: nothing, save a new login, or update one.
    enum Offer: Equatable { case none, save, update }

    func offer(for login: ApsaSavedLogin, password: String) -> Offer {
        guard !password.isEmpty, !isNever(login.origin) else { return .none }
        guard logins.contains(login) else { return .save }
        return backend.password(for: login) == password ? .none : .update
    }
}
