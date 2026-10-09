import Foundation

/// Everyday shorthand (Core readings, FIN-889; area "shorthand"), the part read before the
/// custom lexicon: the slash forms (w/, w/o, b/c, c/o), Attn, min. and max. before a number,
/// the plural of an "&" initialism ("M&Ms"), and the full stop of a sentence that ends in "etc.".
/// The signs and the other abbreviations are rules in TextNormalizer's list (`ShorthandRules`).
///
/// The pass runs before the custom lexicon, because "Max" is a case-sensitive key and the
/// lexicon never matches right after "/", and after money, so "est." and "min." still see the
/// digits of "2,000 pounds". It is the only owner of c/o (cross.json: addresses and shorthand).
enum ShorthandPass {
    typealias Rule = TextNormalizer.Rule

    /// The shorthand pass: in `Phonemizer.phonemize` after the titles pass, only when
    /// normalizing. Its words go through `ShoutedCasing`, because `unshout` runs after it: "BURGER
    /// W/ CHEESE" becomes "BURGER WITH CHEESE", still a shouted line.
    static func apply(_ text: String, british: Bool) -> String {
        var t = text
        if t.contains("/") {
            t = rewrite(t, withForms, readWith)
            t = rewrite(t, because) { m, s in s.substring(with: m.range(at: 1)) == "B" ? "Because" : "because" }
            t = rewrite(t, careOf) { m, s in
                s.substring(with: m.range(at: 1)) == "C" && startsSentence(at: m.range.location, in: s) ? "Care of" : "care of"
            }
        }
        if t.contains("ttn") || t.contains("TTN") {
            t = rewrite(t, attention) { m, s in
                let word = s.substring(with: m.range(at: 1)) == "attn" ? "attention" : "Attention"
                // The abbreviation point goes, unless it was also the line's full stop.
                guard m.range(at: 2).location != NSNotFound else { return word }
                return s.substring(from: NSMaxRange(m.range)).prefix { $0 != "\n" }.allSatisfy(\.isWhitespace) ? word + "." : word
            }
        }
        if t.contains("in.") || t.contains("ax.") {
            t = rewrite(t, minMax) { m, s in
                let lower = m.range(at: 1).location != NSNotFound
                let word = s.substring(with: m.range(at: lower ? 1 : 2))
                if lower, countWords.contains(previousWord(before: m.range.location, in: s).lowercased()) { return nil }
                let full = word.lowercased() == "min" ? "minimum" : "maximum"
                return lower ? full : full.capitalized
            }
        }
        if t.contains("&") { t = rewrite(t, ampersandPlural, cased: false) { m, s in s.substring(with: m.range(at: 1)) + "'s" } }
        if t.contains("etc.") { t = rewrite(t, etcetera, cased: false) { _, _ in "etc.." } }
        return t
    }

    /// Whether `head`, a sentence as Apple's splitter cut it (trimmed), ends in shorthand of this
    /// area that runs on into `next` ("Attn." + "Maria Lopez", "built ca." + "1850"), so the two
    /// are read as one. nil leaves it to `Tokenizer.titleContinues`. Each one needs a chunk case
    /// in Tests/g2p/regression.json: the speech tests phonemize whole lines and never see the split.
    static func sentenceContinues(_ head: String, into next: String) -> Bool? {
        guard head.hasSuffix("."), let first = next.first(where: { !$0.isWhitespace }) else { return nil }
        guard let m = runOn.firstMatch(in: head, range: NSRange(location: 0, length: (head as NSString).length)) else { return nil }
        // "Attn." before its addressee ("Maria Lopez"); "ca." or "c." before a year ("1850.").
        if m.range(at: 1).location != NSNotFound { return first.isUppercase ? true : nil }
        return first.isNumber ? true : nil
    }

