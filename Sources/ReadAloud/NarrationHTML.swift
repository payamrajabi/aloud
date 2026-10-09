import Foundation

/// The HTML an app puts on the clipboard for ⌘C → `NarrationDoc`.
enum NarrationHTML {
    /// Nil when the HTML doesn't parse or holds nothing to read: then the selected text is
    /// read as it is. A selection inside a code block (only code) reads its text, as before
    /// there was HTML.
    static func parse(_ html: String) -> NarrationDoc? {
        guard let blocks = blocks(html), blocks.contains(where: { b in
            b.kind != .code && b.kind != .rule && b.runs.contains { !$0.styles.contains(.strike) && TextPrep.hasWords($0.text) }
        }) else { return nil }
        return NarrationDoc(blocks: blocks)
    }

    /// The HTML's blocks, spoken or not (a Markdown file's HTML block of code is shown).
    static func blocks(_ html: String) -> [NarrationBlock]? {
        guard let xml = try? XMLDocument(xmlString: html5ToHTML4(html), options: [.documentTidyHTML]),
              let root = xml.rootElement() else { return nil }
        let walker = Walker()
        walker.walk(root)
        walker.endBlock()
        return walker.blocks
    }

    private static let html5Block = try! NSRegularExpression(
        pattern: #"<(/?)(?:section|article|main|nav|header|footer|aside|figure|figcaption|details|summary|dialog|hgroup|search|menu)(?=[\s/>])"#,
        options: [.caseInsensitive])
    private static let nonText = try! NSRegularExpression(
        pattern: #"<(template|svg|math|video|audio|canvas)\b[^>]*>[\s\S]*?</\1\s*>"#, options: [.caseInsensitive])

    /// Tidy knows only HTML 4: it drops <section>, <figure>, <header> and the like but keeps
    /// their text, so a <figcaption> ran into the image before it ("A cupOur morning cup").
    /// They become <div>s. What's inside <svg>, <math>, <template> and media isn't text to read.
    private static func html5ToHTML4(_ html: String) -> String {
        let all = NSRange(location: 0, length: (html as NSString).length)
        let stripped = lineBreaks(nonText.stringByReplacingMatches(in: html, range: all, withTemplate: " "))
        return html5Block.stringByReplacingMatches(in: stripped, range: NSRange(location: 0, length: (stripped as NSString).length),
                                                   withTemplate: "<$1div")
    }

    private static let tag = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->|<(/?)([A-Za-z][A-Za-z0-9:-]*)((?:[^>"']|"[^"]*"|'[^']*')*)>"#)
    private static let whiteSpace = try! NSRegularExpression(pattern: #"white-space(?:-collapse)?\s*:\s*([a-z-]+)"#, options: [.caseInsensitive])
    private static let void: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source",
                                            "track", "wbr"]

    /// Text styled `white-space: pre-wrap` (posts on X, chat messages, the prompts in AI
    /// chats) breaks its lines with newlines, which Tidy collapses like any other space:
    /// they become <br>s first, read as a <br> is. A <pre> keeps its own.
    private static func lineBreaks(_ html: String) -> String {
        guard html.range(of: "white-space", options: .caseInsensitive) != nil else { return html }
        let ns = html as NSString
        var out = ""
        var open: [(name: String, keepsBreaks: Bool?)] = []   // nil: inherits
        var last = 0
        func text(upTo end: Int) {
            let t = ns.substring(with: NSRange(location: last, length: end - last))
            let keeps = open.last(where: { $0.keepsBreaks != nil })?.keepsBreaks == true
                && !open.contains { ["pre", "textarea", "script", "style"].contains($0.name) }
            out += keeps ? t.replacingOccurrences(of: "\n", with: "<br>") : t
        }
        for m in tag.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            text(upTo: m.range.location)
            out += ns.substring(with: m.range)
            last = NSMaxRange(m.range)
            guard m.range(at: 2).location != NSNotFound else { continue }   // a comment
            let name = ns.substring(with: m.range(at: 2)).lowercased()
            let attributes = ns.substring(with: m.range(at: 3))
            if m.range(at: 1).length > 0 {
                if let i = open.lastIndex(where: { $0.name == name }) { open.removeSubrange(i...) }
            } else if !void.contains(name), !attributes.hasSuffix("/") {
                let values = whiteSpace.matches(in: attributes, range: NSRange(location: 0, length: (attributes as NSString).length))
                let value = values.last.map { (attributes as NSString).substring(with: $0.range(at: 1)).lowercased() }
                open.append((name, value.map { ["pre", "pre-wrap", "pre-line", "break-spaces", "preserve", "preserve-breaks"].contains($0) }))
            }
        }
        text(upTo: ns.length)
        return out
    }
}

private final class Walker {
    var blocks: [NarrationBlock] = []
    private var open: NarrationBlock?
    private var breaks = 0                  // <br>s in the open block
    private var styles: RunStyles = []
    private var quoteDepth = 0
    private var lists: [List] = []
    private var inCell = 0                  // in a data table's cell, blocks are only spaces

    private static let skipped: Set<String> = ["head", "script", "style", "title", "meta", "template", "noscript", "link",
                                               "svg", "iframe", "object"]
    /// (HTML5's <section>, <figure> and the like are <div>s by now: `html5ToHTML4`.)
    private static let containers: Set<String> = ["html", "body", "div", "address", "center", "dl", "dt", "dd", "form",
                                                  "fieldset", "legend", "caption", "thead", "tbody", "tfoot", "tr", "td", "th"]

    func walk(_ node: XMLNode) {
        switch node.kind {
        case .text: text(node.stringValue ?? "")
        case .element: element(node as! XMLElement)
        default: break   // comments, processing instructions
        }
    }

    private func children(_ el: XMLElement) {
        for child in el.children ?? [] { walk(child) }
    }

    private static func name(_ node: XMLNode) -> String {
        (node.localName ?? node.name ?? "").lowercased()
    }

    private func element(_ el: XMLElement) {
        let name = Self.name(el)
        guard !Self.skipped.contains(name) else { return }
        let css = el.attribute(forName: "style")?.stringValue
        // Word's list paragraphs carry their bullet or number as text in a span it marks to
        // be ignored; `wordListItem` reads it.
        guard css.map(Self.isWordMarker) != true else { return }
        let saved = styles
        defer { styles = saved }
        if let style = RunStyles(tag: name) { styles.insert(style) }
        if let css { applyCSS(css) }

        switch name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            block(.heading(level: Int(String(name.dropFirst())) ?? 1), el)
        case "p":
            if let level = css.flatMap(Self.wordListLevel) { return wordListItem(el, depth: level - 1) }
            block(.paragraph, el)
        case "ul", "ol":
            guard inCell == 0 else { return spaced(el) }
            endBlock()
            let start = el.attribute(forName: "start")?.stringValue.flatMap { Int($0) } ?? 1
            lists.append(List(ordered: name == "ol", start: start, numbering: Self.numbering(el)))
            children(el)
            lists.removeLast()
            endBlock()
        case "li":
            listItem(el)
        case "blockquote":
            guard inCell == 0 else { return spaced(el) }
            endBlock()
            quoteDepth += 1
            children(el)
            endBlock()
            quoteDepth -= 1
        case "pre":
            guard inCell == 0 else { return spaced(el) }
            endBlock()
            let text = el.stringValue ?? ""
            if Self.isCode(el) {
                blocks.append(NarrationBlock(kind: .code, quoteDepth: quoteDepth, runs: [NarrationRun(text: text, styles: .code)]))
            } else {
                // A plain-text page as the browser shows it (a .txt file, an RFC, a mail
                // archive): its lines are read as plain text's are.
                blocks += NarrationPlain.parse(text).blocks.map { b in
                    var b = b
                    b.quoteDepth = quoteDepth
                    return b
                }
            }
        case "hr":
            guard inCell == 0 else { return }
            endBlock()
            blocks.append(NarrationBlock(kind: .rule, quoteDepth: quoteDepth))
        case "br":
            lineBreak()
        case "img":
            image(el)
        case "input":
            // GitHub's task lists: the box is shown, not read.
            if el.attribute(forName: "type")?.stringValue?.lowercased() == "checkbox", let b = open, case .listItem = b.kind,
               !TextPrep.hasWords(b.text) {
                open?.marker = el.attribute(forName: "checked") != nil ? "☑" : "☐"
            }
        case "table":
            table(el)
        default:
            if Self.containers.contains(name) {
                guard inCell == 0 else { return spaced(el) }
                boundary()
                children(el)
                boundary()
            } else {
                children(el)   // inline
            }
        }
    }

    /// A block element inside a table cell: its text, set off by spaces.
    private func spaced(_ el: XMLElement) {
        append(" ", styles)
        children(el)
        append(" ", styles)
    }

    private func block(_ kind: NarrationBlock.Kind, _ el: XMLElement) {
        guard inCell == 0 else { return spaced(el) }
        boundary()
        if open == nil { open = NarrationBlock(kind: kind, quoteDepth: quoteDepth) }
        children(el)
        boundary()
    }

    private struct List {
        var ordered: Bool
        var start: Int
        var numbering: String?     // "a", "A", "i", "I": letters or roman numerals
        var next: [Int: Int] = [:] // by depth: Google Docs can put several levels in one list
    }

    private func listItem(_ el: XMLElement) {
        guard inCell == 0 else { return spaced(el) }
        // A list put straight inside another (Google Docs' sub-lists) is wrapped by Tidy in
        // an <li> of its own: not an item, and it takes no number.
        let own = (el.children ?? []).filter { node in
            switch node.kind {
            case .element: return !["ul", "ol"].contains(Self.name(node))
            case .text: return !(node.stringValue ?? "").allSatisfy(\.isWhitespace)
            default: return false
            }
        }
        if own.isEmpty { return children(el) }
        endBlock()
        var depth = max(0, lists.count - 1)
        // Google Docs gives each item its level, which a flat list needs.
        if let level = el.attribute(forName: "aria-level")?.stringValue.flatMap({ Int($0) }) { depth = max(0, level - 1) }
        var kind = NarrationBlock.Kind.listItem(ordered: false, number: nil, depth: depth)
        var marker: String?
        if let list = lists.last, list.ordered {
            let n = el.attribute(forName: "value")?.stringValue.flatMap { Int($0) }
                ?? list.next[depth] ?? (depth == lists.count - 1 ? list.start : 1)
            lists[lists.count - 1].next = list.next.filter { $0.key < depth }.merging([depth: n + 1]) { $1 }
            // Letters and roman numerals are shown, not read, as in plain text.
            if let numbering = Self.numbering(el) ?? list.numbering, let shown = Self.marker(n, numbering) {
                kind = .listItem(ordered: true, number: nil, depth: depth)
                marker = shown
            } else {
                kind = .listItem(ordered: true, number: n, depth: depth)
            }
        }
        open = NarrationBlock(kind: kind, quoteDepth: quoteDepth, marker: marker)
        children(el)
        endBlock()
    }

    /// An ordered list's numbering when it isn't 1, 2, 3: `type="a"`, or a list-style-type.
    private static func numbering(_ el: XMLElement) -> String? {
        if let type = el.attribute(forName: "type")?.stringValue, ["a", "A", "i", "I"].contains(type) { return type }
        guard let css = el.attribute(forName: "style")?.stringValue?.lowercased(),
              let m = css.range(of: #"list-style(-type)?\s*:[^;]*"#, options: .regularExpression) else { return nil }
        let value = css[m]
        for (name, type) in [("lower-alpha", "a"), ("lower-latin", "a"), ("upper-alpha", "A"), ("upper-latin", "A"),
                             ("lower-roman", "i"), ("upper-roman", "I")] where value.contains(name) {
            return type
        }
        return nil
    }

    /// "c." for 3 in letters, "iii." in roman numerals.
    private static func marker(_ n: Int, _ numbering: String) -> String? {
        guard n > 0 else { return nil }
        let upper = numbering == "A" || numbering == "I"
        var s = ""
        if numbering.lowercased() == "a" {
            var k = n
            while k > 0 { k -= 1; s = String(UnicodeScalar(UInt8(97 + k % 26))) + s; k /= 26 }
        } else {
            guard n < 4000 else { return nil }
            var k = n
            for (value, numeral) in [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"), (50, "l"),
                                     (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")] {
                while k >= value { s += numeral; k -= value }
            }
        }
        return (upper ? s.uppercased() : s) + "."
    }

    // MARK: - Word

    private static func isWordMarker(_ css: String) -> Bool {
        css.range(of: #"mso-list\s*:\s*ignore"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A Word list paragraph's level ("mso-list:l0 level2 lfo1" is 2).
    private static func wordListLevel(_ css: String) -> Int? {
        guard let m = css.range(of: #"mso-list\s*:\s*l\d+\s+level\d+"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return Int(String(css[m].reversed().prefix(while: \.isNumber).reversed()))
    }

    /// A Word list paragraph: an item numbered as its marker is ("2." is read; "a." and
    /// "iv." are shown; "·", "o" and "§" are bullets).
    private func wordListItem(_ el: XMLElement, depth: Int) {
        guard inCell == 0 else { return spaced(el) }
        endBlock()
        let marker = Self.wordMarker(el)?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{00A0}"))) ?? ""
        var kind = NarrationBlock.Kind.listItem(ordered: false, number: nil, depth: depth)
        var shown: String?
        if marker.range(of: #"^\d{1,3}[.)]$"#, options: .regularExpression) != nil {
            kind = .listItem(ordered: true, number: Int(marker.dropLast()), depth: depth)
        } else if marker.range(of: #"^[A-Za-z]{1,5}[.)]$"#, options: .regularExpression) != nil {
            kind = .listItem(ordered: true, number: nil, depth: depth)
            shown = marker
        }
        open = NarrationBlock(kind: kind, quoteDepth: quoteDepth, marker: shown)
        children(el)
        endBlock()
    }

    private static func wordMarker(_ el: XMLElement) -> String? {
        for child in elements(el) {
            if let css = child.attribute(forName: "style")?.stringValue, isWordMarker(css) { return child.stringValue }
            if let found = wordMarker(child) { return found }
        }
        return nil
    }

    // MARK: - Images and code

    /// An image's alt text, unless the page hides it from screen readers (Wikipedia's
    /// formulas, whose MathML isn't copied) or it's an emoji: a picture of one is the
    /// character it shows ("🎉", read as text), and Slack's ":tada:" isn't read.
    private func image(_ el: XMLElement) {
        func attribute(_ name: String) -> String { el.attribute(forName: name)?.stringValue?.lowercased() ?? "" }
        guard attribute("aria-hidden") != "true", !["presentation", "none"].contains(attribute("role")),
              let alt = el.attribute(forName: "alt")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !alt.isEmpty,
              alt.range(of: #"^:[\w+-]+:$"#, options: .regularExpression) == nil else { return }
        let emoji = attribute("class").contains("emoji") || !TextPrep.hasWords(alt)
        append(alt, emoji ? styles : styles.union(.image))
    }

    /// A <pre> is code when it holds <code> (Markdown renderers, Stack Overflow, MDN),
    /// syntax highlighting's classed spans (GitHub, Wikipedia, Sphinx), or has a class of its
    /// own (Slack's code blocks) or a highlighter's around it (GitHub's one-word "swift
    /// build"). A bare one is a plain-text page as the browser shows it.
    private static func isCode(_ pre: XMLElement) -> Bool {
        func marked(_ el: XMLElement) -> Bool {
            elements(el).contains { ["code", "samp", "kbd", "tt"].contains(name($0)) || $0.attribute(forName: "class") != nil || marked($0) }
        }
        let around = (pre.parent as? XMLElement)?.attribute(forName: "class")?.stringValue ?? ""
        return pre.attribute(forName: "class") != nil || marked(pre)
            || around.range(of: #"highlight|code|syntax|hljs|prism|chroma|lang"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Tables

    private func table(_ el: XMLElement) {
        let rows = Self.rows(el)
        // Layout tables (emails) hold other tables, or one cell a row: read their cells as blocks.
        guard inCell == 0, !Self.contains(el, "table"), rows.contains(where: { Self.cells($0.row).count > 1 }) else {
            if inCell > 0 { return spaced(el) }
            endBlock()
            children(el)
            endBlock()
            return
        }
        endBlock()
        for caption in Self.elements(el) where Self.name(caption) == "caption" { block(.paragraph, caption) }
        for (row, inHead) in rows {
            let cells = Self.cells(row)
            let header = inHead || (!cells.isEmpty && cells.allSatisfy { Self.name($0) == "th" })
            open = NarrationBlock(kind: .tableRow(header: header), quoteDepth: quoteDepth)
            inCell += 1
            for (k, cell) in cells.enumerated() {
                if k > 0 { open?.runs.append(NarrationRun(text: NarrationBlock.cellSeparator)) }
                let saved = styles
                if let css = cell.attribute(forName: "style")?.stringValue { applyCSS(css) }
                children(cell)
                styles = saved
            }
            inCell -= 1
            endBlock()
        }
    }

    private static func elements(_ el: XMLElement) -> [XMLElement] {
        (el.children ?? []).compactMap { $0 as? XMLElement }
    }

    private static func rows(_ table: XMLElement) -> [(row: XMLElement, inHead: Bool)] {
        elements(table).flatMap { child -> [(row: XMLElement, inHead: Bool)] in
            switch name(child) {
            case "tr": return [(child, false)]
            case "thead", "tbody", "tfoot":
                return elements(child).filter { name($0) == "tr" }.map { ($0, name(child) == "thead") }
            default: return []
            }
        }
    }

    private static func cells(_ row: XMLElement) -> [XMLElement] {
        elements(row).filter { ["td", "th"].contains(name($0)) }
    }

    private static func contains(_ el: XMLElement, _ tag: String) -> Bool {
        elements(el).contains { name($0) == tag || contains($0, tag) }
    }

    // MARK: - Text

    private func text(_ s: String) {
        let t = s.replacingOccurrences(of: "[ \\t\\n\\r\\f]+", with: " ", options: .regularExpression)
        guard !t.isEmpty, open != nil || t != " " else { return }
        append(t, styles)
    }

    private func append(_ t: String, _ s: RunStyles) {
        if open == nil {
            guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            open = NarrationBlock(kind: .paragraph, quoteDepth: quoteDepth)
        }
        if let last = open!.runs.last, last.styles == s, !s.contains(.image),
           last.text != "\n", last.text != NarrationBlock.cellSeparator {
            open!.runs[open!.runs.count - 1].text += t
        } else {
            open!.runs.append(NarrationRun(text: t, styles: s))
        }
    }

    private func lineBreak() {
        guard open != nil else { return }
        if inCell > 0 { return append(" ", styles) }
        open!.runs.append(NarrationRun(text: "\n"))
        breaks += 1
    }

    /// Ends the open block, unless it's a list item still waiting for its text
    /// ("<li><p>Item</p></li>").
    private func boundary() {
        if let b = open, case .listItem = b.kind, b.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        endBlock()
    }

    func endBlock() {
        guard let b = open else { return }
        open = nil
        let lines = breaks
        breaks = 0
        guard !b.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Two or more <br>s in a paragraph are chat lines, each its own paragraph; a single
        // one is a wrapped line.
        if lines >= 2, b.kind == .paragraph {
            var line = NarrationBlock(kind: .paragraph, quoteDepth: b.quoteDepth)
            for run in b.runs + [NarrationRun(text: "\n")] {
                if run.text == "\n" {
                    if !line.text.trimmingCharacters(in: .whitespaces).isEmpty { blocks.append(line) }
                    line.runs = []
                } else {
                    line.runs.append(run)
                }
            }
            return
        }
        var block = b
        for k in block.runs.indices where block.runs[k].text == "\n" { block.runs[k].text = " " }
        blocks.append(block)
    }

    // MARK: - Inline styles

    /// Inline CSS: Google Docs wraps everything in <b style="font-weight:normal">, so a
    /// normal weight cancels an enclosing bold.
    private func applyCSS(_ css: String) {
        for declaration in css.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1).map {
                $0.replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespaces).lowercased()
            }
            guard parts.count == 2 else { continue }
            let value = parts[1]
            switch parts[0] {
            case "font-weight":
                if value.hasPrefix("bold") || value == "bolder" || (Int(value) ?? 0) >= 600 {
                    styles.insert(.bold)
                } else if value == "normal" || value == "lighter" || (Int(value).map { $0 <= 500 } ?? false) {
                    styles.remove(.bold)
                }
            case "font-style":
                if value.hasPrefix("italic") || value.hasPrefix("oblique") {
                    styles.insert(.italic)
                } else if value == "normal" {
                    styles.remove(.italic)
                }
            case "text-decoration", "text-decoration-line":
                if value.contains("line-through") { styles.insert(.strike) }
                // A link's underline is how links look, not emphasis.
                if value.contains("underline"), !styles.contains(.link) { styles.insert(.underline) }
            default:
                break
            }
        }
    }
}
