import AppKit
import QuickbarCore

/// Drives the launcher from the command line without showing it, so changes
/// can be checked without a human at the keyboard:
///
///     Quickbar --script "type:saf" "key:down" --dump --snapshot /tmp/out.png
///     Quickbar --bench
///
/// Steps: `type:<text>`, `key:<up|down|left|right|tab|return|backspace>`, `wait:<seconds>`.
/// `--dump` prints the rows; `--snapshot` renders the panel to a PNG
/// (`--dark` in dark mode, `--clipboard` the clipboard panel with sample entries).
/// In this mode no hotkeys are registered and the clipboard is not watched.
enum DebugHarness {
    private static let args = Array(CommandLine.arguments.dropFirst())
    static var isActive: Bool { args.contains("--script") || args.contains("--bench") }
    private static weak var launcher: LauncherController?
    private static var started = false
    private static var updates = 0

    static func start(launcher: LauncherController) {
        self.launcher = launcher
    }

    static func indexReady() {
        // The first update carries applications only; wait for the full index.
        updates += 1
        guard isActive, !started, updates >= 2 else { return }
        started = true
        if args.contains("--bench") {
            bench()
            exit(0)
        }
        runScript()
    }

    private static func value(after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func bench() {
        let index = IndexManager.shared.index
        print("items: \(index.items.count)")
        if args.contains("--spin") {
            let end = Date().addingTimeInterval(6)
            while Date() < end { _ = index.search("s") }
        }
        let clock = ContinuousClock()
        for q in ["s", "sa", "saf", "term", "vsc", "xyzzy", "documents", "a b c"] {
            var best = Duration.seconds(1)
            var count = 0
            for _ in 0..<20 {
                let d = clock.measure { count = index.search(q, bonus: Learning.store.bonus(for: q)).count }
                best = min(best, d)
            }
            let micros = Double(best.components.attoseconds) / 1e12
            print(String(format: "%-12@ %4d hits  %7.1f µs", q as NSString, count, micros))
        }
    }

    private static func runScript() {
        guard let launcher, let start = args.firstIndex(of: "--script") else { exit(1) }
        let steps = args[(start + 1)...].prefix { !$0.hasPrefix("--") }
        if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        launcher.panel.position(height: LauncherController.barHeight)

        var delay = 0.0
        for step in steps {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1] : ""
            if parts[0] == "wait" {
                delay += Double(argument) ?? 0.5
                continue
            }
            delay += 0.25
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                switch parts[0] {
                case "type": launcher.debugType(argument)
                case "key": launcher.debugSendCommand(selector(for: argument))
                default: print("unknown step \(step)")
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.4) {
            if args.contains("--dump") {
                for (i, row) in launcher.debugRows.enumerated() {
                    let mark = i == launcher.debugSelectedRow ? ">" : " "
                    print("\(mark) [\(row.kind.rawValue)] \(row.title)  |  \(row.subtitle)")
                }
            }
            if let path = value(after: "--snapshot") {
                if args.contains("--clipboard"), let clipboard = AppDelegate.shared?.clipboardPanel {
                    let texts = ["git commit --amend --no-edit", "https://kagi.com/search?q=swift+concurrency",
                                 "func handleEvents(_ events: [(path: String, flags: FSEventStreamEventFlags)]) {\n    let relevant = events.contains { event in\n        event.flags & structural != 0\n    }\n}",
                                 "Meeting moved to Thursday 15:00", "41e3175"]
                    let sample = texts.enumerated().map { ClipboardEntry(text: $1, date: Date().addingTimeInterval(-Double($0 * $0) * 400)) }
                    snapshot(clipboard.debugPresent(sample), to: path)
                } else {
                    snapshot(launcher.panel, to: path)
                }
            }
            exit(0)
        }
    }

    private static func selector(for key: String) -> Selector {
        switch key {
        case "up": return #selector(NSResponder.moveUp(_:))
        case "down": return #selector(NSResponder.moveDown(_:))
        case "left": return #selector(NSResponder.moveLeft(_:))
        case "right": return #selector(NSResponder.moveRight(_:))
        case "tab": return #selector(NSResponder.insertTab(_:))
        case "backspace": return #selector(NSResponder.deleteBackward(_:))
        default: return #selector(NSResponder.insertNewline(_:))
        }
    }

    private static func snapshot(_ panel: NSPanel, to path: String) {
        guard let view = panel.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // The blur behind the panel is not captured; put a plain background under it.
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
        }
        rep.draw(in: view.bounds)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("snapshot: \(path)")
    }
}
