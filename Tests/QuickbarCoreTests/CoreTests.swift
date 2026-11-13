import Foundation
import Testing
@testable import QuickbarCore

private func app(_ name: String) -> Item {
    Item(id: "/Applications/\(name).app", title: name, kind: .app, path: "/Applications/\(name).app")
}

@Suite struct FuzzyTests {
    @Test func subsequenceRequired() {
        #expect(Fuzzy.score(query: "xyz", title: "Safari") == nil)
        #expect(Fuzzy.score(query: "sfr", title: "Safari") != nil)
        #expect(Fuzzy.score(query: "safarii", title: "Safari") == nil)
    }

    @Test func caseAndDiacriticsIgnored() {
        #expect(Fuzzy.score(query: "CAFE", title: "Café") != nil)
        #expect(Fuzzy.score(query: "é", title: "Cafe") != nil)
    }

    @Test func spacesInQueryIgnored() {
        #expect(Fuzzy.score(query: "vs code", title: "Visual Studio Code") != nil)
    }

    @Test func wordStartsBeatMidWord() {
        let initials = Fuzzy.score(query: "vsc", title: "Visual Studio Code")!
        let scattered = Fuzzy.score(query: "vsc", title: "Invoices Archive")!
        #expect(initials > scattered)
    }

    @Test func prefixBeatsLaterMatch() {
        #expect(Fuzzy.score(query: "r", title: "Reminders")! > Fuzzy.score(query: "r", title: "Brave Browser")!)
    }

    @Test func shorterTitleWinsOnEqualMatch() {
        #expect(Fuzzy.score(query: "saf", title: "Safari")! > Fuzzy.score(query: "saf", title: "Safari Technology Preview")!)
    }

    @Test func camelHumps() {
        #expect(Fuzzy.score(query: "gb", title: "GarageBand")! > Fuzzy.score(query: "gb", title: "Algebra")!)
    }

    @Test func longInputsDoNotCrash() {
        let long = String(repeating: "abc def ", count: 100)
        _ = Fuzzy.score(query: String(repeating: "a", count: 200), title: long)
        _ = Fuzzy.score(query: "abc", title: long)
        _ = Fuzzy.score(query: "日本", title: "日本語のファイル")
    }
}

@Suite struct IndexTests {
    let index = SearchIndex(items: ["Safari", "Brave Browser", "Reminders", "Rectangle", "Xcode", "Terminal"].map(app))

    @Test func ranksBestFirst() {
        #expect(index.search("saf").first?.item.title == "Safari")
        #expect(index.search("xc").first?.item.title == "Xcode")
        #expect(index.search("zzz").isEmpty)
        #expect(index.search("").isEmpty)
    }

    @Test func appsOutrankFilesOnEqualMatch() {
        let idx = SearchIndex(items: [
            Item(id: "/tmp/Notes", title: "Notes", kind: .file, path: "/tmp/Notes"),
            app("Notes"),
        ])
        #expect(idx.search("notes").first?.item.kind == .app)
    }

    @Test func duplicateIDsCollapsed() {
        let idx = SearchIndex(items: [app("Safari"), app("Safari")])
        #expect(idx.items.count == 1)
    }

    @Test func threeSelectionsTakeOver() {
        let learning = LearningStore()
        let brave = app("Brave Browser")
        #expect(index.search("r", bonus: learning.bonus(for: "r")).first?.item.title != brave.title)
        for _ in 0..<3 { learning.record(query: "r", itemID: brave.id) }
        #expect(index.search("r", bonus: learning.bonus(for: "r")).first?.item.title == brave.title)
    }

    @Test func relearningFlipsInThree() {
        let learning = LearningStore()
        let brave = app("Brave Browser"), reminders = app("Reminders")
        for _ in 0..<10 { learning.record(query: "r", itemID: brave.id) }
        // One stray choice does not undo the habit.
        learning.record(query: "r", itemID: reminders.id)
        #expect(index.search("r", bonus: learning.bonus(for: "r")).first?.item.title == brave.title)
        learning.record(query: "r", itemID: reminders.id)
        learning.record(query: "r", itemID: reminders.id)
        #expect(index.search("r", bonus: learning.bonus(for: "r")).first?.item.title == reminders.title)
    }

