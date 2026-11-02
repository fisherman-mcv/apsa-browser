import Foundation
import Network
import WebKit

enum ApsaPrivacyLevel: String, Codable, CaseIterable {
    case standard, strict, maximum, custom
}

struct ApsaPrivacySettings: Codable, Equatable {
    var level = ApsaPrivacyLevel.standard
    var blockThirdPartyCookies = true
    var stripTrackingParameters = true
    var sendGlobalPrivacyControl = true
    var fraudWarnings = true
    var keepHistory = true
    var httpsOnly = false
    var resistFingerprinting = false
    var blockWebRTC = false
    var denyCameraAndMicrophone = false
    var clearDataOnQuit = false
    var blockThirdPartyScripts = false
    var blockThirdPartyFrames = false
    var blockThirdPartyFonts = false
    var disableWebGL = false
    var disableWebAssembly = false
    var disableServiceWorkers = false
    var disableJavaScript = false
    var proxyHost = ""
    var proxyPort = 0
    var keepDataSites: [String] = []

    static func preset(_ level: ApsaPrivacyLevel, from current: ApsaPrivacySettings = ApsaPrivacySettings()) -> ApsaPrivacySettings {
        // Choices that are not about strictness stay as the person set them.
        var result = ApsaPrivacySettings()
        result.proxyHost = current.proxyHost
        result.proxyPort = current.proxyPort
        result.keepDataSites = current.keepDataSites
        result.level = level
        guard level == .strict || level == .maximum else { return result }
        result.keepHistory = false
        result.httpsOnly = true
        result.resistFingerprinting = true
        result.blockWebRTC = true
        result.denyCameraAndMicrophone = true
        result.clearDataOnQuit = true
        guard level == .maximum else { return result }
        result.fraudWarnings = false
        result.blockThirdPartyScripts = true
        result.blockThirdPartyFrames = true
        result.blockThirdPartyFonts = true
        result.disableWebGL = true
        result.disableWebAssembly = true
        result.disableServiceWorkers = true
        return result
    }

    var usesScript: Bool { sendGlobalPrivacyControl || resistFingerprinting || blockWebRTC || disableWebGL || disableWebAssembly || disableServiceWorkers }

    func keepsData(for host: String) -> Bool {
        let lower = host.lowercased()
        return keepDataSites.contains { site in
            let key = site.trimmingCharacters(in: .whitespaces).lowercased()
            return !key.isEmpty && (lower == key || lower.hasSuffix("." + key))
        }
    }
}

