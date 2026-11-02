import AppKit
import CoreML
import ImageIO
import WebKit

struct ApsaReaderRun {
    let text: String
    let link: URL?
    let bold: Bool
    let italic: Bool
    let code: Bool
}

enum ApsaReaderBlock {
    case heading(level: Int, runs: [ApsaReaderRun])
    case paragraph([ApsaReaderRun])
    case listItem(marker: String, depth: Int, runs: [ApsaReaderRun])
    case quote([ApsaReaderRun])
    case code(String)
    case table([[String]])
    case image(URL, alt: String, caption: String)
}

extension ApsaReaderBlock {
    var textRuns: [ApsaReaderRun]? {
        switch self {
        case let .heading(_, runs), let .paragraph(runs), let .listItem(_, _, runs), let .quote(runs): return runs
        case .code, .table, .image: return nil
        }
    }

    func replacing(_ runs: [ApsaReaderRun]) -> ApsaReaderBlock {
        switch self {
        case let .heading(level, _): return .heading(level: level, runs: runs)
        case .paragraph: return .paragraph(runs)
        case let .listItem(marker, depth, _): return .listItem(marker: marker, depth: depth, runs: runs)
        case .quote: return .quote(runs)
        case .code, .table, .image: return self
        }
    }
}

struct ApsaReaderDocument {
    var title: String
    let byline: String
    let site: String
    let url: URL
    var blocks: [ApsaReaderBlock]
    // Size of the original article text, as Readability measured it.
    let sourceLength: Int
    let sourceWords: Int

    init?(json: String) {
        guard let data = json.data(using: .utf8), data.count <= 16 * 1_024 * 1_024,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let address = root["url"] as? String, let url = URL(string: address),
              let items = root["blocks"] as? [[String: Any]] else { return nil }
        func runs(_ value: Any?) -> [ApsaReaderRun] {
            (value as? [[String: Any]] ?? []).compactMap { run in
                guard let text = run["t"] as? String else { return nil }
                let link = (run["h"] as? String).flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
                return ApsaReaderRun(text: text, link: link, bold: run["b"] != nil, italic: run["i"] != nil, code: run["c"] != nil)
            }
        }
        title = root["title"] as? String ?? ""
        byline = root["byline"] as? String ?? ""
        site = root["site"] as? String ?? ""
        self.url = url
        sourceLength = root["length"] as? Int ?? 0
        sourceWords = root["words"] as? Int ?? 0
        blocks = items.compactMap { item in
            switch item["k"] as? String {
            case "h": return .heading(level: max(1, min(6, item["l"] as? Int ?? 2)), runs: runs(item["runs"]))
            case "p": return .paragraph(runs(item["runs"]))
            case "li": return .listItem(marker: item["n"] as? String ?? "•", depth: min(6, item["d"] as? Int ?? 0), runs: runs(item["runs"]))
            case "q": return .quote(runs(item["runs"]))
            case "pre": return .code(item["t"] as? String ?? "")
            case "table": return .table(item["rows"] as? [[String]] ?? [])
            case "img":
                guard let source = (item["src"] as? String).flatMap(URL.init(string:)), ["http", "https"].contains(source.scheme?.lowercased() ?? "") else { return nil }
                return .image(source, alt: item["alt"] as? String ?? "", caption: item["cap"] as? String ?? "")
            default: return nil
            }
        }
    }
}

extension ApsaReaderDocument {
    // Translated text in place of the original. A run keeps the link of the run it came
    // from, and blocks without a result stay as they were.
    func applying(_ results: [Int: [ApsaTranslationRun]]) -> ApsaReaderDocument {
        var copy = self
        if let title = results[-1] { copy.title = ApsaTranslationText.plain(title) }
        for (index, block) in blocks.enumerated() {
            guard let translated = results[index], let source = block.textRuns else { continue }
            copy.blocks[index] = block.replacing(translated.map { run in
                let origin = run.element.flatMap { source.indices.contains($0) ? source[$0] : nil }
                return ApsaReaderRun(text: run.text, link: origin?.link, bold: origin?.bold ?? false, italic: origin?.italic ?? false, code: origin?.code ?? false)
            })
        }
        return copy
    }
}

struct ApsaReaderResources {
    let article: String
    let blocks: String
    let modelURL: URL?

