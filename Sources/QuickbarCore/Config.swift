import Foundation

public struct HotKeySpec: Codable, Equatable, Sendable {
    /// Virtual key code (kVK_*), layout independent.
    public var keyCode: UInt32
    /// Any of "command", "option", "control", "shift".
    public var modifiers: [String]
    /// What to show for the key in the UI, e.g. "Space" or "\\".
    public var label: String

    public init(keyCode: UInt32, modifiers: [String], label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    public var displayString: String {
        let symbols = ["control": "⌃", "option": "⌥", "shift": "⇧", "command": "⌘"]
        let order = ["control", "option", "shift", "command"]
        return order.filter(modifiers.contains).compactMap { symbols[$0] }.joined() + label
    }
}

public struct IndexedFolder: Codable, Equatable, Identifiable, Sendable {
    public var path: String
    /// How many levels below `path` to index. 1 = direct children only.
    public var depth: Int
    public var id: String { path }

    public init(path: String, depth: Int = 1) {
        self.path = path
        self.depth = depth
    }
}

public struct SearchTemplate: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// URL with `{query}` where the percent-encoded search terms go.
    public var url: String
    /// Suggestion endpoint returning OpenSearch JSON, with `{query}`. Optional.
    public var suggestURL: String?

    public init(id: String, name: String, url: String, suggestURL: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.suggestURL = suggestURL
    }

    private static let queryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#")
        return set
    }()

    public func searchURL(for query: String) -> URL? {
        Self.fill(url, query: query)
    }

    public func suggestionURL(for query: String) -> URL? {
        suggestURL.flatMap { Self.fill($0, query: query) }
    }

    private static func fill(_ template: String, query: String) -> URL? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: queryAllowed) else { return nil }
        return URL(string: template.replacingOccurrences(of: "{query}", with: encoded))
    }

    public static let kagi = SearchTemplate(
        id: "kagi", name: "Kagi",
        url: "https://kagi.com/search?q={query}",
        suggestURL: "https://kagi.com/api/autosuggest?q={query}"
    )
}

public struct CustomAbbreviation: Codable, Equatable, Identifiable, Sendable {
    public var abbreviation: String
    /// Item id: a file path for apps/files/folders, or e.g. "template:kagi".
    public var target: String
    public var id: String { abbreviation + "\u{0}" + target }

    public init(abbreviation: String, target: String) {
        self.abbreviation = abbreviation
        self.target = target
    }
}

/// Everything user-configurable. Stored as JSON; missing keys take defaults so
/// old config files keep working when fields are added.
public struct Config: Codable, Equatable, Sendable {
    public var hotKey = HotKeySpec(keyCode: 49, modifiers: ["option"], label: "Space")
    public var clipboardHotKey = HotKeySpec(keyCode: 42, modifiers: ["command"], label: "\\")
    /// Seconds without typing after which the next keystroke starts a new abbreviation.
    public var retypeDelay: Double = 1.0
    public var folders: [IndexedFolder] = [
        IndexedFolder(path: "~", depth: 1),
        IndexedFolder(path: "~/Desktop", depth: 1),
        IndexedFolder(path: "~/Documents", depth: 2),
        IndexedFolder(path: "~/Downloads", depth: 1),
    ]
    public var applicationFolders: [String] = [
        "/Applications",
        "/System/Applications",
        "/System/Library/CoreServices/Applications",
        "~/Applications",
    ]
    /// File and folder names never indexed.
    public var excludedNames: [String] = ["node_modules", "Library", ".git", "DerivedData", "build", "target"]
    public var searchTemplates: [SearchTemplate] = [.kagi]
    /// Template offered as "Search … for <typed text>" at the bottom of results.
    public var defaultSearchTemplate: String = "kagi"
    public var abbreviations: [CustomAbbreviation] = []
    public var clipboardMaxEntries: Int = 100
    public var clipboardPersist: Bool = true
    public var maxResults: Int = 50

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        hotKey = get(.hotKey, d.hotKey)
        clipboardHotKey = get(.clipboardHotKey, d.clipboardHotKey)
        retypeDelay = get(.retypeDelay, d.retypeDelay)
        folders = get(.folders, d.folders)
        applicationFolders = get(.applicationFolders, d.applicationFolders)
        excludedNames = get(.excludedNames, d.excludedNames)
        searchTemplates = get(.searchTemplates, d.searchTemplates)
        defaultSearchTemplate = get(.defaultSearchTemplate, d.defaultSearchTemplate)
        abbreviations = get(.abbreviations, d.abbreviations)
        clipboardMaxEntries = get(.clipboardMaxEntries, d.clipboardMaxEntries)
        clipboardPersist = get(.clipboardPersist, d.clipboardPersist)
        maxResults = get(.maxResults, d.maxResults)
    }

    public static func decode(_ data: Data) -> Config? {
        try? JSONDecoder().decode(Config.self, from: data)
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }

    public func template(withID id: String) -> SearchTemplate? {
        searchTemplates.first { $0.id == id }
    }

    /// Target of a custom abbreviation exactly matching the typed text.
    public func abbreviationTargets(for query: String) -> [String] {
        let q = Fuzzy.normalize(query)
        guard !q.isEmpty else { return [] }
        return abbreviations.filter { Fuzzy.normalize($0.abbreviation) == q }.map(\.target)
    }
}
