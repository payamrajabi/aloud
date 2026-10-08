import Foundation

/// The HTML an app puts on the clipboard for ⌘C → `NarrationDoc`.
enum NarrationHTML {
    /// Nil when the HTML doesn't parse or holds no words.
    static func parse(_ html: String) -> NarrationDoc? {
        guard let xml = try? XMLDocument(xmlString: html5ToHTML4(html), options: [.documentTidyHTML]),
              let root = xml.rootElement() else { return nil }
        let walker = Walker()
        walker.walk(root)
        walker.endBlock()
        guard walker.blocks.contains(where: { TextPrep.hasWords($0.text) }) else { return nil }
        return NarrationDoc(blocks: walker.blocks)
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
        let stripped = nonText.stringByReplacingMatches(in: html, range: all, withTemplate: " ")
        return html5Block.stringByReplacingMatches(in: stripped, range: NSRange(location: 0, length: (stripped as NSString).length),
                                                   withTemplate: "<$1div")
    }
}

private final class Walker {
    var blocks: [NarrationBlock] = []
    private var open: NarrationBlock?
    private var breaks = 0                  // <br>s in the open block
    private var styles: RunStyles = []
    private var quoteDepth = 0
    private var lists: [(ordered: Bool, next: Int)] = []
    private var inCell = 0                  // in a data table's cell, blocks are only spaces

    private static let skipped: Set<String> = ["head", "script", "style", "title", "meta", "template", "noscript", "link",
                                               "svg", "iframe", "object"]
    private static let containers: Set<String> = ["html", "body", "div", "section", "article", "main", "header", "footer",
                                                  "aside", "nav", "figure", "figcaption", "address", "center", "details",
                                                  "summary", "dl", "dt", "dd", "form", "fieldset", "legend", "caption",
                                                  "thead", "tbody", "tfoot", "tr", "td", "th"]

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
        let saved = styles
        defer { styles = saved }
        switch name {
        case "b", "strong": styles.insert(.bold)
        case "i", "em": styles.insert(.italic)
        case "u", "ins": styles.insert(.underline)
        case "s", "strike", "del": styles.insert(.strike)
        case "code", "kbd", "samp", "tt": styles.insert(.code)
        case "a": styles.insert(.link)
        default: break
        }
        if let css = el.attribute(forName: "style")?.stringValue { applyCSS(css) }

        switch name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            block(.heading(level: Int(String(name.dropFirst())) ?? 1), el)
        case "p":
            block(.paragraph, el)
        case "ul", "ol":
            guard inCell == 0 else { return spaced(el) }
            endBlock()
            let start = el.attribute(forName: "start")?.stringValue.flatMap { Int($0) } ?? 1
            lists.append((name == "ol", start))
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
            blocks.append(NarrationBlock(kind: .code, quoteDepth: quoteDepth, runs: [NarrationRun(text: el.stringValue ?? "", styles: .code)]))
        case "hr":
            guard inCell == 0 else { return }
            endBlock()
            blocks.append(NarrationBlock(kind: .rule, quoteDepth: quoteDepth))
        case "br":
            lineBreak()
        case "img":
            if let alt = el.attribute(forName: "alt")?.stringValue, !alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                append(alt, styles.union(.image))
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

    private func listItem(_ el: XMLElement) {
        guard inCell == 0 else { return spaced(el) }
        endBlock()
        var depth = max(0, lists.count - 1)
        // Google Docs lists are flat, with the level as an attribute.
        if let level = el.attribute(forName: "aria-level")?.stringValue.flatMap({ Int($0) }) { depth = max(0, level - 1) }
        var kind = NarrationBlock.Kind.listItem(ordered: false, number: nil, depth: depth)
        if let list = lists.last, list.ordered {
            let n = el.attribute(forName: "value")?.stringValue.flatMap { Int($0) } ?? list.next
            lists[lists.count - 1].next = n + 1
            kind = .listItem(ordered: true, number: n, depth: depth)
        }
        open = NarrationBlock(kind: kind, quoteDepth: quoteDepth)
        children(el)
        endBlock()
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
