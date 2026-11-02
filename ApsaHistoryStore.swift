import Foundation

struct ApsaHistoryEntry: Codable, Equatable {
    var id: UUID
    var url: String
    var title: String
    var date: Date
}

// Browsing history lives only in this file on this Mac. Visits are saved in the
// background shortly after they happen and once more when the app quits.
final class ApsaHistoryStore {
    static let shared = ApsaHistoryStore(file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Apsa Browser", isDirectory: true)
        .appendingPathComponent("history.json"))
    static let changed = Notification.Name("ApsaHistoryChanged")
    static let maximumEntries = 5_000
    private static let titleLookback = 32

    private(set) var entries: [ApsaHistoryEntry] = []
    private let file: URL?
    private let saveDelay: TimeInterval
    private let writer = DispatchQueue(label: "app.apsa.browser.history", qos: .utility)
    private var saveScheduled = false

    init(file: URL?, saveDelay: TimeInterval = 1.5) {
        self.file = file
        self.saveDelay = saveDelay
        guard let file, let data = try? Data(contentsOf: file) else { return }
        if let decoded = try? Self.decoder.decode([ApsaHistoryEntry].self, from: data) {
            entries = Array(decoded.prefix(Self.maximumEntries))
        } else {
            // An unreadable file is set aside, not overwritten by the next visit.
            try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("unreadable"))
        }
    }

    // Only real destinations are history. Credentials in a URL are never stored.
    static func recordableAddress(_ url: URL) -> String? {
        guard ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.user = nil
        parts.password = nil
        return parts.url?.absoluteString
    }

    func visit(_ url: URL, at date: Date = Date()) {
        guard let address = Self.recordableAddress(url) else { return }
        if entries.first?.url == address {
            entries[0].date = date
        } else {
            let title = entries.prefix(Self.titleLookback).first { $0.url == address }?.title ?? ""
            entries.insert(ApsaHistoryEntry(id: UUID(), url: address, title: title, date: date), at: 0)
            if entries.count > Self.maximumEntries { entries.removeLast(entries.count - Self.maximumEntries) }
        }
        didChange()
    }

    func updateTitle(_ title: String, for url: URL) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let address = Self.recordableAddress(url),
              let index = entries.prefix(Self.titleLookback).firstIndex(where: { $0.url == address }),
              entries[index].title != clean else { return }
        entries[index].title = String(clean.prefix(500))
        didChange()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        didChange()
    }

    func clear() {
        entries = []
        didChange()
    }

    func search(_ query: String, limit: Int = 500) -> [ApsaHistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return Array(entries.prefix(limit)) }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return Array(entries.lazy.filter {
            $0.title.range(of: needle, options: options) != nil || $0.url.range(of: needle, options: options) != nil
        }.prefix(limit))
    }

    func saveNow() {
        let snapshot = entries
        writer.sync { self.write(snapshot) }
        saveScheduled = false
    }

    private func didChange() {
        NotificationCenter.default.post(name: Self.changed, object: self)
        guard file != nil, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay) { [weak self] in
            guard let self, self.saveScheduled else { return }
            self.saveScheduled = false
            let snapshot = self.entries
            self.writer.async { self.write(snapshot) }
        }
    }

    private func write(_ snapshot: [ApsaHistoryEntry]) {
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
