import WebKit

// Optional in-window video fullscreen on YouTube: the window fills the screen at
// once, without moving to a separate macOS Space. Off by default.
enum ApsaFastFullscreen {
    static let handlerName = "apsaFastFullscreen"
    private static let enabledKey = "apsa-browser-fast-fullscreen"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func apply(to webView: WKWebView) {
        webView.configuration.preferences.isElementFullscreenEnabled = !isEnabled
        webView.evaluateJavaScript("globalThis.__apsaSetFastFullscreen?.(\(isEnabled ? "true" : "false")) ?? false") { _, _ in }
    }

    static let controllerScript = #"""
    (() => {
      if (globalThis.__apsaFastFullscreenInstalled) return;
      globalThis.__apsaFastFullscreenInstalled = true;
      let enabled = false;
      let observer = null;
      const request = () => { try { webkit.messageHandlers.apsaFastFullscreen.postMessage({}); } catch (_) {} };
      const install = () => {
        if (!enabled) return false;
        const controls = document.querySelector('.ytp-right-controls');
        if (!controls || document.querySelector('.apsa-fast-fullscreen')) return false;
        const button = document.createElement('button');
        button.className = 'ytp-button apsa-fast-fullscreen';
        button.type = 'button';
        button.title = '\#(apsaText("Fast Full Screen"))';
        button.setAttribute('aria-label', '\#(apsaText("Fast Full Screen"))');
        button.textContent = '⛶';
        button.style.cssText = 'font:26px sans-serif;color:#fff;width:48px;height:48px;padding:0;text-align:center;';
        button.addEventListener('click', event => { event.preventDefault(); event.stopPropagation(); request(); });
        controls.append(button);
        return true;
      };
      const stopObserver = () => { observer?.disconnect(); observer = null; };
      const remove = () => { stopObserver(); document.querySelectorAll('.apsa-fast-fullscreen').forEach(button => button.remove()); };
      const watch = () => {
        if (install() || observer || !document.documentElement) return;
        observer = new MutationObserver(() => { if (install()) stopObserver(); });
        observer.observe(document.documentElement, { childList: true, subtree: true });
      };
      const onKeyDown = event => { if (enabled && event.key === 'Escape') request(); };
      addEventListener('keydown', onKeyDown, true);
      globalThis.__apsaSetFastFullscreen = value => {
        enabled = value === true;
        if (enabled) watch(); else remove();
        return enabled;
      };
      addEventListener('pagehide', () => { remove(); removeEventListener('keydown', onKeyDown, true); }, { once: true });
    })();
    """#

    static let enterScript = #"""
    (() => {
      const player = document.querySelector('.html5-video-player, #movie_player');
      const theatre = document.querySelector('.ytp-size-button');
      if (!player && !document.querySelector('video')) return false;
      const wasTheatre = document.querySelector('ytd-watch-flexy')?.hasAttribute('theater') ?? false;
      globalThis.__apsaFastFullscreenPage = { theatre, wasTheatre };
      if (!wasTheatre && theatre) theatre.click();
      return true;
    })()
    """#

    static let exitScript = #"""
    (() => {
      const state = globalThis.__apsaFastFullscreenPage;
      if (!state) return;
      if (!state.wasTheatre && state.theatre?.isConnected) state.theatre.click();
      delete globalThis.__apsaFastFullscreenPage;
    })()
    """#
}

final class ApsaFastFullscreenHandler: NSObject, WKScriptMessageHandler {
    var onRequest: ((WKWebView) -> Void)?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.frameInfo.isMainFrame, let view = message.webView { onRequest?(view) }
    }
}
