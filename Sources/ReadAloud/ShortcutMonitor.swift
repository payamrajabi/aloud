import AppKit
import Carbon

/// Watches the keyboard for the reading, dictation and cancel shortcuts chosen in Settings.
/// Key combinations are Carbon hot keys; modifier taps, double-taps and holds come from event
/// monitors, which need Accessibility access (the same permission reading already uses).
final class ShortcutMonitor: ObservableObject {
    var onRead: (() -> Void)?
    /// Start or finish dictating.
    var onDictate: (() -> Void)?
    /// A dictation is in progress (a press of the dictation key then finishes it).
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
    private var cancelCombo: (code: UInt16, mods: UInt32)?
    private var holdTimer: Timer?
    private var gestures = ModifierGestures(read: nil, dictate: nil)
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
            if let hotKey = HotKey(keyCode: code, modifiers: mods, handler: { [weak self] in
                action == .read ? self?.onRead?() : self?.onDictate?()
            }) {
                hotKeys.append(hotKey)
            } else {
                unavailable.insert(action)
            }
        }
        if case let .combo(code, mods) = ShortcutAction.cancelDictation.binding {
            cancelCombo = (UInt16(code), mods)
        }
        gestures = ModifierGestures(read: ShortcutAction.read.binding, dictate: ShortcutAction.dictate.binding)
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
        cancelCombo = nil
        holdTimer?.invalidate()
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown, let cancelCombo, event.keyCode == cancelCombo.code,
           KeyNames.carbonModifiers(event.modifierFlags) == cancelCombo.mods {
            onCancel?()
        }
        guard !gestures.isEmpty else { return }
        let count = Self.inputCount()
        defer { inputCount = count }
        gestures.recording = isRecording?() ?? false
        if event.type == .keyDown { return perform(gestures.handle(.keyDown)) }
        // Clicks and keys swallowed by system shortcuts (⌘Tab) never reach the monitors; the counters see them.
        if count != inputCount { _ = gestures.handle(.input) }
        perform(gestures.handle(.modifier(code: event.keyCode, flags: event.modifierFlags.rawValue, time: event.timestamp)))
        guard gestures.holdPending else { return }
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: ModifierGestures.holdDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.gestures.recording = self.isRecording?() ?? false
            self.perform(self.gestures.holdTimerFired(at: ProcessInfo.processInfo.systemUptime))
        }
    }

    private func perform(_ action: ModifierGestures.Action?) {
        switch action {
        case .read: onRead?()
        case .dictate: onDictate?()
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