    @Test func learningRoundTrips() throws {
        let learning = LearningStore()
        for _ in 0..<3 { learning.record(query: "R", itemID: "/Applications/Brave Browser.app") }
        let restored = try LearningStore(data: learning.encoded())
        #expect(restored.learned() == [.init(query: "r", itemID: "/Applications/Brave Browser.app", count: 3)])
        restored.forget(query: "r", itemID: "/Applications/Brave Browser.app")
        #expect(restored.learned().isEmpty)
    }

    @Test func searchIsFastOnLargeIndex() {
        var names = [Item]()
        var rng = SystemRandomNumberGenerator()
        let words = ["report", "Invoice", "photo", "Project", "notes", "Final", "draft", "budget", "Screenshot", "meeting"]
        for i in 0..<50_000 {
            let a = words.randomElement(using: &rng)!, b = words.randomElement(using: &rng)!
            names.append(Item(id: "/f/\(i)", title: "\(a) \(b) \(i).txt", kind: .file, path: "/f/\(i)"))
        }
        let big = SearchIndex(items: names)
        let clock = ContinuousClock()
        var worst = Duration.zero
        for q in ["r", "rp", "inv", "pnf", "screenshot 4", "budget meeting 123"] {
            let d = clock.measure { _ = big.search(q) }
            worst = max(worst, d)
        }
        // Generous for debug builds; release is ~10x faster.
        #expect(worst < .milliseconds(400))
    }
}

@Suite struct CalculatorTests {
    @Test(arguments: [
        ("2+2", "4"), ("2 + 3 * 4", "14"), ("(2+3)*4", "20"), ("2^10", "1024"), ("-3^2", "-9"),
        ("10/4", "2.5"), ("1/3", "0.3333333333"), ("sqrt(16)+1", "5"), ("2pi", "6.283185307"),
        ("10 % 3", "1"), ("50% * 80", "40"), ("200 * 15%", "30"), ("5!", "120"), ("0x10 + 1", "17"),
        ("1e3 * 2", "2000"), ("max(1, 5, 3) - min(2, 0)", "5"), ("2(3+4)", "14"), ("=7*6", "42"),
        ("1.5 + 1.5", "3"), ("2 × 3 ÷ 4", "1.5"),
    ])
    func evaluates(_ input: String, _ expected: String) {
        #expect(Calculator.evaluate(input)?.formatted == expected)
    }

    @Test(arguments: ["42", "pi", "hello", "2+", "1password", "7-zip", "a-b", "", "(", "2024-report", "1/0", "..", "3d"])
    func rejects(_ input: String) {
        #expect(Calculator.evaluate(input) == nil)
    }

    @Test func deepNestingDoesNotCrash() {
        #expect(Calculator.evaluate(String(repeating: "(", count: 200) + "1+1") == nil)
        #expect(Calculator.evaluate(String(repeating: "-", count: 250) + "1+1") == nil)
    }
}

@Suite struct URLTests {
    @Test(arguments: [
        ("https://example.com/a?b=c", "https://example.com/a?b=c", true),
        ("example.com", "https://example.com", true),
        ("kagi.com/search?q=x", "https://kagi.com/search?q=x", true),
        ("localhost:3000", "http://localhost:3000", true),
        ("192.168.1.1", "http://192.168.1.1", true),
        ("notes.txt", "https://notes.txt", false),
        ("obsidian://open?vault=x", "obsidian://open?vault=x", true),
    ])
    func detects(_ input: String, _ expected: String, _ strong: Bool) {
        let d = URLDetector.detect(input)
        #expect(d?.url.absoluteString == expected)
        #expect(d?.isStrong == strong)
    }

    @Test(arguments: ["hello", "hello world.com", "1.5", "2+2", "localhost", "foo.", ".com", "a.b", "://x", "3.14.15"])
    func rejects(_ input: String) {
        #expect(URLDetector.detect(input) == nil)
    }
}

