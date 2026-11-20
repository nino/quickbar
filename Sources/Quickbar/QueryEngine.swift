import Foundation
import QuickbarCore

enum LauncherMode: Equatable {
    /// Searching the index by abbreviation.
    case root
    /// Walking the file system; the text filters the folder's contents.
    case browse(path: String)
    /// Typing a query for a search template.
    case text(template: SearchTemplate)
}

/// Turns (mode, typed text) into result rows. Runs on the search queue only:
/// it may touch the file system, and its directory cache is not thread-safe.
final class QueryEngine {
    private var cachedDirectory: (path: String, items: [Item], index: SearchIndex)?

    func invalidateDirectoryCache() {
        cachedDirectory = nil
    }

    /// True when the text is not a plain abbreviation: math, a URL, a path, or
    /// several words. Such text is never auto-cleared and never learned.
    static func isSticky(_ query: String) -> Bool {
        query.contains { !($0.isLetter || $0.isNumber) }
    }

    func rows(mode: LauncherMode, query: String, config: Config, index: SearchIndex, suggestions: [String]) -> [Item] {
        switch mode {
        case .root: return rootRows(query: query, config: config, index: index)
        case .browse(let path): return browseRows(path: path, filter: query, limit: 500)
        case .text(let template): return textRows(template: template, query: query, suggestions: suggestions)
        }
    }

    /// Which characters of each row's title the typed text matched. Runs on the
    /// search queue with the rows, so the main thread only applies the result.
    static func highlights(for rows: [Item], mode: LauncherMode, query: String) -> [[Range<Int>]] {
        var needle = query.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .text: return []
        case .browse: break
        case .root:
            // A typed path filters by its last component only.
            if needle.hasPrefix("/") || needle.hasPrefix("~") {
                needle = needle.hasSuffix("/") ? "" : (needle as NSString).lastPathComponent
            }
        }
        guard !needle.isEmpty else { return [] }
        return rows.map { item in
            switch item.kind {
            case .app, .folder, .file, .searchTemplate, .action, .setting, .snippet:
                return Fuzzy.matchRanges(query: needle, title: item.title)
            case .webSearch, .url, .calculation:
                // These titles are made from the typed text, not matched against it.
                return []
            }
        }
    }

    private func directory(_ path: String) -> (items: [Item], index: SearchIndex) {
        if let c = cachedDirectory, c.path == path { return (c.items, c.index) }
        let items = FileScanner.listDirectory(path)
        let index = SearchIndex(items: items)
        cachedDirectory = (path, items, index)
        return (items, index)
    }

    private func browseRows(path: String, filter: String, limit: Int) -> [Item] {
        let dir = directory(path)
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return Array(dir.items.prefix(limit)) }
        return dir.index.search(trimmed, limit: limit).map(\.item)
    }

    private func textRows(template: SearchTemplate, query: String, suggestions: [String]) -> [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var rows = [Item(
            id: "websearch:typed", title: trimmed, subtitle: "Search \(template.name)",
            kind: .webSearch, payload: trimmed, aux: template.id)]
        for s in suggestions where s.caseInsensitiveCompare(trimmed) != .orderedSame {
            rows.append(Item(id: "suggest:\(s)", title: s, kind: .webSearch, payload: s, aux: template.id))
        }
        return rows
    }

    private func rootRows(query: String, config: Config, index: SearchIndex) -> [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        var rows = [Item]()
        var seen = Set<String>()
        func add(_ item: Item) {
            if seen.insert(item.id).inserted { rows.append(item) }
        }

        // Typed paths: "~/Doc", "/usr/lo"
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            for item in pathRows(trimmed) { add(item) }
            if !rows.isEmpty { return rows }
        }

        // 1. Custom abbreviations always win.
        for target in config.abbreviationTargets(for: trimmed) {
            if let item = index.item(withID: target) ?? Self.fileItem(at: target) { add(item) }
        }

        // 2. Math.
        if let result = Calculator.evaluate(trimmed) {
            add(Item(id: "calc", title: result.formatted, subtitle: "\(trimmed)  —  Enter copies the result",
                     kind: .calculation, payload: result.formatted))
        }

        // 3. URLs. Weak ones ("notes.txt") go below real matches.
        let detected = URLDetector.detect(trimmed)
        func urlItem(_ d: URLDetector.Detected) -> Item {
            Item(id: "url", title: d.url.absoluteString, subtitle: "Open URL", kind: .url, payload: d.url.absoluteString)
        }
        if let detected, detected.isStrong { add(urlItem(detected)) }

        // 4. The index, ranked by match quality plus what was learned.
        for hit in index.search(trimmed, bonus: Learning.store.bonus(for: trimmed), limit: config.maxResults) {
            add(hit.item)
        }

        if let detected, !detected.isStrong { add(urlItem(detected)) }

        // 5. Web search fallbacks, default template first.
        let templates = config.searchTemplates.sorted { a, _ in a.id == config.defaultSearchTemplate }
        for t in templates {
            add(Item(id: "websearch:\(t.id)", title: "Search \(t.name) for “\(trimmed)”",
                     kind: .webSearch, payload: trimmed, aux: t.id))
        }
        return rows
    }

    private static func fileItem(at path: String) -> Item? {
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { return nil }
        return FileScanner.listDirectory((path as NSString).deletingLastPathComponent, includeHidden: true)
            .first { $0.path == path }
    }

    private func pathRows(_ typed: String) -> [Item] {
        let expanded = PathDisplay.expand(typed)
        guard expanded.hasPrefix("/") else { return [] }
        let dirPath: String, partial: String
        if expanded.hasSuffix("/") || typed == "~" {
            dirPath = expanded
            partial = ""
        } else {
            dirPath = (expanded as NSString).deletingLastPathComponent
            partial = (expanded as NSString).lastPathComponent
        }
        guard FileScanner.isBrowsableDirectory(dirPath) else { return [] }
        return browseRows(path: (dirPath as NSString).standardizingPath, filter: partial, limit: 200)
    }
}
