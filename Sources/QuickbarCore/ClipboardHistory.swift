import Foundation

/// One thing that was copied: text (possibly with rich-text forms), an image,
/// or files. Data other than plain text lives in files next to the history;
/// the entry only names them.
public struct ClipboardEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, image, files }

    /// One pasteboard representation stored on disk.
    public struct Payload: Codable, Equatable, Sendable {
        /// Pasteboard type, e.g. "public.png" or "public.rtf".
        public var type: String
        /// File name inside the clipboard data folder.
        public var file: String
        public var bytes: Int

        public init(type: String, file: String, bytes: Int) {
            self.type = type
            self.file = file
            self.bytes = bytes
        }
    }

    public var id: String
    public var kind: Kind
    /// The plain text; for files the paths, one per line; may be empty for images.
    public var text: String
    public var date: Date
    public var payloads: [Payload]
    /// Paths of the copied files (`kind == .files`).
    public var files: [String]
    /// Pixel size and content hash of an image (`kind == .image`).
    public var width: Int?
    public var height: Int?
    public var hash: String?

    public init(text: String, date: Date = Date()) {
        self.init(kind: .text, text: text, date: date)
    }

    public init(id: String = UUID().uuidString, kind: Kind, text: String = "", date: Date = Date(),
                payloads: [Payload] = [], files: [String] = [], width: Int? = nil, height: Int? = nil, hash: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.date = date
        self.payloads = payloads
        self.files = files
        self.width = width
        self.height = height
        self.hash = hash
    }

    /// Histories written before images and files were supported hold only text and date.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        payloads = try c.decodeIfPresent([Payload].self, forKey: .payloads) ?? []
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        hash = try c.decodeIfPresent(String.self, forKey: .hash)
    }

    /// Two entries with the same key are the same copied thing.
    public var key: String {
        Self.key(kind: kind, text: text, files: files, hash: hash)
    }

    public static func key(kind: Kind, text: String = "", files: [String] = [], hash: String? = nil) -> String {
        switch kind {
        case .text: return "t:" + text
        case .image: return "i:" + (hash ?? "")
        case .files: return "f:" + files.joined(separator: "\n")
        }
    }

    public var payloadBytes: Int { payloads.reduce(0) { $0 + $1.bytes } }

    /// Single-line preview for list display.
    public var preview: String {
        switch kind {
        case .image:
            if let width, let height { return "Image  \(width) × \(height)" }
            return "Image"
        case .files:
            let names = files.map { ($0 as NSString).lastPathComponent }
            if names.count == 1 { return names[0] }
            return "\(names.count) files: " + names.prefix(4).joined(separator: ", ") + (names.count > 4 ? ", …" : "")
        case .text:
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
}

/// Most-recent-first list of copied things, deduplicated and capped.
/// Methods that drop entries return them, so their stored data can be deleted.
public struct ClipboardHistory: Codable, Equatable, Sendable {
    public private(set) var entries: [ClipboardEntry] = []
    public var maxEntries: Int
    /// Text larger than this is not kept.
    public static let maxEntryBytes = 1_000_000

    public init(maxEntries: Int = 100) {
        self.maxEntries = maxEntries
    }

    public enum Promotion: Sendable { case alreadyFirst, moved, absent }

    /// If something with this key is already in the history, makes it the
    /// newest entry instead of storing it again.
    public mutating func promote(key: String, date: Date = Date()) -> Promotion {
        if entries.first?.key == key { return .alreadyFirst }
        guard let i = entries.firstIndex(where: { $0.key == key }) else { return .absent }
        var entry = entries.remove(at: i)
        entry.date = date
        entries.insert(entry, at: 0)
        return .moved
    }

    /// Puts a new entry at the front. Returns the entries pushed out by the cap.
    public mutating func insert(_ entry: ClipboardEntry) -> [ClipboardEntry] {
        entries.insert(entry, at: 0)
        guard entries.count > maxEntries else { return [] }
        let dropped = Array(entries[max(maxEntries, 0)...])
        entries.removeLast(dropped.count)
        return dropped
    }

    /// Adds `text` at the front, moving it up if already present. Returns false if ignored.
    @discardableResult
    public mutating func add(_ text: String, date: Date = Date()) -> Bool {
        guard Self.isKeepable(text) else { return false }
        switch promote(key: ClipboardEntry.key(kind: .text, text: text), date: date) {
        case .alreadyFirst: return false
        case .moved: return true
        case .absent:
            _ = insert(ClipboardEntry(text: text, date: date))
            return true
        }
    }

    public static func isKeepable(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= maxEntryBytes && text.contains(where: { !$0.isWhitespace })
    }

    /// Drops the oldest entries that have stored data until the total is
    /// within `budget` bytes. The newest entry is never dropped.
    public mutating func trimPayloads(toBytes budget: Int) -> [ClipboardEntry] {
        var total = entries.reduce(0) { $0 + $1.payloadBytes }
        var dropped = [ClipboardEntry]()
        var i = entries.count - 1
        while total > budget, i > 0 {
            if entries[i].payloadBytes > 0 {
                total -= entries[i].payloadBytes
                dropped.append(entries.remove(at: i))
            }
            i -= 1
        }
        return dropped
    }

    @discardableResult
    public mutating func remove(at index: Int) -> ClipboardEntry? {
        guard entries.indices.contains(index) else { return nil }
        return entries.remove(at: index)
    }

    /// Removes entries the caller found unusable (their stored data is gone).
    public mutating func removeAll(where shouldRemove: (ClipboardEntry) -> Bool) {
        entries.removeAll(where: shouldRemove)
    }

    @discardableResult
    public mutating func clear() -> [ClipboardEntry] {
        defer { entries.removeAll() }
        return entries
    }
}
