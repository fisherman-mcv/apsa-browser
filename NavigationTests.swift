import AppKit

@main struct NavigationTests {
    static func main() {
        let home = URL(string: "apsa://home")!
        let about = URL(string: "apsa://about")!
        let site = URL(string: "https://example.com")!
        var history = ApsaNavigationHistory()
        precondition(!history.canGoBack && !history.canGoForward)
        precondition(history.move(-1) == nil && history.move(1) == nil)
        history.record(home)
        history.record(home)
        precondition(history.entries == [home])
        history.record(about)
        precondition(history.canGoBack && !history.canGoForward)
        precondition(history.move(-1) == home)
        precondition(!history.canGoBack && history.canGoForward)
        precondition(history.move(1) == about)
        precondition(history.move(-1) == home)
        history.record(site)
        precondition(history.entries == [home, site] && !history.canGoForward)
        let redirected = URL(string: "https://www.example.com/")!
        history.replaceCurrent(redirected)
        precondition(history.entries == [home, redirected])
        precondition(history.move(-1) == home && history.move(1) == redirected)
        var otherTab = ApsaNavigationHistory()
        otherTab.record(about)
        precondition(!otherTab.canGoBack && history.canGoBack)
        precondition(apsaTabIndex(forShortcut: 1, tabCount: 0) == nil)
        precondition(apsaTabIndex(forShortcut: 3, tabCount: 5) == 2)
        for number in 6...9 { precondition(apsaTabIndex(forShortcut: number, tabCount: 5) == 4) }
        precondition(apsaTabIndex(forShortcut: 8, tabCount: 12) == 7)
        precondition(apsaTabIndex(forShortcut: 9, tabCount: 12) == 11)
        precondition(apsaTabIndex(forShortcut: 9, tabCount: 9) == 8)
        let suite = "apsa-zoom-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(ApsaPageZoom.saved(in: defaults) == 1, "no saved zoom means actual size")
        ApsaPageZoom.save(1.21, in: defaults)
        precondition(ApsaPageZoom.saved(in: defaults) == 1.21)
        ApsaPageZoom.save(40, in: defaults)
        precondition(ApsaPageZoom.saved(in: defaults) == 3, "a damaged value stays in range")
        ApsaPageZoom.save(0.01, in: defaults)
        precondition(ApsaPageZoom.saved(in: defaults) == 0.5)
        print("Navigation history: traversal, branching, reload, redirect and tab isolation OK")
    }
}
