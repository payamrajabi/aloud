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
        var item: (ordered: Bool, number: Int?, letter: String?)?   // letter: "b)", shown not read
        var indent: Int            // leading spaces (a tab is 4)
        var cells: [String]        // split at tabs, when there are two or more
    }

    static func parse(_ raw: String) -> NarrationDoc {
        // Every non-empty line, with its list marker, indentation and tab-separated cells.
        var lines: [Line] = []
        var blank = true
        for rawLine in NarrationDoc.normalize(raw).components(separatedBy: "\n") {
            let text = collapse(rawLine)
            guard !text.isEmpty else { blank = true; continue }
            let (item, body) = listItem(text)
            let indent = rawLine.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let cells = rawLine.split(separator: "\t").map { collapse(String($0)) }.filter { !$0.isEmpty }
            lines.append(Line(raw: text, text: body, blankBefore: blank, item: item, indent: indent,
                              cells: item == nil && cells.count > 1 ? cells : []))
            blank = false
        }
        // Tab-separated cells make a table only on two lines in a row or more.
        for i in lines.indices where !lines[i].cells.isEmpty {
            if ![i - 1, i + 1].contains(where: { lines.indices.contains($0) && !lines[$0].cells.isEmpty }) { lines[i].cells = [] }
        }
        // A single line break followed by a lowercase letter is a hard wrap (PDFs, emails),
        // unless that line is a lettered list item ("b) …") or either line is a table row
        // ("verbose\tfalse"). A line indented under a list item, with no marker of its own,
        // carries the item on ("- Ask Priya to send the revised" / "  Q3 budget by Friday").
        var joined: [Line] = []
        var itemIndent: Int?   // of the list item the last line belongs to
        for line in lines {
            if !line.blankBefore, let last = joined.last, last.cells.isEmpty, line.cells.isEmpty, line.item == nil {
                let first = line.raw.unicodeScalars.first.map { ("a"..."z").contains($0) } ?? false
                let continuesItem = itemIndent.map { line.indent > $0 } ?? false
                if (first && !isLettered(line.raw)) || continuesItem {
                    joined[joined.count - 1].raw += " " + line.raw
                    joined[joined.count - 1].text += " " + line.raw
                    continue
                }
            }
            itemIndent = line.item != nil ? line.indent : nil
            joined.append(line)
        }
        lines = joined
        // A letter is a list marker only in a run that goes a, b, c… from "a" (or A, B, C…):
        // "A. Lincoln wrote it.", initials ("J. Okafor" / "M. Lindqvist") and "Q." / "A." are text.
        var i = 0
        while i < lines.count {
            guard lines[i].item?.letter != nil else { i += 1; continue }
            var end = i
            while end + 1 < lines.count, lines[end + 1].item?.letter != nil { end += 1 }
            var valid = 0   // how many lines from i continue the alphabet
            if let first = lines[i].item?.letter?.unicodeScalars.first, first == "a" || first == "A" {
                valid = 1
                while i + valid <= end,
                      let previous = lines[i + valid - 1].item?.letter?.unicodeScalars.first,
                      let next = lines[i + valid].item?.letter?.unicodeScalars.first,
                      next.value == previous.value + 1 { valid += 1 }
            }
            for k in i...end where valid < 2 || k >= i + valid {
                lines[k].item = nil
                lines[k].text = lines[k].raw
            }
            i = end + 1
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
                block.marker = item.letter
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

    private static func listItem(_ line: String) -> ((ordered: Bool, number: Int?, letter: String?)?, String) {
        let ns = line as NSString
        let all = NSRange(location: 0, length: ns.length)
        if let m = unordered.firstMatch(in: line, range: all) {
            return ((false, nil, nil), ns.substring(from: NSMaxRange(m.range)))
        }
        if let m = numbered.firstMatch(in: line, range: all) {
            return ((true, Int(ns.substring(with: m.range(at: 1))), nil), ns.substring(from: NSMaxRange(m.range)))
        }
        if let m = lettered.firstMatch(in: line, range: all) {
            return ((true, nil, ns.substring(with: NSRange(location: 0, length: 2))), ns.substring(from: NSMaxRange(m.range)))
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

    /// Lines that close an email or a letter ("Talk soon,", "Thanks for the quick turnaround
    /// on this."): what follows them is a signature, not a section.
    private static let signOffs: Set<String> = ["thanks", "thank", "thx", "ty", "cheers", "regards", "sincerely",
                                                "yours", "warmly", "cordially", "respectfully"]
    private static func isSignOff(_ line: Line) -> Bool {
        let words = line.raw.split(separator: " ").map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        guard let first = words.first else { return false }
        return TextPrep.endsWith(line.raw, ",") || signOffs.contains(first)
            || (words.count <= 3 && ["best", "kind", "warm", "love", "talk", "speak", "see"].contains(first))
    }

    /// Headings: short lines that name what follows (no sentence punctuation, title case)
    /// after the end of a paragraph or a blank line, and before a line that reads as body
    /// text, or before one subheading that does. Chat lines and verse sit among other short
    /// lines, so they don't qualify; nor does any line in text where one is answered by a
    /// question or an exclamation ("Sam Lee" / "Can you look at the PR?"), or where the same
    /// short line keeps coming back before a message ("Sam Ortiz", "INTERVIEWER"): that's a
    /// chat or a transcript.
    private static func headingLines(_ lines: [Line]) -> [Int] {
        let candidate = lines.map(isCandidate)
        func startsSection(_ i: Int) -> Bool {
            guard i > 0 else { return true }
            let previous = lines[i - 1]
            // A signature follows a sign-off ("Talk soon," / "Priya Raman"), blank line or not.
            if isSignOff(previous) { return false }
            if lines[i].blankBefore { return true }
            // After a question or an exclamation, a short line is an answer ("Where are
            // you?" / "Home"); after a lead-in ("Send it to:"), it's what the lead-in names.
            return previous.item != nil || !previous.cells.isEmpty || TextPrep.endsWith(previous.raw, ".…")
        }
        let conversation = lines.indices.contains { i in
            candidate[i] && startsSection(i) && i + 1 < lines.count && lines[i + 1].item == nil
                && TextPrep.endsWith(lines[i + 1].raw, "?!")
        }
        guard !conversation else { return [] }
        // Speaker labels: a line that comes back word for word, each time between messages.
        // (A recipe's "Ingredients" comes back too, but before a list or under a title.)
        var seen: [String: [Int]] = [:]
        for i in lines.indices where candidate[i] {
            seen[lines[i].raw.lowercased().trimmingCharacters(in: .punctuationCharacters), default: []].append(i)
        }
        let repeated = seen.values.filter { $0.count >= 2 }
        let labels = !repeated.isEmpty && repeated.allSatisfy { occurrences in
            occurrences.allSatisfy { i in
                i + 1 < lines.count && !candidate[i + 1] && lines[i + 1].item == nil && lines[i + 1].cells.isEmpty
                    && (i == 0 || !candidate[i - 1])
            }
        }
        guard !labels else { return [] }
        // A line inside a run of text (no blank line on either side) is often a wrapped line
        // that happens to be in title case ("Members of the Riverside Water Authority" /
        // "Board voted on Monday…"): it needs to be short and well under the line after it.
        func midParagraph(_ i: Int) -> Bool {
            i > 0 && !lines[i].blankBefore && (i + 1 >= lines.count || !lines[i + 1].blankBefore)
        }
        func leadsBody(_ i: Int) -> Bool {
            guard i + 1 < lines.count else { return false }
            let words = lines[i].raw.split(separator: " ").count
            let next = lines[i + 1].text
            let nextWords = next.split(separator: " ").count
            // ALL CAPS: a heading is short, or has text in mixed case under it (a block of
            // capitals is a disclaimer, wrapped).
            if !lines[i].raw.contains(where: \.isLowercase), words > 5, !next.contains(where: \.isLowercase) { return false }
            if midParagraph(i), words > 6 || nextWords < 2 * words { return false }
            return (TextPrep.endsWith(next, ".!?…:") && nextWords > words) || (nextWords >= 8 && nextWords >= 2 * words)
        }
        return lines.indices.filter { i in
            guard candidate[i] else { return false }
            let alone = startsSection(i) && leadsBody(i)
            let aboveSubheading = startsSection(i) && i + 1 < lines.count && candidate[i + 1] && leadsBody(i + 1)
            let subheading = i > 0 && candidate[i - 1] && startsSection(i - 1) && leadsBody(i)
            return alone || aboveSubheading || subheading
        }
    }

    /// Words a title doesn't end on ("…Promise That", "…Given In Writing To The").
    private static let danglingWords: Set<String> = ["a", "an", "the", "and", "or", "but", "nor", "of", "that"]

    private static func isCandidate(_ line: Line) -> Bool {
        let text = line.raw
        let words = text.split(separator: " ")
        return line.item == nil && line.cells.isEmpty
            && (1...10).contains(words.count) && text.count <= 80
            && text.first.map { $0.isUppercase || $0.isNumber } == true
            && text.last.map { !".!?;,:…".contains($0) } == true
            && text.contains(where: \.isLetter)
            // A URL, a time, a "|" between a job title and a company, a ZIP code or a UK postcode.
            && text.range(of: #"https?://|www\.|\d{1,2}:\d{2}|\||\b\d{5}(-\d{4})?\b|\b[A-Z]{1,2}\d[A-Z\d]? ?\d[A-Z]{2}\b"#,
                          options: .regularExpression) == nil
            && !conversational.contains(words[0].lowercased().trimmingCharacters(in: .punctuationCharacters))
            && !text.lowercased().hasPrefix("to whom it may concern")
            // A news byline or a date line under a headline ("By Dana Whitfield", "March 4, 2026").
            && text.range(of: #"^By [A-Z]"#, options: .regularExpression) == nil
            && text.range(of: #"^((Mon|Tues|Wednes|Thurs|Fri|Satur|Sun)day,? )?(Jan(uary)?|Feb(ruary)?|Mar(ch)?|Apr(il)?|May|June?|July?|Aug(ust)?|Sep(t(ember)?)?|Oct(ober)?|Nov(ember)?|Dec(ember)?)\.? \d{1,2}(st|nd|rd|th)?,? \d{4}$"#,
                              options: .regularExpression) == nil
            && !danglingWords.contains(words[words.count - 1].lowercased())
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
}
