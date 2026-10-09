import Foundation

/// English text → phonemes in misaki's notation, the symbols Kokoro was trained on.
///
/// Each word comes from the first source that knows it:
///   1. the custom lexicon (hand-written names, brands, tech terms),
///   2. misaki's gold lexicon (US or GB), with its rules for heteronyms, numbers,
///      plurals, past tenses and stress,
///   3. CMUdict, mapped from ARPAbet,
///   4. the mini-bart G2P model, for words in none of them.
/// Sources 3 and 4 are American; their output is converted for British voices.
/// No eSpeak NG code or data is involved.
///
/// Not thread-safe: use one instance per queue.
public final class Phonemizer {
    public let british: Bool
    private let g2p: EnglishG2P
    private let lexicon: Lexicon
    private let custom: CustomLexicon?
    private let normalizes: Bool

    /// - Parameters:
    ///   - normalize: rewrite units, times, dates, fractions and a few abbreviations into
    ///     words first (on by default; off reproduces the reference misaki pipeline).
    public init(british: Bool, data: G2PData, custom: CustomLexicon? = nil, normalize: Bool = true) {
        self.british = british
        self.custom = custom
        self.normalizes = normalize
        let lexicon = Lexicon(british: british, data: data)
        self.lexicon = lexicon
        let inner = EnglishG2P(lexicon: lexicon, fallback: nil)
        g2p = EnglishG2P(lexicon: lexicon, fallback: Fallback(data: data, british: british, inner: { inner }))
    }

    /// Phonemes for `text`. Words that can't be pronounced at all are left out
    /// (or replaced by `unknown`).
    public func phonemize(_ text: String, unknown: String = "") -> String {
        var t = text
        var stresses: [String] = []
        if normalizes {
            (t, stresses) = Self.holdStress(t)
            t = TextNormalizer.linkLabels(t)
        }
        // Hand-written terms first, on the raw text; then normalize everything else.
        if let custom { t = custom.mark(t.precomposedStringWithCanonicalMapping, british: british) }
        if normalizes {
            t = unshout(t)
            t = TextNormalizer.normalize(t, skippingMarkedSpans: custom != nil)
            t = Self.restoreStress(t, stresses)
        }
        return g2p.phonemize(t, unk: unknown).trimmingCharacters(in: .whitespaces)
    }

    private static let marked = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(/[^)]*/\)"#)

    private static let capsWord = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}'’])\p{Lu}[\p{Lu}'’]*\p{Lu}(?![\p{L}\p{N}])"#)
    private static let twoCapitals = try! NSRegularExpression(pattern: #"\p{Lu}\p{Lu}"#)

    /// In a sentence written all in capitals ("TOP TEN TIPS FOR CODERS", "WHO AM I?", a
    /// licence's disclaimer) each shouted word is written in lower case, so it's read as the
    /// word: NLTagger took every one for a name, and names the gold lexicon doesn't have are
    /// spelled out ("T I P S F O R"). Acronyms (`Lexicon.isShoutedWord`) and terms the custom
    /// lexicon has already marked keep their reading. A sentence with any lower-case letter
    /// ("The API is down") is left alone. `ShoutedSentences` decides, on the text as read
    /// (a marked term counts as its own letters).
    private func unshout(_ text: String) -> String {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        guard Self.twoCapitals.firstMatch(in: text, range: all) != nil else { return text }
        // The plain stretches between marks, each with where it starts in the text as read.
        var pieces: [(range: NSRange, plain: Bool, start: Int)] = []
        var read: [Unicode.Scalar] = []
        var last = 0
        func plain(upTo end: Int) {
            let r = NSRange(location: last, length: end - last)
            pieces.append((r, true, read.count))
            read += ns.substring(with: r).unicodeScalars
        }
        for m in Self.marked.matches(in: text, range: all) {
            plain(upTo: m.range.location)
            pieces.append((m.range, false, read.count))
            read += ns.substring(with: m.range(at: 1)).unicodeScalars
            last = NSMaxRange(m.range)
        }
        plain(upTo: ns.length)

        var shouted = ShoutedSentences()
        var out = ""
        for piece in pieces {
            let s = ns.substring(with: piece.range)
            guard piece.plain else { out += s; continue }
            let ps = s as NSString
            var cursor = 0, offset = piece.start   // UTF-16 in `s`, and scalars in `read`
            for m in Self.capsWord.matches(in: s, range: NSRange(location: 0, length: ps.length)) {
                let gap = ps.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                out += gap
                offset += gap.unicodeScalars.count
                let word = ps.substring(with: m.range)
                out += shouted.contains(offset, in: read) && lexicon.isShoutedWord(word) ? word.lowercased() : word
                offset += word.unicodeScalars.count
                cursor = NSMaxRange(m.range)
            }
            out += ps.substring(from: cursor)
        }
        return out
    }

    // MARK: - Stress links

    private static let open = "\u{E010}", close = "\u{E011}"
    private static let stressLink = try! NSRegularExpression(pattern: #"\[([^\[\]]+)\]\((\+(?:\d+|0\.5))\)"#)
    private static let heldStress = try! NSRegularExpression(pattern: "\(open)([^\(open)\(close)]*)\(close)")

    /// The player writes emphasis as misaki's raised-stress link ("[very](+1)"), which
    /// `linkLabels` would read as a plain label and the custom lexicon and normalizer would
    /// write inside. Its words are set between private-use marks until those steps are done.
    /// Only "+" links count: any other link target, "(-1)" included, is still just a label.
    private static func holdStress(_ text: String) -> (String, [String]) {
        let ns = text as NSString
        var out = "", stresses: [String] = []
        var last = 0
        for m in stressLink.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += open + ns.substring(with: m.range(at: 1)) + close
            stresses.append(ns.substring(with: m.range(at: 2)))
            last = NSMaxRange(m.range)
        }
        return (stresses.isEmpty ? text : out + ns.substring(from: last), stresses)
    }

    /// The held words as stress links again. A term the custom lexicon marked inside keeps
    /// its fixed pronunciation (links don't nest); the words around it get the stress.
    private static func restoreStress(_ text: String, _ stresses: [String]) -> String {
        guard !stresses.isEmpty else { return text }
        let ns = text as NSString
        let matches = heldStress.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard matches.count == stresses.count else {
            return text.replacingOccurrences(of: open, with: "").replacingOccurrences(of: close, with: "")
        }
        func link(_ s: String, _ stress: String) -> String {
            guard let first = s.firstIndex(where: { $0.isLetter || $0.isNumber }),
                  let last = s.lastIndex(where: { !$0.isWhitespace }) else { return s }
            return String(s[..<first]) + "[" + s[first...last] + "](\(stress))" + s[s.index(after: last)...]
        }
        var out = ""
        var last = 0
        for (m, stress) in zip(matches, stresses) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let inner = ns.substring(with: m.range(at: 1))
            let ins = inner as NSString
            var cursor = 0
            for mark in marked.matches(in: inner, range: NSRange(location: 0, length: ins.length)) {
                out += link(ins.substring(with: NSRange(location: cursor, length: mark.range.location - cursor)), stress)
                out += ins.substring(with: mark.range)
                cursor = NSMaxRange(mark.range)
            }
            out += link(ins.substring(from: cursor), stress)
            last = NSMaxRange(m.range)
        }
        return out + ns.substring(from: last)
    }
}
