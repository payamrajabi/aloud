import AppKit
import SwiftUI

/// Read-only text with the current sentence highlighted. Clicking a sentence jumps to it.
/// Headings, lists, quotes, code and struck text are styled as the selection had them.
struct SentenceTextView: NSViewRepresentable {
    let text: String
    var styles: [DisplayStyle] = []
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
        textView.onClick = { [text, ranges, onSelect] index in
            if let i = ranges.firstIndex(where: { NSLocationInRange(index, $0) || NSMaxRange($0) == index }) {
                onSelect(i)
            } else if let i = ranges.firstIndex(where: { $0.location > index }),
                      !(text as NSString).substring(with: NSRange(location: index, length: ranges[i].location - index)).contains("\n") {
                onSelect(i)  // a list item's bullet or number: its own sentence, not the one before
            } else if let i = ranges.lastIndex(where: { $0.location <= index }) {
                onSelect(i)
            }
        }

        if c.text != text || c.styles != styles {
            c.text = text
            c.styles = styles
            c.highlighted = -1
            textView.textStorage?.setAttributedString(Self.styled(text, styles))
        }

        guard c.highlighted != current, let storage = textView.textStorage else { return }
        c.highlighted = current
        let full = NSRange(location: 0, length: storage.length)
        let r = current < ranges.count && NSMaxRange(ranges[current]) <= storage.length ? ranges[current] : nil
        let shown = r.map { Self.withListMarker($0, styles) }
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: full)
        // Text already read is dimmed; the current sentence is highlighted.
        Self.color(storage, styles, readUpTo: shown?.location ?? 0)
        if let shown {
            storage.addAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.22), range: shown)
        }
        storage.endEditing()
        if let r { scrollToCenter(r, in: textView) }
    }

    // MARK: - Styles

    private static let bodySize: CGFloat = 15

    /// The text with its fonts, indents and spacing. Colors are set by `color`.
    private static func styled(_ text: String, _ styles: [DisplayStyle]) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 8
        let body = NSFont.systemFont(ofSize: bodySize)
        let s = NSMutableAttributedString(string: text, attributes: [
            .font: body,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
        let ns = text as NSString
        func adjustParagraph(_ range: NSRange, _ change: (NSMutableParagraphStyle) -> Void) {
            let style = (s.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle ?? paragraph)
                .mutableCopy() as! NSMutableParagraphStyle
            change(style)
            s.addAttribute(.paragraphStyle, value: style, range: range)
        }
        func adjustFont(_ range: NSRange, _ trait: NSFontTraitMask) {
            s.enumerateAttribute(.font, in: range) { value, sub, _ in
                guard let font = value as? NSFont else { return }
                s.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: sub)
            }
        }
        // Block styles first (whole lines), then the inline ones on top.
        for style in styles {
            switch style.kind {
            case .heading(let level):
                let (size, weight, space): (CGFloat, NSFont.Weight, CGFloat) =
                    [(22, .bold, 10), (19, .bold, 8), (17, .semibold, 6)][safe: level - 1] ?? (15, .semibold, 4)
                s.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: weight), range: style.range)
                adjustParagraph(style.range) { $0.paragraphSpacingBefore += space }
            case .quote(let depth):
                adjustParagraph(style.range) {
                    $0.headIndent += 16 * CGFloat(depth)
                    $0.firstLineHeadIndent += 16 * CGFloat(depth)
                }
            case .listMarker:
                // Wrapped lines hang under the item's text, not under its bullet or number.
                var start = 0, end = 0
                ns.getLineStart(&start, end: nil, contentsEnd: &end, for: style.range)
                let prefix = ns.substring(with: NSRange(location: start, length: NSMaxRange(style.range) - start))
                adjustParagraph(NSRange(location: start, length: end - start)) { $0.headIndent += prefix.size(withAttributes: [.font: body]).width }
            default:
                break
            }
        }
        for style in styles {
            switch style.kind {
            case .code: s.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: style.range)
            case .bold: adjustFont(style.range, .boldFontMask)
            case .italic: adjustFont(style.range, .italicFontMask)
            case .underline: s.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: style.range)
            case .strike: s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: style.range)
            default: break
            }
        }
        return s
    }

    /// A list item's first sentence with its bullet or number, which the chunk ranges leave
    /// out: it's read with the sentence, so it isn't dimmed before it.
    private static func withListMarker(_ r: NSRange, _ styles: [DisplayStyle]) -> NSRange {
        guard let marker = styles.first(where: { $0.kind == .listMarker && NSMaxRange($0.range) == r.location }) else { return r }
        return NSUnionRange(marker.range, r)
    }

    /// Text colors, with everything before `end` dimmed as read. Quotes are a shade lighter
    /// than the text around them; code and struck text keep their own color throughout.
    private static func color(_ storage: NSTextStorage, _ styles: [DisplayStyle], readUpTo end: Int) {
        let full = NSRange(location: 0, length: storage.length)
        func paint(_ range: NSRange, unread: NSColor, read: NSColor) {
            let r = NSIntersectionRange(range, full)
            let split = min(max(end, r.location), NSMaxRange(r))
            storage.addAttribute(.foregroundColor, value: read, range: NSRange(location: r.location, length: split - r.location))
            storage.addAttribute(.foregroundColor, value: unread, range: NSRange(location: split, length: NSMaxRange(r) - split))
        }
        paint(full, unread: .labelColor, read: .secondaryLabelColor)
        for style in styles {
            if case .quote = style.kind { paint(style.range, unread: .secondaryLabelColor, read: .tertiaryLabelColor) }
        }
        for style in styles {
            switch style.kind {
            case .code: paint(style.range, unread: .secondaryLabelColor, read: .secondaryLabelColor)
            case .strike: paint(style.range, unread: .tertiaryLabelColor, read: .tertiaryLabelColor)
            default: break
            }
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
        var styles: [DisplayStyle] = []
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
