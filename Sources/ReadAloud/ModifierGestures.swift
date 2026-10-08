import AppKit

/// Tap / double-tap / hold detection for the modifier keys that the shortcuts use, free of timers and
/// event monitors so it can be tested. While idle, the read and dictate (start) gestures count; while
/// recording, the finish gesture takes over its key and the start one is off. Holding the dictation
/// key on its own is push-to-talk.
/// One key can carry a tap and a double-tap (tap right ⌥ to dictate, double-tap it to read): its tap
/// then waits out the double-click interval in case a second one follows, and the owner calls
/// `tapTimerFired` at `tapDeadline`.
struct ModifierGestures {
    enum Event {
        case modifier(code: UInt16, flags: UInt, time: TimeInterval)  // flagsChanged
        case keyDown
        case input  // a click, or a key another app's shortcut swallowed
    }

    enum Action: Equatable { case read, dictate, finish, holdBegan, holdEnded, interrupted }

    static let holdDelay: TimeInterval = 0.3
    private static let families = NSEvent.ModifierFlags([.command, .option, .control, .shift, .function]).rawValue

    /// Only tap and double-tap bindings matter here; key combinations are hot keys.
    let read: KeyBinding?, dictate: KeyBinding?, finish: KeyBinding?
    var interval = NSEvent.doubleClickInterval
    /// Set by the owner before each event: a dictation is in progress.
    var recording = false

    private var press: (key: ModifierKey, at: TimeInterval, clean: Bool, consumed: Bool)?
    /// The last clean tap, which a quick second tap turns into a double-tap. `then` is what it does
    /// on its own once that can't happen any more.
    private var lastTap: (key: ModifierKey, at: TimeInterval, then: Action?)?
    private var holding = false
    /// Presses of this key that start before `until` belong to the gesture that just fired.
    private var quiet: (key: ModifierKey, until: TimeInterval)?

    init(read: KeyBinding?, dictate: KeyBinding?, finish: KeyBinding?) {
        func gesture(_ binding: KeyBinding?) -> KeyBinding? { binding?.modifierKey == nil ? nil : binding }
        self.read = gesture(read)
        self.dictate = gesture(dictate)
        self.finish = gesture(finish)
    }

    var isEmpty: Bool { read == nil && dictate == nil && finish == nil }

    /// What `binding` does right now.
    private func action(for binding: KeyBinding) -> Action? {
        let live: [(KeyBinding?, Action)] = recording
            ? [(finish, .finish), (read?.modifierKey == finish?.modifierKey ? nil : read, .read)]
            : [(read, .read), (dictate, .dictate)]
        return live.first { $0.0 == binding }?.1
    }

    private func hasGesture(_ key: ModifierKey) -> Bool {
        action(for: .tap(key)) != nil || action(for: .doubleTap(key)) != nil
    }

    /// The dictation key is down on its own: start the hold timer.
    var holdPending: Bool {
        guard let press else { return false }
        return press.key == dictate?.modifierKey && press.clean && !press.consumed && !holding && !recording
    }

    /// When a tap that's waiting for a possible second one should go ahead on its own.
    var tapDeadline: TimeInterval? {
        guard let lastTap, lastTap.then != nil else { return nil }
        return lastTap.at + interval
    }

    mutating func handle(_ event: Event) -> Action? {
        switch event {
        case .keyDown, .input:
            let waiting = endDoubleTap()
            press?.clean = false
            if case .keyDown = event, holding {
                holding = false
                return .interrupted
            }
            return waiting
        case let .modifier(code, flags, time):
            guard let key = ModifierKey(code: code), press == nil ? hasGesture(key) : press?.key == key else {
                // Another modifier changed: it's a chord, not a tap.
                press?.clean = false
                return endDoubleTap()
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

    /// No second tap came in time: the waiting tap does its own thing.
    mutating func tapTimerFired(at time: TimeInterval) -> Action? {
        guard let deadline = tapDeadline, time >= deadline else { return nil }
        return endDoubleTap()
    }

    /// Anything other than a second tap means the last tap stays single: returns what it does.
    private mutating func endDoubleTap() -> Action? {
        defer { lastTap = nil }
        return lastTap?.then
    }

    private mutating func down(_ key: ModifierKey, flags: UInt, at time: TimeInterval) -> Action? {
        let clean = flags & Self.families & ~key.family.rawValue == 0
        let isQuiet = quiet.map { $0.key == key && time < $0.until } ?? false
        if clean, !isQuiet, let tap = lastTap, tap.key == key, time - tap.at <= interval,
           let double = action(for: .doubleTap(key)) {
            lastTap = nil
            press = (key, time, false, true)  // fire now; ignore the rest of this press
            quiet = (key, time + interval)    // and a third tap
            return double
        }
        press = (key, time, clean && !isQuiet, isQuiet)
        return endDoubleTap()
    }

    private mutating func up(at time: TimeInterval) -> Action? {
        defer { press = nil }
        if holding {
            holding = false
            return .holdEnded
        }
        guard let press, press.clean, !press.consumed else { return nil }
        let tap = action(for: .tap(press.key))
        if tap == .finish {
            quiet = (press.key, press.at + interval)  // a double tap finishes once; its second tap mustn't start again
            return .finish  // however long the press
        }
        guard time - press.at < Self.holdDelay else { return nil }
        guard action(for: .doubleTap(press.key)) != nil else { return tap }
        lastTap = (press.key, press.at, tap)
        return nil
    }
}
