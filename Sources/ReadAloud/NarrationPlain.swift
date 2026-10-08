import Foundation

/// Plain text → `NarrationDoc`. Each line is a block, as the 1.6.0 chunker read it; list
/// items are found by their markers, tab-separated lines (a table copied from a page) are
/// table rows, and headings are found only where the layout leaves little doubt. When
/// unsure, a line is a paragraph: a heading read as body text costs a little pause, body
/// text read as a heading sounds wrong.
enum NarrationPlain {
    private struct Line {
        var raw: String
        var text: String           // without its list marker
        var blankBefore: Bool      // the start of the text counts
        var item: (ordered: Bool, number: Int?, lettered: Bool)?
        var indent: Int            // leading spaces (a tab is 4)
        var cells: [String]        // split at tabs, when there are two or more
    }

    static func parse(_ raw: String) -> NarrationDoc {
        var lines: [Line] = []
        var blank = true
        for rawLine in TextPrep.normalizeCharacters(raw).components(separatedBy: "\n") {
            let text = collapse(rawLine)
            guard !text.isEmpty else { blank = true; continue }
            // A single line break followed by a lowercase letter is a hard wrap (PDFs,
            // emails), unless that line is a lettered list item ("b) …").
            if !blank, let first = text.unicodeScalars.first, ("a"..."z").contains(first), !isLettered(text), !lines.isEmpty {
                lines[lines.count - 1].raw += " " + text
                lines[lines.count - 1].text += " " + text
                lines[lines.count - 1].cells = []
                continue
            }
            let (item, body) = listItem(text)
            let indent = rawLine.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let cells = rawLine.split(separator: "\t").map { collapse(String($0)) }.filter { !$0.isEmpty }
            lines.append(Line(raw: text, text: body, blankBefore: blank, item: item, indent: indent,
                              cells: item == nil && cells.count > 1 ? cells : []))
            blank = false
        }
        // A letter is a list marker only beside another one: "A. Lincoln wrote it." is a sentence.
        for i in lines.indices where lines[i].item?.lettered == true {
            if ![i - 1, i + 1].contains(where: { lines.indices.contains($0) && lines[$0].item?.lettered == true }) {
                lines[i].item = nil
                lines[i].text = lines[i].raw
            }
        }
        // Tab-separated cells make a table only on two lines in a row or more.
        for i in lines.indices where !lines[i].cells.isEmpty {
            if ![i - 1, i + 1].contains(where: { lines.indices.contains($0) && !lines[$0].cells.isEmpty }) { lines[i].cells = [] }
        }

        let headings = lines.count >= 2 ? headingLines(lines) : []
        var blocks: [NarrationBlock] = []
        var indents: [Int] = []   // of the open list levels
        for (i, line) in lines.enumerated() {
            var block = NarrationBlock(kind: .paragraph, runs: [NarrationRun(text: line.text)])
            if let item = line.item {
                while let last = indents.last, line.indent < last { indents.removeLast() }
                if indents.last.map({ line.indent > $0 }) ?? true { indents.append(line.indent) }
                block.kind = .listItem(ordered: item.ordered, number: item.number, depth: indents.count - 1)
            } else {
                indents = []
                if !line.cells.isEmpty {
                    let first = i == 0 || lines[i - 1].cells.isEmpty
                    block.kind = .tableRow(header: first)
                    block.runs = line.cells.enumerated().flatMap { k, cell in
                        (k > 0 ? [NarrationRun(text: NarrationBlock.cellSeparator)] : []) + [NarrationRun(text: cell)]
                    }
                } else if headings.contains(i) {
                    // With more than one, the first is the title.
                    block.kind = .heading(level: headings.count > 1 && i == headings[0] ? 1 : 2)
                } else if line.text.hasSuffix(":"), i + 1 < lines.count, lines[i + 1].item != nil {
                    block.leadIn = true
                }
            }
            blocks.append(block)
        }
        return NarrationDoc(blocks: blocks)
    }

