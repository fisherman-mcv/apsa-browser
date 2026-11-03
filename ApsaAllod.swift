import CryptoKit
import Foundation
import Network
import WebKit

// Opens allod:// pages: one TLS request line, a status line back, then the body.
// Certificates are trusted on first use and refused if they change later.
enum ApsaAllod {
    static let scheme = "allod"
    static let defaultPort: UInt16 = 7171
    static let knownHostsKey = "apsa-browser-allod-known-hosts"

    struct Response {
        var url: URL
        var status: Int
        var meta: String
        var body: Data
    }

    enum Failure: LocalizedError {
        case certificateChanged(String), badResponse, tooManyRedirects
        var errorDescription: String? {
            switch self {
            case .certificateChanged(let host): return apsaText("The certificate for %@ has changed since your last visit.", host)
            case .badResponse: return apsaText("The server sent a response this browser cannot read.")
            case .tooManyRedirects: return apsaText("The page redirected too many times.")
            }
        }
    }

    static func fetch(_ url: URL, redirects: Int = 5, defaults: UserDefaults = .standard, completion: @escaping (Result<Response, Error>) -> Void) {
        guard let host = url.host, redirects >= 0 else { return completion(.failure(Failure.tooManyRedirects)) }
        let port = UInt16(url.port ?? Int(defaultPort))
        let hostKey = "\(host):\(port)"
        let tlsOptions = NWProtocolTLS.Options()
        var changed = false
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, trust, verify in
            let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
            guard let certificate = chain?.first else { return verify(false) }
            let fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02X", $0) }.joined(separator: ":")
            var known = defaults.dictionary(forKey: knownHostsKey) as? [String: String] ?? [:]
            if let saved = known[hostKey], saved != fingerprint { changed = true; return verify(false) }
            if known[hostKey] == nil { known[hostKey] = fingerprint; defaults.set(known, forKey: knownHostsKey) }
            verify(true)
        }, .global())

        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: tlsOptions))
        var received = Data()
        var finished = false
        func finish(_ result: Result<Response, Error>) {
            guard !finished else { return }
            finished = true
            connection.cancel()
            if case .success(let response) = result, response.status == 31 {
                guard let next = URL(string: response.meta, relativeTo: url)?.absoluteURL else { return completion(.failure(Failure.badResponse)) }
                return fetch(next, redirects: redirects - 1, defaults: defaults, completion: completion)
            }
            completion(result)
        }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data { received.append(data) }
                if let error, received.isEmpty { return finish(.failure(error)) }
                if isComplete || error != nil { return finish(parse(received, url: url)) }
                receive()
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data((url.absoluteString + "\r\n").utf8), completion: .contentProcessed { _ in })
                receive()
            case .failed(let error), .waiting(let error):
                finish(.failure(changed ? Failure.certificateChanged(hostKey) : error))
            default: break
            }
        }
        connection.start(queue: .global())
    }

    static func parse(_ data: Data, url: URL) -> Result<Response, Error> {
        guard let end = data.range(of: Data("\r\n".utf8)),
              let header = String(data: data[..<end.lowerBound], encoding: .utf8),
              let status = Int(header.prefix(2)) else { return .failure(Failure.badResponse) }
        let meta = header.count > 3 ? String(header.dropFirst(3)) : ""
        return .success(Response(url: url, status: status, meta: meta, body: Data(data[end.upperBound...])))
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // Turns a text/allod page into HTML. The page decides only structure;
    // the look comes from here.
    static func html(page source: String, url: URL) -> String {
        var body = ""
        var pre = false
        var list = false
        for line in source.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let isItem = !pre && line.hasPrefix("* ")
            if list, !isItem { body += "</ul>"; list = false }
            if line.hasPrefix("```") {
                body += pre ? "</pre>" : "<pre>"
                pre.toggle()
                continue
            }
            if pre { body += escape(line) + "\n"; continue }
            if isItem, !list { body += "<ul>"; list = true }
            if let level = ["### ", "## ", "# "].firstIndex(where: { line.hasPrefix($0) }).map({ 3 - $0 }) {
                body += "<h\(level)>\(escape(String(line.dropFirst(level + 1))))</h\(level)>"
            } else if line.hasPrefix("=>") {
                let parts = line.dropFirst(2).trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard let target = parts.first else { continue }
                let label = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : String(target)
                body += "<p class=\"link\"><a href=\"\(escape(String(target)))\">\(escape(label))</a></p>"
            } else if isItem {
                body += "<li>\(escape(String(line.dropFirst(2))))</li>"
            } else if line.hasPrefix(">") {
                body += "<blockquote>\(escape(line.dropFirst().trimmingCharacters(in: .whitespaces)))</blockquote>"
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                body += "<p>\(escape(line))</p>"
            }
        }
        if pre { body += "</pre>" }
        if list { body += "</ul>" }
        let title = source.components(separatedBy: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? url.host ?? ""
        return document(title: title, url: url, body: body)
    }

    static func errorPage(_ message: String, url: URL) -> String {
        document(title: apsaText("Page not available"), url: url, body: "<h1>\(escape(apsaText("Page not available")))</h1><p>\(escape(message))</p>")
    }

    private static func document(title: String, url: URL, body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><base href="\(escape(url.absoluteString))">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src allod:">
        <title>\(escape(title))</title><style>
        :root { color-scheme: light dark; }
        body { font: 17px/1.6 -apple-system, system-ui, sans-serif; max-width: 42rem; margin: 3rem auto; padding: 0 1.25rem; }
        h1, h2, h3 { line-height: 1.25; margin: 1.6em 0 .5em; }
        h1 { margin-top: 0; }
        p { margin: .5em 0; }
        p.link { margin: .25em 0; }
        a { color: LinkText; }
        blockquote { margin: 1em 0; padding-left: 1em; border-left: 3px solid color-mix(in srgb, CanvasText 25%, transparent); }
        pre { font: 14px/1.45 ui-monospace, Menlo, monospace; overflow-x: auto; padding: .8em 1em; border-radius: 8px; background: color-mix(in srgb, CanvasText 6%, transparent); }
        </style></head><body>\(body)</body></html>
        """
    }
}

final class ApsaAllodSchemeHandler: NSObject, WKURLSchemeHandler {
    private var stopped = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let id = ObjectIdentifier(task)
        ApsaAllod.fetch(url) { result in
            DispatchQueue.main.async {
                guard self.stopped.remove(id) == nil else { return }
                var type = "text/html"
                var data: Data
                var pageURL = url
                switch result {
                case .success(let response) where response.status == 20:
                    pageURL = response.url
                    let mediaType = response.meta.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    if mediaType == "text/allod" {
                        data = Data(ApsaAllod.html(page: String(decoding: response.body, as: UTF8.self), url: pageURL).utf8)
                    } else if mediaType.hasPrefix("image/") {
                        type = mediaType
                        data = response.body
                    } else {
                        type = "text/plain"
                        data = response.body
                    }
                case .success(let response):
                    data = Data(ApsaAllod.errorPage("\(response.status) \(response.meta)", url: url).utf8)
                case .failure(let error):
                    data = Data(ApsaAllod.errorPage(error.localizedDescription, url: url).utf8)
                }
                task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: "utf-8"))
                task.didReceive(data)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }
}
