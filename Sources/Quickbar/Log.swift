import Foundation

/// Appends to ~/Library/Logs/Quickbar.log on a background queue.
/// `debug` lines are written only when launched with QUICKBAR_DEBUG=1:
///
///     open --env QUICKBAR_DEBUG=1 build/Quickbar.app
enum Log {
    static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Quickbar.log")
    private static let queue = DispatchQueue(label: "quickbar.log", qos: .utility)
    private static let debugEnabled = ProcessInfo.processInfo.environment["QUICKBAR_DEBUG"] == "1"
    private static let maxBytes = 1_000_000
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: @autoclosure () -> String) {
        write(message())
    }

    static func debug(_ message: @autoclosure () -> String) {
        if debugEnabled { write(message()) }
    }

    private static func write(_ message: String) {
        let date = Date()
        queue.async {
            let line = "\(formatter.string(from: date)) \(message)\n"
            if DebugHarness.isActive {
                FileHandle.standardError.write(Data(line.utf8))
                return
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > maxBytes { try? FileManager.default.removeItem(at: url) }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
