import AppKit
import QuickbarCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

    private(set) var launcher: LauncherController!
    private(set) var clipboardPanel: ClipboardPanelController!

    private enum HotKeyID {
        static let launcher: UInt32 = 1
        static let clipboard: UInt32 = 2
        static let clipboardReverse: UInt32 = 3
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        buildMenu()

        let store = ConfigStore.shared
        launcher = LauncherController()
        clipboardPanel = ClipboardPanelController()
        launcher.actionHandler = { [weak self] in self?.perform(action: $0) }

        IndexManager.shared.onUpdate = { [weak self] in
            self?.launcher.indexDidUpdate()
            DebugHarness.indexReady()
        }
        IndexManager.shared.configure(store.config)

        if DebugHarness.isActive {
            DebugHarness.start(launcher: launcher)
            return
        }

        ClipboardStore.shared.start(config: store.config)
        registerHotKeys()

        store.onChange = { [weak self] old, new in
            if old.hotKey != new.hotKey || old.clipboardHotKey != new.clipboardHotKey {
                self?.registerHotKeys()
            }
            if old.folders != new.folders || old.applicationFolders != new.applicationFolders
                || old.excludedNames != new.excludedNames || old.searchTemplates != new.searchTemplates {
                IndexManager.shared.configure(new)
            }
            if old.clipboardMaxEntries != new.clipboardMaxEntries || old.clipboardPersist != new.clipboardPersist {
                ClipboardStore.shared.apply(config: new)
            }
        }

        if store.isFirstRun { launcher.show() }
    }

    /// `open -a Quickbar` while already running shows the bar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        launcher.show()
        return false
    }

    func registerHotKeys() {
        let config = ConfigStore.shared.config
        let center = HotKeyCenter.shared
        center.unregisterAll()
        center.register(id: HotKeyID.launcher, spec: config.hotKey) { [weak self] in
            self?.clipboardPanel.hide()
            self?.launcher.toggle()
        }
        let clip = config.clipboardHotKey
        let modifiers = HotKeyCenter.cocoaModifiers(clip.modifiers)
        center.register(id: HotKeyID.clipboard, spec: clip) { [weak self] in
            self?.launcher.hide()
            self?.clipboardPanel.hotKeyPressed(reverse: false, modifiers: modifiers)
        }
        if !clip.modifiers.contains("shift") {
            var reverse = clip
            reverse.modifiers.append("shift")
            center.register(id: HotKeyID.clipboardReverse, spec: reverse) { [weak self] in
                self?.launcher.hide()
                self?.clipboardPanel.hotKeyPressed(reverse: true, modifiers: modifiers)
            }
        }
    }

    func suspendHotKeys() {
        HotKeyCenter.shared.unregisterAll()
    }

    private func perform(action: String) {
        switch action {
        case "settings": SettingsWindowController.shared.show()
        case "rescan": IndexManager.shared.rebuild()
        case "reload": ConfigStore.shared.reload()
        case "config": NSWorkspace.shared.activateFileViewerSelecting([AppPaths.config])
        case "clipboard": clipboardPanel.hotKeyPressed(reverse: false, modifiers: [])
        case "clear-clipboard": ClipboardStore.shared.clear()
        case "quit": NSApp.terminate(nil)
        default: Log.info("unknown action \(action)")
        }
    }

    /// An accessory app shows no menu bar, but text fields still need an Edit
    /// menu for ⌘V, ⌘C, ⌘A and friends to work.
    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Quickbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}
