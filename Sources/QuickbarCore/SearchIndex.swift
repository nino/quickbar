import Foundation

public struct SearchHit: Sendable {
    public let item: Item
    public let score: Int32
}

/// Immutable snapshot of everything searchable. Built on a background queue,
/// then swapped in whole; searching never locks.
public final class SearchIndex: Sendable {
    public let items: [Item]
    private let keyBytes: [UInt8]
    private let bonusBytes: [UInt8]
    /// `offsets[i]..<offsets[i+1]` is item i's range in the blobs.
    private let offsets: [UInt32]
    private let masks: [UInt64]
    private let kindBonuses: [Int32]
    private let idToIndex: [String: Int]

    public static let empty = SearchIndex(items: [])

    public init(items: [Item]) {
        var seen = Set<String>()
        var unique = [Item]()
        unique.reserveCapacity(items.count)
        for item in items where seen.insert(item.id).inserted { unique.append(item) }

        var keyBytes = [UInt8]()
        var bonusBytes = [UInt8]()
        var offsets = [UInt32]()
        var masks = [UInt64]()
        var idToIndex = [String: Int](minimumCapacity: unique.count)
        offsets.reserveCapacity(unique.count + 1)
        masks.reserveCapacity(unique.count)
        offsets.append(0)
        for (i, item) in unique.enumerated() {
            let key = Fuzzy.makeKey(item.title)
            keyBytes.append(contentsOf: key.bytes)
            bonusBytes.append(contentsOf: key.bonus)
            offsets.append(UInt32(keyBytes.count))
            masks.append(key.mask)
            idToIndex[item.id] = i
        }
        self.items = unique
        self.keyBytes = keyBytes
        self.bonusBytes = bonusBytes
        self.offsets = offsets
        self.masks = masks
        self.kindBonuses = unique.map { Self.kindBonus($0.kind) }
        self.idToIndex = idToIndex
    }

    public func item(withID id: String) -> Item? {
        idToIndex[id].map { items[$0] }
    }

    static func kindBonus(_ kind: ItemKind) -> Int32 {
        switch kind {
        case .app: return 6
        case .searchTemplate: return 4
        case .folder, .action, .setting: return 2
        default: return 0
        }
    }

    /// How many previously opened matches may be added beyond `limit`.
    static let maxUsedExtras = 10

    public func search(_ query: String, bonus: LearningBonus = .none, limit: Int = 50) -> [SearchHit] {
        let q = Fuzzy.queryBytes(query)
        if q.isEmpty || items.isEmpty { return [] }
        let qmask = Fuzzy.mask(of: q)
        var scored = [(score: Int32, index: Int32)]()

        withUnsafeTemporaryAllocation(of: Int32.self, capacity: 2 * Fuzzy.maxTextLength) { scratch in
            q.withUnsafeBufferPointer { qb in
                keyBytes.withUnsafeBufferPointer { kb in
                    bonusBytes.withUnsafeBufferPointer { bb in
                        masks.withUnsafeBufferPointer { mb in
                            offsets.withUnsafeBufferPointer { ob in
                                for i in 0..<mb.count where qmask & ~mb[i] == 0 {
                                    let start = Int(ob[i]), end = Int(ob[i + 1])
                                    let text = UnsafeBufferPointer(rebasing: kb[start..<end])
                                    let bon = UnsafeBufferPointer(rebasing: bb[start..<end])
                                    if let s = Fuzzy.score(query: qb, text: text, bonus: bon, scratch: scratch.baseAddress!) {
                                        scored.append((s, Int32(i)))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Ranking touches only flat arrays; copying `Item`s here would dominate
        // the cost for short queries that match thousands of titles.
        let useLearning = !bonus.isEmpty
        // Matches that have been opened before; kept even when they fall below
        // the cut, so any used item can be reached, chosen and so learned for
        // a new abbreviation.
        var used = [(score: Int32, index: Int32)]()
        let adjustments = useLearning ? bonus.resolved(using: idToIndex) : [:]
        for k in scored.indices {
            let i = Int(scored[k].index)
            scored[k].score += kindBonuses[i]
            if let adjust = adjustments[i] {
                scored[k].score += adjust.bonus
                if adjust.used { used.append(scored[k]) }
            }
        }

        // Short queries match most of the index but only `limit` rows are shown:
        // find the score of the limit-th best with a histogram and drop the rest
        // before sorting.
        if scored.count > 4 * limit {
            var lo = Int32.max, hi = Int32.min
            for s in scored { lo = min(lo, s.score); hi = max(hi, s.score) }
            var counts = [Int](repeating: 0, count: Int(hi - lo) + 1)
            for s in scored { counts[Int(s.score - lo)] += 1 }
            var kept = 0, cutoff = hi
            while cutoff > lo {
                kept += counts[Int(cutoff - lo)]
                if kept >= limit { break }
                cutoff -= 1
            }
            scored.removeAll { $0.score < cutoff }
        }

        // Ties: shorter title first, then index order (applications come first).
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let la = offsets[Int(a.index) + 1] - offsets[Int(a.index)]
            let lb = offsets[Int(b.index) + 1] - offsets[Int(b.index)]
            if la != lb { return la < lb }
            return a.index < b.index
        }
        var top = Array(scored.prefix(limit))
        if !used.isEmpty, scored.count > limit || top.count < used.count {
            let shown = Set(top.map(\.index))
            let extra = used.filter { !shown.contains($0.index) }.sorted { $0.score > $1.score }
            top.append(contentsOf: extra.prefix(Self.maxUsedExtras))
        }
        return top.map { SearchHit(item: items[Int($0.index)], score: $0.score) }
    }
}
