import Foundation

/// Markdown → `NarrationDoc`, by Foundation's parser.
enum NarrationMarkdown {
    // MARK: - Detection

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }
    private static let heading = regex(#"^#{1,6}\s+\S"#)
    /// A quote marker, but not ">50% of users" or ">= 3".
    private static let quote = regex(#"^\s{0,3}>(?![\d=])"#)
    private static let fenceLine = regex(#"^\s{0,3}(```|~~~)"#)
    /// A table's delimiter row ("|---|:--:|", "--- | ---"): without one, "| a | b |" lines
    /// are text (MySQL output, org-mode), and Markdown would run them together.
    private static let tableDelimiter = regex(#"^\s*\|?(\s*:?-+:?\s*\|)+\s*(:?-+:?\s*)?$"#)
    private static let ruleLine = regex(#"^\s{0,3}(-{3,}|\*{3,}|_{3,})\s*$"#)
    /// **x**, __x y__ (not a Python name like __init__), ~~x~~, `x`, [x](y), ![x](y). The
    /// space inside __x y__ is the first one after the opening word: "__main__.py" and a
    /// long line after it took seconds when any split of the line could be tried.
    private static let inline = regex(#"\*\*\S(?:[^\n]*?\S)?\*\*|__[^_\s][^_\s]*\s[^_\n]*?[^_\s]__|~~\S(?:[^\n]*?\S)?~~|`[^`\n]+`|!?\[[^\]\n]*\]\([^)\s]+(?:\s+"[^"\n]*")?\)"#)

    /// Markdown other than list markers: headings, quotes, fences, rules, tables, inline
    /// marks. This is what makes text Markdown rather than prose, chat or email; a lone
    /// "*", a #hashtag, snake_case or list lines aren't enough, and nor are the marks plain
    /// text makes by other means:
    /// - a dash line under a line of text ("Please book by Friday." / "---" / "Jordan"), an
    ///   email's separator: a rule counts with blank lines around it;
    /// - "| a | b |" rows with no delimiter row;
    /// - "# " lines that are comments ("# Install the dependencies" over "npm install") or
    ///   notes ("# of seats: 40").
    static func hasMarkupBeyondLists(_ s: String) -> Bool {
        let text = NarrationDoc.normalize(s)
        let all = NSRange(location: 0, length: (text as NSString).length)
        if fenceLine.firstMatch(in: text, range: all) != nil || inline.firstMatch(in: text, range: all) != nil { return true }
        let lines = text.components(separatedBy: "\n")
        func blank(_ k: Int) -> Bool { !lines.indices.contains(k) || lines[k].trimmingCharacters(in: .whitespaces).isEmpty }
        for (i, line) in lines.enumerated() {
            if matches(quote, line) { return true }
            if matches(ruleLine, line), blank(i - 1), blank(i + 1) { return true }
            if matches(tableDelimiter, line), !blank(i - 1), lines[i - 1].contains("|") { return true }
            if matches(heading, line), looksLikeHeading(line, next: blank(i + 1) ? nil : lines[i + 1]) { return true }
        }
        return false
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// A "# " line that reads as a heading: not one that opens on a lowercase word ("# of
    /// seats", "# install deps"), nor one with a line of code under it.
    private static func looksLikeHeading(_ line: String, next: String?) -> Bool {
        let words = line.drop { $0 == "#" }.split(separator: " ")
        if let first = words.first, first.first?.isLowercase == true, !first.contains(where: \.isUppercase) { return false }
        guard let next else { return true }
        return !looksLikeCode(next)
    }

    /// A line of code or config rather than prose: it opens on a lowercase word ("npm
    /// install", "server:") or a "$" prompt, or has an assignment, a brace, a call or a
    /// closing ";".
    private static func looksLikeCode(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if let c = t.first, c.isLowercase || c == "$" { return true }
        return t.range(of: #"[={}]|\w\(|;$"#, options: .regularExpression) != nil
    }

    // MARK: - Parsing

    static func parse(_ raw: String) -> NarrationDoc {
        let text = NarrationDoc.normalize(raw)
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

    /// "# of seats: 40", "## the end": a lowercase small word after the marks isn't a heading's.
    private static let notHeading = try! NSRegularExpression(pattern: #"^(\s{0,3})(#{1,6})(?=[ \t]+(?:of|the|a|an|and|or|to|in|on|at|by|for|with|from|per|vs)\b)"#)
    /// ">50% of respondents", ">= 3 items": a comparison, not a quote.
    private static let notQuote = try! NSRegularExpression(pattern: #"^(\s{0,3})>(?=[\d=])"#)

    /// Removes YAML front matter, HTML comments and footnote markers; escapes, outside code,
    /// Python names ("__init__", which CommonMark makes a bold "init"), placeholders that
    /// aren't HTML ("<your-token>", "<env>", "Vec<T>"), "# of …" and ">50%" lines; and keeps
    /// the lines of plain text that has a little Markdown in it apart (`separator`).
    private static func prepare(_ text: String) -> String {
        var s = text
        // A selection that starts at a rule ("---", "## Part two", …, "---") isn't front
        // matter: that has no blank lines.
        if let m = frontMatter.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)),
           (s as NSString).substring(with: m.range).range(of: #"\n[ \t]*\n"#, options: .regularExpression) == nil {
            s = (s as NSString).replacingCharacters(in: m.range, with: "")
        }
        s = replace(comment, in: s, with: "")
        let source = s.components(separatedBy: "\n")
        let tables = tableRows(source)
        func blank(_ k: Int) -> Bool { !source.indices.contains(k) || source[k].trimmingCharacters(in: .whitespaces).isEmpty }
        var inFence = false
        var inHTML = false
        var listOpen = false                        // the last line belongs to a list item
        var previous: (Quoted, Shape)?              // the last line, when it's text and not blank
        var lines: [String] = []
        for (i, line) in source.enumerated() {
            let isFence = matches(fenceLine, line)
            if isFence { inFence.toggle() }
            guard !inFence, !isFence else { lines.append(line); previous = nil; continue }
            guard !blank(i) else { lines.append(line); previous = nil; inHTML = false; continue }
            // An HTML block ("<div align=center>" … to a blank line) is left as it is.
            if !inHTML, startsHTMLBlock(line, afterBlank: previous == nil) { inHTML = true }
            guard !inHTML else { lines.append(line); previous = nil; continue }

            var l = replace(footnoteDefinition, in: line, with: "$1")
            l = replace(notQuote, in: replace(notHeading, in: l, with: #"$1\\$2"#), with: #"$1\\>"#)
            l = outsideCodeSpans(l) { part in
                escapeTags(replace(dunder, in: replace(footnoteRef, in: part, with: ""), with: #"\\_\\_$1\\_\\_"#), in: s)
            }
            let q = quoted(l)
            var shape = tables.contains(i) ? .table : Self.shape(q.content)
            let indent = q.content.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            var separate = false
            if let (pq, pshape) = previous {
                if pq.depth > q.depth {
                    // "> I have a dentist appointment on Wednesday." / "Thanks": the reply,
                    // not a lazy continuation of the quote.
                    separate = true
                } else if pq.depth == q.depth {
                    switch shape {
                    case .underline(let mark, let count):
                        // "Title" / "-----" is a heading; a dash line under the end of a
                        // longer paragraph, or under a sentence, or "--" (a signature's
                        // separator), is a rule or text.
                        guard pshape == .text, !listOpen else { break }
                        let single = i < 2 || blank(i - 2) || [.heading, .rule].contains(Self.shape(quoted(source[i - 2]).content))
                        let setext = count >= 3 && single && blank(i + 1) && isTitleLike(pq.content)
                        if !setext {
                            separate = true
                            shape = mark == "-" && count >= 3 ? .rule : .text
                        }
                    case .text:
                        let open = pshape == .text || pshape == .listItem
                        separate = open && startsNewLine(after: pq.content, q.content, indent: indent, inList: listOpen)
                    default:
                        break
                    }
                }
            }
            if separate { lines.append(Array(repeating: ">", count: q.depth).joined(separator: " ")) }
            switch shape {
            case .listItem: listOpen = true
            case .text: listOpen = listOpen && !separate && (previous != nil || indent >= 2)
            default: listOpen = false
            }
            previous = (q, shape)
            lines.append(l)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Lines

    private struct Quoted {
        var depth: Int           // how many ">"
        var content: String      // after them
    }

    private static func quoted(_ line: String) -> Quoted {
        var depth = 0
        var rest = Substring(line)
        while true {
            let spaces = rest.prefix { $0 == " " }.count
            guard spaces <= 3, rest.dropFirst(spaces).first == ">" else { break }
            rest = rest.dropFirst(spaces + 1)
            if rest.first == " " { rest = rest.dropFirst() }
            depth += 1
        }
        return Quoted(depth: depth, content: String(rest))
    }

    private enum Shape: Equatable {
        case text, heading, listItem, rule, table
        case underline(Character, Int)   // a setext underline, or a dash line
    }

    private static let atxHeading = regex(#"^\s{0,3}#{1,6}(\s|$)"#)
    private static let underline = regex(#"^\s{0,3}(-+|=+)\s*$"#)
    private static let anyRule = regex(#"^\s{0,3}((\*\s*){3,}|(_\s*){3,}|(-\s*){3,})$"#)
    private static let listMarker = regex(#"^\s*([-*+]|\d{1,9}[.)])(\s|$)"#)

    private static func shape(_ content: String) -> Shape {
        if matches(atxHeading, content) { return .heading }
        if matches(underline, content) {
            let marks = content.filter { $0 == "-" || $0 == "=" }
            return .underline(marks.first ?? "-", marks.count)
        }
        if matches(anyRule, content) { return .rule }
        if matches(listMarker, content) { return .listItem }
        return .text
    }

    /// The lines of GFM tables: a header row, its delimiter row and the rows under them.
    private static func tableRows(_ lines: [String]) -> Set<Int> {
        var rows = Set<Int>()
        for k in lines.indices.dropFirst() where matches(tableDelimiter, lines[k]) && lines[k - 1].contains("|")
            && !lines[k - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            var j = k - 1
            while j < lines.count, lines[j].contains("|") { rows.insert(j); j += 1 }
        }
        return rows
    }

    /// A one-line paragraph that could be a setext heading's text.
    private static func isTitleLike(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.count <= 80 && t.contains(where: \.isLetter) && !TextPrep.endsWith(t, ".,;:!")
    }

    /// Words a line doesn't end on when it ends a thought: the next line carries it on
    /// ("…with a natural voice in the" / "Safari app"). Not "to", "on", "in", "that", "by":
    /// short replies end on them ("Happy to", "Hold on", "Count me in").
    private static let carryingWords: Set<String> = ["a", "an", "the", "and", "or", "but", "nor", "of", "with", "from",
                                                     "than", "into", "onto", "for", "at", "if", "which", "via", "per",
                                                     "between", "through", "within", "during", "your", "our", "their",
                                                     "my", "its"]

    /// Whether a line of a paragraph starts a line of its own, as plain text keeps it ("Sam
    /// Ortiz" / "Can you run `make test`?", "Hi team," / "**Reminder:** …"), rather than
    /// carrying the line before on (a hard wrap): it does unless it starts with a lowercase
    /// letter, the line before ends on "the", "and", "of"…, or it's indented under a list
    /// item. CommonMark would run them all together.
    private static func startsNewLine(after a: String, _ b: String, indent: Int, inList: Bool) -> Bool {
        if indent >= 4 || (inList && indent >= 2) || a.hasSuffix("\\") { return false }
        let start = b.drop { " \t*_~`[(\"'“‘".contains($0) }
        if start.first?.isLowercase == true { return false }
        let last = a.split(separator: " ").last.map { $0.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted) }
        return !carryingWords.contains(last ?? "")
    }

    // MARK: HTML in Markdown

    /// HTML block starts (CommonMark's kinds 1 to 6, and 7: a lone known tag after a blank line).
    private static let htmlBlock = try! NSRegularExpression(pattern: #"^\s{0,3}(<[!?]|<(script|pre|style|textarea)(\s|>|$)|</?(address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|search|section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul)(\s|/?>|$))"#, options: [.caseInsensitive])
    private static let loneTag = try! NSRegularExpression(pattern: #"^\s{0,3}</?([A-Za-z][A-Za-z0-9-]*)(\s[^<>]*)?/?>\s*$"#)

    private static func startsHTMLBlock(_ line: String, afterBlank: Bool) -> Bool {
        if matches(htmlBlock, line) { return true }
        guard afterBlank, let m = loneTag.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return false }
        return htmlElements.contains((line as NSString).substring(with: m.range(at: 1)).lowercased())
    }

    private static let htmlElements: Set<String> = [
        "a", "abbr", "address", "area", "article", "aside", "audio", "b", "bdi", "bdo", "big", "blockquote", "body", "br",
        "button", "canvas", "caption", "center", "cite", "code", "col", "colgroup", "data", "dd", "del", "details", "dfn",
        "dialog", "div", "dl", "dt", "em", "embed", "figcaption", "figure", "font", "footer", "form", "h1", "h2", "h3", "h4",
        "h5", "h6", "head", "header", "hr", "html", "i", "iframe", "img", "input", "ins", "kbd", "label", "li", "link",
        "main", "map", "mark", "meta", "meter", "nav", "nobr", "noscript", "object", "ol", "option", "output", "p", "param",
        "path", "picture", "pre", "progress", "q", "rp", "rt", "ruby", "s", "samp", "script", "section", "select", "small",
        "source", "span", "strike", "strong", "style", "sub", "summary", "sup", "svg", "table", "tbody", "td", "template",
        "textarea", "tfoot", "th", "thead", "time", "title", "tr", "track", "tt", "u", "ul", "var", "video", "wbr",
    ]
    private static let voidElements: Set<String> = ["br", "hr", "img", "wbr"]
    private static let tagStart = try! NSRegularExpression(pattern: #"<(?=/?[A-Za-z])"#)
    private static let tagAt = try! NSRegularExpression(pattern: #"<(/?)([A-Za-z][A-Za-z0-9-]*)((?:\s[^<>]*?)?)\s*(/?)>"#)
    private static let autolinkAt = try! NSRegularExpression(pattern: #"<(?:[A-Za-z][A-Za-z0-9+.-]{1,31}:[^\s<>]*|[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+)>"#)

    /// Escapes a "<" that opens no HTML, so the words stay ("Replace <your-token>", "deploy
    /// <env>", "press <Enter>", "Vec<T>", "a<b and c>d"). HTML is a known element that is
    /// closed somewhere in the text, has attributes ("<a href=…>"), or needs no closing
    /// ("<br>", "<img …>"); a placeholder is none of those, and CommonMark would drop it.
    private static func escapeTags(_ part: String, in text: String) -> String {
        let ns = part as NSString
        var out = ""
        var last = 0
        for m in tagStart.matches(in: part, range: NSRange(location: 0, length: ns.length)) {
            let p = m.range.location
            let before = ns.substring(to: p)
            if before.hasSuffix("\\") || before.hasSuffix("](") { continue }
            let rest = NSRange(location: p, length: ns.length - p)
            if autolinkAt.firstMatch(in: part, options: .anchored, range: rest) != nil { continue }
            if let tag = tagAt.firstMatch(in: part, options: .anchored, range: rest) {
                let closing = tag.range(at: 1).length > 0
                let name = ns.substring(with: tag.range(at: 2)).lowercased()
                let attributes = ns.substring(with: tag.range(at: 3))
                let selfClosing = tag.range(at: 4).length > 0
                if htmlElements.contains(name), closing || selfClosing || voidElements.contains(name) || attributes.contains("=")
                    || text.range(of: "</\(name)>", options: .caseInsensitive) != nil { continue }
            }
            out += ns.substring(with: NSRange(location: last, length: p - last)) + "\\"
            last = p
        }
        return out + ns.substring(from: last)
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
