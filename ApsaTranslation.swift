import AppKit
import NaturalLanguage
import SwiftUI
import Translation
import WebKit

// Everything is translated on this Mac by the system. No text leaves the browser.
struct ApsaTranslationRun: Equatable {
    var text: String
    // Which of the block's own inline elements this text belongs to, if any.
    var element: Int?
}

enum ApsaTranslationText {
    private static let scheme = "apsa-run"
    static let targetKey = "apsa-browser-translate-target"

    // The translator keeps a link attribute on the words it belongs to, which lets
    // reordered sentences still end up inside the right element.
    static func attributed(_ runs: [ApsaTranslationRun]) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var part = AttributedString(run.text)
            if let element = run.element { part.link = URL(string: "\(scheme)://\(element)") }
            result.append(part)
        }
        return result
    }

    static func runs(from text: AttributedString) -> [ApsaTranslationRun] {
        var result: [ApsaTranslationRun] = []
        for run in text.runs {
            let value = String(text[run.range].characters)
            let element = run.link.flatMap { $0.scheme == scheme ? $0.host.flatMap(Int.init) : nil }
            if let last = result.last, last.element == element { result[result.count - 1].text += value }
            else { result.append(ApsaTranslationRun(text: value, element: element)) }
        }
        return result
    }

    static func plain(_ runs: [ApsaTranslationRun]) -> String { runs.map(\.text).joined() }

    static func detectLanguage(_ sample: String, declared: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(sample.prefix(4_000)))
        if let found = recognizer.languageHypotheses(withMaximum: 1).first, found.value >= 0.6 { return found.key.rawValue.split(separator: "-").first.map(String.init) }
        return declared.split(separator: "-").first.map { $0.lowercased() }
    }

    static var target: String {
        get { UserDefaults.standard.string(forKey: targetKey) ?? ApsaLanguage.systemLanguage?.split(separator: "-").first.map(String.init) ?? "en" }
        set { UserDefaults.standard.set(newValue, forKey: targetKey) }
    }

    static let targets: [(code: String, name: String)] = [
        ("ru", "Русский"), ("en", "English"), ("uk", "Українська"), ("de", "Deutsch"), ("fr", "Français"), ("es", "Español"), ("it", "Italiano"),
        ("pt", "Português"), ("pl", "Polski"), ("tr", "Türkçe"), ("zh", "中文"), ("ja", "日本語"), ("ko", "한국어"), ("ar", "العربية")
    ]
}

struct ApsaTranslationItem {
    let id: Int
    let runs: [ApsaTranslationRun]
}

@available(macOS 15.0, *)
final class ApsaTranslationEngine: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    private var waiting: [(items: [ApsaTranslationItem], done: ([Int: [ApsaTranslationRun]]) -> Void)] = []
    private var draining = false
    var onFailure: (Error) -> Void = { _ in }

    func start(source: String?, target: String) {
        waiting = []
        configuration = TranslationSession.Configuration(source: source.map { Locale.Language(identifier: $0) }, target: Locale.Language(identifier: target))
    }

    func stop() {
        waiting = []
        configuration = nil
    }

    func translate(_ items: [ApsaTranslationItem], done: @escaping ([Int: [ApsaTranslationRun]]) -> Void) {
        waiting.append((items, done))
        guard !draining else { return }
        configuration?.invalidate()
    }

    // SwiftUI hands out the session here, and it must not outlive this call. The system
    // shows its own download prompt when the language pair is not installed yet.
    @MainActor
    func drain(_ session: TranslationSession) async {
        draining = true
        defer { draining = false }
        do {
            try await session.prepareTranslation()
            while !waiting.isEmpty {
                let job = waiting.removeFirst()
                let requests = job.items.map { item -> TranslationSession.Request in
                    if #available(macOS 26.4, *) { return TranslationSession.Request(sourceText: ApsaTranslationText.attributed(item.runs), clientIdentifier: String(item.id)) }
                    return TranslationSession.Request(sourceText: ApsaTranslationText.plain(item.runs), clientIdentifier: String(item.id))
                }
                var results: [Int: [ApsaTranslationRun]] = [:]
                for response in try await session.translations(from: requests) {
                    guard let id = response.clientIdentifier.flatMap(Int.init) else { continue }
                    if #available(macOS 26.4, *), let attributed = response.attributedTargetText { results[id] = ApsaTranslationText.runs(from: attributed) }
                    else { results[id] = [ApsaTranslationRun(text: response.targetText, element: nil)] }
                }
                job.done(results)
            }
        } catch {
            waiting = []
            onFailure(error)
        }
    }
}

