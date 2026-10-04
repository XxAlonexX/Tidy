import Cocoa
import QuickLookThumbnailing
import UniformTypeIdentifiers
@preconcurrency import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandlerWithReply, WKUIDelegate, WKNavigationDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private let cleaner = Cleaner()
    private lazy var thumbs = ThumbnailSchemeHandler(cleaner: cleaner)
    private let wallpapers = WallpaperSchemeHandler()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let config = WKWebViewConfiguration()
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "jev")
        config.setURLSchemeHandler(thumbs, forURLScheme: ThumbnailSchemeHandler.scheme)
        config.setURLSchemeHandler(wallpapers, forURLScheme: WallpaperSchemeHandler.scheme)
        webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(1440, screen.width * 0.9), height: min(900, screen.height * 0.9))
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = Config.appName
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.04, green: 0.06, blue: 0.11, alpha: 1)
        window.minSize = NSSize(width: 820, height: 560)
        window.contentView = webView
        window.setFrameAutosaveName("MainWindow")
        if !window.setFrameUsingName("MainWindow") { window.center() }
        window.makeKeyAndOrderFront(nil)

        let page = Bundle.main.url(forResource: "index", withExtension: "html")!
        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        NSApp.activate(ignoringOtherApps: true)

        Task { await License.revalidateIfStale() }
        #if JEV_DEBUG
        DebugHarness.run(webView)
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }


    /// Covers an app left open overnight: the reminder is re-checked when it comes back to the front.
    func applicationDidBecomeActive(_ notification: Notification) {
        webView?.evaluateJavaScript("window.jevCheckNag && window.jevCheckNag()")
        // The Mac's wallpaper may have changed while we were in the background.
        webView?.evaluateJavaScript("window.jevRefreshWallpaper && window.jevRefreshWallpaper()")
    }

    // MARK: Bridge (JS: window.webkit.messageHandlers.jev.postMessage({cmd, args}) -> Promise)

    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else {
            return replyHandler(nil, "bad message")
        }
        let args = body["args"] as? [String: Any] ?? [:]
        Task { @MainActor in
            do { replyHandler(try await self.handle(cmd, args), nil) }
            catch { replyHandler(nil, error.localizedDescription) }
        }
    }

    private func handle(_ cmd: String, _ args: [String: Any]) async throws -> Any {
        switch cmd {
        case "status":
            return [
                "hasKey": APIKeyStore.load() != nil, "licensed": License.isLicensed, "email": (License.email as Any?) ?? NSNull(),
                "nagDue": License.nagDue, "price": Config.priceLabel,
            ]
        case "defaultFolder":
            if let dev = ProcessInfo.processInfo.environment["JEV_START_FOLDER"] { return dev }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].path
        case "scan":
            let path = (args["folder"] as? String) ?? ""
            return try cleaner.scan(URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true))
        case "pickFolder":
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = "Choose"
            panel.message = "Choose a folder for Jev to clean"
            panel.directoryURL = cleaner.root
            let response = await panel.beginSheetModal(for: window)
            guard response == .OK, let url = panel.url else { return NSNull() }
            return try cleaner.scan(url)
        case "classify":
            let threshold = (args["threshold"] as? NSNumber)?.doubleValue ?? 0.5
            cleaner.classify(threshold: threshold, allJev: args["allJev"] as? Bool ?? false, apiKey: APIKeyStore.load()) { [weak self] event in
                self?.send(event)
            }
            return true
        case "move":
            return ["moved": try cleaner.move()]
        case "undo":
            return ["restored": try cleaner.undo()]
        case "saveKey":
            let key = ((args["key"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty { APIKeyStore.delete(); return ["hasKey": false] }
            try await Jev.check(apiKey: key)
            APIKeyStore.save(key)
            return ["hasKey": true]
        case "activateLicense":
            let email = try await License.activate((args["key"] as? String) ?? "")
            return ["licensed": true, "email": (email as Any?) ?? NSNull()]
        case "nagShown":
            License.markNagShown()
            return true
        case "openCheckout":
            NSWorkspace.shared.open(Config.checkoutURL)
            return true
        case "openKeyConsole":
            NSWorkspace.shared.open(Config.typesafeConsoleURL)
            return true
        case "getAppearance":
            return ["prefs": Appearance.prefs, "hasCustom": Appearance.customWallpaper != nil]
        case "setAppearance":
            try Appearance.save(args["prefs"] ?? NSNull())
            return true
        case "pickWallpaper":
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.image]
            panel.prompt = "Use as Wallpaper"
            panel.message = "Choose a picture for Jev Cleaner's desktop"
            panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            let response = await panel.beginSheetModal(for: window)
            guard response == .OK, let url = panel.url else { return NSNull() }
            try Appearance.importWallpaper(from: url)
            return true
        case "revealFolder":
            if let root = cleaner.root { NSWorkspace.shared.activateFileViewerSelecting([root]) }
            return true
        default:
            throw JevError.http(0, "unknown command \(cmd)")
        }
    }

    private func send(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.jevEvent(\(json))")
    }

    // MARK: Native dialogs for confirm()/alert(), and external links open in the browser

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, url.scheme == "https" || url.scheme == "http" {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: "About \(Config.appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(menuItem("Settings…", "settings", ","))
        app.addItem(menuItem("Change Wallpaper…", "wallpaper", ""))
        app.addItem(menuItem("Support \(Config.appName) (\(Config.priceLabel))…", "support", ""))
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(Config.appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit \(Config.appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let file = NSMenu(title: "File")
        file.addItem(menuItem("Choose Folder…", "pick", "o"))
        file.addItem(menuItem("Rescan", "rescan", "r"))
        file.addItem(menuItem("Clean with Jev", "clean", "\r"))
        fileItem.submenu = file

        // Needed so ⌘C/⌘V/⌘A work inside the web view's text fields.
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        win.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        windowItem.submenu = win
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }

    private func menuItem(_ title: String, _ action: String, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: key)
        item.representedObject = action
        item.target = self
        return item
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        webView.evaluateJavaScript("window.jevMenu && window.jevMenu('\(action)')")
    }
}

/// Serves `jevthumb://t/<id>` as a real Finder-style thumbnail (photos, PDFs, videos, app icons).
final class ThumbnailSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "jevthumb"
    private let cleaner: Cleaner
    private var stopped = Set<ObjectIdentifier>()

    init(cleaner: Cleaner) { self.cleaner = cleaner }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = task.request.url?.lastPathComponent ?? ""
        guard let file = MainActor.assumeIsolated({ cleaner.files[id] }) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: file, size: CGSize(width: 96, height: 96), scale: 2, representationTypes: .all
        )
        let key = ObjectIdentifier(task)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, error in
            let png = rep.flatMap { NSBitmapImageRep(cgImage: $0.cgImage).representation(using: .png, properties: [:]) }
            DispatchQueue.main.async {
                if self.stopped.remove(key) != nil { return }
                guard let png else { return task.didFailWithError(error ?? URLError(.cannotDecodeContentData)) }
                task.didReceive(URLResponse(url: task.request.url!, mimeType: "image/png", expectedContentLength: png.count, textEncodingName: nil))
                task.didReceive(png)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
}
