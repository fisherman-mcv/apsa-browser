import AppKit
import WebKit

// Runs in WebKit and AppKit with no visible window, no Dock icon and no focus.
@main struct ReaderTests {
    static func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let resources = ApsaReaderResources(folder: folder, modelFolder: folder.appendingPathComponent("ReaderBlocks.mlmodelc"))!
        typealias Choice = ApsaReader.Choice
        // Readability is kept unless it clearly lost text; weak pages are refused.
        precondition(ApsaReader.choose(modelWords: 500, modelLength: 3000, readabilityWords: 480, readabilityLength: 2900) == .readability)
        precondition(ApsaReader.choose(modelWords: 900, modelLength: 5000, readabilityWords: 200, readabilityLength: 1200) == .model)
        precondition(ApsaReader.choose(modelWords: 500, modelLength: 3000, readabilityWords: 0, readabilityLength: 0) == .model)
        precondition(ApsaReader.choose(modelWords: 3, modelLength: 20, readabilityWords: 800, readabilityLength: 5000) == .readability)
        precondition(ApsaReader.choose(modelWords: 3, modelLength: 20, readabilityWords: 80, readabilityLength: 500) == .refuse)
        precondition(ApsaReader.choose(modelWords: 0, modelLength: 0, readabilityWords: 0, readabilityLength: 0) == .refuse)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: configuration)
        func read(_ html: String, base: String = "https://example.org/a/b") -> ApsaReaderDocument? {
            view.loadHTMLString(html, baseURL: URL(string: base))
            spin(0.8)
            var result: ApsaReaderDocument?, done = false
            ApsaReader.extract(from: view, resources: resources) { result = $0; done = true }
            while !done { spin(0.01) }
            return result
        }
        let body = String(repeating: "Это настоящий абзац статьи, в нём достаточно обычного связного текста, запятых и точек. ", count: 5)
        let secret = "secret-\(UUID().uuidString)"
        let page = """
        <!doctype html><html><head><title>Заголовок статьи</title></head><body>
        <nav><a href="/x">Главная</a><a href="/y">Разделы</a></nav>
        <article><h1>Заголовок статьи</h1>
        <p>\(body)<a href="/link">ссылка</a> и <a href="javascript:alert(1)">плохая</a> <strong>жирный</strong> <code>код</code>.</p>
        <h2>Раздел</h2><p>\(body)</p><ul><li>Первый пункт списка достаточной длины<ul><li>Вложенный пункт</li></ul></li></ul>
        <blockquote>Цитата из источника, которая должна остаться.</blockquote><pre>let x = 1
          y = 2</pre>
        <table><tr><th>Город</th><th>Люди</th></tr><tr><td>Осло</td><td>700</td></tr></table>
        <figure><img src="/photo.png" alt="Фото"><figcaption>Подпись</figcaption></figure>
        <p>\(body)<script>window.ran = true</script></p></article>
        <form><input type="password" value="\(secret)"><input type="text" value="\(secret)"></form>
        <footer>Подвал сайта, все права защищены.</footer></body></html>
        """
        guard let document = read(page) else { fatalError("article must parse") }
        precondition(document.title == "Заголовок статьи")
        var kinds = Set<String>(), allText = "", links: [String] = []
        func gather(_ runs: [ApsaReaderRun]) { for run in runs { allText += run.text; if let link = run.link { links.append(link.absoluteString) } } }
        for block in document.blocks {
            switch block {
            case let .heading(_, runs): kinds.insert("h"); gather(runs)
            case let .paragraph(runs): kinds.insert("p"); gather(runs)
            case let .listItem(_, depth, runs): kinds.insert(depth > 0 ? "nested" : "li"); gather(runs)
            case let .quote(runs): kinds.insert("q"); gather(runs)
            case let .code(value): kinds.insert("pre"); allText += value; precondition(value.contains("\n"), "code keeps its lines")
            case let .table(rows): kinds.insert("table"); precondition(rows == [["Город", "Люди"], ["Осло", "700"]])
            case let .image(url, alt, caption): kinds.insert("img"); precondition(url.absoluteString == "https://example.org/photo.png" && alt == "Фото" && caption == "Подпись")
            }
        }
        precondition(kinds.isSuperset(of: ["h", "p", "li", "nested", "q", "pre", "table", "img"]), "missing: \(kinds)")
        precondition(links == ["https://example.org/link"], "only web links, made absolute: \(links)")
        precondition(!allText.contains("Подвал") && !allText.contains("Главная"), "site furniture is dropped")
        precondition(!allText.contains(secret), "field values never reach the reader")

        // The reader must not touch the live page.
        var scripts: Any?, finished = false
        view.evaluateJavaScript("document.querySelector('nav') !== null && document.querySelector('footer') !== null") { value, _ in scripts = value; finished = true }
        while !finished { spin(0.01) }
        precondition(scripts as? Bool == true, "extraction works on a copy")

        precondition(read("<!doctype html><title>Войти</title><form><input type=password><button>Войти</button></form>") == nil, "a login page is refused")
        precondition(read("<!doctype html><title>x</title><p>Коротко.</p>") == nil, "a stub is refused")

        // The shipped model runs, quickly enough to use on a real page.
        let probe = view
        probe.loadHTMLString(page, baseURL: URL(string: "https://example.org/a/b"))
        spin(0.8)
        var rows: [[String: Any]]?, gotRows = false
        probe.callAsyncJavaScript(resources.blocks, arguments: [:], in: nil, in: .page) { result in
            if case let .success(value) = result { rows = value as? [[String: Any]] }
            gotRows = true
        }
        while !gotRows { spin(0.01) }
        let started = Date()
        guard let rows, let scored = ApsaReader.scores(for: rows, modelURL: resources.modelURL), scored.count == rows.count else { fatalError("model must score blocks") }
        print(String(format: "model: %d blocks in %.0f ms", rows.count, Date().timeIntervalSince(started) * 1000))
        let footer = rows.firstIndex { ($0["text"] as? String)?.hasPrefix("Подвал") == true }
        let paragraph = rows.firstIndex { ($0["text"] as? String)?.hasPrefix("Это настоящий абзац") == true }
        print("scores: paragraph", paragraph.map { scored[$0] } ?? -1, "footer", footer.map { scored[$0] } ?? -1)
        precondition(paragraph.map { scored[$0] >= ApsaReader.keepScore } == true, "a real paragraph must be kept")
        precondition(footer.map { scored[$0] < scored[paragraph!] } ?? true, "a footer must score lower")
        var built: String?, gotBuilt = false
        probe.callAsyncJavaScript("return JSON.stringify(globalThis.__apsaReaderBuild(indices));", arguments: ["indices": [paragraph!]], in: nil, in: .page) { result in
            if case let .success(value) = result { built = value as? String }
            gotBuilt = true
        }
        while !gotBuilt { spin(0.01) }
        let fromModel = built.flatMap(ApsaReaderDocument.init(json:))
        precondition(fromModel?.blocks.count == 1)
        if case let .paragraph(runs)? = fromModel?.blocks.first {
            precondition(runs.contains { $0.link?.absoluteString == "https://example.org/link" }, "model output keeps real links")
            precondition(!runs.contains { $0.link?.scheme == "javascript" })
        } else { fatalError("expected a paragraph") }

        // A page that breaks built-ins for itself cannot break extraction.
        precondition(read("<!doctype html><title>Заголовок</title><script>JSON.stringify = () => 'broken'; Array.from = null;</script><article><p>\(body)</p><p>\(body)</p></article>") != nil)

        let items = ApsaReaderPage(document: document) { _ in }.translationItems()
        precondition(items.first?.id == -1 && items.count > 3 && !items.contains { $0.runs.map(\.text).joined().contains("let x") }, "code is not translated")
        let linked = items.first { $0.runs.contains { $0.element != nil } }!
        let elementIndex = linked.runs.first { $0.element != nil }!.element!
        let translated = document.applying([-1: [ApsaTranslationRun(text: "Article title", element: nil)], linked.id: [ApsaTranslationRun(text: "Переведённая ", element: nil), ApsaTranslationRun(text: "ссылка", element: elementIndex)]])
        precondition(translated.title == "Article title")
        if case let .paragraph(runs) = translated.blocks[linked.id] {
            precondition(runs[1].link?.absoluteString == "https://example.org/link", "a translated link goes to the same place")
        } else { fatalError("expected a paragraph") }

        let readerPage = ApsaReaderPage(document: document) { _ in }
        readerPage.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        readerPage.layoutSubtreeIfNeeded()
        precondition(readerPage.textViewCount >= document.blocks.count, "every block is shown")
        readerPage.applyBrowserTheme()
        precondition(readerPage.textViewCount >= document.blocks.count)
        precondition(ApsaReaderPage.tableText([["a", "bb"], ["ccc", "d"]]) == "a    bb\nccc  d")
        print("Reader: article blocks, links, tables, refusals, isolation and page OK")
        exit(0)
    }
}
