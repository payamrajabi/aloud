import AppKit
import ApplicationServices

/// Gets the selected text from whatever app is in front.
/// First asks the app through Accessibility; if that returns nothing, it
/// simulates ⌘C and restores the clipboard afterwards.
enum SelectionReader {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func read(completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let text = viaAccessibility() ?? viaCopy()
            DispatchQueue.main.async { completion(text) }
        }
    }

    private static func viaAccessibility() -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.4)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    private static func viaCopy() -> String? {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let before = pasteboard.changeCount

        waitForModifiersReleased()
        postCommandC()

        // Wait up to ~0.5 s for the app to put the selection on the clipboard.
        var copied = false
        for _ in 0..<25 {
            usleep(20_000)
            if pasteboard.changeCount != before { copied = true; break }
        }
        guard copied else { return nil }  // nothing selected; clipboard untouched
        usleep(30_000)
        let text = pasteboard.string(forType: .string)
        restore(pasteboard, saved)
        return text
    }

    /// The shortcut's modifier keys are usually still held; wait so ⌘C isn't ⌃⌥⌘C.
    static func waitForModifiersReleased() {
        let mask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        for _ in 0..<40 {
            if CGEventSource.flagsState(.combinedSessionState).intersection(mask).isEmpty { return }
            usleep(15_000)
        }
    }

    private static func postCommandC() { postCommand(key: 8) }

    /// Posts ⌘ + key (8 = C, 9 = V) to the frontmost app.
    static func postCommand(key: CGKeyCode) {
        let source = CGEventSource(stateID: .privateState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    static func snapshot(_ pb: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    static func restore(_ pb: NSPasteboard, _ items: [[(NSPasteboard.PasteboardType, Data)]]) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(restored)
    }
}