enum ApsaPrivacy {
    private static let localHosts = ["localhost", "127.0.0.1", "::1"]
    private static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "mc_cid", "mc_eid", "yclid", "_hsenc", "_hsmi", "igshid", "twclid", "ttclid", "li_fat_id", "vero_id", "oly_enc_id", "oly_anon_id", "_openstat"
    ]

    static func cleaned(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = parts.queryItems, !items.isEmpty else { return nil }
        let kept = items.filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !trackingParameters.contains(name)
        }
        guard kept.count != items.count else { return nil }
        parts.queryItems = kept.isEmpty ? nil : kept
        return parts.url
    }

    static func httpsVersion(of url: URL) -> URL? {
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased(), !localHosts.contains(host), !host.hasSuffix(".localhost"),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "https"
        if parts.port == 80 { parts.port = nil }
        return parts.url
    }

    static func ruleListJSON(_ settings: ApsaPrivacySettings) -> String? {
        var rules: [[String: Any]] = []
        func rule(_ trigger: [String: Any], _ type: String) { rules.append(["trigger": trigger, "action": ["type": type]]) }
        if settings.blockThirdPartyCookies { rule(["url-filter": ".*", "load-type": ["third-party"]], "block-cookies") }
        if settings.blockThirdPartyScripts { rule(["url-filter": ".*", "load-type": ["third-party"], "resource-type": ["script"]], "block") }
        if settings.blockThirdPartyFonts { rule(["url-filter": ".*", "load-type": ["third-party"], "resource-type": ["font"]], "block") }
        if settings.blockThirdPartyFrames { rule(["url-filter": ".*", "load-type": ["third-party"], "resource-type": ["document"], "load-context": ["child-frame"]], "block") }
        if settings.httpsOnly { rule(["url-filter": "^http://", "unless-domain": localHosts.filter { $0 != "::1" }.map { "*\($0)" }], "make-https") }
        guard !rules.isEmpty, let data = try? JSONSerialization.data(withJSONObject: rules) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // Each launch gets its own seed, and each site derives its own noise from it, so a
    // site sees stable values within a session and nothing that links it to another site.
    static func script(_ settings: ApsaPrivacySettings, seed: UInt32) -> String {
        var parts = ["const seedBase = \(seed);", #"""
        const define = (object, name, value) => { try { Object.defineProperty(object, name, { get: () => value, configurable: true }); } catch (_) {} };
        let hash = seedBase;
        for (const char of location.hostname) hash = Math.imul(hash ^ char.charCodeAt(0), 16777619) >>> 0;
        const noise = index => { let x = Math.imul(hash + index, 2654435761) >>> 0; x ^= x >>> 15; return x; };
        """#]
        if settings.sendGlobalPrivacyControl { parts.append("define(Navigator.prototype, 'globalPrivacyControl', true);") }
        if settings.blockWebRTC {
            parts.append(#"""
            for (const name of ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCDataChannel', 'RTCSessionDescription', 'RTCIceCandidate']) { try { delete globalThis[name]; globalThis[name] = undefined; } catch (_) {} }
            """#)
        }
        if settings.disableWebAssembly { parts.append("try { delete globalThis.WebAssembly; globalThis.WebAssembly = undefined; } catch (_) {}") }
        if settings.disableServiceWorkers { parts.append("define(Navigator.prototype, 'serviceWorker', undefined);") }
        if settings.disableWebGL {
            parts.append(#"""
            const originalContext = HTMLCanvasElement.prototype.getContext;
            HTMLCanvasElement.prototype.getContext = function (type, ...rest) { return /webgl/i.test(String(type)) ? null : originalContext.call(this, type, ...rest); };
            """#)
        }
        if settings.resistFingerprinting {
            parts.append(#"""
            // Values shared by a large group of Macs, in place of this machine's own.
            define(Navigator.prototype, 'hardwareConcurrency', 8);
            define(Navigator.prototype, 'maxTouchPoints', 0);
            define(Navigator.prototype, 'plugins', []);
            define(Navigator.prototype, 'mimeTypes', []);
            define(Screen.prototype, 'width', 1920);
            define(Screen.prototype, 'height', 1080);
            define(Screen.prototype, 'availWidth', 1920);
            define(Screen.prototype, 'availHeight', 1080);
            define(Screen.prototype, 'colorDepth', 24);
            define(Screen.prototype, 'pixelDepth', 24);
            define(globalThis, 'devicePixelRatio', 2);
            define(globalThis, 'screenX', 0);
            define(globalThis, 'screenY', 0);

            // Rounded clocks make timing attacks and hardware measurement harder.
            const originalNow = Performance.prototype.now;
            Performance.prototype.now = function () { return Math.round(originalNow.call(this) / 16.67) * 16.67; };

            // A tiny change per site: invisible, and a canvas hash no longer identifies the machine.
            const perturb = data => { for (let i = 0; i < data.length; i += 4 * 97) data[i] = data[i] ^ (noise(i) & 1); return data; };
            const originalGetImageData = CanvasRenderingContext2D.prototype.getImageData;
            CanvasRenderingContext2D.prototype.getImageData = function (...args) { const image = originalGetImageData.apply(this, args); perturb(image.data); return image; };
            const exporting = (name, original) => function (...args) {
              if (this.width > 0 && this.height > 0) {
                const copy = document.createElement('canvas');
                copy.width = this.width; copy.height = this.height;
                const context = copy.getContext('2d');
                if (context) {
                  context.drawImage(this, 0, 0);
                  const image = originalGetImageData.call(context, 0, 0, copy.width, copy.height);
                  perturb(image.data);
                  context.putImageData(image, 0, 0);
                  return original.apply(copy, args);
                }
              }
              return original.apply(this, args);
            };
            HTMLCanvasElement.prototype.toDataURL = exporting('toDataURL', HTMLCanvasElement.prototype.toDataURL);
            HTMLCanvasElement.prototype.toBlob = exporting('toBlob', HTMLCanvasElement.prototype.toBlob);

            for (const prototype of [globalThis.WebGLRenderingContext?.prototype, globalThis.WebGL2RenderingContext?.prototype]) {
              if (!prototype) continue;
              const originalParameter = prototype.getParameter;
              prototype.getParameter = function (name) {
                if (name === 37445) return 'Apple Inc.';
                if (name === 37446) return 'Apple GPU';
                return originalParameter.call(this, name);
              };
            }
            if (globalThis.AudioBuffer) {
              const originalChannel = AudioBuffer.prototype.getChannelData;
              AudioBuffer.prototype.getChannelData = function (...args) {
                const data = originalChannel.apply(this, args);
                for (let i = 0; i < data.length; i += 997) data[i] += (noise(i) % 2 ? 1 : -1) * 1e-7;
                return data;
              };
            }
            if (navigator.mediaDevices?.enumerateDevices) navigator.mediaDevices.enumerateDevices = async () => [];
            """#)
        }
        return "(() => {\n" + parts.joined(separator: "\n") + "\n})();"
    }

    @available(macOS 14.0, *)
    static func proxyConfigurations(_ settings: ApsaPrivacySettings) -> [ProxyConfiguration] {
        let host = settings.proxyHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, (1...65_535).contains(settings.proxyPort), let port = NWEndpoint.Port(rawValue: UInt16(settings.proxyPort)) else { return [] }
        return [ProxyConfiguration(socksv5Proxy: .hostPort(host: NWEndpoint.Host(host), port: port))]
    }
}

final class ApsaPrivacyStore {
    static let shared = ApsaPrivacyStore()
    static let changed = Notification.Name("ApsaPrivacyChanged")
    private static let key = "apsa-browser-privacy"
    private let defaults: UserDefaults
    let seed = UInt32.random(in: 1...UInt32.max)
    private(set) var settings: ApsaPrivacySettings

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(ApsaPrivacySettings.self, from: $0) } ?? ApsaPrivacySettings()
    }

    func update(_ change: (inout ApsaPrivacySettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.key) }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    func choose(_ level: ApsaPrivacyLevel) {
        update { $0 = ApsaPrivacySettings.preset(level, from: $0) }
    }

    // Changing one switch by hand leaves the named levels behind.
    func set(_ path: WritableKeyPath<ApsaPrivacySettings, Bool>, _ value: Bool) {
        update {
            $0[keyPath: path] = value
            $0.level = .custom
        }
    }

    // Removes cookies, storage and cache, and leaves the sites the person chose to keep.
    func clearWebData(completion: @escaping () -> Void) {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { [settings] records in
            let doomed = records.filter { !settings.keepsData(for: $0.displayName) }
            store.removeData(ofTypes: types, for: doomed, completionHandler: completion)
        }
    }
}
