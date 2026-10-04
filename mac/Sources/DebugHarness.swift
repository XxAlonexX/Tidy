#if JEV_DEBUG
import Cocoa
@preconcurrency import WebKit

/// Test-only: JEV_DEBUG_STEPS="3:snap:/tmp/a.png|3.2:js:clean()|12:quit" drives the app and snapshots its own web view.
/// Compiled only with -D JEV_DEBUG, never into release builds.
@MainActor
enum DebugHarness {
    static func run(_ webView: WKWebView) {
        guard let steps = ProcessInfo.processInfo.environment["JEV_DEBUG_STEPS"] else { return }
        // Keep the window "visible" to WebKit (so animations run) but invisible and click-through for the person at the Mac.
        webView.window?.alphaValue = 0.01
        webView.window?.ignoresMouseEvents = true
        webView.window?.level = .floating
        webView.window?.orderFrontRegardless()
        for step in steps.split(separator: "|") {
            let parts = step.split(separator: ":", maxSplits: 2).map(String.init)
            guard let t = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                switch parts[1] {
                case "snap":
                    webView.takeSnapshot(with: nil) { img, _ in
                        guard let tiff = img?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[2]))
                        print("snap", parts[2])
                    }
                case "js":
                    webView.evaluateJavaScript(parts[2]) { r, e in print("js", parts[2], "->", r ?? "nil", e?.localizedDescription ?? "") }
                default:
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
#endif
