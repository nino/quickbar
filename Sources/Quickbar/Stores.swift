import AppKit
import QuickbarCore

enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Quickbar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static let config = support.appendingPathComponent("config.json")
    static let learning = support.appendingPathComponent("learning.json")
    static let clipboard = support.appendingPathComponent("clipboard.json")
}

/// All disk writes go through here so the main thread never touches the disk.
enum Disk {
    static let queue = DispatchQueue(label: "quickbar.disk", qos: .utility)

    static func write(_ data: @autoclosure @escaping () -> Data, to url: URL, privateFile: Bool = false) {
        // Scripted runs must not touch the user's real settings or history.
        if DebugHarness.isActive { return }
        queue.async {
            do {
                try data().write(to: url, options: .atomic)
                if privateFile {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
            } catch {
                Log.info("failed to write \(url.lastPathComponent): \(error)")
            }
        }
    }
}

/// Coalesces bursts of calls into one, `delay` after the last.
final class Debouncer {
    private var work: DispatchWorkItem?
    private let delay: TimeInterval
    private let queue: DispatchQueue

    init(delay: TimeInterval, queue: DispatchQueue = .main) {
        self.delay = delay
        self.queue = queue
    }

    func call(_ block: @escaping () -> Void) {
        work?.cancel()
        let item = DispatchWorkItem(block: block)
        work = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

/// The user's configuration. Main thread only; background work takes a copy.
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var config: Config {
        didSet {
            guard config != oldValue else { return }
            if !isReloading { saver.call { [config] in Disk.write(config.encoded(), to: AppPaths.config) } }
            onChange?(oldValue, config)
        }
    }
    var onChange: ((_ old: Config, _ new: Config) -> Void)?
    let isFirstRun: Bool
    private var isReloading = false
    private let saver = Debouncer(delay: 0.3)

    private init() {
        // Read once at launch, before the UI exists. The file is tiny.
        if let data = try? Data(contentsOf: AppPaths.config), let loaded = Config.decode(data) {
            config = loaded
            isFirstRun = false
        } else {
            config = Config()
            isFirstRun = !FileManager.default.fileExists(atPath: AppPaths.config.path)
            if isFirstRun { Disk.write(Config().encoded(), to: AppPaths.config) }
        }
    }

    /// Re-reads config.json after a hand edit.
    func reload() {
        Disk.queue.async {
            guard let data = try? Data(contentsOf: AppPaths.config), let loaded = Config.decode(data) else {
                Log.info("config.json is missing or invalid; keeping current settings")
                return
            }
            DispatchQueue.main.async {
                self.isReloading = true
                self.config = loaded
                self.isReloading = false
            }
        }
    }
}

enum Learning {
    static let store: LearningStore = {
        if let data = try? Data(contentsOf: AppPaths.learning), let s = try? LearningStore(data: data) { return s }
        return LearningStore()
    }()
    private static let saver = Debouncer(delay: 1.0)

    static func save() {
        saver.call { Disk.write(store.encoded(), to: AppPaths.learning) }
    }
}
