import Foundation

/// Precomputed, lowercased search key for one title.
public struct MatchKey: Sendable {
    /// Lowercased, diacritic-folded UTF-8.
    public var bytes: [UInt8]
    /// Per-byte bonus for matching at that position (word starts, camel humps).
    public var bonus: [UInt8]
    /// Bit set of the character classes present, for cheap rejection.
    public var mask: UInt64
}

/// Abbreviation matching: the query's characters must appear in order in the
/// title. Matches at word starts and consecutive runs score higher.
public enum Fuzzy {
    public static let maxTextLength = 96
    public static let maxQueryLength = 32

    static let matchScore: Int32 = 16
    static let consecutiveBonus: Int32 = 8
    static let bonusFirst: UInt8 = 12
    static let bonusWord: UInt8 = 9
    static let bonusCamel: UInt8 = 7
    static let bonusDigit: UInt8 = 5
    static let bonusAfterDot: UInt8 = 4
    static let none: Int32 = -1_000_000

    private enum CharClass { case lower, upper, digit, separator, dot, other }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    public static func makeKey(_ title: String) -> MatchKey {
        var bytes = [UInt8]()
        var bonus = [UInt8]()
        bytes.reserveCapacity(title.utf8.count)
        bonus.reserveCapacity(title.utf8.count)
        var previous = CharClass.separator
        var seenContent = false

        for scalar in fold(title).unicodeScalars {
            let cls: CharClass
            switch scalar {
            case " ", "-", "_", "/", "(", ")", "[", "]", ",", "+": cls = .separator
            case ".": cls = .dot
            case "0"..."9": cls = .digit
            default:
                let p = scalar.properties
                cls = p.isUppercase ? .upper : (p.isLowercase ? .lower : .other)
            }

            var b: UInt8 = 0
            if cls != .separator && cls != .dot {
                if !seenContent {
                    b = bonusFirst
                } else if previous == .separator {
                    b = bonusWord
                } else if previous == .dot {
                    b = bonusAfterDot
                } else if cls == .upper && previous == .lower {
                    b = bonusCamel
                } else if cls == .digit && previous != .digit {
                    b = bonusDigit
                }
                seenContent = true
            }

            var first = true
            for byte in scalar.properties.lowercaseMapping.utf8 {
                bytes.append(byte)
                bonus.append(first ? b : 0)
                first = false
            }
            previous = cls
            if bytes.count >= maxTextLength { break }
        }
        if bytes.count > maxTextLength {
            bytes.removeLast(bytes.count - maxTextLength)
            bonus.removeLast(bonus.count - maxTextLength)
        }
        return MatchKey(bytes: bytes, bonus: bonus, mask: mask(of: bytes))
    }

    /// Lowercased, folded, whitespace-stripped query bytes.
    public static func queryBytes(_ query: String) -> [UInt8] {
        var out = [UInt8]()
        for scalar in fold(query).unicodeScalars where !scalar.properties.isWhitespace {
            out.append(contentsOf: scalar.properties.lowercaseMapping.utf8)
            if out.count >= maxQueryLength { break }
        }
        if out.count > maxQueryLength { out.removeLast(out.count - maxQueryLength) }
        return out
    }

    /// The normalized form of a query, used as the key for learning and abbreviations.
    public static func normalize(_ query: String) -> String {
        String(decoding: queryBytes(query), as: UTF8.self)
    }

    @inline(__always)
    static func bit(_ b: UInt8) -> UInt64 {
        switch b {
        case 97...122: return 1 << UInt64(b - 97)        // a-z
        case 48...57: return 1 << UInt64(b - 48 + 26)    // 0-9
        case 0...127: return 1 << 36
        default: return 1 << 37
        }
    }

    public static func mask<S: Sequence>(of bytes: S) -> UInt64 where S.Element == UInt8 {
        var m: UInt64 = 0
        for b in bytes { m |= bit(b) }
        return m
    }

    /// Scores `query` against `text`. Returns nil when it is not a subsequence.
    /// `scratch` must have room for `2 * maxTextLength` values.
    @inline(__always)
    public static func score(
        query q: UnsafeBufferPointer<UInt8>,
        text t: UnsafeBufferPointer<UInt8>,
        bonus: UnsafeBufferPointer<UInt8>,
        scratch: UnsafeMutablePointer<Int32>
    ) -> Int32? {
        let n = q.count, m = t.count
        if n == 0 || n > m { return nil }

        // One character: no alignment to choose, just the best position.
        // Single-letter queries match most of the index, so this path is hot.
        if n == 1 {
            let q0 = q[0]
            var best = none
            for j in 0..<m where t[j] == q0 {
                let s = matchScore &+ Int32(bonus[j]) &- Int32(min(j, 6))
                if s > best { best = s }
            }
            if best == none { return nil }
            return m == 1 ? best &+ 24 : best &- Int32(min(m - 1, 40) / 4)
        }

        // Cheap subsequence check before the DP.
        var qi = 0
        for j in 0..<m where t[j] == q[qi] {
            qi += 1
            if qi == n { break }
        }
        if qi < n { return nil }

        var prev = scratch
        var cur = scratch + maxTextLength
        let floor = none / 2

        let q0 = q[0]
        for j in 0..<m {
            prev[j] = t[j] == q0 ? matchScore &+ Int32(bonus[j]) &- Int32(min(j, 6)) : none
        }

        // Wrapping arithmetic: values stay within a few thousand of `none`,
        // and overflow checks in this loop cost more than the loop itself.
        for i in 1..<n {
            let qc = q[i]
            // Best score of the previous row reachable through a gap ending before j.
            var gap = none
            cur[0] = none
            for j in 1..<m {
                if j >= 2 { gap = max(gap &- 1, prev[j &- 2] &- 3) }
                var best = none
                if t[j] == qc {
                    let diagonal = prev[j &- 1]
                    if diagonal > floor {
                        best = diagonal &+ matchScore &+ max(Int32(bonus[j]), consecutiveBonus)
                    }
                    if gap > floor {
                        best = max(best, gap &+ matchScore &+ Int32(bonus[j]))
                    }
                }
                cur[j] = best
            }
            swap(&prev, &cur)
        }

        var result = none
        for j in (n - 1)..<m where prev[j] > result { result = prev[j] }
        if result <= floor { return nil }
        result -= Int32(min(m - n, 40) / 4)
        if n == m { result += 24 }
        return result
    }

