import AppKit
import Carbon.HIToolbox
import QuickbarCore

/// Global hotkeys via Carbon. Needs no permissions and fires even when
/// another app is frontmost.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var installed = false
    private let signature: OSType = 0x5142_4152 // 'QBAR'

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if status == noErr { HotKeyCenter.shared.handlers[id.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    static func carbonModifiers(_ names: [String]) -> UInt32 {
        var flags: UInt32 = 0
        if names.contains("command") { flags |= UInt32(cmdKey) }
        if names.contains("option") { flags |= UInt32(optionKey) }
        if names.contains("control") { flags |= UInt32(controlKey) }
        if names.contains("shift") { flags |= UInt32(shiftKey) }
        return flags
    }

    static func cocoaModifiers(_ names: [String]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if names.contains("command") { flags.insert(.command) }
        if names.contains("option") { flags.insert(.option) }
        if names.contains("control") { flags.insert(.control) }
        if names.contains("shift") { flags.insert(.shift) }
        return flags
    }

    @discardableResult
    func register(id: UInt32, spec: HotKeySpec, handler: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        unregister(id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            spec.keyCode, Self.carbonModifiers(spec.modifiers),
            EventHotKeyID(signature: signature, id: id), GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.info("could not register hotkey \(spec.displayString) (status \(status))")
            return false
        }
        refs[id] = ref
        handlers[id] = handler
        return true
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
    }

    func unregisterAll() {
        for id in Array(refs.keys) { unregister(id: id) }
    }
}

enum KeyNames {
    static let special: [UInt32: String] = [
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Escape): "⎋", UInt32(kVK_Delete): "⌫", UInt32(kVK_ForwardDelete): "⌦",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→", UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘", UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]

    static func label(for event: NSEvent) -> String {
        if let s = special[UInt32(event.keyCode)] { return s }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }

    static func modifierNames(_ flags: NSEvent.ModifierFlags) -> [String] {
        var names = [String]()
        if flags.contains(.control) { names.append("control") }
        if flags.contains(.option) { names.append("option") }
        if flags.contains(.shift) { names.append("shift") }
        if flags.contains(.command) { names.append("command") }
        return names
    }
}
