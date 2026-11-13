import Foundation

public struct ClipboardEntry: Codable, Equatable, Sendable {
    public var text: String
    public var date: Date

    public init(text: String, date: Date = Date()) {
        self.text = text
        self.date = date
    }

    /// Single-line preview for list display.
    public var preview: String {
        var out = ""
        var lastWasSpace = true
        for ch in text.prefix(400) {
            if ch.isWhitespace || ch.isNewline {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

/// Most-recent-first list of copied text, deduplicated and capped.
public struct ClipboardHistory: Codable, Equatable, Sendable {
    public private(set) var entries: [ClipboardEntry] = []
    public var maxEntries: Int
    /// Entries larger than this are not kept.
    public static let maxEntryBytes = 1_000_000

    public init(maxEntries: Int = 100) {
        self.maxEntries = maxEntries
    }

    /// Adds `text` at the front, moving it up if already present. Returns false if ignored.
    @discardableResult
    public mutating func add(_ text: String, date: Date = Date()) -> Bool {
        guard !text.isEmpty, text.utf8.count <= Self.maxEntryBytes,
              text.contains(where: { !$0.isWhitespace })
        else { return false }
        if entries.first?.text == text { return false }
        entries.removeAll { $0.text == text }
        entries.insert(ClipboardEntry(text: text, date: date), at: 0)
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
        return true
    }

    public mutating func remove(at index: Int) {
        guard entries.indices.contains(index) else { return }
        entries.remove(at: index)
    }

    public mutating func clear() { entries.removeAll() }
}
