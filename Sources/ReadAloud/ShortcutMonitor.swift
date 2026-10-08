import AppKit
import Carbon

/// Watches the keyboard for the reading and dictation shortcuts chosen in Settings.
/// Reading and starting dictation by key combination are Carbon hot keys; the finish and cancel
/// combinations only matter while dictating, so they're watched rather than taken from other apps.
/// Modifier taps, double-taps and holds come from event monitors, which need Accessibility access
/// (the same permission reading already uses).
final class ShortcutMonitor: ObservableObject {
    var onRead: (() -> Void)?
    /// Start dictating. `provisional`: the tap may yet be the first of a double-tap, and
    /// `onConfirm` or `onRetract` follows.
    var onDictate: ((_ provisional: Bool) -> Void)?
    var onConfirm: (() -> Void)?
    var onRetract: (() -> Void)?
    var onFinish: (() -> Void)?
    /// A dictation is in progress (the finish shortcut then takes over its key).
    var isRecording: (() -> Bool)?
    var onHoldBegan: (() -> Void)?
    var onHoldEnded: (() -> Void)?
    /// Another key was pressed while the dictation key was held (e.g. a normal ⌘C).
    var onInterrupted: (() -> Void)?
    var onCancel: (() -> Void)?

    /// Shortcuts another app already holds, after the last `start()`.
    @Published private(set) var unavailable: Set<ShortcutAction> = []
    /// Off while Settings records a new shortcut, so pressing it doesn't also trigger the old one.
    var isSuspended = false {
        didSet { isSuspended ? stop() : start() }
    }

    private var monitors: [Any] = []
    private var hotKeys: [HotKey] = []
    private var finishCombo: Combo?
    private var cancelCombo: Combo?
    private var holdTimer: Timer?
    private var tapTimer: Timer?
    private var gestures = ModifierGestures(read: nil, dictate: nil, finish: nil)
    private var inputCount: UInt32 = 0
    private var observer: Any?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .shortcutsChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.isSuspended else { return }
            self.start()
        }
    }

    func start() {
        stop()
        var unavailable: Set<ShortcutAction> = []
        defer { self.unavailable = unavailable }
        for action in [ShortcutAction.read, .dictate] {
            guard case let .combo(code, mods) = action.binding else { continue }
            if let hotKey = HotKey(keyCode: code, modifiers: mods, handler: { [weak self] in self?.hotKeyPressed(action) }) {
                hotKeys.append(hotKey)
            } else {
                unavailable.insert(action)
            }
        }
        let finish = ShortcutAction.finishDictation.binding
        // The same combination as Start dictation reaches its hot key instead.
        finishCombo = finish == ShortcutAction.dictate.binding ? nil : Combo(finish)
        cancelCombo = Combo(ShortcutAction.cancelDictation.binding)
        gestures = ModifierGestures(read: ShortcutAction.read.binding, dictate: ShortcutAction.dictate.binding, finish: finish)
        inputCount = Self.inputCount()
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
        hotKeys = []
        finishCombo = nil
        cancelCombo = nil
        holdTimer?.invalidate()
        tapTimer?.invalidate()
    }

    /// Reading always reads; the dictation combination starts, or finishes when it's also the finish shortcut.
    private func hotKeyPressed(_ action: ShortcutAction) {
        if action == .read {
            onRead?()
        } else if isRecording?() != true {
            onDictate?(false)
        } else if ShortcutAction.finishDictation.binding == action.binding {
            onFinish?()
        }
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            if cancelCombo?.matches(event) == true { onCancel?() }
            if finishCombo?.matches(event) == true { onFinish?() }
        }
        guard !gestures.isEmpty else { return }
        let count = Self.inputCount()
        defer {
            inputCount = count
            scheduleTapTimer()
        }
        gestures.recording = isRecording?() ?? false
        if event.type == .keyDown { return perform(gestures.handle(.keyDown)) }
        // Clicks and keys swallowed by system shortcuts (⌘Tab) never reach the monitors; the counters see them.
        if count != inputCount { perform(gestures.handle(.input)) }
        perform(gestures.handle(.modifier(code: event.keyCode, flags: event.modifierFlags.rawValue, time: event.timestamp)))
        guard gestures.holdPending else { return }
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: ModifierGestures.holdDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.gestures.recording = self.isRecording?() ?? false
            self.perform(self.gestures.holdTimerFired(at: ProcessInfo.processInfo.systemUptime))
        }
    }

    /// A tap that might be the first of a double-tap: go ahead with it if no second tap comes.
    private func scheduleTapTimer() {
        tapTimer?.invalidate()
        guard let deadline = gestures.tapDeadline else { return }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime) + 0.005
        tapTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.gestures.recording = self.isRecording?() ?? false
            self.perform(self.gestures.tapTimerFired(at: ProcessInfo.processInfo.systemUptime))
            self.scheduleTapTimer()
        }
    }

    private func perform(_ action: ModifierGestures.Action?) {
        switch action {
        case .read: onRead?()
        case .dictate: onDictate?(false)
        case .dictateProvisionally: onDictate?(true)
        case .confirmDictation: onConfirm?()
        case .readInstead:
            onRetract?()
            onRead?()
        case .finish: onFinish?()
        case .holdBegan: onHoldBegan?()
        case .holdEnded: onHoldEnded?()
        case .interrupted: onInterrupted?()
        case nil: break
        }
    }

    /// A key combination watched by the event monitors.
    private struct Combo {
        let code: UInt16, mods: UInt32

        init?(_ binding: KeyBinding?) {
            guard case let .combo(code, mods) = binding else { return nil }
            self.code = UInt16(code)
            self.mods = mods
        }

        func matches(_ event: NSEvent) -> Bool {
            event.keyCode == code && KeyNames.carbonModifiers(event.modifierFlags) == mods
        }
    }

    /// Key presses and clicks seen system-wide so far.
    private static func inputCount() -> UInt32 {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        return types.reduce(0) { $0 &+ CGEventSource.counterForEventType(.combinedSessionState, eventType: $1) }
    }
}