    private static func collapse(_ s: String) -> String {
        s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    private static let unordered = try! NSRegularExpression(pattern: #"^[-*•◦▪–] (?=\S)"#)
    private static let numbered = try! NSRegularExpression(pattern: #"^(\d{1,3})[.)] (?=\S)"#)
    private static let lettered = try! NSRegularExpression(pattern: #"^[a-zA-Z][.)] (?=\S)"#)

    private static func isLettered(_ line: String) -> Bool {
        lettered.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    private static func listItem(_ line: String) -> ((ordered: Bool, number: Int?, lettered: Bool)?, String) {
        let ns = line as NSString
        let all = NSRange(location: 0, length: ns.length)
        if let m = unordered.firstMatch(in: line, range: all) {
            return ((false, nil, false), ns.substring(from: NSMaxRange(m.range)))
        }
        if let m = numbered.firstMatch(in: line, range: all) {
            return ((true, Int(ns.substring(with: m.range(at: 1))), false), ns.substring(from: NSMaxRange(m.range)))
        }
        if let m = lettered.firstMatch(in: line, range: all) {
            return ((true, nil, true), ns.substring(from: NSMaxRange(m.range)))
        }
        return (nil, line)
    }

    /// Words that open chat and email lines ("Sounds good", "Thanks Sam", "Subject: …"),
    /// not headings.
    private static let conversational: Set<String> = ["hi", "hey", "hello", "dear", "thanks", "thank", "ok", "okay", "yes",
                                                      "yeah", "yep", "no", "nope", "sure", "cool", "great", "nice", "lol",
                                                      "haha", "sounds", "sorry", "cheers", "best", "regards", "love", "bye",
                                                      "good", "omg", "wow", "oh", "hmm", "oops", "yay", "ugh", "btw", "fyi",
                                                      "ps", "np", "thx", "ty", "congrats", "congratulations",
                                                      "subject", "re", "fwd", "fw", "cc", "bcc"]

    /// Small words a title leaves lowercase ("A Note on Grind Size").
    private static let minorWords: Set<String> = ["a", "an", "the", "and", "but", "or", "nor", "for", "so", "yet", "as",
                                                  "at", "by", "in", "of", "off", "on", "per", "to", "up", "via", "vs",
                                                  "with", "from", "into", "onto", "over", "than", "out", "about", "after",
                                                  "before", "under", "upon", "without", "within", "between", "through",
                                                  "de", "du", "la", "le", "van", "von", "der", "del", "da", "di"]

    /// Headings: short lines that name what follows (no sentence punctuation, title case)
    /// after the end of a paragraph or a blank line, and before a line that reads as body
    /// text, or before one subheading that does. Chat lines and verse sit among other short
    /// lines, so they don't qualify; nor does any line in text where one is answered by a
    /// question or an exclamation ("Sam Lee" / "Can you look at the PR?"): that's a chat.
    private static func headingLines(_ lines: [Line]) -> [Int] {
        let candidate = lines.map(isCandidate)
        func startsSection(_ i: Int) -> Bool {
            guard i > 0, !lines[i].blankBefore else { return true }
            let previous = lines[i - 1]
            // After a question or an exclamation, a short line is an answer ("Where are
            // you?" / "Home").
            return previous.item != nil || !previous.cells.isEmpty || endsSentence(previous.raw, with: ".…:")
        }
        let conversation = lines.indices.contains { i in
            candidate[i] && startsSection(i) && i + 1 < lines.count && lines[i + 1].item == nil
                && endsSentence(lines[i + 1].raw, with: "?!")
        }
        guard !conversation else { return [] }
        func leadsBody(_ i: Int) -> Bool {
            guard i + 1 < lines.count else { return false }
            let words = lines[i].raw.split(separator: " ").count
            let next = lines[i + 1].text
            let nextWords = next.split(separator: " ").count
            return (endsSentence(next) && nextWords > words) || (nextWords >= 8 && nextWords >= 2 * words)
        }
        return lines.indices.filter { i in
            guard candidate[i] else { return false }
            let alone = startsSection(i) && leadsBody(i)
            let aboveSubheading = startsSection(i) && i + 1 < lines.count && candidate[i + 1] && leadsBody(i + 1)
            let subheading = i > 0 && candidate[i - 1] && startsSection(i - 1) && leadsBody(i)
            return alone || aboveSubheading || subheading
        }
    }

    private static func isCandidate(_ line: Line) -> Bool {
        let text = line.raw
        let words = text.split(separator: " ")
        return line.item == nil && line.cells.isEmpty
            && (1...10).contains(words.count) && text.count <= 80
            && text.first.map { $0.isUppercase || $0.isNumber } == true
            && text.last.map { !".!?;,:…".contains($0) } == true
            && text.contains(where: \.isLetter)
            && text.range(of: #"https?://|www\.|\d{1,2}:\d{2}"#, options: .regularExpression) == nil
            && !conversational.contains(words[0].lowercased().trimmingCharacters(in: .punctuationCharacters))
            && isTitleCase(words)
    }

    /// Every word but the small ones starts with a capital or is a number ("What You
    /// Need", "Chapter 1", "Setting Up Your iPhone"). Chat, verse and wrapped prose
    /// ("Quick question", "Sugar is sweet", "Results from the second trial") don't.
    private static func isTitleCase(_ words: [Substring]) -> Bool {
        words.allSatisfy { word in
            let w = word.trimmingCharacters(in: CharacterSet.letters.union(.decimalDigits).inverted)
            guard w.first?.isLetter == true else { return true }
            return w.contains(where: \.isUppercase) || minorWords.contains(w.lowercased())
        }
    }

    private static func endsSentence(_ s: String, with marks: String = ".!?…:") -> Bool {
        let closing: Set<Character> = ["\"", "'", "”", "’", ")", "]"]
        guard let last = s.last(where: { !closing.contains($0) }) else { return false }
        return marks.contains(last)
    }
}
