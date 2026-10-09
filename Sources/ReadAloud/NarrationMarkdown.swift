import Foundation

/// Markdown → `NarrationDoc`, by Foundation's parser.
enum NarrationMarkdown {
    // MARK: - Detection

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }
    private static let heading = regex(#"^#{1,6}\s+\S"#)
    private static let quote = regex(#"^\s{0,3}>"#)
    private static let fenceLine = regex(#"^\s{0,3}(```|~~~)"#)
    private static let tableLine = regex(#"^\s*\|.*\|\s*$"#)
    private static let ruleLine = regex(#"^\s{0,3}(-{3,}|\*{3,}|_{3,})\s*$"#)
    /// **x**, __x y__ (not a Python name like __init__), ~~x~~, `x`, [x](y), ![x](y). The
    /// space inside __x y__ is the first one after the opening word: "__main__.py" and a
    /// long line after it took seconds when any split of the line could be tried.
    private static let inline = regex(#"\*\*\S(?:[^\n]*?\S)?\*\*|__[^_\s][^_\s]*\s[^_\n]*?[^_\s]__|~~\S(?:[^\n]*?\S)?~~|`[^`\n]+`|!?\[[^\]\n]*\]\([^)\s]+(?:\s+"[^"\n]*")?\)"#)

    /// Markdown other than list markers: headings, quotes, fences, rules, tables, inline
    /// marks. This is what makes text Markdown rather than prose, chat or email; a lone
    /// "*", a #hashtag, snake_case or list lines aren't enough.
    static func hasMarkupBeyondLists(_ s: String) -> Bool {
        let all = NSRange(location: 0, length: (s as NSString).length)
        func has(_ re: NSRegularExpression) -> Bool { re.firstMatch(in: s, range: all) != nil }
        return has(heading) || has(quote) || has(fenceLine) || has(ruleLine) || has(inline) || tableLine.numberOfMatches(in: s, range: all) >= 2
    }

    // MARK: - Parsing

    static func parse(_ raw: String) -> NarrationDoc {
        let text = TextPrep.normalizeCharacters(raw)
        // Foundation reads text indented four spaces as code; it's only code here when the
        // author fenced some.
        let fenced = fenceLine.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
        guard let attributed = try? AttributedString(
            markdown: prepare(text),
            options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        ) else { return NarrationPlain.parse(raw) }

        var blocks: [NarrationBlock] = []
        var openKey: Int?
        var openCell: Int?
        var seenItems = Set<Int>()
        var htmlStyles: RunStyles = []   // from inline <u>, <s>, <b>… tags
        var htmlKey = -1

        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            let inline = run.inlinePresentationIntent ?? []
            if inline.contains(.blockHTML) {
                // An HTML block ("<div align=center>…</div>"): read like copied HTML.
                openKey = nil
                blocks += NarrationHTML.blocks(text) ?? []
                continue
            }
            let (key, cell, kind, quoteDepth) = describe(run.presentationIntent, fenced: fenced, seenItems: &seenItems, htmlKey: &htmlKey)
            if key != openKey {
                blocks.append(NarrationBlock(kind: kind, quoteDepth: quoteDepth))
                openKey = key
                openCell = cell
                htmlStyles = []   // an unclosed <u> ends with its paragraph
            } else if cell != openCell {
                blocks[blocks.count - 1].runs.append(NarrationRun(text: NarrationBlock.cellSeparator))
                openCell = cell
            }

            if inline.contains(.inlineHTML) {
                if let run = applyTag(text, to: &htmlStyles) { blocks[blocks.count - 1].runs.append(run) }
                continue
            }
            var styles = htmlStyles
            if inline.contains(.stronglyEmphasized) { styles.insert(.bold) }
            if inline.contains(.emphasized) { styles.insert(.italic) }
            if inline.contains(.code) { styles.insert(.code) }
            if inline.contains(.strikethrough) { styles.insert(.strike) }
            if run.link != nil { styles.insert(.link) }
            if run.imageURL != nil { styles.insert(.image) }
            var t = text
            if inline.contains(.softBreak) || inline.contains(.lineBreak) {
                t = " "
            } else if kind != .code {
                t = t.replacingOccurrences(of: "\n", with: " ")
            }
            blocks[blocks.count - 1].runs.append(NarrationRun(text: t, styles: styles))
        }
        return NarrationDoc(blocks: blocks)
    }

    /// The block a run belongs to (a table's cells share their row's block), its cell, and
    /// the block's kind and quote depth.
    private static func describe(_ intent: PresentationIntent?, fenced: Bool, seenItems: inout Set<Int>, htmlKey: inout Int)
        -> (key: Int, cell: Int?, kind: NarrationBlock.Kind, quoteDepth: Int) {
        guard let components = intent?.components, let innermost = components.first else {
            htmlKey -= 1
            return (htmlKey, nil, .paragraph, 0)
        }
        var key = innermost.identity
        var cell: Int?
        var kind = NarrationBlock.Kind.paragraph
        var item: (identity: Int, ordinal: Int)?
        var ordered = false
        var lists = 0, quotes = 0
        for c in components {   // innermost first
            switch c.kind {
            case .header(let level): kind = .heading(level: level)
            case .codeBlock: kind = fenced ? .code : .paragraph
            case .thematicBreak: kind = .rule
            case .tableCell: cell = c.identity
            case .tableHeaderRow: kind = .tableRow(header: true); key = c.identity
            case .tableRow: kind = .tableRow(header: false); key = c.identity
            case .listItem(let ordinal): if item == nil { item = (c.identity, ordinal) }
            case .orderedList: if lists == 0 { ordered = true }; lists += 1
            case .unorderedList: lists += 1
            case .blockQuote: quotes += 1
            default: break
            }
        }
        // A list item's first paragraph carries its bullet; later ones are paragraphs.
        if let item, kind == .paragraph, !seenItems.contains(item.identity) {
            seenItems.insert(item.identity)
            kind = .listItem(ordered: ordered, number: ordered ? item.ordinal : nil, depth: max(0, lists - 1))
        }
        return (key, cell, kind, quotes)
    }

    private static let tag = try! NSRegularExpression(pattern: #"^<(/?)([A-Za-z][A-Za-z0-9-]*)([^>]*)>$"#)
    private static let alt = try! NSRegularExpression(pattern: #"\balt\s*=\s*(?:"([^"]*)"|'([^']*)')"#, options: [.caseInsensitive])

    /// An inline HTML tag: the styles of `RunStyles(tag:)` (<u> underline, <s> strike through,
    /// <b> and <i> as Markdown's…), <br> a space, <img alt> an image. Any other tag is dropped.
    private static func applyTag(_ html: String, to styles: inout RunStyles) -> NarrationRun? {
        let ns = html as NSString
        guard let m = tag.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let closing = m.range(at: 1).length > 0
        let name = ns.substring(with: m.range(at: 2)).lowercased()
        switch name {
        case "br": return NarrationRun(text: " ", styles: styles)
        case "img":
            let attrs = ns.substring(with: m.range(at: 3))
            guard let a = alt.firstMatch(in: attrs, range: NSRange(location: 0, length: (attrs as NSString).length)) else { return nil }
            let text = (attrs as NSString).substring(with: a.range(at: 1).location != NSNotFound ? a.range(at: 1) : a.range(at: 2))
            return NarrationRun(text: text, styles: styles.union(.image))
        default: break
        }
        guard let style = RunStyles(tag: name) else { return nil }
        if closing { styles.remove(style) } else if !html.hasSuffix("/>") { styles.insert(style) }
        return nil
    }

    // MARK: - Before parsing

    /// YAML front matter: "key:" lines from the first one on, closed by "---" or "...".
    private static let frontMatter = try! NSRegularExpression(pattern: #"\A---[ \t]*\n(?=[A-Za-z_][\w-]*[ \t]*:)[\s\S]*?\n(?:---|\.\.\.)[ \t]*(?:\n|\z)"#)
    private static let comment = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->"#)
    private static let footnoteDefinition = try! NSRegularExpression(pattern: #"^(\s{0,3})\[\^[^\]\s]+\]:[ \t]*"#)
    private static let codeSpan = try! NSRegularExpression(pattern: #"(`+)[\s\S]*?\1"#)
    private static let footnoteRef = try! NSRegularExpression(pattern: #"\[\^[^\]\s]+\]"#)
    private static let dunder = try! NSRegularExpression(pattern: #"(?<![\w\\])__([A-Za-z0-9][A-Za-z0-9_]*?)__(?![A-Za-z0-9])"#)

    /// Removes YAML front matter, HTML comments and footnote markers, and escapes Python
    /// names ("__init__", which CommonMark makes a bold "init"), outside code.
    private static func prepare(_ text: String) -> String {
        var s = text
        // A selection that starts at a rule ("---", "## Part two", …, "---") isn't front
        // matter: that has no blank lines.
        if let m = frontMatter.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)),
           (s as NSString).substring(with: m.range).range(of: #"\n[ \t]*\n"#, options: .regularExpression) == nil {
            s = (s as NSString).replacingCharacters(in: m.range, with: "")
        }
        s = replace(comment, in: s, with: "")
        var inFence = false
        var lines: [String] = []
        for line in s.components(separatedBy: "\n") {
            let isFence = fenceLine.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
            if isFence { inFence.toggle() }
            guard !inFence, !isFence else { lines.append(line); continue }
            var l = replace(footnoteDefinition, in: line, with: "$1")
            l = outsideCodeSpans(l) { part in
                replace(dunder, in: replace(footnoteRef, in: part, with: ""), with: #"\\_\\_$1\\_\\_"#)
            }
            lines.append(l)
        }
        return lines.joined(separator: "\n")
    }

    private static func replace(_ re: NSRegularExpression, in s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }

    private static func outsideCodeSpans(_ line: String, _ transform: (String) -> String) -> String {
        let ns = line as NSString
        var out = ""
        var last = 0
        for m in codeSpan.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            out += transform(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            out += ns.substring(with: m.range)
            last = NSMaxRange(m.range)
        }
        return out + transform(ns.substring(from: last))
    }
}
