import Cocoa
import WebKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var webView: WKWebView!

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        let width: CGFloat = 520
        let height: CGFloat = 720
        
        let screenRect = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let originX = screenRect.origin.x + (screenRect.width - width) / 2
        let originY = screenRect.origin.y + (screenRect.height - height) / 2
        let rect = NSRect(x: originX, y: originY, width: width, height: height)

        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered,
                          defer: false)
        window.title = "2048 Benchmark Game"
        
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: config)
        webView.autoresizingMask = [.width, .height]
        
        let htmlPath: String
        if CommandLine.arguments.count > 1 {
            htmlPath = CommandLine.arguments[1]
        } else if let resPath = Bundle.main.path(forResource: "index", ofType: "html") {
            htmlPath = resPath
        } else {
            htmlPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("index.html").path
        }
        
        let url = URL(fileURLWithPath: htmlPath)
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
