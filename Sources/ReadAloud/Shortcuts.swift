import AppKit
import Carbon

/// One modifier key on one side of the keyboard.
enum ModifierKey: String, CaseIterable {
    case leftOption, rightOption, leftCommand, rightCommand, leftControl, rightControl, leftShift, rightShift, fn

    /// Key code in flagsChanged events.
    var code: UInt16 {
        switch self {
        case .leftOption: return 58
        case .rightOption: return 61
        case .leftCommand: return 55
        case .rightCommand: return 54
        case .leftControl: return 59
        case .rightControl: return 62
        case .leftShift: return 56
        case .rightShift: return 60
        case .fn: return 63
        }
    }

    /// The device-specific flag bit (NX_DEVICEL…/R…KEYMASK) that says this exact key is down.
    var bit: UInt {
        switch self {
        case .leftControl: return 0x01
        case .leftShift: return 0x02
        case .rightShift: return 0x04
        case .leftCommand: return 0x08
        case .rightCommand: return 0x10
        case .leftOption: return 0x20
        case .rightOption: return 0x40
        case .rightControl: return 0x2000
        case .fn: return NSEvent.ModifierFlags.function.rawValue
        }
    }

    var family: NSEvent.ModifierFlags {
        switch self {
        case .leftOption, .rightOption: return .option
        case .leftCommand, .rightCommand: return .command
        case .leftControl, .rightControl: return .control
        case .leftShift, .rightShift: return .shift
        case .fn: return .function
        }
    }

    init?(code: UInt16) {
        guard let key = Self.allCases.first(where: { $0.code == code }) else { return nil }
        self = key
    }

    var symbol: String {
        switch family {
        case .option: return "⌥"
        case .command: return "⌘"
        case .control: return "⌃"
        case .shift: return "⇧"
        default: return "fn"
        }
    }

    /// "left ⌥", "fn".
    var name: String {
        switch self {
        case .fn: return "fn"
        case .leftOption, .leftCommand, .leftControl, .leftShift: return "left \(symbol)"
        default: return "right \(symbol)"
        }
    }
}

/// What a shortcut is: a key combination, or a tap or double-tap of one modifier key.
enum KeyBinding: Equatable {
    /// `modifiers` are Carbon flags (cmdKey, optionKey…), as RegisterEventHotKey wants them.
    case combo(keyCode: UInt32, modifiers: UInt32)
    case tap(ModifierKey)
    case doubleTap(ModifierKey)

    var modifierKey: ModifierKey? {
        switch self {
        case .combo: return nil
        case .tap(let key), .doubleTap(let key): return key
        }
    }

    /// For menus and sentences: "⌃⌥R", "double-tap left ⌥", "right ⌥".
    var display: String {
        switch self {
        case let .combo(code, mods): return KeyNames.modifierSymbols(carbon: mods) + KeyNames.name(for: code)
        case .tap(let key): return key.name
        case .doubleTap(let key): return "double-tap \(key.name)"
        }
    }

    /// Starts a sentence: "Double-tap left ⌥", "Press ⌃⌥R", "Tap right ⌥".
    var instruction: String {
        switch self {
        case .combo: return "Press \(display)"
        case .tap(let key): return "Tap \(key.name)"
        case .doubleTap(let key): return "Double-tap \(key.name)"
        }
    }

    // Stored as text: "combo:15:6144", "tap:rightOption", "doubleTap:leftOption".
    var storageValue: String {
        switch self {
        case let .combo(code, mods): return "combo:\(code):\(mods)"
        case .tap(let key): return "tap:\(key.rawValue)"
        case .doubleTap(let key): return "doubleTap:\(key.rawValue)"
        }
    }

    init?(storageValue: String) {
        let parts = storageValue.split(separator: ":").map(String.init)
        switch (parts.first, parts.count) {
        case ("combo", 3):
            guard let code = UInt32(parts[1]), let mods = UInt32(parts[2]) else { return nil }
            self = .combo(keyCode: code, modifiers: mods)
        case ("tap", 2):
            guard let key = ModifierKey(rawValue: parts[1]) else { return nil }
            self = .tap(key)
        case ("doubleTap", 2):
            guard let key = ModifierKey(rawValue: parts[1]) else { return nil }
            self = .doubleTap(key)
        default:
            return nil
        }
    }
}

