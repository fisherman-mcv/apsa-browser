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
      const request = (escape = false) => { try { webkit.messageHandlers.apsaFastFullscreen.postMessage({ escape }); } catch (_) {} };
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
      const onKeyDown = event => { if (enabled && event.key === 'Escape') request(true); };
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
    var onRequest: ((WKWebView, Bool) -> Void)?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let isEscape = (message.body as? [String: Any])?["escape"] as? Bool ?? false
        if message.frameInfo.isMainFrame, let view = message.webView { onRequest?(view, isEscape) }
    }
}

enum ApsaPictureInPicture {
    // Picks the video in full screen, else the largest playing one, else the
    // largest; leaves full screen first so the system can take the video.
    static let toggleScript = #"""
    (() => {
      const videos = [...document.querySelectorAll('video')];
      const current = videos.find(v => v.webkitPresentationMode === 'picture-in-picture');
      if (current) { current.webkitSetPresentationMode('inline'); return 'inline'; }
      const area = v => v.clientWidth * v.clientHeight;
      const full = document.fullscreenElement || document.webkitFullscreenElement;
      const inFull = full ? [...full.querySelectorAll('video')].concat(full.tagName === 'VIDEO' ? [full] : []) : [];
      const playing = videos.filter(v => !v.paused && v.readyState > 1);
      const video = (inFull.length ? inFull : playing.length ? playing : videos).sort((a, b) => area(b) - area(a))[0];
      if (!video?.webkitSupportsPresentationMode?.('picture-in-picture')) return 'none';
      const enter = () => video.webkitSetPresentationMode('picture-in-picture');
      if (full) {
        document.addEventListener('fullscreenchange', enter, { once: true });
        (document.exitFullscreen || document.webkitExitFullscreen).call(document);
      } else enter();
      return 'picture-in-picture';
    })()
    """#
}
