import WebKit

// Apsa extensions: a folder with extension.json, scripts and styles. Each one runs in
// its own WebKit content world, so it sees the page's DOM but not the page's
// JavaScript or other extensions. The format is described in EXTENSIONS.md.
struct ApsaExtension: Decodable {
    let format: Int
    let id: String
    let name: String
    let description: String
    let version: String
    let matches: [String]
    var scripts: [String]? = nil
    var styles: [String]? = nil
    var runAt: String? = nil
    var allFrames: Bool? = nil
    var folder = URL(fileURLWithPath: "/")

    private enum CodingKeys: String, CodingKey { case format, id, name, description, version, matches, scripts, styles, runAt, allFrames }
}

enum ApsaExtensions {
    private static let enabledKey = "apsa-browser-extensions"

    static var userFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apsa Browser/Extensions", isDirectory: true)
    }

    // Built-in ones first; a user's extension with the same id replaces the built-in one.
    static func all(in folders: [URL] = [Bundle.main.resourceURL!.appendingPathComponent("extensions"), userFolder]) -> [ApsaExtension] {
        var found: [String: ApsaExtension] = [:]
        for folder in folders {
            let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for item in items.sorted(by: { $0.path < $1.path }) {
                guard let data = try? Data(contentsOf: item.appendingPathComponent("extension.json")),
                      var ext = try? JSONDecoder().decode(ApsaExtension.self, from: data),
                      ext.format == 1, !ext.id.isEmpty, !ext.matches.isEmpty else { continue }
                ext.folder = item
                found[ext.id] = ext
            }
        }
        return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static var enabled: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: enabledKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: enabledKey) }
    }

    static func install(on controller: WKUserContentController) {
        let on = enabled
        for ext in all() where on.contains(ext.id) {
            for script in userScripts(for: ext) { controller.addUserScript(script) }
        }
    }

    static func userScripts(for ext: ApsaExtension) -> [WKUserScript] {
        let world = WKContentWorld.world(name: "apsa-extension:\(ext.id)")
        let frames = !(ext.allFrames ?? false)
        func read(_ names: [String]?) -> String {
            (names ?? []).compactMap { name -> String? in
                let file = ext.folder.appendingPathComponent(name).standardizedFileURL
                guard file.path.hasPrefix(ext.folder.standardizedFileURL.path + "/") else { return nil }
                return try? String(contentsOf: file, encoding: .utf8)
            }.joined(separator: "\n")
        }
        func json(_ value: Any) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), encoding: .utf8)!
        }
        let guardLine = "if (!\(json(ext.matches.map(patternRegex))).some(source => new RegExp(source).test(location.href))) return;"
        var scripts: [WKUserScript] = []
        let css = read(ext.styles)
        if !css.isEmpty {
            let source = "(() => { \(guardLine) const style = document.createElement('style'); style.textContent = \(json(css)); document.documentElement.append(style); })();"
            scripts.append(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: frames, in: world))
        }
        let js = read(ext.scripts)
        if !js.isEmpty {
            let source = "(() => { \(guardLine)\ntry {\n\(js)\n} catch (error) { console.error('\(ext.id)', error); } })();"
            scripts.append(WKUserScript(source: source, injectionTime: ext.runAt == "start" ? .atDocumentStart : .atDocumentEnd, forMainFrameOnly: frames, in: world))
        }
        return scripts
    }

    // "<all_urls>", or scheme://host/path where scheme may be *, host may start
    // with *. (the domain and its subdomains), and * in the path matches anything.
    static func patternRegex(_ pattern: String) -> String {
        if pattern == "<all_urls>" { return "^https?://" }
        let parts = pattern.components(separatedBy: "://")
        guard parts.count == 2 else { return "(?!)" }
        let scheme = parts[0] == "*" ? "https?" : NSRegularExpression.escapedPattern(for: parts[0])
        let slash = parts[1].firstIndex(of: "/") ?? parts[1].endIndex
        var host = String(parts[1][..<slash])
        let path = String(parts[1][slash...])
        var hostRegex = ""
        if host == "*" { hostRegex = "[^/]+" } else {
            if host.hasPrefix("*.") { hostRegex = "(?:[^/]+\\.)?"; host.removeFirst(2) }
            hostRegex += NSRegularExpression.escapedPattern(for: host)
        }
        let pathRegex = path.isEmpty ? "(?:/.*)?" : path.split(separator: "*", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: ".*")
        return "^\(scheme)://\(hostRegex)(?::\\d+)?\(pathRegex)$"
    }
}