/// The things a global shortcut can do, and the shortcut chosen for each.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case read, dictate, cancelDictation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .read: return "Read selection"
        case .dictate: return "Dictate"
        case .cancelDictation: return "Cancel dictation"
        }
    }

    /// Cancelling only makes sense as a key combination: a stray modifier tap shouldn't throw away a long dictation.
    var allowsModifierKeys: Bool { self != .cancelDictation }

    var defaultBinding: KeyBinding {
        switch self {
        case .read: return .doubleTap(.leftOption)
        case .dictate: return .doubleTap(.rightOption)
        case .cancelDictation: return .combo(keyCode: UInt32(kVK_Escape), modifiers: UInt32(controlKey | optionKey))
        }
    }

    private var defaultsKey: String { "shortcut.\(rawValue)" }
    private static let none = "none"

    /// The chosen shortcut, or nil when it's been cleared.
    var binding: KeyBinding? {
        guard let stored = UserDefaults.standard.string(forKey: defaultsKey) else {
            return Self.migratedBinding(for: self) ?? defaultBinding
        }
        return stored == Self.none ? nil : KeyBinding(storageValue: stored) ?? defaultBinding
    }

    func set(_ binding: KeyBinding?) {
        UserDefaults.standard.set(binding?.storageValue ?? Self.none, forKey: defaultsKey)
        NotificationCenter.default.post(name: .shortcutsChanged, object: nil)
    }

    static func restoreDefaults() {
        for action in allCases { UserDefaults.standard.removeObject(forKey: action.defaultsKey) }
        // Defaults now mean the defaults, not whatever the old menus said.
        for key in ["doubleTapKey", "shortcut", "dictationShortcut"] { UserDefaults.standard.removeObject(forKey: key) }
        NotificationCenter.default.post(name: .shortcutsChanged, object: nil)
    }

    /// The action already using `binding` (or its modifier key), other than this one.
    func conflict(with binding: KeyBinding) -> ShortcutAction? {
        Self.allCases.first { other in
            guard other != self, let theirs = other.binding else { return false }
            if theirs == binding { return true }
            return theirs.modifierKey != nil && theirs.modifierKey == binding.modifierKey
        }
    }

    // Hints for menus, messages and the welcome text.

    /// "double-tap left ⌥", or "no shortcut".
    var hint: String { binding?.display ?? "no shortcut" }

    /// Before 1.5, shortcuts were picked from menus: Double-Tap (a modifier family, or Off),
    /// Shortcut (a reading hot key) and Dictation Shortcut (used while Double-Tap was Off).
    private static func migratedBinding(for action: ShortcutAction) -> KeyBinding? {
        let defaults = UserDefaults.standard
        let old = ["doubleTapKey", "shortcut", "dictationShortcut"].map { defaults.string(forKey: $0) }
        guard old.contains(where: { $0 != nil }) else { return nil }  // never changed: use the defaults
        let doubleTap = old[0] ?? "option"
        let family: (left: ModifierKey, right: ModifierKey)? = [
            "option": (.leftOption, .rightOption), "shift": (.leftShift, .rightShift),
            "command": (.leftCommand, .rightCommand), "control": (.leftControl, .rightControl),
        ][doubleTap]
        switch action {
        case .read:
            if let family { return .doubleTap(family.left) }
            let presets: [String: (Int, Int)] = [
                "ctrl-opt-r": (kVK_ANSI_R, controlKey | optionKey), "opt-esc": (kVK_Escape, optionKey),
                "ctrl-opt-space": (kVK_Space, controlKey | optionKey), "cmd-shift-1": (kVK_ANSI_1, cmdKey | shiftKey),
            ]
            let preset = presets[defaults.string(forKey: "shortcut") ?? ""] ?? presets["ctrl-opt-r"]!
            return .combo(keyCode: UInt32(preset.0), modifiers: UInt32(preset.1))
        case .dictate:
            if let family { return .doubleTap(family.right) }
            switch defaults.string(forKey: "dictationShortcut") {
            case "rightCommand": return .tap(.rightCommand)
            case "fn": return .tap(.fn)
            case "controlOptionD": return .combo(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey))
            default: return .tap(.rightOption)
            }
        case .cancelDictation:
            return nil
        }
    }
}

extension Notification.Name {
    static let shortcutsChanged = Notification.Name("AloudShortcutsChanged")
}

/// Names and symbols for keys, as macOS shows them in menus.
enum KeyNames {
    static func modifierSymbols(carbon mods: UInt32) -> String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey) != 0 { s += "⌥" }
        if mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if mods & UInt32(cmdKey) != 0 { s += "⌘" }
        return s
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods = 0
        if flags.contains(.command) { mods |= cmdKey }
        if flags.contains(.option) { mods |= optionKey }
        if flags.contains(.control) { mods |= controlKey }
        if flags.contains(.shift) { mods |= shiftKey }
        return UInt32(mods)
    }

    private static let special: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// F-keys are fine as shortcuts on their own; anything else needs ⌘, ⌥ or ⌃.
    static func isFunctionKey(_ code: UInt32) -> Bool { special[Int(code)]?.hasPrefix("F") == true }

    /// The key's label on the current keyboard layout: "R", "1", "Space".
    static func name(for code: UInt32) -> String {
        if let name = special[Int(code)] { return name }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { layout in
            UCKeyTranslate(layout.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(code), UInt16(kUCKeyActionDisplay),
                           0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}
