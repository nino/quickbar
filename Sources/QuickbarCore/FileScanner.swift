import Foundation

/// File-system scanning. Always call off the main thread.
public enum FileScanner {
    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .localizedNameKey]

    private static func children(of url: URL, includeHidden: Bool = false) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys,
            options: includeHidden ? [] : [.skipsHiddenFiles]
        )) ?? []
    }

    static func makeItem(for url: URL) -> Item {
        let values = try? url.resourceValues(forKeys: Set(keys))
        let isDirectory = values?.isDirectory ?? false
        let isPackage = values?.isPackage ?? false
        let path = url.path
        let parent = PathDisplay.abbreviate(url.deletingLastPathComponent().path)

        if url.pathExtension == "app" {
            var name = values?.localizedName ?? url.lastPathComponent
            if name.hasSuffix(".app") { name.removeLast(4) }
            return Item(id: path, title: name, subtitle: parent, kind: .app, path: path)
        }
        let kind: ItemKind = isDirectory && !isPackage ? .folder : .file
        return Item(id: path, title: url.lastPathComponent, subtitle: parent, kind: kind, path: path)
    }

    /// Applications in `directories`, looking up to two levels into plain subfolders
    /// (e.g. /Applications/Utilities).
    public static func scanApplications(in directories: [String]) -> [Item] {
        var items = [Item]()
        func visit(_ url: URL, level: Int) {
            for child in children(of: url) {
                if child.pathExtension == "app" {
                    items.append(makeItem(for: child))
                } else if level < 2,
                          (try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]))
                              .map({ $0.isDirectory == true && $0.isPackage != true }) == true {
                    visit(child, level: level + 1)
                }
            }
        }
        for dir in directories {
            visit(URL(fileURLWithPath: PathDisplay.expand(dir), isDirectory: true), level: 0)
        }
        // Finder lives outside the usual application folders.
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        if FileManager.default.fileExists(atPath: finder.path) { items.append(makeItem(for: finder)) }
        // Safari ships in a cryptex: it opens from /Applications but is not listed there.
        for app in children(of: URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications")) where app.pathExtension == "app" {
            let visible = URL(fileURLWithPath: "/Applications/" + app.lastPathComponent)
            items.append(makeItem(for: FileManager.default.fileExists(atPath: visible.path) ? visible : app))
        }
        return items
    }

    /// Files and folders under `root`, `depth` levels deep. The root itself is included.
    public static func scanFolder(root: String, depth: Int, excluding: Set<String>, limit: Int = 30_000) -> [Item] {
        let rootURL = URL(fileURLWithPath: PathDisplay.expand(root), isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDir), isDir.boolValue else { return [] }
        var items = [makeItem(for: rootURL)]
        var frontier = [rootURL]
        for level in 0..<max(depth, 0) {
            var next = [URL]()
            for dir in frontier {
                for child in children(of: dir) where !excluding.contains(child.lastPathComponent) {
                    let item = makeItem(for: child)
                    items.append(item)
                    if items.count >= limit { return items }
                    if item.kind == .folder && level + 1 < depth { next.append(child) }
                }
            }
            frontier = next
            if frontier.isEmpty { break }
        }
        return items
    }

    /// One directory's contents, sorted the way Finder sorts names.
    public static func listDirectory(_ path: String, includeHidden: Bool = false) -> [Item] {
        let url = URL(fileURLWithPath: PathDisplay.expand(path), isDirectory: true)
        return children(of: url, includeHidden: includeHidden)
            .map(makeItem(for:))
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public static func isBrowsableDirectory(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey]) else { return false }
        return v.isDirectory == true
    }
}
