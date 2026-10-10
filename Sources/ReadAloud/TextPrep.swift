import Foundation
import NaturalLanguage
import Phonemizer

/// One piece of text that is synthesized and played as a unit.
struct Chunk {
    let range: NSRange      // location in the displayed text (UTF-16)
    let speech: String      // what is actually sent to the voice model
    let pauseAfter: Double  // seconds of silence after this chunk (at 1×)
    var speed: Float = 1    // the voice's speaking rate: slower for headings and quotes
}

enum TextPrep {
    static let maxChunkLength = 280

    /// Normalizes copied text: line endings, hard-wrapped lines, extra spaces.
    static func clean(_ raw: String) -> String {
        var s = normalizeCharacters(raw)
        func sub(_ pattern: String, _ template: String) {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        sub("[ \\t]+", " ")
        sub(" *\\n *", "\n")
        // A single line break followed by a lowercase letter is a hard wrap (PDFs, emails).
        sub("([^\\n])\\n(?=[a-z])", "$1 ")
        sub("\\n{3,}", "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Line endings, no-break spaces and invisible characters.
    static func normalizeCharacters(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{00AD}", with: "")
            // A byte-order mark or zero-width space glued to a word garbled it ("\u{FEFF}Hello").
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{200B}", with: "")
    }

    /// The 1.6.0 chunking (every line a paragraph, pauses 0.08 / 0.22 / 0.5, speed 1), kept
    /// for `--say --flat` before/after listening and the lexicon benchmark.
    static func legacyChunks(for text: String) -> [Chunk] {
        let ns = text as NSString
        var result: [Chunk] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { para, paraRange, _, _ in
            guard let para, hasWords(para) else { return }
            let speakable = pieces(in: ns, range: paraRange, protected: markupSpans(in: ns, range: paraRange))
                .compactMap { piece -> (NSRange, String, Bool)? in
                    let speech = speechText(ns.substring(with: piece.range))
                    return hasWords(speech) ? (piece.range, speech, piece.endsSentence) : nil
                }
            for (k, item) in speakable.enumerated() {
                let pause: Double = k == speakable.count - 1 ? 0.5 : (item.2 ? 0.22 : 0.08)
                result.append(Chunk(range: item.0, speech: item.1, pauseAfter: pause))
            }
        }
        splitOpening(&result, in: ns)
        return result
    }

    /// One block's sentences, as trimmed ranges of `ns` with whether each piece ends its
    /// sentence. `protected` spans (links, images) are never split.
    static func pieces(in ns: NSString, range: NSRange, protected: [NSRange]) -> [(range: NSRange, endsSentence: Bool)] {
        let para = ns.substring(with: range)
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = para
        var sentences: [NSRange] = []
        tokenizer.enumerateTokens(in: para.startIndex..<para.endIndex) { r, _ in
            let local = NSRange(r, in: para)
            sentences.append(NSRange(location: range.location + local.location, length: local.length))
            return true
        }
        if sentences.isEmpty { sentences = [range] }
        // NLTokenizer ends a sentence after "St.", "Gov." or "Sen." even before a name: "We
        // flew to St." was read as Street, then a pause, then "Louis on Friday." It also
        // ends one inside Markdown ("![" | "Screenshot…](docs/install.png)"), and the half
        // without its "![" was read with its file path.
        var joined: [NSRange] = []
        for sentence in sentences {
            if let last = joined.last,
               protected.contains(where: { $0.location < sentence.location && sentence.location < NSMaxRange($0) })
                || Tokenizer.titleContinues(ns.substring(with: last), into: ns.substring(with: sentence)) {
                joined[joined.count - 1] = NSUnionRange(last, sentence)
            } else {
                joined.append(sentence)
            }
        }
        // "Did the build pass? No. 2 tests failed.": the answer "No." is read on its own,
        // as the word; kept with the number it was read "Number two tests failed."
        sentences = []
        for sentence in joined {
            if let previous = sentences.last,
               let n = Tokenizer.answerNoLength(ns.substring(with: sentence), after: ns.substring(with: previous)) {
                sentences.append(NSRange(location: sentence.location, length: n))
                sentences.append(NSRange(location: sentence.location + n, length: sentence.length - n))
            } else {
                sentences.append(sentence)
            }
        }

        var result: [(range: NSRange, endsSentence: Bool)] = []
        for sentence in sentences {
            let parts = split(sentence, in: ns, protected: protected)
            for (k, part) in parts.enumerated() {
                let trimmed = trim(part, in: ns)
                if trimmed.length > 0 { result.append((trimmed, k == parts.count - 1)) }
            }
        }
        return result
    }

    /// Each chunk costs ~0.4 s to start generating plus time proportional to its
    /// length, so a long first sentence delays the start. Split its opening
    /// words off at a natural break so the first audio arrives in about half a second.
    private static func splitOpening(_ chunks: inout [Chunk], in ns: NSString) {
        guard let first = chunks.first,
              let (a, b) = openingHalves(first.range, in: ns, protected: markupSpans(in: ns, range: first.range)) else { return }
        let speechA = speechText(ns.substring(with: a))
        let speechB = speechText(ns.substring(with: b))
        guard hasWords(speechA), hasWords(speechB) else { return }
        chunks[0] = Chunk(range: a, speech: speechA, pauseAfter: 0.02)
        chunks.insert(Chunk(range: b, speech: speechB, pauseAfter: first.pauseAfter), at: 1)
    }

    /// A first chunk longer than 90 characters as its opening words and the rest, trimmed
    /// (`openingCut`). Nil to leave it whole.
    static func openingHalves(_ r: NSRange, in ns: NSString, protected: [NSRange]) -> (NSRange, NSRange)? {
        guard let cut = openingCut(r, in: ns, protected: protected) else { return nil }
        return (trim(NSRange(location: r.location, length: cut - r.location), in: ns),
                trim(NSRange(location: cut, length: NSMaxRange(r) - cut), in: ns))
    }

    /// Where to split a first chunk longer than 90 characters: after its opening words, at a
    /// comma, dash or space, never inside a `protected` span. Nil to leave it whole.
    private static func openingCut(_ r: NSRange, in ns: NSString, protected: [NSRange]) -> Int? {
        guard r.length > 90 else { return nil }
        let search = NSRange(location: r.location + 25, length: min(60, r.length - 45))
        var cut = Int.max
        for mark in [", ", "; ", ": ", " — ", " – ", " ("] {
            let m = ns.range(of: mark, options: [], range: search)
            if m.location != NSNotFound { cut = min(cut, mark == " (" ? m.location + 1 : NSMaxRange(m)) }
        }
        if cut == Int.max {
            let m = ns.range(of: " ", options: .backwards, range: NSRange(location: r.location + 25, length: 30))
            guard m.location != NSNotFound else { return nil }
            cut = NSMaxRange(m)
        }
        // Never inside a link or image: its halves would be read with the path.
        if let span = protected.first(where: { $0.location < cut && cut < NSMaxRange($0) }) {
            guard span.location - r.location >= 25 else { return nil }
            cut = span.location
        }
        return cut
    }

    /// Splits overly long sentences at commas, semicolons, dashes or spaces.
    static func split(_ range: NSRange, in ns: NSString, protected: [NSRange]) -> [NSRange] {
        var out: [NSRange] = []
        var start = range.location
        let end = NSMaxRange(range)
        let markup = end - start > maxChunkLength ? protected : []
        while end - start > maxChunkLength {
            let window = NSRange(location: start + maxChunkLength / 2, length: maxChunkLength / 2)
            var cut = -1
            for mark in ["; ", ": ", " — ", " – ", ", "] {
                let r = ns.range(of: mark, options: .backwards, range: window)
                if r.location != NSNotFound { cut = NSMaxRange(r); break }
            }
            if cut < 0 {
                let r = ns.range(of: " ", options: .backwards, range: window)
                cut = r.location != NSNotFound ? NSMaxRange(r) : start + maxChunkLength
            }
            // Not inside a link or image: before it, or after it if it starts the piece.
            if let span = markup.first(where: { $0.location < cut && cut < NSMaxRange($0) }) {
                cut = span.location > start ? span.location : min(end, NSMaxRange(span))
            }
            out.append(NSRange(location: start, length: cut - start))
            start = cut
        }
        if end > start { out.append(NSRange(location: start, length: end - start)) }
        return out
    }

    static func trim(_ range: NSRange, in ns: NSString) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        let ws = CharacterSet.whitespacesAndNewlines
        while start < end, let u = Unicode.Scalar(ns.character(at: start)), ws.contains(u) { start += 1 }
        while end > start, let u = Unicode.Scalar(ns.character(at: end - 1)), ws.contains(u) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    private static let markupPattern = try! NSRegularExpression(pattern: #"!?\[[^\]\n]*\]\([^)\n]*\)"#)

    /// Markdown links and images in `range`: "[the FAQ](docs/faq.md)", "![A cat](cat.png)".
    /// `speechText` reads each as its label; split apart, the path was read too.
    private static func markupSpans(in ns: NSString, range: NSRange) -> [NSRange] {
        markupPattern.matches(in: ns as String, range: range).map(\.range)
    }

    /// Light cleanup of what gets spoken (the display text is untouched).
    static func speechText(_ s: String) -> String {
        speechCleanup(s).trimmingCharacters(in: .whitespaces)
    }

    /// `speechText` without the trim, for pieces of a sentence that are joined afterwards.
    /// `lineStart`: `s` starts a line, where a ">" is a quote marker; inside a sentence
    /// ("**count** > 5") it's read.
    static func speechCleanup(_ s: String, lineStart: Bool = true) -> String {
        var t = s
        func sub(_ pattern: String, _ template: String) {
            t = t.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        sub("!?\\[([^\\]]*)\\]\\([^)]*\\)", "$1")  // markdown links and images: just the label
        sub("https?://\\S+", "link")
        sub("\\[\\d+(,\\s*\\d+)*\\]", "")      // citation markers like [12]
        // Formatting tags shown as text (a viewer that escapes Markdown's inline HTML) were read
        // "you thirty seconds slash you". Placeholders ("<your-token>") read well and stay.
        sub("(?i)</?(u|b|i|s|em|strong|del|ins|strike|mark|sup|sub|small|kbd|code|span)\\s*>|<br\\s*/?>", "")
        if lineStart { sub("^(\\s*>)+", " ") }  // a markdown quote ("a > b" is read)
        sub("[`|•▪●◦]+", " ")                 // markdown and bullet symbols
        t = markupSigns(t)                    // and "*", "#", "~", except where they're read
        sub("\\s+", " ")
        return t
    }

    private static let signRuns = try! NSRegularExpression(pattern: #"[*#~]+"#)
    private static let aboutNumber = try! NSRegularExpression(pattern: #"^[ \t]?[-−+]?[$£€¥₹₩]?\d"#)
    private static let numberOf = try! NSRegularExpression(pattern: #"^[ \t]+of(?![\p{L}\p{N}])"#)
    private static let keyVerbs: Set<String> = ["press", "presses", "pressed", "pressing", "hit", "tap", "enter", "dial"]
    private static let keyNouns: Set<String> = ["key", "keys", "button", "buttons"]

    /// "*", "#" and "~" are markup (bold, headings, strikethrough, "~/paths") and read as a space,
    /// except where the phonemizer reads them (FIN-889): "#" against a digit ("#1", "#31#") or
    /// after a letter ("C#"), "# of", a hashtag ("#blessed", read "hashtag blessed" by the
    /// messaging pack, FIN-896), "~" before a number ("~5", "~ 10 km", "9~5"), and
    /// a keypad "*" or "#" on its own after a key verb or before "key" or "button" ("Press * then
    /// 2"). A run of two or more ("**", "##", "~~") is always markup.
    private static func markupSigns(_ t: String) -> String {
        let ns = t as NSString
        let matches = signRuns.matches(in: t, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return t }
        var out = "", last = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += isRead(m.range, in: ns) ? ns.substring(with: m.range) : " "
            last = NSMaxRange(m.range)
        }
        return out + ns.substring(from: last)
    }

    /// Whether the single sign at `range` is one the phonemizer reads.
    private static func isRead(_ range: NSRange, in s: NSString) -> Bool {
        guard range.length == 1 else { return false }
        let start = max(0, range.location - 24), end = min(s.length, NSMaxRange(range) + 24)
        let before = s.substring(with: NSRange(location: start, length: range.location - start))
        let after = s.substring(with: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range)))
        let sign = s.substring(with: range)
        let rest = NSRange(location: 0, length: (after as NSString).length)
        if sign == "~" { return aboutNumber.firstMatch(in: after, range: rest) != nil }
        let previous = before.last, next = after.first
        if sign == "#", previous?.isNumber == true || next?.isNumber == true || previous?.isLetter == true
            || numberOf.firstMatch(in: after, range: rest) != nil {
            return true
        }
        // A hashtag, which the messaging pack reads "hashtag …" (FIN-896).
        if sign == "#", MessagingPass.startsHashtag(before: before, after: after) { return true }
        // A key on its own: "Press * then 2.", "Press # to finish.", "the # key".
        guard previous.map(\.isWhitespace) ?? true, next.map({ $0.isWhitespace || ".,;:!?)".contains($0) }) ?? true else { return false }
        let wordBefore = String(before.reversed().drop { $0 == " " || $0 == "\t" }.prefix { $0.isLetter }.reversed())
        let wordAfter = String(after.drop { $0 == " " || $0 == "\t" }.prefix { $0.isLetter })
        return keyVerbs.contains(wordBefore.lowercased()) || keyNouns.contains(wordAfter.lowercased())
    }

    static func hasWords(_ s: String) -> Bool {
        s.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// Whether `s` ends with one of `marks`, looking past closing quotes and brackets.
    static func endsWith(_ s: String, _ marks: String) -> Bool {
        let closing: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»"]
        guard let last = s.last(where: { !closing.contains($0) }) else { return false }
        return marks.contains(last)
    }
}