    /// The abbreviations Apple's splitter takes for a full stop: Attn (group 1), and ca. and c.
    private static let runOn = try! NSRegularExpression(pattern: #"(?:(?<![\p{L}\p{N}_.])(Attn|ATTN|attn)|(?<![\p{L}\p{N}_.&])(?:ca|c))\.$"#)

    /// The left edge of a slash form: the start of a line, a space, an opening bracket or a quote,
    /// and not a number (or %) and a space. So "Shift+W/Shift+S", "a/b/c" and "example.com/w/page"
    /// are left alone, and so are "5 W/kg" (watts) and "5% w/w".
    private static let slashStart = #"(?:^|(?<=[\s(\[{"“‘']))(?<![\d%]\s)"#

    /// w/o or w/out before a word, w/in before a word or number, and w/ before a word, a number, a
    /// price or a bracket, spaced ("w/ avocado") or glued to a word ("w/lemon"). Group 1 is the W,
    /// 2 out, 3 in, 4 the word glued to a plain w/.
    private static let withForms = try! NSRegularExpression(pattern: slashStart
        + #"([Ww])/(?:(out|OUT|[Oo])(?=\s+[\p{L}"“'‘(\[])|(in|IN)(?=\s+[\p{L}\p{N}])|(?=\s+[\p{L}\p{N}$£€(\["“'‘])|(?=(\p{L}{2,})(?![\p{L}\p{N}_/=?]|\.\p{L})))"#,
        options: .anchorsMatchLines)

    /// Units a w/ glued to them makes a rate of watts ("W/kg", "W/mK"), not "with".
    private static let wattUnits: Set<String> = ["kg", "km", "cm", "mm", "hr", "hrs", "sr", "sec", "min", "mol", "ft", "lb",
                                                 "lbs", "yr", "mk", "hz", "khz", "mhz", "ghz", "cd", "lm", "mi", "in"]

    private static func readWith(_ m: NSTextCheckingResult, _ s: NSString) -> String? {
        let capital = s.substring(with: m.range(at: 1)) == "W" && startsSentence(at: m.range.location, in: s)
        let word: String
        if m.range(at: 2).location != NSNotFound {
            // "w/o Jan 6" is "week of", and "W/O" before a number is a work order.
            let next = s.substring(from: NSMaxRange(m.range)).drop { $0.isWhitespace }.prefix { $0.isLetter }
            if CalendarNames.timeWords.contains(String(next)) { return nil }
            word = "without"
        } else if m.range(at: 3).location != NSNotFound {
            word = "within"
        } else if m.range(at: 4).location != NSNotFound {
            // Glued: "w/lemon", "w/Kubernetes". Not a unit ("W/kg") or a form that failed above.
            let glued = s.substring(with: m.range(at: 4)).lowercased()
            if wattUnits.contains(glued) || ["o", "out", "in"].contains(glued) { return nil }
            word = "with "
        } else {
            word = "with"
        }
        return capital ? word.prefix(1).uppercased() + word.dropFirst() : word
    }

    /// b/c with a lower-case c ("B/C" is hepatitis or benefit/cost), followed by a word that
    /// isn't a verb of maths ("the ratio b/c is small") and not after an operator ("a + b/c").
    private static let because = try! NSRegularExpression(pattern: slashStart
        + #"(?<![=+\-*×÷^/<>]\s{1,2})([bB])/c(?![\p{L}\p{N}/]|\.\p{L})(?=\s+(?!(?:is|are|was|were|equals|and|or)(?![\p{L}\p{N}]))[\p{L}\p{N}"“'‘(])"#,
        options: .anchorsMatchLines)

    /// c/o before a capitalised word (a name or a company). Before a lower-case word, a colon or
    /// a number it's clinical ("c/o chest pain", "C/O: Chest pain") or a check-out ("C/O 11 AM").
    private static let careOf = try! NSRegularExpression(pattern: slashStart + #"([Cc])/[Oo](?=\s+\p{Lu})"#, options: .anchorsMatchLines)

    /// Attn with a colon or its point, or before a capitalised word: "Attn: Accounts Payable",
    /// "Attn. Maria Lopez". Lower-case attn before a word is code ("the attn weights").
    private static let attention = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_.])(Attn|ATTN|attn)(?:(\.)(?=\s|$)|(?=\s*:)|(?=\s+\p{Lu}))"#)

