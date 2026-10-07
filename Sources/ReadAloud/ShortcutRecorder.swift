import AppKit
import Carbon

/// Records a new shortcut in Settings: a key combination, or a tap or double-tap of one modifier
/// key. A lone modifier tap waits the double-click interval to see whether a second tap follows.
final class ShortcutRecorder: ObservableObject {
    struct Problem: Equatable {
        let action: ShortcutAction
        let text: String
    }

    /// The shortcut being recorded.
    @Published private(set) var action: ShortcutAction?
    /// What's held or tapped so far: "⌃⌥", "right ⌥".
    @Published private(set) var preview = ""
    @Published private(set) var problem: Problem?

    /// Turns the app's shortcuts off while recording, so pressing one doesn't also trigger it.
    var setSuspended: ((Bool) -> Void)?

    private var monitor: Any?
    private var down: (key: ModifierKey, at: TimeInterval, clean: Bool)?
    private var lastTap: (key: ModifierKey, at: TimeInterval)?
    private var tapTimer: Timer?
    private static let families: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]

    func begin(_ action: ShortcutAction) {
        if self.action == nil { setSuspended?(true) }
        reset()
        self.action = action
        problem = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func end() {
        guard action != nil else { return }
        reset()
        action = nil
        setSuspended?(false)
    }

    /// Clears a shortcut, or sets it, unless another action already uses it.
    func assign(_ binding: KeyBinding?, to action: ShortcutAction) {
        if let binding, let other = action.conflict(with: binding) {
            problem = Problem(action: action, text: "\(binding.display.capitalizedFirst) is already the shortcut to \(other.title.lowercased()).")
            NSSound.beep()
            return
        }
        problem = nil
        action.set(binding)
    }

    private func reset() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        tapTimer?.invalidate()
        down = nil
        lastTap = nil
        preview = ""
    }

    private func commit(_ binding: KeyBinding?) {
        guard let action else { return }
        end()
        assign(binding, to: action)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let action else { return event }
        switch event.type {
        case .leftMouseDown:
            end()  // clicking anywhere (including another shortcut) stops recording this one
            return event
        case .keyDown:
            tapTimer?.invalidate()
            lastTap = nil
            down = nil
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let code = UInt32(event.keyCode)
            if mods.isEmpty, code == kVK_Escape {
                end()
            } else if mods.isEmpty, code == kVK_Delete || code == kVK_ForwardDelete {
                commit(nil)
            } else if mods.isDisjoint(with: [.command, .option, .control]), !KeyNames.isFunctionKey(code) {
                problem = Problem(action: action, text: action.allowsModifierKeys
                    ? "Add ⌘, ⌥ or ⌃ to the key, or tap a modifier key on its own."
                    : "Add ⌘, ⌥ or ⌃ to the key.")
                NSSound.beep()
            } else {
                commit(.combo(keyCode: code, modifiers: KeyNames.carbonModifiers(mods)))
            }
            return nil
        case .flagsChanged:
            let held = event.modifierFlags.intersection([.command, .option, .control, .shift])
            preview = KeyNames.modifierSymbols(carbon: KeyNames.carbonModifiers(held))
            guard action.allowsModifierKeys, let key = ModifierKey(code: event.keyCode) else { return nil }
            if event.modifierFlags.rawValue & key.bit != 0 {
                let clean = event.modifierFlags.intersection(Self.families).subtracting(key.family).isEmpty
                if clean, let tap = lastTap, tap.key == key, event.timestamp - tap.at <= NSEvent.doubleClickInterval {
                    commit(.doubleTap(key))
                    return nil
                }
                tapTimer?.invalidate()
                lastTap = nil
                down = (key, event.timestamp, clean)
            } else if let press = down, press.key == key {
                down = nil
                // A long press isn't a tap; wait for the next key.
                guard press.clean, event.timestamp - press.at < 0.6 else { return nil }
                lastTap = (key, press.at)
                preview = key.name.capitalizedFirst
                tapTimer = Timer.scheduledTimer(withTimeInterval: NSEvent.doubleClickInterval, repeats: false) { [weak self] _ in
                    self?.commit(.tap(key))
                }
            } else {
                down = nil
            }
            return nil
        default:
            return event
        }
    }
}

extension String {
    /// "Double-tap left ⌥", but "fn" stays lowercase, as Apple writes it.
    var capitalizedFirst: String { hasPrefix("fn") ? self : prefix(1).uppercased() + dropFirst() }
}
