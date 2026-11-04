import AppKit
import WebKit

// Runs with no window, no Dock icon and no focus. The system player is
// replaced with a stub, so nothing opens on screen.
@main struct PictureInPictureTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        func run(_ html: String) -> String {
            web.loadHTMLString("""
            <script>
            HTMLVideoElement.prototype.webkitSupportsPresentationMode = () => true;
            HTMLVideoElement.prototype.webkitSetPresentationMode = function (mode) { document.title = this.id + ':' + mode; };
            Object.defineProperty(HTMLVideoElement.prototype, 'paused', { get() { return !this.hasAttribute('data-playing'); } });
            Object.defineProperty(HTMLVideoElement.prototype, 'readyState', { get() { return 4; } });
            </script>\(html)
            """, baseURL: nil)
            var result: String?
            let end = Date().addingTimeInterval(15)
            while result == nil, Date() < end {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                if web.isLoading { continue }
                web.evaluateJavaScript(ApsaPictureInPicture.toggleScript + "; document.title") { value, _ in result = value as? String }
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            return result ?? "timeout"
        }
        let big = "<video id=big style='width:600px;height:300px'></video>"
        let small = "<video id=small data-playing style='width:200px;height:100px'></video>"
        precondition(run(big) == "big:picture-in-picture", "the only video")
        precondition(run(big + small) == "small:picture-in-picture", "a playing video wins over a larger paused one")
        precondition(run("<p>no video</p>") == "", "pages without video are left alone")
        print("Picture in picture: video choice OK")
    }
}
