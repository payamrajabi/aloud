import Foundation
import NaturalLanguage
import Phonemizer

/// One piece of text that is synthesized and played as a unit.
struct Chunk {
    let range: NSRange      // location in the displayed text (UTF-16)
    let speech: String      // what is actually sent to the voice model
    let pauseAfter: Double  // seconds of silence after this chunk
}

enum TextPrep {
    static let maxChunkLength = 280

    /// Normalizes copied text: line endings, hard-wrapped lines, extra spaces.
    static func clean(_ raw: String) -> String {
        var s = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{00AD}", with: "")
            // A byte-order mark or zero-width space glued to a word garbled it ("\u{FEFF}Hello").
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{200B}", with: "")
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

    static func chunks(for text: String) -> [Chunk] {
        let ns = text as NSString
        var result: [Chunk] = []
        let tokenizer = NLTokenizer(unit: .sentence)

        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { para, paraRange, _, _ in
            guard let para, hasWords(para) else { return }
            tokenizer.string = para
            var sentences: [NSRange] = []
            tokenizer.enumerateTokens(in: para.startIndex..<para.endIndex) { r, _ in
                let local = NSRange(r, in: para)
                sentences.append(NSRange(location: paraRange.location + local.location, length: local.length))
                return true
            }
            if sentences.isEmpty { sentences = [paraRange] }
            // NLTokenizer ends a sentence after "St.", "Gov." or "Sen." even before a name: "We
            // flew to St." was read as Street, then a pause, then "Louis on Friday."
            var joined: [NSRange] = []
            for sentence in sentences {
                if let last = joined.last, Tokenizer.titleContinues(ns.substring(with: last), into: ns.substring(with: sentence)) {
                    joined[joined.count - 1] = NSUnionRange(last, sentence)
                } else {
                    joined.append(sentence)
                }
            }
            sentences = joined

            var pieces: [(NSRange, Bool)] = []  // (range, ends a sentence)
            for sentence in sentences {
                let parts = split(sentence, in: ns)
                for (k, part) in parts.enumerated() {
                    pieces.append((part, k == parts.count - 1))
                }
            }
            let speakable = pieces.compactMap { range, endsSentence -> (NSRange, String, Bool)? in
                let trimmed = trim(range, in: ns)
                guard trimmed.length > 0 else { return nil }
                let speech = speechText(ns.substring(with: trimmed))
                guard hasWords(speech) else { return nil }
                return (trimmed, speech, endsSentence)
            }
            for (k, item) in speakable.enumerated() {
                let pause: Double = k == speakable.count - 1 ? 0.5 : (item.2 ? 0.22 : 0.08)
                result.append(Chunk(range: item.0, speech: item.1, pauseAfter: pause))
            }
        }
        splitOpening(&result, in: ns)
        return result
    }

    /// Each chunk costs ~0.4 s to start generating plus time proportional to its
    /// length, so a long first sentence delays the start. Split its opening
    /// words off at a natural break so the first audio arrives in about half a second.
    private static func splitOpening(_ chunks: inout [Chunk], in ns: NSString) {
        guard let first = chunks.first, first.range.length > 90 else { return }
        let r = first.range
        let search = NSRange(location: r.location + 25, length: min(60, r.length - 45))
        var cut = Int.max
        for mark in [", ", "; ", ": ", " — ", " – ", " ("] {
            let m = ns.range(of: mark, options: [], range: search)
            if m.location != NSNotFound { cut = min(cut, mark == " (" ? m.location + 1 : NSMaxRange(m)) }
        }
        if cut == Int.max {
            let m = ns.range(of: " ", options: .backwards, range: NSRange(location: r.location + 25, length: 30))
            guard m.location != NSNotFound else { return }
            cut = NSMaxRange(m)
        }
        let a = trim(NSRange(location: r.location, length: cut - r.location), in: ns)
        let b = trim(NSRange(location: cut, length: NSMaxRange(r) - cut), in: ns)
        let speechA = speechText(ns.substring(with: a))
        let speechB = speechText(ns.substring(with: b))
        guard hasWords(speechA), hasWords(speechB) else { return }
        chunks[0] = Chunk(range: a, speech: speechA, pauseAfter: 0.02)
        chunks.insert(Chunk(range: b, speech: speechB, pauseAfter: first.pauseAfter), at: 1)
    }

    /// Splits overly long sentences at commas, semicolons, dashes or spaces.
    private static func split(_ range: NSRange, in ns: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var start = range.location
        let end = NSMaxRange(range)
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
            out.append(NSRange(location: start, length: cut - start))
            start = cut
        }
        if end > start { out.append(NSRange(location: start, length: end - start)) }
        return out
    }

    private static func trim(_ range: NSRange, in ns: NSString) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        let ws = CharacterSet.whitespacesAndNewlines
        while start < end, let u = Unicode.Scalar(ns.character(at: start)), ws.contains(u) { start += 1 }
        while end > start, let u = Unicode.Scalar(ns.character(at: end - 1)), ws.contains(u) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Light cleanup of what gets spoken (the display text is untouched).
    static func speechText(_ s: String) -> String {
        var t = s
        func sub(_ pattern: String, _ template: String) {
            t = t.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        sub("!?\\[([^\\]]*)\\]\\([^)]*\\)", "$1")  // markdown links and images: just the label
        sub("https?://\\S+", "link")
        sub("\\[\\d+(,\\s*\\d+)*\\]", "")      // citation markers like [12]
        sub("^(\\s*>)+", " ")                 // a markdown quote ("a > b" is read)
        sub("[*#`~|•▪●◦]+", " ")              // markdown and bullet symbols
        sub("\\s+", " ")
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func hasWords(_ s: String) -> Bool {
        s.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}
