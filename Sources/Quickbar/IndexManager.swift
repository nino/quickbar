import AppKit
import QuickbarCore

/// Owns the search index: builds it on a background queue, swaps it in
/// atomically, and rebuilds when watched folders change.
final class IndexManager {
    static let shared = IndexManager()

    private let lock = NSLock()
    private var current = SearchIndex.empty
    private let queue = DispatchQueue(label: "quickbar.index", qos: .utility)
    private var stream: FSEventStreamRef?
    /// Queue-confined.
    private var config = Config()
    private var watched: [(path: String, depth: Int)] = []
    private var rebuildPending = false

    /// Called on the main thread after each rebuild.
    var onUpdate: (() -> Void)?

    var index: SearchIndex {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    static let actions: [Item] = [
        Item(id: "action:settings", title: "Quickbar Settings", subtitle: "Hotkeys, folders, abbreviations", kind: .action, payload: "settings"),
        Item(id: "action:rescan", title: "Rescan Quickbar Index", subtitle: "Re-read applications and folders", kind: .action, payload: "rescan"),
        Item(id: "action:reload", title: "Reload Quickbar Config", subtitle: "Re-read config.json after editing it by hand", kind: .action, payload: "reload"),
        Item(id: "action:config", title: "Reveal Quickbar Config File", subtitle: "Show config.json in Finder", kind: .action, payload: "config"),
        Item(id: "action:clipboard", title: "Clipboard History", subtitle: "Show everything you copied", kind: .action, payload: "clipboard"),
        Item(id: "action:clear-clipboard", title: "Clear Clipboard History", subtitle: "Forget everything you copied", kind: .action, payload: "clear-clipboard"),
        Item(id: "action:quit", title: "Quit Quickbar", kind: .action, payload: "quit"),
    ]

    /// Applications, search templates and built-in actions: quick to gather and
    /// never blocked by a privacy prompt.
    static func baseItems(config: Config) -> [Item] {
        var items = FileScanner.scanApplications(in: config.applicationFolders)
        for t in config.searchTemplates {
            items.append(Item(id: "template:\(t.id)", title: t.name, subtitle: "Search — press Space to type", kind: .searchTemplate, payload: t.id))
        }
        items.append(contentsOf: actions)
        return items
    }

    /// Applies a config: rebuilds the index and re-targets the folder watcher.
    func configure(_ config: Config) {
        queue.async {
            self.config = config
            self.rebuildNow()
            self.restartWatching()
        }
    }

    func rebuild() {
        queue.async { self.rebuildNow() }
    }

    private func publish(_ items: [Item]) {
        let built = SearchIndex(items: items)
        lock.lock()
        current = built
        lock.unlock()
        DispatchQueue.main.async { self.onUpdate?() }
    }

    private func rebuildNow() {
        let start = DispatchTime.now()
        var items = Self.baseItems(config: config)
        // On the first build, make applications searchable right away: scanning
        // a protected folder can sit behind a permission prompt for minutes.
        if index.items.isEmpty { publish(items) }
        let excluded = Set(config.excludedNames)
        for folder in config.folders {
            items.append(contentsOf: FileScanner.scanFolder(root: folder.path, depth: folder.depth, excluding: excluded))
        }
        publish(items)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        NSLog("Quickbar: indexed \(items.count) items in \(String(format: "%.0f", ms)) ms")
    }

    // MARK: - FSEvents

    private func restartWatching() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        // Applications are found up to two folders deep.
        watched = config.applicationFolders.map { (PathDisplay.expand($0), 3) }
            + config.folders.map { (PathDisplay.expand($0.path), $0.depth) }
        watched = watched.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !watched.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info, let array = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            Unmanaged<IndexManager>.fromOpaque(info).takeUnretainedValue().handleEvents(Array(array.prefix(count)))
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, watched.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes))
        else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// FSEvents reports whole subtrees; only changes within the indexed depth matter.
    private func handleEvents(_ paths: [String]) {
        let relevant = paths.contains { path in
            let dir = path.hasSuffix("/") ? String(path.dropLast()) : path
            return watched.contains { root in
                if dir == root.path { return true }
                guard dir.hasPrefix(root.path + "/") else { return false }
                let levelsBelowRoot = dir.dropFirst(root.path.count + 1).split(separator: "/").count
                return levelsBelowRoot < root.depth
            }
        }
        guard relevant, !rebuildPending else { return }
        rebuildPending = true
        queue.asyncAfter(deadline: .now() + 1.5) {
            self.rebuildPending = false
            self.rebuildNow()
        }
    }
}
