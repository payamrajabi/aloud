import Carbon
import Foundation

struct Shortcut: Equatable {
    let id: String
    let keyCode: UInt32
    let modifiers: UInt32
    let display: String

    static let presets: [Shortcut] = [
        Shortcut(id: "ctrl-opt-r", keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥R"),
        Shortcut(id: "opt-esc", keyCode: UInt32(kVK_Escape), modifiers: UInt32(optionKey), display: "⌥⎋"),
        Shortcut(id: "ctrl-opt-space", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥Space"),
        Shortcut(id: "cmd-shift-1", keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey | shiftKey), display: "⇧⌘1"),
    ]

    static var current: Shortcut {
        let id = UserDefaults.standard.string(forKey: "shortcut")
        return presets.first { $0.id == id } ?? presets[0]
    }
}

/// A system-wide keyboard shortcut (Carbon hot key; needs no special permission).
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static var nextID: UInt32 = 1

    private var ref: EventHotKeyRef?
    private let id: UInt32

    init?(_ shortcut: Shortcut, handler: @escaping () -> Void) {
        Self.installHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x5244_414C), id: id)  // 'RDAL'
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
        Self.handlers[id] = handler
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