    /// min. and max. before a number or a lower-case word ("Min. 8 characters", "the min. and max.
    /// values"); never after a number ("20 min. at"). Capitalised, only at the start of a line or
    /// after "(", because "Max." after a word is the name ("I met Max. 5 of us went").
    private static let minMax = try! NSRegularExpression(pattern:
        #"(?:(?<![\p{L}\p{N}_.])(?<!\d\s)(min|max)|(?:^|(?<=\())(Min|Max))\.(?=\s*[~≈]?[$£€¥₹₩]?\d|\s+\p{Ll})"#,
        options: .anchorsMatchLines)

    /// Words before min. that make it minutes: "a ten min. walk", "a few min.", "a min.".
    private static let countWords: Set<String> = [
        "a", "an", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty",
        "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "few", "several", "couple", "many", "more", "some",
    ]

    /// The plural of an initialism with "&": "M&Ms", "B&Bs", "Q&As", "P&Ls" → "M&M's". Without
    /// the apostrophe the last letter and its "s" were one word ("Ms" read "Miz", "Ls" "L S").
    private static let ampersandPlural = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}&])(\p{Lu}&\p{Lu})s(?![\p{L}\p{N}'’&])"#)

    /// "etc." that ends its sentence: the end of a line, or a capital next. The tech lexicon reads
    /// "etc." as one term with its period, so the sentence lost its full stop and ran into the
    /// next ("…etc. Then go."). A second period, outside the term, is the full stop.
    private static let etcetera = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_.])etc\.(?=[ \t]*$|\s+\p{Lu})"#, options: .anchorsMatchLines)

    /// Whether a shorthand at `location` starts its sentence: nothing before it on its line, or a
    /// full stop, question or exclamation mark, past spaces, opening brackets and quotes.
    static func startsSentence(at location: Int, in s: NSString) -> Bool {
        var i = location - 1
        while i >= 0, let c = Unicode.Scalar(s.character(at: i)), " \t([{\"“‘'".unicodeScalars.contains(c) { i -= 1 }
        guard i >= 0, let c = Unicode.Scalar(s.character(at: i)) else { return true }
        return "\n\r.!?…".unicodeScalars.contains(c)
    }

    /// The word just before `location`, past spaces ("" when there's none).
    private static func previousWord(before location: Int, in s: NSString) -> String {
        var end = location
        while end > 0, let c = Unicode.Scalar(s.character(at: end - 1)), c == " " || c == "\t" { end -= 1 }
        var start = end
        while start > 0, let c = Unicode.Scalar(s.character(at: start - 1)), Scalars.isLetter(c) { start -= 1 }
        return s.substring(with: NSRange(location: start, length: end - start))
    }

    /// `text` with each match of `regex` replaced by what `read` gives (nil leaves the match as
    /// it is). Inserted words take the case of their sentence (`ShoutedCasing`, made only once a
    /// match is read); `cased: false` for a rewrite that inserts no words.
    private static func rewrite(_ text: String, _ regex: NSRegularExpression, cased: Bool = true,
                                _ read: (NSTextCheckingResult, NSString) -> String?) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var casing: ShoutedCasing?
        var out = "", last = 0, changed = false
        for m in matches {
            guard var words = read(m, ns) else { continue }
            if cased {
                if casing == nil { casing = ShoutedCasing(text) }
                words = casing!.cased(words, at: m.range.location)
            }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + words
            last = NSMaxRange(m.range)
            changed = true
        }
        return changed ? out + ns.substring(from: last) : text
    }
}
