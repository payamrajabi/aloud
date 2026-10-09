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
        var cues = Cues(t)
        if cues.slash {
            t = rewrite(t, slashWords, cased: true) { m, s in
                let found = s.substring(with: m.range)
                if found.lowercased().hasPrefix("c/o") { return "Class of" }
                return slashWordReadings[found]
            }
            t = rewrite(t, withAfterNumber) { m, s in
                let word = m.range(at: 2).location != NSNotFound ? "without" : "with"
                return s.substring(with: m.range(at: 1)) == "W" ? word.capitalized : word
            }
            t = rewrite(t, withForms, readWith)
            t = rewrite(t, because) { m, s in s.substring(with: m.range(at: 1)) == "B" ? "Because" : "because" }
            t = rewrite(t, careOf) { m, s in
                s.substring(with: m.range(at: 1)) == "C" && startsSentence(at: m.range.location, in: s) ? "Care of" : "care of"
            }
            t = rewrite(t, settledSlashes) { m, s in
                let found = s.substring(with: m.range)
                let capital = found.first?.isUppercase == true && startsSentence(at: m.range.location, in: s)
                let words: String
                switch found.lowercased() {
                case "w/e": words = m.range(at: 1).location != NSNotFound ? "week ending" : "whatever"
                case "w/c": words = "week commencing"
                case "b/w": words = "between"
                default: words = "shout out"
                }
                return capital ? words.prefix(1).uppercased() + words.dropFirst() : words
            }
            t = rewrite(t, withoutAtEnd) { m, s in
                s.substring(with: m.range(at: 1)) == "W" && startsSentence(at: m.range.location, in: s) ? "Without" : "without"
            }
            cues = Cues(t)
        }
        if cues.intl {
            // The lexicon reads "Intl" as a word (JavaScript's Intl); with its point before a word
            // it's "International" ("Intl. observers").
            t = rewrite(t, international) { _, _ in "International" }
        }
        if cues.attn {
            t = rewrite(t, attention) { m, s in
                let word = s.substring(with: m.range(at: 1)) == "attn" ? "attention" : "Attention"
                // The abbreviation point goes, unless it was also the line's full stop.
                guard m.range(at: 2).location != NSNotFound else { return word }
                return s.substring(from: NSMaxRange(m.range)).prefix { $0 != "\n" }.allSatisfy(\.isWhitespace) ? word + "." : word
            }
            cues = Cues(t)
        }
        if cues.minMax {
            t = rewrite(t, minMax) { m, s in
                let lower = m.range(at: 1).location != NSNotFound
                let word = s.substring(with: m.range(at: lower ? 1 : 2))
                if lower, countWords.contains(previousWord(before: m.range.location, in: s).lowercased()) { return nil }
                let full = word.lowercased() == "min" ? "minimum" : "maximum"
                return lower ? full : full.capitalized
            }
            cues = Cues(t)
        }
        if cues.ampersand {
            t = rewrite(t, ampersandPlural, cased: false) { m, s in s.substring(with: m.range(at: 1)) + "'s" }
            cues = Cues(t)
        }
        if cues.etc { t = rewrite(t, etcetera, cased: false) { _, _ in "etc.." } }
        if cues.comparison {
            // "+/-" first, so its minus isn't taken for a sign ("+/- 5%", "+/-5%").
            t = rewrite(t, plusMinus) { _, _ in "plus or minus " }
            t = rewrite(t, comparison) { m, s in
                let sign = s.substring(with: m.range(at: 1))
                // "<3" on its own is a heart ("Love u <3"), not "less than three".
                if sign == "<", s.substring(with: m.range(at: 2)) == "3", matches(heartAfter, in: s, at: NSMaxRange(m.range)) { return nil }
                return sign == "<" ? "less than " : "more than "
            }
        }
        if cues.abbreviation {
            t = rewrite(t, exampleAbbreviations) { m, s in
                let found = s.substring(with: m.range(at: 1))
                let words = found.lowercased() == "e.g." ? "for example" : found.lowercased() == "i.e." ? "that is" : "package"
                return found.first?.isUppercase == true ? words.prefix(1).uppercased() + words.dropFirst() : words
            }
        }
        if cues.digit {
            // A hurricane's category: "a Cat 3 storm", "a Cat. 4 hurricane" (the lexicon has "cat").
            t = rewrite(t, stormCategory) { m, s in "Category " + s.substring(with: m.range(at: 1)) }
            // A size in a recipe after its count: "2 lg. eggs", "1 sm. onion" (the lexicon has "LG").
            t = rewrite(t, recipeSize) { m, s in
                let found = s.substring(with: m.range(at: 1)).lowercased()
                return found.hasPrefix("l") ? "large" : found.hasPrefix("s") ? "small" : "medium"
            }
            t = rewrite(t, noBeforeNumber, cased: false) { _, _ in "No," }
            t = rewrite(t, mixedCode, cased: false) { m, s in splitCode(s.substring(with: m.range)) }
            t = rewrite(t, retirementPlan, cased: false) { m, s in s.substring(with: m.range(at: 1)) + "(k)" }
        }
        return t
    }

    // MARK: Words before the lexicon

    /// Shorthand with a slash that the lexicon would split: "w/end", "y/y", "m/m", "q/q", and
    /// "C/O" before a class year ("C/O 2025"). y/y and its kind become the lexicon's YoY, MoM and
    /// QoQ, read per voice ("year over year", "year on year"). "w/e" is whatever or a week
    /// ending, and stays (shorthand.json).
    private static let slashWords = try! NSRegularExpression(pattern: #"(?:^|(?<=[\s(\[{"“‘']))"#
        + #"(?:[Ww]/end|[yY]/[yY]|[mM]/[mM]|[qQ]/[qQ]|C/O(?=[ \t]+(?:'\d{2}|(?:19|20)\d{2})(?!\d)))(?![\p{L}\p{N}/])"#,
        options: .anchorsMatchLines)
    private static let slashWordReadings = ["w/end": "weekend", "W/end": "Weekend", "y/y": "YoY", "Y/Y": "YoY",
                                            "m/m": "MoM", "M/M": "MoM", "q/q": "QoQ", "Q/Q": "QoQ"]

    /// Slash shorthand where what's around it settles which it is (shorthand.json left them as
    /// letters for want of that): "w/e" before a date is a week ending (group 1, empty) and
    /// opening its sentence before a comma "whatever" ("w/e, it's fine"); "w/c" before a date a
    /// week commencing; "b/w" before a number "between" ("b/w 2 and 4"; "b/w photo" stays); and
    /// "S/O" before "to" a shout out.
    private static let settledSlashes = try! NSRegularExpression(pattern: slashStart
        + #"(?:[Ww]/[Ee](?=[ \t]+"# + dateAhead + #")()|(?<=^|[\n.!?][ \t])[Ww]/e(?=,)|[Ww]/[Cc](?=[ \t]+"# + dateAhead + #")|[Bb]/[Ww](?=[ \t]+\d)|[Ss]/[Oo](?=[ \t]+to(?![\p{L}])))(?![\p{L}\p{N}/])"#,
        options: .anchorsMatchLines)
    /// A date after "w/e" or "w/c": "10/12", "13 Oct", "Oct 13".
    private static let dateAhead = #"(?:\d{1,2}(?:[/.]\d{1,2}|(?!\d))|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\p{L}*\.?[ \t]+\d)"#
    /// "w/o" ending its clause, even after a price: "Free shipping w/ Prime, $5.99 w/o."
    private static let withoutAtEnd = try! NSRegularExpression(pattern: #"(?:^|(?<=[\s(\[{"“‘']))([Ww])/[Oo](?=[.,;:!?)]|[ \t]*$)"#,
                                                              options: .anchorsMatchLines)

    /// "Intl." before a word: "Intl. observers".
    private static let international = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_.])Intl\.(?=[ \t]+\p{L})"#)
    /// "Cat 3" or "Cat. 4" before a storm.
    private static let stormCategory = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])Cat\.?[ \t]?([1-5])(?=[ \t]+(?:storm|hurricane|typhoon|cyclone)s?(?![\p{L}]))"#)
    /// "lg.", "sm." or "med." after a count and before what it sizes: "2 lg. eggs".
    private static let recipeSize = try! NSRegularExpression(pattern: #"(?<=\d[ \t])(lg|lge|sm|med)\.(?=[ \t]+\p{Ll})"#)

    /// "w/" after an amount or a percentage, before a word: "$62.40 w/ tip", "15% w/ code"; and
    /// "w/o" (group 2) after any number ("then 1:1 w/o laptops"). The slash forms above skip a
    /// number and a space ("5 W/kg" is watts), but a spaced "w/" and a word after an amount is
    /// only ever "with".
    private static let withAfterNumber = try! NSRegularExpression(pattern: #"(?<=[\d%][ \t])([Ww])/(?:(?=[ \t]+[\p{L}$£€(])|(out|OUT|[Oo])(?=[ \t]+[\p{L}"“'‘(\[]))"#)

    /// "+/-" and "±" written out: "+/- 5%", "+/-5%".
    private static let plusMinus = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}+/])\+/[-−][ \t]?(?=[~≈]?[$£€¥₹₩]?\d|[ \t]*\d)"#)
    /// "<" or ">" glued before a number: ">60%", "<40%", "<5 min", ">2s" (≤ and ≥ are the
    /// lexicon's: "less than or equal to"; spaced, "a > 5" is the operator rule's). Not markup ("<3>"),
    /// an arrow ("<-5", "->5") or an operator between two numbers ("3<5", spaced "3 < 5" is the
    /// operator rule's).
    private static let comparison = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}<>=\-!])([<>])(?=[~≈]?[$£€¥₹₩]?(\d+)(?![\d]*>))"#)
    /// After "<3", what leaves it a heart: the end, a line break, or anything but a number's unit
    /// or a word ("<3 days" is less than three days; "Love u <3", "<3 you" are hearts).
    private static let heartAfter = try! NSRegularExpression(pattern: #"3(?=[ \t]*(?:$|\n|[^\p{L}\p{N}\s%.,]|[!.,?][ \t]*(?:$|\n|\p{Lu}))|[ \t]+(?:you|u|ya|this|it|xx?)\b)"#,
                                                             options: [.anchorsMatchLines])

    /// "e.g." and "i.e." before a word (the tech lexicon reads "e.g." as letters), and "Pkg." for
    /// "package". Alone ("e.g.") they stay the lexicon's.
    private static let exampleAbbreviations = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_.])((?:[Ee]\.[Gg]|[Ii]\.[Ee])\.|Pkg\.|pkg\.)(?=,?[ \t]+[\p{L}\p{N}"“(])"#)

    /// "No." as the word before a number it can't be numbering: a year at the start of a quote
    /// ("he said: \"No. 2026 is the year…\"") or an amount in per cent ("\"No. 100 per cent
    /// no\""). The tokenizer reads "No." before any number as "number"; with a comma it's the
    /// word, and the pause stays.
    private static let noBeforeNumber = try! NSRegularExpression(pattern:
        #"(?:(?<=["“‘'][ \t]?)(No)\.(?=[ \t]+(?:19|20)\d\d(?![\d,.%]))|(?<![\p{L}\p{N}])(No)\.(?=[ \t]+\d+(?:\.\d+)?[ \t]*(?:%|per[ \t]?cent|percent)(?![\p{L}])))"#)

    /// A code of capitals and digits with a 2 between letters ("7FHK2L", "R2D2", "H2O2"): spaced
    /// where letters and digits meet, so the 2 stays a number. The G2P read "K2L" as "K to L",
    /// as it should "B2B" and "P2P", which are three characters and left alone.
    private static let mixedCode = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}\-_./@#])(?=[\p{Lu}\d]{4,12}(?![\p{L}\p{N}]))(?=[\p{Lu}\d]*\d)[\p{Lu}\d]*\p{Lu}2\p{Lu}[\p{Lu}\d]*(?![\p{L}\p{N}\-_/@])"#)

    /// "401k" as the lexicon's "401(k)", which it reads "four oh one K" (it was "four hundred one K").
    private static let retirementPlan = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}.,$£€])(401)[kK](?![\p{L}\p{N}])"#)

    private static func splitCode(_ code: String) -> String {
        var out = ""
        var previous: Character?
        for c in code {
            if let p = previous, p.isNumber != c.isNumber { out += " " }
            out.append(c)
            previous = c
        }
        return out
    }

    /// Whether `regex` matches right at `location`, seeing the text on both sides.
    private static func matches(_ regex: NSRegularExpression, in s: NSString, at location: Int) -> Bool {
        regex.firstMatch(in: s as String, options: [.anchored, .withTransparentBounds], range: NSRange(location: location, length: s.length - location)) != nil
    }

    /// What the pass's steps need to find before they run: "/", "ttn" or "TTN" (Attn), "in." or
    /// "ax." (min. and max.), "&" and "etc.". One pass over the UTF-8: Foundation's
    /// `String.contains` searches Unicode-aware and cost more than the rest of the pass, on
    /// every sentence read. All of them are ASCII, so a byte match is the same test.
    private struct Cues {
        var slash = false, attn = false, minMax = false, ampersand = false, etc = false
        /// "Intl." (the lexicon's word).
        var intl = false
        /// "<", ">", "≤", "≥" or "+/".
        var comparison = false
        /// ".g." or ".e." (e.g., i.e.), or "kg." (Pkg.).
        var abbreviation = false
        var digit = false

        init(_ text: String) {
            var b1: UInt8 = 0, b2: UInt8 = 0, b3: UInt8 = 0  // the three bytes before `b`
            for b in text.utf8 {
                switch b {
                case UInt8(ascii: "/"):
                    slash = true
                    if b1 == UInt8(ascii: "+") { comparison = true }
                case UInt8(ascii: "&"): ampersand = true
                case UInt8(ascii: "<"), UInt8(ascii: ">"): comparison = true
                case 0xA4, 0xA5: if b1 == 0x89 && b2 == 0xE2 { comparison = true }  // ≤ ≥
                case UInt8(ascii: "n"): if b1 == UInt8(ascii: "t") && b2 == UInt8(ascii: "t") { attn = true }
                case UInt8(ascii: "N"): if b1 == UInt8(ascii: "T") && b2 == UInt8(ascii: "T") { attn = true }
                case UInt8(ascii: "."):
                    if b2 == UInt8(ascii: "i") && b1 == UInt8(ascii: "n") || b2 == UInt8(ascii: "a") && b1 == UInt8(ascii: "x") { minMax = true }
                    if b3 == UInt8(ascii: "e") && b2 == UInt8(ascii: "t") && b1 == UInt8(ascii: "c") { etc = true }
                    if b3 == UInt8(ascii: "n") && b2 == UInt8(ascii: "t") && b1 == UInt8(ascii: "l") { intl = true }
                    if b2 == UInt8(ascii: ".") && (b1 | 0x20 == UInt8(ascii: "g") || b1 | 0x20 == UInt8(ascii: "e"))
                        || b2 == UInt8(ascii: "k") && b1 == UInt8(ascii: "g") { abbreviation = true }
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = true
                default: break
                }
                (b3, b2, b1) = (b2, b1, b)
            }
        }
    }

    /// Whether `head`, a sentence as Apple's splitter cut it (trimmed), ends in shorthand of this
    /// area that runs on into `next` ("Attn." + "Maria Lopez", "built ca." + "1850"), so the two
    /// are read as one. nil leaves it to `Tokenizer.titleContinues`. Each one needs a chunk case
    /// in Tests/g2p/regression.json: the speech tests phonemize whole lines and never see the split.
    static func sentenceContinues(_ head: String, into next: String) -> Bool? {
        guard head.hasSuffix("."), let first = next.first(where: { !$0.isWhitespace }) else { return nil }
        let all = NSRange(location: 0, length: (head as NSString).length)
        // "after Wk." + "9", "The Natl." + "Weather Service", "(feat." + "Billy Ray Cyrus)", and a
        // list's Roman marker ("Agenda: I. Intro, II." + "Q3 results").
        if let m = runOnLabel.firstMatch(in: head, range: all) {
            if m.range(at: 1).location != NSNotFound { return first.isNumber ? true : nil }
            return first.isUppercase ? true : nil
        }
        // "See col." + "B in the tracker" (a column), "Asst." + "Mgr: Ana" (a role).
        if let m = runOnRole.firstMatch(in: head, range: all) {
            if m.range(at: 1).location != NSNotFound {
                let rest = next.drop { $0.isWhitespace }
                return first.isUppercase && rest.dropFirst().first?.isLetter != true ? true : nil
            }
            return roleNext.firstMatch(in: next, range: NSRange(location: 0, length: (next as NSString).length)) != nil ? true : nil
        }
        guard let m = runOn.firstMatch(in: head, range: all) else { return nil }
        // "Attn." before its addressee ("Maria Lopez"); "ca." or "c." before a year ("1850.").
        if m.range(at: 1).location != NSNotFound { return first.isUppercase ? true : nil }
        return first.isNumber ? true : nil
    }

    /// More abbreviations Apple's splitter takes for a full stop: "Wk." before a number (group 1),
    /// "Natl.", "Intl.", "feat." and "ft." before a name, and a list's Roman marker after a comma,
    /// colon or semicolon.
    private static let runOnLabel = try! NSRegularExpression(pattern:
        #"(?:(?<![\p{L}\p{N}_.])(Wk|wk)|(?<![\p{L}\p{N}_.])(?:Natl|natl|Intl|intl|feat|Feat)|(?<=\p{L}[ \t])ft|[,:;][ \t]+(?:[IVX]{1,4}|[ivx]{1,4}))\.$"#)
    /// "col." (group 1) and "Asst." at the end of a sentence as Apple's splitter cut it.
    private static let runOnRole = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_.])(?:(col)|Asst|asst)\.$"#)
    /// A role after "Asst.": "Mgr", "Director".
    private static let roleNext = try! NSRegularExpression(pattern: #"^\s*(?i:mgr|manager|dir|director|prof|professor|editor|secretary|coach|principal|chief|head|supervisor|producer|treasurer|curator)(?![\p{L}])"#)
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
