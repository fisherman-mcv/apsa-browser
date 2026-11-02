import Foundation

struct ApsaTabFolder: Codable, Equatable {
    var id: UUID
    var name: String
    var collapsed: Bool
}

enum ApsaTabRow: Equatable {
    case folder(ApsaTabFolder, count: Int)
    case tab(UUID, nested: Bool)
}

// The tab list keeps a folder's members next to each other, so its order is also
// the order on screen and the order Command-1 to 9 count in.
func apsaTabRows(_ tabs: [(id: UUID, folder: UUID?)], folders: [ApsaTabFolder]) -> [ApsaTabRow] {
    var rows: [ApsaTabRow] = []
    var shown = Set<UUID>()
    for tab in tabs {
        guard let id = tab.folder, let folder = folders.first(where: { $0.id == id }) else {
            rows.append(.tab(tab.id, nested: false))
            continue
        }
        guard shown.insert(id).inserted else { continue }
        let members = tabs.filter { $0.folder == id }
        rows.append(.folder(folder, count: members.count))
        if !folder.collapsed { rows += members.map { .tab($0.id, nested: true) } }
    }
    return rows
}

// Where a tab goes when it enters or leaves a folder: after the folder's last member.
func apsaTabOrder(_ tabs: [(id: UUID, folder: UUID?)], moving id: UUID, to folder: UUID?) -> [UUID] {
    guard let source = tabs.first(where: { $0.id == id }) else { return tabs.map(\.id) }
    let group = folder ?? source.folder
    var order = tabs.filter { $0.id != id }
    guard let group, let last = order.lastIndex(where: { $0.folder == group }) else {
        if folder == nil { return tabs.map(\.id) }
        return tabs.map(\.id)
    }
    order.insert(source, at: last + 1)
    return order.map(\.id)
}

struct ApsaSavedTab: Codable, Equatable {
    var id: UUID
    var url: String
    var title: String
    var folder: UUID?
    var icon: String?
}

struct ApsaSavedWindow: Codable, Equatable {
    var tabs: [ApsaSavedTab]
    var folders: [ApsaTabFolder]
    var activeTab: UUID?
    var sidebarVisible: Bool
    var frame: [Double]?
}

// Open windows and tabs, on this Mac only. A tab's address is stored, not its page,
// so a restored tab costs nothing until it is opened.
final class ApsaSessionStore {
    static let shared = ApsaSessionStore(file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Apsa Browser", isDirectory: true)
        .appendingPathComponent("session.json"))
    private static let enabledKey = "apsa-browser-restore-tabs"
    private static let maximumTabsPerWindow = 500
    private static let maximumIconBytes = 64 * 1_024

    private let file: URL?
    private let defaults: UserDefaults
    private let saveDelay: TimeInterval
    private let writer = DispatchQueue(label: "app.apsa.browser.session", qos: .utility)
    private var pending: [ApsaSavedWindow]?
    private var saveScheduled = false
    private var lastWritten: Data?

    init(file: URL?, defaults: UserDefaults = .standard, saveDelay: TimeInterval = 1) {
        self.file = file
        self.defaults = defaults
        self.saveDelay = saveDelay
    }

    var restoresTabs: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
            if !newValue { clear() }
        }
    }

    func load() -> [ApsaSavedWindow] {
        guard restoresTabs, let file, let data = try? Data(contentsOf: file) else { return [] }
        guard let windows = try? JSONDecoder().decode([ApsaSavedWindow].self, from: data) else {
            try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("unreadable"))
            return []
        }
        return windows.compactMap(Self.sanitized)
    }

    private static func sanitized(_ window: ApsaSavedWindow) -> ApsaSavedWindow? {
        var clean = window
        clean.tabs = Array(window.tabs.filter { URL(string: $0.url) != nil }.prefix(maximumTabsPerWindow))
        guard !clean.tabs.isEmpty else { return nil }
        let used = Set(clean.tabs.compactMap(\.folder))
        clean.folders = window.folders.filter { used.contains($0.id) }
        let known = Set(clean.folders.map(\.id))
        for index in clean.tabs.indices {
            if let folder = clean.tabs[index].folder, !known.contains(folder) { clean.tabs[index].folder = nil }
            if let icon = clean.tabs[index].icon, icon.utf8.count > maximumIconBytes || !icon.hasPrefix("data:image/png;base64,") { clean.tabs[index].icon = nil }
        }
        if !clean.tabs.contains(where: { $0.id == clean.activeTab }) { clean.activeTab = clean.tabs.last?.id }
        return clean
    }

    func save(_ windows: [ApsaSavedWindow]) {
        guard restoresTabs, file != nil else { return }
        pending = windows
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay) { [weak self] in
            guard let self, self.saveScheduled else { return }
            self.flush(wait: false)
        }
    }

    func saveNow() { flush(wait: true) }

    private func flush(wait: Bool) {
        saveScheduled = false
        guard let windows = pending, let file, let data = try? JSONEncoder().encode(windows) else { return }
        pending = nil
        guard data != lastWritten else { return }
        lastWritten = data
        let work = {
            let manager = FileManager.default
            try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? data.write(to: file, options: .atomic)) != nil else { return }
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        if wait { writer.sync(execute: work) } else { writer.async(execute: work) }
    }

    func clear() {
        pending = nil
        saveScheduled = false
        lastWritten = nil
        if let file { writer.async { try? FileManager.default.removeItem(at: file) } }
    }
}
