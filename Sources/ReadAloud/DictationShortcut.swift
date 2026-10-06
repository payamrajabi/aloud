import AppKit
import Carbon

/// How dictation is started. Modifier-only keys behave like Superwhisper:
/// tap to start/stop, or hold to talk and release to finish.
enum DictationShortcut: String, CaseIterable {
    case rightOption, rightCommand, fn, controlOptionD

    static var current: DictationShortcut {
        DictationShortcut(rawValue: UserDefaults.standard.string(forKey: "dictationShortcut") ?? "") ?? .rightOption
    }

    var title: String {
        switch self {
        case .rightCommand: return "Right ⌘ (tap, or hold to talk)"
        case .rightOption: return "Right ⌥ (tap, or hold to talk)"
        case .fn: return "fn (tap, or hold to talk)"
        case .controlOptionD: return "⌃⌥D"
        }
    }

    var short: String {
        switch self {
        case .rightCommand: return "right ⌘"
        case .rightOption: return "right ⌥"
        case .fn: return "fn"
        case .controlOptionD: return "⌃⌥D"
        }
    }

    /// For modifier-only shortcuts: the key code and the device-specific flag bit.
    fileprivate var modifierKey: (code: UInt16, isDown: (NSEvent.ModifierFlags) -> Bool)? {
        switch self {
        case .rightCommand: return (54, { $0.rawValue & 0x10 != 0 })     // NX_DEVICERCMDKEYMASK
        case .rightOption: return (61, { $0.rawValue & 0x40 != 0 })      // NX_DEVICERALTKEYMASK
        case .fn: return (63, { $0.contains(.function) })
        case .controlOptionD: return nil
        }
    }
}

/// Watches the keyboard for the dictation shortcut (or double-taps) and ⌃⌥Esc (cancel).
/// Needs Accessibility access (the same permission reading already uses).
final class DictationTrigger {
    var onTap: (() -> Void)?
    /// Double-tap of the left key, when double-tap is on.
    var onReadDoubleTap: (() -> Void)?
    var onHoldBegan: (() -> Void)?
    var onHoldEnded: (() -> Void)?
    /// Another key was pressed while the modifier was held (e.g. a normal ⌘C).
    var onInterrupted: (() -> Void)?
    /// ⌃⌥Esc. Plain Esc is too easy to hit by accident and would throw away a long dictation.
    var onCancel: (() -> Void)?

    private static let holdDelay: TimeInterval = 0.3
    private var monitors: [Any] = []
    private var hotKey: HotKey?
    private var shortcut = DictationShortcut.current
    private var downAt: Date?
    private var clean = false
    private var holding = false
    private var holdTimer: Timer?
    private var doubleTap: DoubleTapDetector?
    private var inputCount: UInt32 = 0

    func start() {
        stop()
        shortcut = .current
        doubleTap = DoubleTapKey.current.detector()
        inputCount = Self.inputCount()
        if doubleTap == nil, shortcut == .controlOptionD {
            let combo = Shortcut(id: "dictation", keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥D")
            hotKey = HotKey(combo) { [weak self] in self?.onTap?() }
        }
        let handler: (NSEvent) -> Void = { [weak self] event in self?.handle(event) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        hotKey = nil
        holdTimer?.invalidate()
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.control, .option] {
            onCancel?()
        }
        if doubleTap != nil { return handleDoubleTap(event) }
        if event.type == .keyDown {
            guard downAt != nil else { return }
            clean = false
            holdTimer?.invalidate()
            if holding {
                holding = false
                onInterrupted?()
            }
            return
        }

        guard let key = shortcut.modifierKey else { return }
        guard event.keyCode == key.code else {
            // Another modifier changed while ours is down: it's a chord, not a dictation tap.
            if downAt != nil { clean = false }
            return
        }
        if key.isDown(event.modifierFlags) {
            let others: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
            let own: NSEvent.ModifierFlags = shortcut == .rightCommand ? .command : shortcut == .rightOption ? .option : .function
            downAt = Date()
            clean = event.modifierFlags.intersection(others).subtracting(own).isEmpty
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDelay, repeats: false) { [weak self] _ in
                guard let self, self.clean, self.downAt != nil else { return }
                self.holding = true
                self.onHoldBegan?()
            }
        } else {
            holdTimer?.invalidate()
            if holding {
                holding = false
                onHoldEnded?()
            } else if clean, let downAt, Date().timeIntervalSince(downAt) < Self.holdDelay {
                onTap?()
            }
            downAt = nil
            clean = false
        }
    }

    private func handleDoubleTap(_ event: NSEvent) {
        let count = Self.inputCount()
        defer { inputCount = count }
        if event.type == .keyDown { return perform(doubleTap?.handle(.keyDown)) }
        // Clicks and keys swallowed by system shortcuts (⌘Tab) never reach the monitors; the counters see them.
        if count != inputCount { _ = doubleTap?.handle(.input) }
        perform(doubleTap?.handle(.modifier(code: event.keyCode, flags: event.modifierFlags.rawValue, time: event.timestamp)))
        guard doubleTap?.holdPending == true else { return }
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: DoubleTapDetector.holdDelay, repeats: false) { [weak self] _ in
            self?.perform(self?.doubleTap?.holdTimerFired(at: ProcessInfo.processInfo.systemUptime))
        }
    }

    private func perform(_ action: DoubleTapDetector.Action?) {
        switch action {
        case .read: onReadDoubleTap?()
        case .dictate: onTap?()
        case .holdBegan: onHoldBegan?()
        case .holdEnded: onHoldEnded?()
        case .interrupted: onInterrupted?()
        case nil: break
        }
    }

    /// Key presses and clicks seen system-wide so far.
    private static func inputCount() -> UInt32 {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        return types.reduce(0) { $0 &+ CGEventSource.counterForEventType(.combinedSessionState, eventType: $1) }
    }
}