    /// Convenience for one-off scoring (tests, small lists).
    public static func score(query: String, title: String) -> Int32? {
        let q = queryBytes(query)
        let key = makeKey(title)
        return score(queryBytes: q, key: key)
    }

    public static func score(queryBytes q: [UInt8], key: MatchKey) -> Int32? {
        if q.isEmpty { return nil }
        if mask(of: q) & ~key.mask != 0 { return nil }
        return withUnsafeTemporaryAllocation(of: Int32.self, capacity: 2 * maxTextLength) { scratch in
            q.withUnsafeBufferPointer { qb in
                key.bytes.withUnsafeBufferPointer { tb in
                    key.bonus.withUnsafeBufferPointer { bb in
                        score(query: qb, text: tb, bonus: bb, scratch: scratch.baseAddress!)
                    }
                }
            }
        }
    }

    // MARK: - Highlighting

    /// Which bytes of `key` the best alignment of `q` uses, in ascending order.
    /// Same scoring as `score`, kept separate so the hot path carries no
    /// bookkeeping; this runs only for the rows that are shown.
    public static func matchPositions(queryBytes q: [UInt8], key: MatchKey) -> [Int] {
        let t = key.bytes, bonus = key.bonus
        let n = q.count, m = t.count
        if n == 0 || n > m { return [] }
        let floor = none / 2

        func first(_ j: Int) -> Int32 {
            t[j] == q[0] ? matchScore &+ Int32(bonus[j]) &- Int32(min(j, 6)) : none
        }
        var prev = (0..<m).map(first)
        // parent[i][j]: where query byte i-1 matched when byte i matches at j.
        var parent = [[Int]](repeating: [Int](repeating: -1, count: m), count: n)

        if n > 1 {
            for i in 1..<n {
                var cur = [Int32](repeating: none, count: m)
                var gap = none, gapFrom = -1
                for j in 1..<m {
                    if j >= 2 {
                        let fresh = prev[j - 2] &- 3
                        if fresh > gap &- 1 { gap = fresh; gapFrom = j - 2 } else { gap = gap &- 1 }
                    }
                    guard t[j] == q[i] else { continue }
                    var best = none
                    if prev[j - 1] > floor {
                        best = prev[j - 1] &+ matchScore &+ max(Int32(bonus[j]), consecutiveBonus)
                        parent[i][j] = j - 1
                    }
                    if gap > floor, gap &+ matchScore &+ Int32(bonus[j]) > best {
                        best = gap &+ matchScore &+ Int32(bonus[j])
                        parent[i][j] = gapFrom
                    }
                    cur[j] = best
                }
                prev = cur
            }
        }

        var end = -1, result = floor
        for j in (n - 1)..<m where prev[j] > result { result = prev[j]; end = j }
        guard end >= 0 else { return [] }
        var positions = [Int](repeating: 0, count: n)
        var j = end
        for i in stride(from: n - 1, through: 0, by: -1) {
            guard j >= 0 else { return [] }
            positions[i] = j
            j = parent[i][j]
        }
        return positions
    }

    /// The parts of `title` that `query` matched, as UTF-16 ranges for display.
    /// Empty when the query does not match the title.
    public static func matchRanges(query: String, title: String) -> [Range<Int>] {
        let q = queryBytes(query)
        guard !q.isEmpty else { return [] }
        let key = makeKey(title)
        guard mask(of: q) & ~key.mask == 0 else { return [] }
        let positions = matchPositions(queryBytes: q, key: key)
        guard !positions.isEmpty else { return [] }

        // The key is folded and lowercased, so its bytes do not line up with
        // the title's. Rebuild it character by character to know which
        // character each byte came from.
        var owner = [Range<Int>]()
        owner.reserveCapacity(key.bytes.count)
        var bytes = [UInt8]()
        bytes.reserveCapacity(key.bytes.count)
        var offset = 0
        for ch in title {
            let width = ch.utf16.count
            let range = offset..<(offset + width)
            offset += width
            if let ascii = ch.asciiValue {
                bytes.append(ascii >= 65 && ascii <= 90 ? ascii + 32 : ascii)
                owner.append(range)
            } else {
                for scalar in fold(String(ch)).unicodeScalars {
                    for byte in scalar.properties.lowercaseMapping.utf8 {
                        bytes.append(byte)
                        owner.append(range)
                    }
                }
            }
            if bytes.count >= key.bytes.count { break }
        }
        // If folding the whole title behaved differently from folding its
        // characters, the mapping is wrong; show no highlight rather than a wrong one.
        guard bytes.count >= key.bytes.count, bytes.prefix(key.bytes.count).elementsEqual(key.bytes) else { return [] }

        var ranges = [Range<Int>]()
        for p in positions {
            let r = owner[p]
            if let last = ranges.last, last.upperBound >= r.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                ranges.append(r)
            }
        }
        return ranges
    }
}
