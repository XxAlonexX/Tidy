import Cocoa
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import WebKit

/// The person's look-and-feel choices. The web UI owns the shape of `prefs`; this side only stores it
/// and keeps a copy of their custom wallpaper in Application Support.
enum Appearance {
    private static let prefsKey = "appearancePrefs"
    /// Long edge of stored/served wallpapers: sharp on a 5K display, light enough to decode instantly.
    static let maxPixels = 3200

    static var prefs: Any {
        guard let data = UserDefaults.standard.data(forKey: prefsKey),
              let json = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
        return json
    }

    static func save(_ prefs: Any) throws {
        // JSONSerialization raises (not throws) on anything but an object/array at the top level.
        guard JSONSerialization.isValidJSONObject(prefs) else { throw JevError.http(0, "bad appearance prefs") }
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: prefs), forKey: prefsKey)
    }

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Config.appName, isDirectory: true)
    }

    static var customWallpaper: URL? {
        let url = folder.appendingPathComponent("Wallpaper.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The picture currently on this Mac's desktop. Aerial/dynamic wallpapers may not be readable images.
    @MainActor static var systemWallpaper: URL? {
        guard let screen = NSScreen.main else { return nil }
        return NSWorkspace.shared.desktopImageURL(for: screen)
    }

    /// Re-encodes any image ImageIO can read (HEIC, PNG, TIFF, RAW…) as a right-sized JPEG.
    static func jpeg(from url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    static func importWallpaper(from url: URL) throws {
        guard let data = jpeg(from: url) else { throw JevError.http(0, "That file isn't an image Tidy can read.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("Wallpaper.jpg"), options: .atomic)
    }
}

/// Serves `jevwall://w/custom` (the imported picture) and `jevwall://w/system` (the Mac's own wallpaper).
final class WallpaperSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "jevwall"
    private var stopped = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let which = task.request.url?.lastPathComponent ?? ""
        let file = MainActor.assumeIsolated { which == "system" ? Appearance.systemWallpaper : Appearance.customWallpaper }
        let key = ObjectIdentifier(task)
        DispatchQueue.global(qos: .userInitiated).async {
            let data = file.flatMap { which == "custom" ? try? Data(contentsOf: $0) : Appearance.jpeg(from: $0) }
            DispatchQueue.main.async {
                if self.stopped.remove(key) != nil { return }
                guard let data else { return task.didFailWithError(URLError(.fileDoesNotExist)) }
                task.didReceive(URLResponse(url: task.request.url!, mimeType: "image/jpeg", expectedContentLength: data.count, textEncodingName: nil))
                task.didReceive(data)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }
}
