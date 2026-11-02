import Foundation

@main struct BookmarkTests {
    static func main() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = folder.appendingPathComponent("bookmarks.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "apsa.bookmark.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let site = URL(string: "https://example.com/a")!
        let other = URL(string: "https://other.example/b")!

        let store = ApsaBookmarkStore(file: file, defaults: defaults)
        precondition(!ApsaBookmarkStore.canBookmark(URL(string: "apsa://home")!))
        precondition(!store.toggle(url: URL(string: "apsa://home")!, title: "Дом", icon: nil))
        precondition(store.bookmarks.isEmpty)
        precondition(store.toggle(url: site, title: "  Пример  ", icon: nil))
        precondition(store.bookmark(for: site)?.title == "Пример" && store.bookmark(for: site)?.kind == "link")
        precondition(store.toggle(url: other, title: "", icon: "javascript:alert(1)"))
        precondition(store.bookmark(for: other)?.title == "other.example" && store.bookmark(for: other)?.icon == nil)
        store.setIcon("data:image/png;base64,AAAA", for: other)
        precondition(store.bookmark(for: other)?.icon == "data:image/png;base64,AAAA")
        store.setIcon("https://tracker.example/x.png", for: other)
        precondition(store.bookmark(for: other)?.icon == "data:image/png;base64,AAAA")

        let id = store.bookmark(for: other)!.id
        store.rename(id, to: "  Другой  ")
        store.rename(id, to: "   ")
        precondition(store.bookmark(id: id)?.title == "Другой")
        store.move(id, toFolder: " Работа ")
        precondition(store.folders == ["Работа"])
        precondition(store.grouped.map(\.folder) == [nil, "Работа"])
        precondition(store.search("работа").count == 1 && store.search("пример").count == 1 && store.search("нет").isEmpty)
        store.move(id, toFolder: "  ")
        precondition(store.folders.isEmpty)
        store.move(id, toFolder: "Работа")

        precondition(store.toggle(url: URL(string: "https://me:secret@example.com/private")!, title: "Личное", icon: nil))
        precondition(store.bookmark(for: URL(string: "https://example.com/private")!) != nil)

        let extra = URL(string: "https://third.example/c")!
        precondition(store.saveAll([(extra, "Третья", nil), (site, "Пример", nil), (URL(string: "apsa://home")!, "Дом", nil)], toFolder: " Вкладки ") == 2)
        precondition(store.bookmark(for: extra)?.folder == "Вкладки" && store.bookmark(for: site)?.folder == "Вкладки")
        precondition(store.bookmarks.filter { $0.url == site.absoluteString }.count == 1)
        precondition(store.saveAll([(extra, "", nil)], toFolder: "  ") == 0)

        store.saveNow()
        let attributes = try! FileManager.default.attributesOfItem(atPath: file.path)
        precondition((attributes[.posixPermissions] as! NSNumber).intValue == 0o600)
        precondition(!String(data: try! Data(contentsOf: file), encoding: .utf8)!.contains("secret"))
        let reloaded = ApsaBookmarkStore(file: file, defaults: defaults)
        precondition(reloaded.bookmarks.map(\.id) == store.bookmarks.map(\.id))
        precondition(reloaded.bookmarks.map(\.title) == store.bookmarks.map(\.title) && reloaded.bookmarks.map(\.folder) == store.bookmarks.map(\.folder))

        precondition(!reloaded.toggle(url: site, title: "", icon: nil))
        precondition(reloaded.bookmark(for: site) == nil)
        reloaded.collapsed = true
        precondition(ApsaBookmarkStore(file: nil, defaults: defaults).collapsed)

        reloaded.saveNow()
        try! Data("не json".utf8).write(to: file)
        let damaged = ApsaBookmarkStore(file: file, defaults: defaults)
        precondition(damaged.bookmarks.isEmpty)
        precondition(FileManager.default.fileExists(atPath: file.path + ".unreadable"))
        print("Bookmarks: toggle, folders, search, persistence, privacy and bounds OK")
    }
}
