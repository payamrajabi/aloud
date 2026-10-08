import Foundation

/// A selection's structure (headings, lists, quotes, tables, emphasis), read from the
/// app's HTML, from Markdown, or guessed from plain text. `NarrationPlanner` turns it
/// into the text the player shows and the chunks the voice says.
struct RunStyles: OptionSet, Hashable {
    let rawValue: Int
    static let bold = RunStyles(rawValue: 1 << 0)
    static let italic = RunStyles(rawValue: 1 << 1)
    static let underline = RunStyles(rawValue: 1 << 2)
    static let strike = RunStyles(rawValue: 1 << 3)
    static let code = RunStyles(rawValue: 1 << 4)
    static let link = RunStyles(rawValue: 1 << 5)
    /// The run's text is the image's alt text.
    static let image = RunStyles(rawValue: 1 << 6)

    static let emphasis: RunStyles = [.bold, .italic, .underline]
}

struct NarrationRun: Equatable {
    var text: String
    var styles: RunStyles = []
}

struct NarrationBlock: Equatable {
    enum Kind: Equatable {
        case heading(level: Int)  // 1...6
        case paragraph
        case listItem(ordered: Bool, number: Int?, depth: Int)  // depth 0 = top level
        /// Cells are separated by a run whose text is `cellSeparator`.
        case tableRow(header: Bool)
        /// A fenced code block: shown, never spoken.
        case code
        /// A thematic break: shown as "⸻", never spoken.
        case rule
    }
    static let cellSeparator = "\t"

    var kind: Kind
    var quoteDepth = 0  // 0 = not in a blockquote
    var runs: [NarrationRun] = []
    /// A paragraph that ends with ":" and introduces a list (the planner also works it out).
    var leadIn = false

    var text: String { runs.map(\.text).joined() }
}

struct NarrationDoc: Equatable {
    var blocks: [NarrationBlock] = []
}

enum NarrationFormat: String {
    case markdown, html, plain, auto
}

extension NarrationDoc {
    /// Whether text without HTML is Markdown (`looksLikeMarkdown`) or plain.
    static func detect(_ raw: String) -> NarrationFormat {
        NarrationMarkdown.looksLikeMarkdown(raw) ? .markdown : .plain
    }

    /// The app's HTML when it parses, else Markdown when the text looks like it, else plain
    /// text. A forced `format` skips the detection (tests, `--format`). The player should
    /// load through here.
    static func parse(_ raw: String, html: String? = nil, format: NarrationFormat = .auto) -> NarrationDoc {
        switch format {
        case .markdown: return NarrationMarkdown.parse(raw)
        case .html: return NarrationHTML.parse(html ?? raw) ?? NarrationDoc()
        case .plain: return NarrationPlain.parse(raw)
        case .auto:
            if let html, let doc = NarrationHTML.parse(html) { return doc }
            // List markers alone are usually text copied from a page ("Brew" / "1. Heat the
            // water…" / "The whole pour…", one block a line). Markdown would run those lines
            // together; the plain reader takes the same markers and keeps each line.
            return NarrationMarkdown.hasMarkupBeyondLists(raw) ? NarrationMarkdown.parse(raw) : NarrationPlain.parse(raw)
        }
    }
}
