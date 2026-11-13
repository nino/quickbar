import Foundation

/// Score adjustments for one query, computed once per search.
public struct LearningBonus: Sendable {
    var perItem: [String: Int32]
    var uses: [String: Int]

    public static let none = LearningBonus(perItem: [:], uses: [:])

    public var isEmpty: Bool { perItem.isEmpty && uses.isEmpty }

    /// Something opened before outranks something never opened unless the
    /// never-opened one is a clearly better match: the base bonus is about the
    /// gap between a mid-word and a word-start match of one letter.
    @inline(__always)
    public func value(for id: String) -> Int32 {
        adjustment(for: id).bonus
    }

    @inline(__always)
    func adjustment(for id: String) -> (bonus: Int32, used: Bool) {
        var v = perItem[id] ?? 0
        guard let u = uses[id], u > 0 else { return (v, false) }
        v += 18 + min(Int32(log2(Double(u + 1)) * 3), 15)
        return (v, true)
    }

    /// The same adjustments keyed by position in an index. Search matches
    /// thousands of items for short queries but only a handful have a bonus,
    /// so it looks these few up once instead of hashing every match's id.
    func resolved(using idToIndex: [String: Int]) -> [Int: (bonus: Int32, used: Bool)] {
        var out = [Int: (bonus: Int32, used: Bool)](minimumCapacity: perItem.count + uses.count)
        for id in perItem.keys {
            if let i = idToIndex[id] { out[i] = adjustment(for: id) }
        }
        for id in uses.keys where perItem[id] == nil {
            if let i = idToIndex[id] { out[i] = adjustment(for: id) }
        }
        return out
    }
}

/// Remembers which item was chosen for which typed abbreviation.
///
/// Each (abbreviation, item) pair has a count from 0 to `maxCount`. Choosing an
/// item raises its count and lowers every rival's for that abbreviation by one,
/// so three choices in a row always take over the top spot, and one stray
/// choice does not undo an established habit.
public final class LearningStore: @unchecked Sendable {
    public static let maxCount = 5
    /// Count at which an item is pinned to the top for its abbreviation.
    public static let dominantCount = 3

    struct Stored: Codable {
        var abbreviations: [String: [String: Int]] = [:]
        var uses: [String: Int] = [:]
    }

    private let lock = NSLock()
    private var stored = Stored()

    public init() {}

    public init(data: Data) throws {
        stored = try JSONDecoder().decode(Stored.self, from: data)
    }

    public func encoded() -> Data {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(stored)) ?? Data()
    }

    public func record(query: String, itemID: String) {
        let q = Fuzzy.normalize(query)
        lock.lock(); defer { lock.unlock() }
        stored.uses[itemID, default: 0] += 1
        guard !q.isEmpty else { return }
        var counts = stored.abbreviations[q] ?? [:]
        for (id, c) in counts where id != itemID {
            counts[id] = c > 1 ? c - 1 : nil
        }
        counts[itemID] = min((counts[itemID] ?? 0) + 1, Self.maxCount)
        stored.abbreviations[q] = counts
    }

    /// Counts a use without teaching an abbreviation (e.g. opened while browsing).
    public func recordUse(itemID: String) {
        lock.lock(); defer { lock.unlock() }
        stored.uses[itemID, default: 0] += 1
    }

    public func forget(query: String, itemID: String) {
        lock.lock(); defer { lock.unlock() }
        stored.abbreviations[query]?[itemID] = nil
        if stored.abbreviations[query]?.isEmpty == true { stored.abbreviations[query] = nil }
    }

    public struct Learned: Identifiable, Hashable, Sendable {
        public var query: String
        public var itemID: String
        public var count: Int
        public var id: String { query + "\u{0}" + itemID }
    }

    public func learned() -> [Learned] {
        lock.lock(); defer { lock.unlock() }
        return stored.abbreviations
            .flatMap { q, counts in counts.map { Learned(query: q, itemID: $0.key, count: $0.value) } }
            .sorted { ($0.query, -$0.count, $0.itemID) < ($1.query, -$1.count, $1.itemID) }
    }

    public func bonus(for query: String) -> LearningBonus {
        let q = Fuzzy.normalize(query)
        lock.lock(); defer { lock.unlock() }
        var perItem = [String: Int32]()
        if !q.isEmpty {
            for (learnedQuery, counts) in stored.abbreviations {
                if learnedQuery == q {
                    for (id, c) in counts {
                        let b: Int32 = c >= Self.dominantCount ? 1000 + Int32(c) : (c == 2 ? 25 : 10)
                        perItem[id, default: 0] += b
                    }
                } else if learnedQuery.hasPrefix(q) || q.hasPrefix(learnedQuery) {
                    // Related abbreviations nudge: "saf" learned helps "sa".
                    for (id, c) in counts {
                        perItem[id, default: 0] += Int32(min(c, 3)) * 3
                    }
                }
            }
        }
        return LearningBonus(perItem: perItem, uses: stored.uses)
    }
}
