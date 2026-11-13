import AppKit
import QuickbarCore

/// Icons are fetched and rasterized off the main thread, then cached.
final class IconCache {
    static let shared = IconCache()
    static let pointSize: CGFloat = 32

    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "quickbar.icons", qos: .userInitiated, attributes: .concurrent)
    private var symbols: [ItemKind: NSImage] = [:]

    private init() {
        cache.countLimit = 2000
    }

    /// Immediate icon if there is one: a symbol for non-file items or a cached file icon.
    func immediate(for item: Item) -> NSImage? {
        guard let path = item.path else { return symbol(for: item.kind) }
        return cache.object(forKey: path as NSString)
    }

    func load(_ item: Item, completion: @escaping (NSImage) -> Void) {
        guard let path = item.path else { return }
        queue.async {
            let image = Self.rasterize(NSWorkspace.shared.icon(forFile: path))
            self.cache.setObject(image, forKey: path as NSString)
            DispatchQueue.main.async { completion(image) }
        }
    }

    private func symbol(for kind: ItemKind) -> NSImage? {
        if let s = symbols[kind] { return s }
        let name: String
        switch kind {
        case .searchTemplate, .webSearch: name = "magnifyingglass"
        case .url: name = "globe"
        case .calculation: name = "equal.square"
        case .action: name = "gearshape"
        default: name = "doc"
        }
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        image?.isTemplate = true
        symbols[kind] = image
        return image
    }

    /// Draws into a bitmap now so the main thread never pays for lazy icon decoding.
    private static func rasterize(_ image: NSImage) -> NSImage {
        let points = pointSize
        let pixels = Int(points * 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return image }
        // Set the point size before making the context, so it draws at 2x.
        rep.size = NSSize(width: points, height: points)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: points, height: points), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: rep.size)
        out.addRepresentation(rep)
        return out
    }
}