    init?(bundle: Bundle = .main) {
        guard let library = bundle.url(forResource: "Readability", withExtension: "js", subdirectory: "reader") else { return nil }
        self.init(folder: library.deletingLastPathComponent(), modelFolder: bundle.url(forResource: "ReaderBlocks", withExtension: "mlmodelc", subdirectory: "reader"))
    }

    init?(folder: URL, modelFolder: URL?) {
        guard let library = try? String(contentsOf: folder.appendingPathComponent("Readability.js"), encoding: .utf8),
              let article = try? String(contentsOf: folder.appendingPathComponent("article.js"), encoding: .utf8),
              let extract = try? String(contentsOf: folder.appendingPathComponent("extract.js"), encoding: .utf8) else { return nil }
        self.article = library + "\n" + article
        self.blocks = "return (\n" + extract + "\n);"
        self.modelURL = modelFolder
    }
}

enum ApsaReader {
    private static let world = WKContentWorld.world(name: "apsa-reader")
    // Thresholds chosen in native/browser/reader-lab on sites the model had not seen.
    static let keepScore = 0.7
    static let switchRatio = 1.5
    static let minimumWords = 40
    static let fallbackLength = 1_500
    static let minimumModelLength = 180

    enum Choice: Equatable { case readability, model, refuse }

    // Readability is the more precise of the two. The model takes over only where
    // Readability lost most of what the model is sure about, as on forums, and a page
    // that both find weak is refused rather than shown in fragments.
    static func choose(modelWords: Int, modelLength: Int, readabilityWords: Int, readabilityLength: Int) -> Choice {
        let modelUsable = modelWords >= minimumWords && modelLength >= minimumModelLength
        if !modelUsable { return readabilityLength >= fallbackLength ? .readability : .refuse }
        if readabilityWords < minimumWords || Double(modelWords) >= switchRatio * Double(readabilityWords) { return .model }
        return .readability
    }

    private static var loadedModel: MLModel?
    private static func model(at url: URL?) -> MLModel? {
        if let loadedModel { return loadedModel }
        guard let url else { return nil }
        loadedModel = try? MLModel(contentsOf: url)
        return loadedModel
    }

    static func scores(for blocks: [[String: Any]], modelURL: URL?) -> [Double]? {
        guard let model = model(at: modelURL), !blocks.isEmpty else { return nil }
        let providers = blocks.compactMap { block -> MLFeatureProvider? in
            guard let features = block["features"] as? [String: NSNumber] else { return nil }
            return try? MLDictionaryFeatureProvider(dictionary: features.mapValues { $0.doubleValue })
        }
        guard providers.count == blocks.count, let output = try? model.predictions(fromBatch: MLArrayBatchProvider(array: providers)) else { return nil }
        return (0..<output.count).map { index in
            let probabilities = output.features(at: index).featureValue(for: "labelProbability")?.dictionaryValue as? [Int64: NSNumber]
            return probabilities?[1]?.doubleValue ?? 0
        }
    }

    // Each step runs in its own content world, so the page's scripts cannot interfere,
    // and a page that redefines built-ins cannot break extraction.
    static func extract(from view: WKWebView, resources: ApsaReaderResources, completion: @escaping (ApsaReaderDocument?) -> Void) {
        view.callAsyncJavaScript(resources.article, arguments: [:], in: nil, in: world) { result in
            var readable: ApsaReaderDocument?
            if case let .success(value) = result, let json = value as? String, !json.isEmpty { readable = ApsaReaderDocument(json: json) }
            view.callAsyncJavaScript(resources.blocks, arguments: [:], in: nil, in: world) { blockResult in
                guard case let .success(value) = blockResult, let blocks = value as? [[String: Any]] else { completion(readable); return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let scored = scores(for: blocks, modelURL: resources.modelURL)
                    DispatchQueue.main.async {
                        guard let scored else { completion(readable); return }
                        var kept: [Int] = [], words = 0, length = 0
                        for (index, block) in blocks.enumerated() where scored[index] >= keepScore {
                            kept.append(index)
                            guard block["kind"] as? String != "image", let text = block["text"] as? String else { continue }
                            words += text.split(separator: " ").count
                            length += text.count + 1
                        }
                        switch choose(modelWords: words, modelLength: length, readabilityWords: readable?.sourceWords ?? 0, readabilityLength: readable?.sourceLength ?? 0) {
                        case .refuse: completion(nil)
                        case .readability: completion(readable)
                        case .model:
                            view.callAsyncJavaScript("return JSON.stringify(globalThis.__apsaReaderBuild(indices));", arguments: ["indices": kept], in: nil, in: world) { built in
                                if case let .success(value) = built, let json = value as? String, let document = ApsaReaderDocument(json: json) { completion(document) }
                                else { completion(readable) }
                            }
                        }
                    }
                }
            }
        }
    }
}

