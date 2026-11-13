import Foundation

public enum Suggestions {
    /// Parses OpenSearch suggestion JSON: `["query", ["suggestion", ...], ...]`.
    /// Kagi, DuckDuckGo and Google all answer in this shape.
    public static func parseOpenSearch(_ data: Data, limit: Int = 8) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              root.count >= 2, let list = root[1] as? [Any]
        else { return [] }
        var seen = Set<String>()
        var out = [String]()
        for case let s as String in list {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted {
                out.append(trimmed)
                if out.count >= limit { break }
            }
        }
        return out
    }
}
