import Foundation

struct ApsaBookmark: Codable, Equatable {
    var id: UUID
    // Only "link" exists today. The field leaves room for other kinds later.
    var kind: String
    var url: String
    var title: String
    var folder: String?
    var icon: String?
    var created: Date
}

// Bookmarks live only in this file on this Mac, and are saved right after a change.
final class ApsaBookmarkStore {
    static let shared = ApsaBookmarkStore(file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Apsa Browser", isDirectory: true)
        .appendingPathComponent("bookmarks.json"))
    static let changed = Notification.Name("ApsaBookmarksChanged")
    static let maximumEntries = 5_000
    private static let collapsedKey = "apsa-browser-bookmarks-collapsed"
    private static let maximumIconBytes = 64 * 1_024

    private(set) var bookmarks: [ApsaBookmark] = []
    private let file: URL?
    private let defaults: UserDefaults
    private let writer = DispatchQueue(label: "app.apsa.browser.bookmarks", qos: .utility)

    init(file: URL?, defaults: UserDefaults = .standard) {
        self.file = file
        self.defaults = defaults
        guard let file, let data = try? Data(contentsOf: file) else { return }
        if let decoded = try? Self.decoder.decode([ApsaBookmark].self, from: data) {
            bookmarks = Array(decoded.prefix(Self.maximumEntries))
        } else {
            // An unreadable file is set aside, not overwritten by the next change.
            try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("unreadable"))
        }
    }

    var collapsed: Bool {
        get { defaults.bool(forKey: Self.collapsedKey) }
        set {
            defaults.set(newValue, forKey: Self.collapsedKey)
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }

    var folders: [String] {
        Array(Set(bookmarks.compactMap(\.folder))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // Loose bookmarks first, then one group per folder.
    var grouped: [(folder: String?, items: [ApsaBookmark])] {
        var groups: [(folder: String?, items: [ApsaBookmark])] = []
        let loose = bookmarks.filter { $0.folder == nil }
        if !loose.isEmpty { groups.append((nil, loose)) }
        for folder in folders { groups.append((folder, bookmarks.filter { $0.folder == folder })) }
        return groups
    }

    static func canBookmark(_ url: URL) -> Bool { ApsaHistoryStore.recordableAddress(url) != nil }

    func bookmark(for url: URL) -> ApsaBookmark? {
        guard let address = ApsaHistoryStore.recordableAddress(url) else { return nil }
        return bookmarks.first { $0.url == address }
    }

    func bookmark(id: UUID) -> ApsaBookmark? { bookmarks.first { $0.id == id } }

    @discardableResult
    func toggle(url: URL, title: String, icon: String?) -> Bool {
        guard let address = ApsaHistoryStore.recordableAddress(url) else { return false }
        if let existing = bookmarks.first(where: { $0.url == address }) {
            remove(existing.id)
            return false
        }
        guard bookmarks.count < Self.maximumEntries else { return false }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        bookmarks.append(ApsaBookmark(id: UUID(), kind: "link", url: address, title: String((clean.isEmpty ? url.host ?? address : clean).prefix(500)),
                                      folder: nil, icon: Self.bounded(icon), created: Date()))
        didChange()
        return true
    }

    // Saving a set of tabs: already saved addresses move into the folder instead of
    // being duplicated or, as with the star, removed.
    @discardableResult
    func saveAll(_ pages: [(url: URL, title: String, icon: String?)], toFolder folder: String) -> Int {
        let name = String(folder.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        guard !name.isEmpty else { return 0 }
        var saved = 0
        for page in pages {
            guard let address = ApsaHistoryStore.recordableAddress(page.url) else { continue }
            if let index = bookmarks.firstIndex(where: { $0.url == address }) {
                bookmarks[index].folder = name
            } else {
                guard bookmarks.count < Self.maximumEntries else { break }
                let clean = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
                bookmarks.append(ApsaBookmark(id: UUID(), kind: "link", url: address, title: String((clean.isEmpty ? page.url.host ?? address : clean).prefix(500)),
                                              folder: name, icon: Self.bounded(page.icon), created: Date()))
            }
            saved += 1
        }
        if saved > 0 { didChange() }
        return saved
    }

    func remove(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
        didChange()
    }

    func rename(_ id: UUID, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[index].title = String(clean.prefix(500))
        didChange()
    }

    func move(_ id: UUID, toFolder folder: String?) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        let clean = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        bookmarks[index].folder = clean?.isEmpty == false ? String(clean!.prefix(100)) : nil
        didChange()
    }

    func setIcon(_ icon: String, for url: URL) {
        guard let address = ApsaHistoryStore.recordableAddress(url), let bounded = Self.bounded(icon),
              let index = bookmarks.firstIndex(where: { $0.url == address }), bookmarks[index].icon != bounded else { return }
        bookmarks[index].icon = bounded
        didChange()
    }

    func search(_ query: String) -> [ApsaBookmark] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return bookmarks }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return bookmarks.filter {
            $0.title.range(of: needle, options: options) != nil || $0.url.range(of: needle, options: options) != nil
                || $0.folder?.range(of: needle, options: options) != nil
        }
    }

    func saveNow() {
        let snapshot = bookmarks
        writer.sync { self.write(snapshot) }
    }

    private static func bounded(_ icon: String?) -> String? {
        guard let icon, icon.utf8.count <= maximumIconBytes, icon.hasPrefix("data:image/png;base64,") else { return nil }
        return icon
    }

    private func didChange() {
        NotificationCenter.default.post(name: Self.changed, object: self)
        guard file != nil else { return }
        let snapshot = bookmarks
        writer.async { self.write(snapshot) }
    }

    private func write(_ snapshot: [ApsaBookmark]) {
        guard let file, let data = try? Self.encoder.encode(snapshot) else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
