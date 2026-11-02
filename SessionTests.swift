import Foundation

@main struct SessionTests {
    static func main() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = folder.appendingPathComponent("session.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "apsa.session.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), work = UUID()
        let open = ApsaTabFolder(id: work, name: "Работа", collapsed: false)
        let tabs: [(id: UUID, folder: UUID?)] = [(a, nil), (b, work), (c, work), (d, nil)]
        precondition(apsaTabRows(tabs, folders: [open]) == [.tab(a, nested: false), .folder(open, count: 2), .tab(b, nested: true), .tab(c, nested: true), .tab(d, nested: false)])
        var closed = open; closed.collapsed = true
        precondition(apsaTabRows(tabs, folders: [closed]) == [.tab(a, nested: false), .folder(closed, count: 2), .tab(d, nested: false)])
        precondition(apsaTabRows([(a, work)], folders: []) == [.tab(a, nested: false)], "a tab whose folder is gone stays visible")
        precondition(apsaTabOrder(tabs, moving: d, to: work) == [a, b, c, d])
        precondition(apsaTabOrder([(a, nil), (d, nil), (b, work), (c, work)], moving: a, to: work) == [d, b, c, a])
        precondition(apsaTabOrder(tabs, moving: b, to: nil) == [a, c, b, d], "a tab leaves past its old folder")
        precondition(apsaTabOrder(tabs, moving: a, to: nil) == [a, b, c, d])

        let store = ApsaSessionStore(file: file, defaults: defaults, saveDelay: 60)
        precondition(store.restoresTabs && store.load().isEmpty)
        let window = ApsaSavedWindow(tabs: [
            ApsaSavedTab(id: a, url: "https://example.com/", title: "Пример", folder: work, icon: "data:image/png;base64,AAAA"),
            ApsaSavedTab(id: b, url: "apsa://home", title: "Новая вкладка", folder: nil, icon: nil)
        ], folders: [closed], activeTab: b, sidebarVisible: false, frame: [10, 20, 800, 600])
        store.save([window])
        precondition(store.load().isEmpty, "saving is delayed")
        store.saveNow()
        precondition(store.load() == [window])
        let attributes = try! FileManager.default.attributesOfItem(atPath: file.path)
        precondition((attributes[.posixPermissions] as! NSNumber).intValue == 0o600)

        var odd = window
        odd.tabs[0].icon = "https://tracker.example/x.png"
        odd.tabs[0].folder = UUID()
        odd.activeTab = UUID()
        odd.folders = [closed]
        store.save([odd, ApsaSavedWindow(tabs: [], folders: [], activeTab: nil, sidebarVisible: true, frame: nil)])
        store.saveNow()
        let clean = store.load()
        precondition(clean.count == 1 && clean[0].tabs[0].icon == nil && clean[0].tabs[0].folder == nil)
        precondition(clean[0].folders.isEmpty && clean[0].activeTab == b)

        store.restoresTabs = false
        store.saveNow()
        Thread.sleep(forTimeInterval: 0.2)
        precondition(!FileManager.default.fileExists(atPath: file.path), "turning restore off removes the saved session")
        store.save([window])
        store.saveNow()
        precondition(!FileManager.default.fileExists(atPath: file.path))
        store.restoresTabs = true

        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try! Data("не json".utf8).write(to: file)
        precondition(store.load().isEmpty && FileManager.default.fileExists(atPath: file.path + ".unreadable"))
        print("Session: folders, ordering, persistence, cleanup and damage OK")
    }
}
