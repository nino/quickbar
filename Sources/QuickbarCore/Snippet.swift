import Foundation

/// A piece of text kept for pasting or typing into other apps.
public struct Snippet: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// Optional; empty means the list shows the start of the text instead.
    public var title: String
    public var text: String

    public init(id: String = UUID().uuidString.lowercased(), title: String = "", text: String) {
        self.id = id
        self.title = title
        self.text = text
    }

    /// Hand-written entries may leave out everything but the text.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        // Derived from the text so learning keeps pointing at the same snippet
        // across launches until the file is next saved with a real id.
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? "text-\(Self.stableHash(text))"
    }

    /// FNV-1a. `hashValue` is seeded per process, so it cannot name anything on disk.
    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    public static let titleLength = 60
    public static let previewLength = 80

    /// The text on one line: runs of whitespace and line breaks become single
    /// spaces, and anything past `length` characters is cut with an ellipsis.
    public static func preview(_ text: String, length: Int) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > length else { return line }
        return line.prefix(length).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// What lists show: the title, or the start of the text when there is none.
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.preview(text, length: Self.titleLength) : trimmed
    }

    public var hasTitle: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func itemID(_ id: String) -> String { "snippet:\(id)" }

    /// The row for the index, or nil while the snippet has nothing to insert.
    public var item: Item? {
        guard !text.isEmpty, !displayTitle.isEmpty else { return nil }
        return Item(
            id: Self.itemID(id), title: displayTitle,
            subtitle: hasTitle ? Self.preview(text, length: Self.previewLength) : "",
            kind: .snippet, payload: text)
    }
}