@available(macOS 15.0, *)
private struct ApsaTranslationHost: View {
    @ObservedObject var engine: ApsaTranslationEngine
    var body: some View {
        Color.clear.frame(width: 1, height: 1).translationTask(engine.configuration) { session in
            await engine.drain(session)
        }
    }
}

// Connects one page to the engine. The hosting view is created on first use, so a
// browser that never translates carries none of this.
@available(macOS 15.0, *)
final class ApsaPageTranslator: NSObject, WKScriptMessageHandler {
    static let world = WKContentWorld.world(name: "apsa-translate")
    static let handlerName = "apsaTranslate"
    let engine = ApsaTranslationEngine()
    private(set) lazy var hostView: NSView = NSHostingView(rootView: ApsaTranslationHost(engine: engine))
    private var translating: WKWebView?
    private let script: String

    init?(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "translate", withExtension: "js", subdirectory: "translate"),
              let script = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        self.script = script
    }

    func install(on configuration: WKWebViewConfiguration) {
        configuration.userContentController.add(self, contentWorld: Self.world, name: Self.handlerName)
    }

    var isTranslating: Bool { translating != nil }
    func isTranslating(_ view: WKWebView) -> Bool { translating === view }

    func start(in view: WKWebView, alreadyInLanguage: @escaping () -> Void) {
        stop()
        translating = view
        view.callAsyncJavaScript(script + "\nreturn globalThis.apsaTranslate.start();", arguments: [:], in: nil, in: Self.world) { [weak self, weak view] result in
            guard let self, let view, self.translating === view, case let .success(value) = result, let page = value as? [String: Any] else { return }
            let target = ApsaTranslationText.target
            let source = ApsaTranslationText.detectLanguage(page["sample"] as? String ?? "", declared: page["lang"] as? String ?? "")
            if source == target {
                self.stop(in: view)
                alreadyInLanguage()
                return
            }
            self.engine.start(source: source, target: target)
        }
    }

    func stop(in view: WKWebView? = nil) {
        if let view, translating !== view { return }
        translating?.callAsyncJavaScript("return globalThis.apsaTranslate?.stop();", arguments: [:], in: nil, in: Self.world, completionHandler: nil)
        translating = nil
        engine.stop()
    }

    func forget(_ view: WKWebView) {
        if translating === view {
            translating = nil
            engine.stop()
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let view = message.webView, view === translating,
              let body = message.body as? [String: Any], body["event"] as? String == "blocks", let raw = body["items"] as? [[String: Any]] else { return }
        let items = raw.compactMap { item -> ApsaTranslationItem? in
            guard let id = item["id"] as? Int, let runs = item["runs"] as? [[String: Any]] else { return nil }
            return ApsaTranslationItem(id: id, runs: runs.compactMap { run in (run["t"] as? String).map { ApsaTranslationRun(text: $0, element: run["e"] as? Int) } })
        }
        engine.translate(items) { [weak self, weak view] results in
            guard let self, let view, self.translating === view else { return }
            for (id, runs) in results {
                let values = runs.map { run -> [String: Any] in
                    var value: [String: Any] = ["t": run.text]
                    if let element = run.element { value["e"] = element }
                    return value
                }
                view.callAsyncJavaScript("return globalThis.apsaTranslate?.apply(id, runs);", arguments: ["id": id, "runs": values], in: nil, in: Self.world, completionHandler: nil)
            }
        }
    }
}
