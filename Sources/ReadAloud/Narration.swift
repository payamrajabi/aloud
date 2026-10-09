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

extension RunStyles {
    /// The style an inline HTML tag gives its text, for copied HTML and Markdown's inline
    /// tags alike. Nil for a tag that doesn't style text.
    init?(tag: String) {
        switch tag {
        case "b", "strong": self = .bold
        case "i", "em": self = .italic
        case "u", "ins": self = .underline
        case "s", "strike", "del": self = .strike
        case "code", "kbd", "samp", "tt": self = .code
        case "a": self = .link
        default: return nil
        }
    }
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
    /// A list item's marker when it isn't a bullet or a spoken number: a letter ("b)"), a
    /// roman numeral, a task box (☐ ☑). Shown; only a letter is also read.
    var marker: String?

    var text: String { runs.map(\.text).joined() }
}

struct NarrationDoc: Equatable {
    var blocks: [NarrationBlock] = []
}

enum NarrationFormat: String {
    case markdown, html, plain, auto
}

extension NarrationDoc {
    /// `TextPrep.normalizeCharacters`, with the Unicode line and paragraph separators (a
    /// Cocoa text view's ⌃↩ and ⌥↩ breaks) and NEL as line breaks: 1.6.0's paragraph and
    /// sentence splitting broke at them, and the parsers split lines at "\n" only.
    static func normalize(_ raw: String) -> String {
        TextPrep.normalizeCharacters(raw)
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{0085}", with: "\n")
    }

    /// Whether text without HTML is read as Markdown or as plain text. List markers alone
    /// are usually text copied from a page ("Brew" / "1. Heat the water…" / "The whole
    /// pour…", one block a line): Markdown would run those lines together, and the plain
    /// reader takes the same markers and keeps each line.
    static func detect(_ raw: String) -> NarrationFormat {
        NarrationMarkdown.hasMarkupBeyondLists(raw) ? .markdown : .plain
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
            return detect(raw) == .markdown ? NarrationMarkdown.parse(raw) : NarrationPlain.parse(raw)
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