private final class ReaderCanvas: NSView {
    override var isFlipped: Bool { true }
}

// The reading page. Native text, so selection, find and themes work as everywhere else.
final class ApsaReaderPage: NSView {
    private static let columnWidth: CGFloat = 720
    private static let maximumImages = 40
    private static let imageSession: URLSession = {
        // Images load without cookies, so they cannot identify the reader to the site.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    private var document: ApsaReaderDocument
    private let original: ApsaReaderDocument
    private let navigate: (URL) -> Void
    private let pageSelection = ApsaPageSelection()
    private let scroll = NSScrollView()
    private let canvas = ReaderCanvas()
    private var stack: NSStackView?
    private var constraintsInUse: [NSLayoutConstraint] = []
    private var tasks: [URLSessionDataTask] = []

    init(document: ApsaReaderDocument, navigate: @escaping (URL) -> Void) {
        self.document = document
        self.original = document
        self.navigate = navigate
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = canvas
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            canvas.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        render()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { tasks.forEach { $0.cancel() } }

    var textViewCount: Int { stack?.arrangedSubviews.count ?? 0 }
    var isTranslated = false

    // Every text block with its plain text, for the translator.
    func translationItems() -> [ApsaTranslationItem] {
        var items = [ApsaTranslationItem(id: -1, runs: [ApsaTranslationRun(text: original.title, element: nil)])]
        for (index, block) in original.blocks.enumerated() {
            guard let runs = block.textRuns else { continue }
            items.append(ApsaTranslationItem(id: index, runs: runs.enumerated().map { ApsaTranslationRun(text: $1.text, element: $1.link == nil ? nil : $0) }))
        }
        return items
    }

    func showTranslation(_ results: [Int: [ApsaTranslationRun]]) {
        document = original.applying(results)
        isTranslated = true
        render()
    }

    func showOriginal() {
        document = original
        isTranslated = false
        render()
    }

    var sampleText: String {
        original.blocks.compactMap { $0.textRuns?.map(\.text).joined() }.joined(separator: " ")
    }
    func applyBrowserTheme() { render() }

    override var acceptsFirstResponder: Bool { true }
    override func selectAll(_ sender: Any?) {
        window?.makeFirstResponder(self)
        pageSelection.selectAll()
    }
    @objc func copy(_ sender: Any?) { pageSelection.copy(to: .general) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    private func render() {
        tasks.forEach { $0.cancel() }
        tasks = []
        NSLayoutConstraint.deactivate(constraintsInUse)
        stack?.removeFromSuperview()
        let palette = ApsaThemeStore.shared.selected.palette
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(column)
        stack = column
        let wide = column.widthAnchor.constraint(equalToConstant: Self.columnWidth)
        wide.priority = .defaultHigh
        constraintsInUse = [
            column.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 44),
            column.bottomAnchor.constraint(equalTo: canvas.bottomAnchor, constant: -64),
            column.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: canvas.leadingAnchor, constant: 28),
            column.trailingAnchor.constraint(lessThanOrEqualTo: canvas.trailingAnchor, constant: -28),
            wide
        ]
        NSLayoutConstraint.activate(constraintsInUse)

        append(text(plain: document.title, size: 34, weight: .bold, color: palette.text), to: column)
        let source = [document.byline, document.site.isEmpty ? document.url.host ?? "" : document.site].filter { !$0.isEmpty }.joined(separator: " · ")
        if !source.isEmpty { append(text(plain: source, size: 13, weight: .regular, color: palette.secondary), to: column) }
        column.setCustomSpacing(26, after: column.arrangedSubviews[column.arrangedSubviews.count - 1])

        var images = 0
        for block in document.blocks {
            switch block {
            case let .heading(level, runs):
                let sizes: [CGFloat] = [28, 24, 21, 19, 17, 16]
                if let last = column.arrangedSubviews.last { column.setCustomSpacing(26, after: last) }
                append(text(runs: runs, size: sizes[level - 1], weight: .bold, color: palette.text, palette: palette), to: column)
            case let .paragraph(runs):
                append(text(runs: runs, size: 17, weight: .regular, color: palette.text, palette: palette), to: column)
            case let .listItem(marker, depth, runs):
                var all = [ApsaReaderRun(text: marker + "  ", link: nil, bold: false, italic: false, code: false)]
                all += runs
                append(text(runs: all, size: 17, weight: .regular, color: palette.text, palette: palette), to: column, indent: 18 * CGFloat(depth + 1))
            case let .quote(runs):
                append(text(runs: runs, size: 17, weight: .regular, color: palette.secondary, palette: palette), to: column, indent: 22)
            case let .code(value):
                append(preformatted(value, palette: palette), to: column)
            case let .table(rows):
                append(preformatted(Self.tableText(rows), palette: palette), to: column)
            case let .image(url, alt, caption):
                guard images < Self.maximumImages else { continue }
                images += 1
                addImage(url, alt: alt, caption: caption, palette: palette, to: column)
            }
        }
        pageSelection.attach(to: canvas)
    }

    // Columns line up in a monospaced font, which keeps tables readable without a grid.
    static func tableText(_ rows: [[String]]) -> String {
        let columns = rows.map(\.count).max() ?? 0
        var widths = [Int](repeating: 0, count: columns)
        for row in rows { for (index, cell) in row.enumerated() { widths[index] = max(widths[index], min(40, cell.count)) } }
        return rows.map { row in
            row.enumerated().map { index, cell in
                let clipped = cell.count > 40 ? String(cell.prefix(39)) + "…" : cell
                return clipped.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    private func append(_ view: NSView, to column: NSStackView, indent: CGFloat = 0) {
        guard indent > 0 else {
            column.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            return
        }
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: wrapper.topAnchor), view.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: indent), view.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor)
        ])
        column.addArrangedSubview(wrapper)
        wrapper.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    private func paragraphStyle(size: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = size >= 20 ? 3 : 6
        return style
    }

