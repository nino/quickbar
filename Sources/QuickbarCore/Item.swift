import Foundation

public enum ItemKind: String, Codable, Sendable {
    case app
    case folder
    case file
    /// A search template in the index ("Kagi"). Space/Tab/Enter starts typing a query for it.
    case searchTemplate
    /// A concrete web search: `payload` is the query, `aux` the template id.
    case webSearch
    /// `payload` is the URL string.
    case url
    /// `payload` is the result to copy.
    case calculation
    /// A pane of System Settings; `payload` is the URL that opens it, `aux`
    /// the path of its extension bundle (for the icon).
    case setting
    /// Built-in command; `payload` is the action name.
    case action
}

/// One row the launcher can show and act on.
public struct Item: Hashable, Sendable {
    /// Stable identity used for learning and abbreviations. File-system items use their path.
    public var id: String
    public var title: String
    public var subtitle: String
    public var kind: ItemKind
    public var path: String?
    public var payload: String?
    public var aux: String?

    public init(
        id: String, title: String, subtitle: String = "", kind: ItemKind,
        path: String? = nil, payload: String? = nil, aux: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.path = path
        self.payload = payload
        self.aux = aux
    }

    public var isFileSystemItem: Bool { path != nil }
}

public enum PathDisplay {
    private static let home = NSHomeDirectory()

    /// "/Users/me/Documents" -> "~/Documents"
    public static func abbreviate(_ path: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    public static func expand(_ path: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }
}
