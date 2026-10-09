import AppKit
import os
import ApplicationServices

/// A selection's text, and the app's HTML for it when Aloud copied the selection to read
/// its structure (headings, lists, bold…).
struct Selection {
    var text: String
    var html: String?
}

/// Gets the selected text from whatever app is in front.
/// First asks the app through Accessibility; if that returns nothing, it
/// simulates ⌘C and restores the clipboard afterwards. A selection of several lines that
/// isn't Markdown is also copied, behind the scenes, for the app's HTML.
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

    /// The longest one-line selection read without copying it: about a long sentence.
    static let oneSentence = 160

    /// One read at a time: a read that copies must not take another's copy for the
    /// clipboard to put back.
    private static let queue = DispatchQueue(label: "SelectionReader", qos: .userInitiated)

    /// `current`: the text already being read. Selecting it again only pauses or resumes,
    /// so it isn't copied again for its HTML.
    static func read(current: String = "", completion: @escaping (Selection?) -> Void) {
        queue.async {
            var lateCopy: (() -> Void)?
            let selection = capture(current: current.trimmingCharacters(in: .whitespacesAndNewlines), lateCopy: &lateCopy)
            DispatchQueue.main.async { completion(selection) }
            lateCopy?()   // reading starts meanwhile; the next read waits for it
        }
    }

    private static func capture(current: String, lateCopy: inout (() -> Void)?) -> Selection? {
        let log = ReadingLog.logger
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown app"
        guard let text = viaAccessibility() else {
            log.info("read from \(app, privacy: .public): Accessibility gave no text, copying")
            guard let copied = viaCopy(selected: nil, lateCopy: &lateCopy), let text = copied.text else { return nil }
            return Selection(text: text, html: copied.html.flatMap { checked($0, text) })
        }
        // A sentence or so on one line has no structure to find, and Markdown carries its own:
        // both stay on the fast path. A long single line is copied: Chromium apps (the Claude
        // app, Chrome, Slack) give a selection across paragraphs as one line, its headings run
        // into the text. (A list alone is usually a web page's text with its numbers, so it's
        // copied too: the page's headings and bold come with the HTML.)
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
        log.info("read from \(app, privacy: .public): Accessibility gave \(text.count) characters on \(lines.count) lines")
        let short = lines.count < 2 && text.count <= Self.oneSentence
        guard !short, !NarrationMarkdown.hasMarkupBeyondLists(text),
              text.trimmingCharacters(in: .whitespacesAndNewlines) != current
        else {
            log.info("not copied: \(short ? "one short line" : text.trimmingCharacters(in: .whitespacesAndNewlines) == current ? "already reading it" : "the text is Markdown", privacy: .public)")
            return Selection(text: text)
        }
        guard let html = viaCopy(selected: text, lateCopy: &lateCopy)?.html, let match = checked(html, text) else {
            return Selection(text: text)
        }
        return Selection(text: text, html: match)
    }

    /// The HTML if it shows the selection, logging which and what tags it holds.
    private static func checked(_ html: String, _ text: String) -> String? {
        let ok = matches(html, text)
        ReadingLog.logger.info("the app's HTML \(ok ? "matches" : "does NOT match", privacy: .public) the selection; tags: \(tagCounts(html), privacy: .public)")
        return ok ? html : nil
    }

    /// "h1 1, h2 3, p 12, li 4…": the block tags that carry structure, counted.
    private static func tagCounts(_ html: String) -> String {
        var counts: [String: Int] = [:]
        let re = try! NSRegularExpression(pattern: #"<(h[1-6]|p|li|div|br|pre|blockquote|table|strong|b|em)\b"#, options: .caseInsensitive)
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            counts[(html as NSString).substring(with: m.range(at: 1)).lowercased(), default: 0] += 1
        }
        let pre = html.range(of: "white-space: *pre", options: [.regularExpression, .caseInsensitive]) != nil ? ", white-space pre" : ""
        return counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + pre
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

    /// The selection as the app copies it: its plain text and, when it offers one, its HTML.
    /// `selected`: the text Accessibility read, when there is one. The app is then only slow
    /// if nothing arrives in time (a whole long page can take it a second): `lateCopy` waits
    /// for its copy and puts the clipboard back.
    private static func viaCopy(selected: String?, lateCopy: inout (() -> Void)?) -> (text: String?, html: String?)? {
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
        guard copied else {
            ReadingLog.logger.info("copy: nothing arrived within 0.5 s")
            if let selected {
                lateCopy = {
                    for _ in 0..<100 {   // ~3 s
                        usleep(30_000)
                        guard pasteboard.changeCount != before else { continue }
                        usleep(30_000)
                        // Ours, not something copied since: put back what was there.
                        if let late = pasteboard.string(forType: .string), matches(late, selected) { restore(pasteboard, saved) }
                        return
                    }
                }
            }
            return nil  // nothing selected; clipboard untouched
        }
        usleep(30_000)
        let text = pasteboard.string(forType: .string)
        let html = pasteboard.string(forType: .html)
        let types = (pasteboard.types ?? []).map(\.rawValue).joined(separator: " ")
        ReadingLog.logger.info("copy: \(text?.count ?? 0) characters of text, \(html?.count ?? 0) of HTML; types \(types, privacy: .public)")
        restore(pasteboard, saved)
        return (text, html)
    }

    // MARK: - Does the HTML match the selection?

    /// Whether the HTML shows the selected text, comparing only letters and digits: one
    /// holds at least 90% of the other's in order, or they're about as long (within 15%) and
    /// share most words (Jaccard ≥ 0.85). Guards against reading something else the app put
    /// on the clipboard (a link, say) instead of the selection.
    static func matches(_ html: String, _ text: String) -> Bool {
        let visible = visibleText(html)
        let a = letters(visible), b = letters(text)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b || holdsMost(of: a, in: b) || holdsMost(of: b, in: a) { return true }
        guard abs(a.count - b.count) * 100 <= 15 * max(a.count, b.count) else { return false }
        let wa = words(visible), wb = words(text)
        return Double(wa.intersection(wb).count) >= 0.85 * Double(wa.union(wb).count)
    }

    /// The text a browser would show, roughly: no tags, comments, scripts, styles or entities.
    /// Cheap on purpose; the real parse happens once, when the player loads it.
    private static func visibleText(_ html: String) -> String {
        var s = html
        for pattern in ["(?is)<(head|script|style|template|noscript)\\b.*?</\\1\\s*>", "(?s)<!--.*?-->", "<[^>]*>", "&#?\\w+;"] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return s
    }

    private static func letters(_ s: String) -> [UInt32] {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(\.value)
    }

    private static func words(_ s: String) -> Set<Substring> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber })
    }

    /// Whether `big` holds at least 90% of `small`'s letters in order. Walks the two side by
    /// side; where they differ, it looks up to 1,000 letters ahead in `big` for `small`'s next
    /// eight (`big` has something extra), else counts the letter missing (`small` has
    /// something extra, like a list's numbers). Gives up once more than 10% are missing.
    private static func holdsMost(of small: [UInt32], in big: [UInt32]) -> Bool {
        let allowed = small.count / 10
        var i = 0, j = 0, missing = 0
        while i < small.count {
            if j < big.count, small[i] == big[j] {
                i += 1
                j += 1
                continue
            }
            let k = min(8, small.count - i)
            var p = j + 1
            let last = min(big.count - k, j + 1_000)
            while p <= last {
                var q = 0
                while q < k, big[p + q] == small[i + q] { q += 1 }
                if q == k { break }
                p += 1
            }
            if p <= last {
                j = p
            } else {
                missing += 1
                if missing > allowed { return false }
                i += 1
            }
        }
        return true
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