@Suite struct ConfigTests {
    @Test func missingKeysTakeDefaults() {
        let c = Config.decode(Data(#"{"retypeDelay": 2.5}"#.utf8))!
        #expect(c.retypeDelay == 2.5)
        #expect(c.hotKey == Config().hotKey)
        #expect(c.searchTemplates == [.kagi])
    }

    @Test func roundTrips() {
        var c = Config()
        c.abbreviations = [.init(abbreviation: "R", target: "/Applications/Brave Browser.app")]
        #expect(Config.decode(c.encoded()) == c)
        #expect(c.abbreviationTargets(for: "r") == ["/Applications/Brave Browser.app"])
        #expect(c.abbreviationTargets(for: "re").isEmpty)
    }

    @Test func templateEncodesQuery() {
        #expect(SearchTemplate.kagi.searchURL(for: "c++ & rust?")?.absoluteString
            == "https://kagi.com/search?q=c%2B%2B%20%26%20rust%3F")
    }

    @Test func hotKeyDisplay() {
        #expect(Config().hotKey.displayString == "⌥Space")
        #expect(Config().clipboardHotKey.displayString == "⌘\\")
    }
}

@Suite struct ClipboardTests {
    @Test func dedupesAndCaps() {
        var h = ClipboardHistory(maxEntries: 3)
        let results = [h.add("a"), h.add("b"), h.add("b"), h.add("a")]
        #expect(results == [true, true, false, true])
        #expect(h.entries.map(\.text) == ["a", "b"])
        h.add("c"); h.add("d")
        #expect(h.entries.map(\.text) == ["d", "c", "a"])
        let ignored = [h.add("   \n"), h.add("")]
        #expect(ignored == [false, false])
    }

    @Test func previewCollapsesWhitespace() {
        #expect(ClipboardEntry(text: "  a\n\n  b\tc ").preview == "a b c")
    }
}

@Suite struct SuggestionTests {
    @Test func parsesOpenSearch() {
        let data = Data(#"["swift",["swift concurrency","Swift Concurrency","swift ui"]]"#.utf8)
        #expect(Suggestions.parseOpenSearch(data) == ["swift concurrency", "swift ui"])
        #expect(Suggestions.parseOpenSearch(Data("garbage".utf8)).isEmpty)
    }
}

@Suite struct ScannerTests {
    @Test func scansToDepth() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("quickbar-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("a/b/c"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("node_modules/x"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("a/file.txt"))
        try Data().write(to: root.appendingPathComponent(".hidden"))
        defer { try? fm.removeItem(at: root) }

        let depth1 = FileScanner.scanFolder(root: root.path, depth: 1, excluding: ["node_modules"])
        #expect(Set(depth1.map(\.title)) == [root.lastPathComponent, "a"])
        let depth2 = FileScanner.scanFolder(root: root.path, depth: 2, excluding: ["node_modules"])
        #expect(Set(depth2.map(\.title)) == [root.lastPathComponent, "a", "b", "file.txt"])
        #expect(FileScanner.listDirectory(root.appendingPathComponent("a").path).map(\.title) == ["b", "file.txt"])
    }
}

@Suite struct HighlightTests {
    private func marked(_ query: String, _ title: String) -> String {
        let utf16 = Array(title.utf16)
        var out = ""
        var i = 0
        for r in Fuzzy.matchRanges(query: query, title: title) {
            out += String(decoding: utf16[i..<r.lowerBound], as: UTF16.self)
            out += "[" + String(decoding: utf16[r], as: UTF16.self) + "]"
            i = r.upperBound
        }
        return out + String(decoding: utf16[i...], as: UTF16.self)
    }

    @Test func prefersWordStarts() {
        #expect(marked("vsc", "Visual Studio Code") == "[V]isual [S]tudio [C]ode")
        #expect(marked("saf", "Safari") == "[Saf]ari")
        #expect(marked("r", "Brave Browser") == "B[r]ave Browser")
    }

    @Test func noMatchGivesNoRanges() {
        #expect(Fuzzy.matchRanges(query: "xyz", title: "Safari").isEmpty)
        #expect(Fuzzy.matchRanges(query: "", title: "Safari").isEmpty)
    }

    @Test func nonASCIITitlesMapBackToCharacters() {
        #expect(marked("cafe", "Café Notes") == "[Café] Notes")
        #expect(marked("pdf", "年8月 report.pdf") == "年8月 report.[pdf]")
        #expect(marked("uber", "Über uns") == "[Über] uns")
    }

    @Test func alignmentAgreesWithScore() {
        // The highlighted alignment must be one that reaches the reported score:
        // every highlighted character is a query character, in order.
        for (q, title) in [("term", "Terminal"), ("ss", "System Settings"), ("abc", "a b c abc"), ("gd", "Google Drive Docs")] {
            let key = Fuzzy.makeKey(title)
            let positions = Fuzzy.matchPositions(queryBytes: Fuzzy.queryBytes(q), key: key)
            #expect(positions.count == q.utf8.count)
            #expect(positions == positions.sorted())
            #expect(positions.map { key.bytes[$0] } == Array(q.utf8))
        }
    }
}
