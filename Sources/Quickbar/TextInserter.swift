import AppKit

/// Gets text into whichever app has the keyboard: on the clipboard, pasted
/// with a synthetic ⌘V, or typed out key by key for fields that refuse a paste.
///
/// Everything runs on its own queue. The pasteboard and the permission check
/// are IPC, and typing sleeps between keys.
enum TextInserter {
    private static let queue = DispatchQueue(label: "quickbar.insert", qos: .userInitiated)

    private enum Key {
        static let v: CGKeyCode = 9
        static let `return`: CGKeyCode = 36
        static let tab: CGKeyCode = 48
    }

    static func copy(_ text: String) {
        run("copy", text) { write(text) }
    }

    /// The text stays on the clipboard afterwards, so a paste that did not
    /// land can be repeated by hand.
    static func paste(_ text: String) {
        run("paste", text) {
            write(text)
            guard canPostKeys(for: "paste") else { return }
            waitForTarget()
            post(Key.v, flags: .maskCommand)
        }
    }

    static func typeOut(_ text: String) {
        run("type", text) {
            guard canPostKeys(for: "type") else { return }
            waitForTarget()
            for character in text {
                if character.isNewline {
                    post(Key.return)
                } else if character == "\t" {
                    post(Key.tab)
                } else {
                    // The key code is ignored by text input when the event
                    // carries its own string.
                    post(0, string: String(character))
                }
                // Posted without a pause, some apps drop or reorder keys.
                usleep(2_000)
            }
        }
    }

    private static func run(_ name: String, _ text: String, _ work: @escaping () -> Void) {
        // Scripted runs must not paste or type into whatever app is in front.
        if DebugHarness.isActive {
            print("\(name): \(text.count) characters")
            return
        }
        queue.async(execute: work)
    }

    private static func write(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Synthetic keys reach other apps only with the Accessibility permission;
    /// without it they are dropped silently, so ask instead.
    private static func canPostKeys(for what: String) -> Bool {
        if CGPreflightPostEventAccess() { return true }
        Log.info("cannot \(what) a snippet: Accessibility permission is missing")
        _ = CGRequestPostEventAccess()
        return false
    }

    /// Waits until the keys that triggered this are up and the app behind the
    /// bar has the keyboard again.
    private static func waitForTarget() {
        // ⌘ or ⌥ still held from ⌘↩ / ⌥↩ would turn typed letters into
        // shortcuts in the target app.
        let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let deadline = Date().addingTimeInterval(1.5)
        while !CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty, Date() < deadline {
            usleep(10_000)
        }
        usleep(80_000)
    }

    private static func post(_ keyCode: CGKeyCode, flags: CGEventFlags = [], string: String? = nil) {
        // A private source starts with no modifiers, whatever is physically held.
        let source = CGEventSource(stateID: .privateState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { continue }
            event.flags = flags
            if let string {
                let units = Array(string.utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            event.post(tap: .cghidEventTap)
        }
    }
}
