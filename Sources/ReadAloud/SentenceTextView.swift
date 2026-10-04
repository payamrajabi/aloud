import AppKit
import SwiftUI

/// Read-only text with the current sentence highlighted. Clicking a sentence jumps to it.
struct SentenceTextView: NSViewRepresentable {
    let text: String
    let ranges: [NSRange]
    let current: Int
    let onSelect: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = ClickableTextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 6
        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        let c = context.coordinator
        textView.onClick = { [ranges, onSelect] index in
            if let i = ranges.firstIndex(where: { NSLocationInRange(index, $0) || NSMaxRange($0) == index }) {
                onSelect(i)
            } else if let i = ranges.lastIndex(where: { $0.location <= index }) {
                onSelect(i)
            }
        }

        if c.text != text {
            c.text = text
            c.highlighted = -1
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.paragraphSpacing = 8
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 15),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]))
        }

        guard c.highlighted != current, let storage = textView.textStorage else { return }
        c.highlighted = current
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: full)
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        if current < ranges.count, NSMaxRange(ranges[current]) <= storage.length {
            let r = ranges[current]
            // Text already read is dimmed; the current sentence is highlighted.
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                 range: NSRange(location: 0, length: r.location))
            storage.addAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.22), range: r)
            storage.endEditing()
            scrollToCenter(r, in: textView)
        } else {
            storage.endEditing()
        }
    }

    private func scrollToCenter(_ range: NSRange, in textView: NSTextView) {
        guard let layout = textView.layoutManager, let container = textView.textContainer,
              let clip = textView.enclosingScrollView?.contentView else { return }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let visible = clip.bounds
        let top = rect.minY + textView.textContainerOrigin.y
        // Only scroll when the sentence drifts out of the middle band.
        if top < visible.minY + visible.height * 0.15 || rect.maxY > visible.maxY - visible.height * 0.25 {
            let target = max(0, min(top - visible.height * 0.3, textView.frame.height - visible.height))
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                clip.animator().setBoundsOrigin(NSPoint(x: 0, y: target))
            }
        }
    }

    final class Coordinator {
        var text = ""
        var highlighted = -1
        weak var textView: ClickableTextView?
    }
}

final class ClickableTextView: NSTextView {
    var onClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onClick?(characterIndexForInsertion(at: point))
    }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: .pointingHand)
    }
}
