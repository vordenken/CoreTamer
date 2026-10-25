import AppKit

/// Reuses icons across table refreshes and bounds memory as processes come and go.
final class ProcessIconCache {
    private let images = NSCache<NSString, NSImage>()
    private let load: (String) -> NSImage

    init(load: @escaping (String) -> NSImage = { NSWorkspace.shared.icon(forFile: $0) }) {
        self.load = load
        images.countLimit = 256
    }

    func icon(for path: String) -> NSImage {
        let key = TamerView.iconPath(for: path) as NSString
        if let image = images.object(forKey: key) { return image }
        let image = load(key as String)
        images.setObject(image, forKey: key)
        return image
    }
}
