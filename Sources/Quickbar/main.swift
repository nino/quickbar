import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// No Dock icon, no menu bar: Quickbar lives behind its hotkeys.
app.setActivationPolicy(.accessory)
app.run()
