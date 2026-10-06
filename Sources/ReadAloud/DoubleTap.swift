import AppKit

/// Double-tap a modifier: the left key reads the selection, the right key dictates.
/// A single tap does nothing, so a stray tap can't stop a long dictation.
enum DoubleTapKey: String, CaseIterable {
    case option, shift, command, control, off

    static var current: DoubleTapKey {
        DoubleTapKey(rawValue: UserDefaults.standard.string(forKey: "doubleTapKey") ?? "") ?? .option
    }

    static var isOn: Bool { current != .off }

    var symbol: String {
        switch self {
        case .option: return "⌥"
        case .shift: return "⇧"
        case .command: return "⌘"
        case .control: return "⌃"
        case .off: return ""
        }
    }

    var title: String { self == .off ? "Off" : "\(symbol) \(rawValue.capitalized)" }

    /// Key codes and device-specific flag bits (NX_DEVICEL…/R…KEYMASK) of the left and right keys.
    func detector() -> DoubleTapDetector? {
        let flags = NSEvent.ModifierFlags.self
        switch self {
        case .option: return DoubleTapDetector(left: .init(code: 58, bit: 0x20), right: .init(code: 61, bit: 0x40), family: flags.option.rawValue)
        case .shift: return DoubleTapDetector(left: .init(code: 56, bit: 0x02), right: .init(code: 60, bit: 0x04), family: flags.shift.rawValue)
        case .command: return DoubleTapDetector(left: .init(code: 55, bit: 0x08), right: .init(code: 54, bit: 0x10), family: flags.command.rawValue)
        case .control: return DoubleTapDetector(left: .init(code: 59, bit: 0x01), right: .init(code: 62, bit: 0x2000), family: flags.control.rawValue)
        case .off: return nil
        }
    }

    // How the active shortcuts are named in menus, messages and the welcome text.

    /// "double-tap left ⌥", or the reading hot key ("⌃⌥R").
    static var readHint: String { isOn ? "double-tap left \(current.symbol)" : Shortcut.current.display }
    /// "double-tap right ⌥", or the dictation shortcut ("right ⌥").
    static var dictateHint: String { isOn ? "double-tap right \(current.symbol)" : DictationShortcut.current.short }
    /// Starts a sentence: "Double-tap right ⌥" or "Press right ⌥".
    static var dictateAction: String { isOn ? "Double-tap right \(current.symbol)" : "Press \(DictationShortcut.current.short)" }
}

/// Tap / double-tap / hold detection for one modifier family, free of timers and
/// event monitors so it can be tested. Taps on the left and right keys are tracked separately.
struct DoubleTapDetector {
    struct Key: Equatable {
        let code: UInt16
        let bit: UInt
    }

    enum Event {
        case modifier(code: UInt16, flags: UInt, time: TimeInterval)  // flagsChanged
        case keyDown
        case input  // a click, or a key another app's shortcut swallowed
    }

    enum Action: Equatable { case read, dictate, holdBegan, holdEnded, interrupted }

    static let holdDelay: TimeInterval = 0.3
    private static let families = NSEvent.ModifierFlags([.command, .option, .control, .shift, .function]).rawValue

    let left: Key, right: Key, family: UInt
    var interval = NSEvent.doubleClickInterval

    private var press: (key: Key, at: TimeInterval, clean: Bool, consumed: Bool)?
    private var lastTap: (key: Key, at: TimeInterval)?
    private var holding = false

    init(left: Key, right: Key, family: UInt) {
        (self.left, self.right, self.family) = (left, right, family)
    }

    /// The right key is down on its own: start the hold timer.
    var holdPending: Bool {
        guard let press else { return false }
        return press.key == right && press.clean && !press.consumed && !holding
    }

    mutating func handle(_ event: Event) -> Action? {
        switch event {
        case .keyDown, .input:
            lastTap = nil
            press?.clean = false
            if case .keyDown = event, holding {
                holding = false
                return .interrupted
            }
            return nil
        case let .modifier(code, flags, time):
            guard let key = [left, right].first(where: { $0.code == code }), press == nil || press?.key == key else {
                // Another modifier changed: it's a chord, not a tap.
                lastTap = nil
                press?.clean = false
                return nil
            }
            if flags & key.bit != 0 {
                return press == nil ? down(key, flags: flags, at: time) : nil
            }
            return up(at: time)
        }
    }

    mutating func holdTimerFired(at time: TimeInterval) -> Action? {
        guard holdPending, let press, time - press.at >= Self.holdDelay else { return nil }
        holding = true
        return .holdBegan
    }

    private mutating func down(_ key: Key, flags: UInt, at time: TimeInterval) -> Action? {
        let clean = flags & Self.families & ~family == 0
        defer { lastTap = nil }
        if clean, let tap = lastTap, tap.key == key, time - tap.at <= interval {
            press = (key, time, false, true)  // fire now; ignore the rest of this press
            return key == left ? .read : .dictate
        }
        press = (key, time, clean, false)
        return nil
    }

    private mutating func up(at time: TimeInterval) -> Action? {
        defer { press = nil }
        if holding {
            holding = false
            return .holdEnded
        }
        if let press, press.clean, !press.consumed, time - press.at < Self.holdDelay {
            lastTap = (press.key, press.at)
        } else {
            lastTap = nil
        }
        return nil
    }
}
