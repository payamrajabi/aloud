import AppKit

/// Tap / double-tap / hold detection for the modifier keys that the reading and dictation
/// shortcuts use, free of timers and event monitors so it can be tested.
/// `.dictate` means start (the dictation gesture while idle) or finish (any clean press of the
/// dictation key while recording). Holding the dictation key on its own is push-to-talk.
struct ModifierGestures {
    enum Event {
        case modifier(code: UInt16, flags: UInt, time: TimeInterval)  // flagsChanged
        case keyDown
        case input  // a click, or a key another app's shortcut swallowed
    }

    enum Action: Equatable { case read, dictate, holdBegan, holdEnded, interrupted }

    static let holdDelay: TimeInterval = 0.3
    private static let families = NSEvent.ModifierFlags([.command, .option, .control, .shift, .function]).rawValue

    /// Only tap and double-tap bindings matter here; key combinations are hot keys.
    let read: KeyBinding?, dictate: KeyBinding?
    var interval = NSEvent.doubleClickInterval
    /// Set by the owner before each event: a dictation is in progress.
    var recording = false

    private var press: (key: ModifierKey, at: TimeInterval, clean: Bool, consumed: Bool)?
    private var lastTap: (key: ModifierKey, at: TimeInterval)?
    private var holding = false
    /// Dictation-key taps that start before this belong to the gesture that just started or finished a recording.
    private var quietUntil = -TimeInterval.infinity

    init(read: KeyBinding?, dictate: KeyBinding?) {
        self.read = read?.modifierKey == nil ? nil : read
        self.dictate = dictate?.modifierKey == nil ? nil : dictate
    }

    var isEmpty: Bool { read == nil && dictate == nil }

    private var dictateKey: ModifierKey? { dictate?.modifierKey }

    private func binding(for key: ModifierKey) -> KeyBinding? {
        key == dictateKey ? dictate : read?.modifierKey == key ? read : nil
    }

    /// The dictation key is down on its own: start the hold timer.
    var holdPending: Bool {
        guard let press else { return false }
        return press.key == dictateKey && press.clean && !press.consumed && !holding && !recording
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
            guard let key = ModifierKey(code: code), binding(for: key) != nil, press == nil || press?.key == key else {
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

    private mutating func down(_ key: ModifierKey, flags: UInt, at time: TimeInterval) -> Action? {
        let clean = flags & Self.families & ~key.family.rawValue == 0
        let isDictate = key == dictateKey
        defer { lastTap = nil }
        if clean, case .doubleTap = binding(for: key), let tap = lastTap, tap.key == key,
           time - tap.at <= interval, !(isDictate && recording) {
            press = (key, time, false, true)  // fire now; ignore the rest of this press
            if isDictate { quietUntil = time + interval }
            return isDictate ? .dictate : .read
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
        lastTap = nil
        guard let press, press.clean, !press.consumed else { return nil }
        let isDictate = press.key == dictateKey
        if isDictate, press.at < quietUntil { return nil }
        if isDictate, recording {
            quietUntil = press.at + interval  // a double tap finishes once; its second tap mustn't start again
            return .dictate
        }
        guard time - press.at < Self.holdDelay else { return nil }
        if case .tap = binding(for: press.key) { return isDictate ? .dictate : .read }
        lastTap = (press.key, press.at)
        return nil
    }
}