    private func field(_ attributed: NSAttributedString, palette: ApsaPalette) -> ApsaSelectableTextView {
        let view = ApsaSelectableTextView(attributed)
        view.onOpenLink = { [weak self] in self?.navigate($0) }
        view.maximumNumberOfLines = 0
        view.lineBreakMode = .byWordWrapping
        view.linkTextAttributes = [.foregroundColor: palette.accent, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    private func text(plain: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> ApsaSelectableTextView {
        field(NSAttributedString(string: plain, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraphStyle(size: size)]), palette: ApsaThemeStore.shared.selected.palette)
    }

    private func text(runs: [ApsaReaderRun], size: CGFloat, weight: NSFont.Weight, color: NSColor, palette: ApsaPalette) -> ApsaSelectableTextView {
        let result = NSMutableAttributedString()
        let style = paragraphStyle(size: size)
        for (index, run) in runs.enumerated() {
            var font = run.code ? NSFont.monospacedSystemFont(ofSize: size - 1, weight: weight) : NSFont.systemFont(ofSize: size, weight: run.bold ? .bold : weight)
            if run.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
            if let link = run.link { attributes[.link] = link }
            let value = index == 0 ? String(run.text.drop { $0 == " " }) : run.text
            result.append(NSAttributedString(string: value, attributes: attributes))
        }
        return field(result, palette: palette)
    }

    private func preformatted(_ value: String, palette: ApsaPalette) -> NSView {
        let view = field(NSAttributedString(string: value, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: palette.text]), palette: palette)
        view.textContainerInset = NSSize(width: 12, height: 10)
        view.drawsBackground = true
        view.backgroundColor = palette.surface
        return view
    }

    private func addImage(_ url: URL, alt: String, caption: String, palette: ApsaPalette, to column: NSStackView) {
        let picture = NSImageView()
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.translatesAutoresizingMaskIntoConstraints = false
        picture.isHidden = true
        picture.setAccessibilityLabel(alt.isEmpty ? caption : alt)
        column.addArrangedSubview(picture)
        picture.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        if !caption.isEmpty { append(text(plain: caption, size: 13, weight: .regular, color: palette.secondary), to: column) }
        let task = Self.imageSession.dataTask(with: url) { [weak picture] data, _, _ in
            guard let data, data.count <= 16 * 1_024 * 1_024, let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1_600, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return }
            DispatchQueue.main.async {
                guard let picture else { return }
                picture.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                picture.heightAnchor.constraint(equalTo: picture.widthAnchor, multiplier: CGFloat(image.height) / CGFloat(max(1, image.width))).isActive = true
                picture.isHidden = false
            }
        }
        tasks.append(task)
        task.resume()
    }
}
