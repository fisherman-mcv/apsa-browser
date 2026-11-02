import Foundation

@main struct HistoryTests {
    static func main() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = folder.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let site = URL(string: "https://example.com/a")!
        let other = URL(string: "https://other.example/b")!

        let store = ApsaHistoryStore(file: file, saveDelay: 60)
        store.visit(URL(string: "apsa://home")!)
        precondition(store.entries.isEmpty)
        store.visit(site)
        store.visit(site)
        precondition(store.entries.count == 1)
        store.updateTitle("  Пример  ", for: site)
        precondition(store.entries[0].title == "Пример")
        store.visit(other)
        precondition(store.entries.map(\.url) == [other.absoluteString, site.absoluteString])
        store.visit(site)
        precondition(store.entries.count == 3 && store.entries[0].title == "Пример")
        store.visit(URL(string: "https://me:secret@example.com/private")!)
        precondition(store.entries[0].url == "https://example.com/private")
        precondition(store.search("пример").count == 2 && store.search("other").count == 1 && store.search("нет такого").isEmpty)

        store.saveNow()
        let attributes = try! FileManager.default.attributesOfItem(atPath: file.path)
        precondition((attributes[.posixPermissions] as! NSNumber).intValue == 0o600)
        let reloaded = ApsaHistoryStore(file: file, saveDelay: 60)
        precondition(reloaded.entries.map(\.url) == store.entries.map(\.url))
        precondition(!String(data: try! Data(contentsOf: file), encoding: .utf8)!.contains("secret"))

        reloaded.remove(reloaded.entries[0].id)
        precondition(reloaded.entries.count == 3)
        reloaded.clear()
        precondition(reloaded.entries.isEmpty)

        try! Data("не json".utf8).write(to: file)
        let damaged = ApsaHistoryStore(file: file, saveDelay: 60)
        precondition(damaged.entries.isEmpty)
        precondition(FileManager.default.fileExists(atPath: file.path + ".unreadable"))

        let bounded = ApsaHistoryStore(file: nil)
        for index in 0...ApsaHistoryStore.maximumEntries { bounded.visit(URL(string: "https://example.com/\(index)")!) }
        precondition(bounded.entries.count == ApsaHistoryStore.maximumEntries)
        print("Browsing history: visits, titles, search, persistence, privacy and bounds OK")
    }
}
