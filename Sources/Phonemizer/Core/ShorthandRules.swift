import Foundation

/// Shorthand and signs read by TextNormalizer's rules (Core readings, FIN-889; area
/// "shorthand"): §, ¶, ™, ®, ©, ‰, №, "#", "~", the adjectival degree, and the abbreviations
/// (e.g., i.e., approx., avg., est., ca. and c. as circa). Each hook runs at its own place in the
/// list (`TextNormalizer.makeRules`); the part read before the custom lexicon is `ShorthandPass`.
enum ShorthandRules {
    typealias Rule = TextNormalizer.Rule

    /// After the wiki-heading and symbol-run rules, before keyboard shortcuts: § and ¶, then ™,
    /// ® and © (with Lexicon.symbols), ‰, №, N°, Nos., and "#": "number", then "# of", then the
    /// "#" key ("pound" in US, "hash" in GB).
    static func signs(british: Bool) -> [Rule] {
        var rules: [Rule] = []
        // "§ 4.2", "§§ 3-5", "¶ 2": the signs were silent. A pilcrow is "paragraph" only before a
        // number; elsewhere it marks the end of a paragraph and is silent ("the end.¶").
        rules.append(Rule(#"(§§?|¶¶?(?=\s?\d))\s?|[ \t]*¶+(?!¶|\s?\d)"#) { m, s in
            guard m.range(at: 1).location != NSNotFound else { return spaceBetween(m.range, in: s) }
            let sign = s.substring(with: m.range(at: 1))
            let before = m.range.location > 0 ? s.substring(with: NSRange(location: m.range.location - 1, length: 1)) : " "
            let word = ["§": "section", "§§": "sections", "¶": "paragraph", "¶¶": "paragraphs"][sign]!
            return (before.first?.isWhitespace == false && before != "(" ? " " : "") + word + " "
        })
        // ™, ℠ and ® are silent: nobody reads "Acme trademark" aloud (DECISIONS 3). A full stop
        // after one stays ("Buy Acme®.").
        rules.append(Rule(#"[™℠®]+"#) { m, s in spaceBetween(m.range, in: s) })
        // © is "copyright" (Lexicon.symbols), but not beside the word itself: "Copyright © 2024",
        // "© Crown copyright 2024" said it twice. "Copyright (c) 2024" drops the "(c)".
        rules.append(Rule(#"((?i:copyright))[ \t]*(?:©|\([cC]\))|©[ \t]*(?=(?:\p{Lu}\p{L}*[ \t]+)?(?i:copyright)(?![\p{L}]))"#) { m, s in
            m.range(at: 1).location != NSNotFound ? s.substring(with: m.range(at: 1)) : ""
        })
        // "(c) 2024 Acme" opening a line is a copyright line; "(c) 2019 sales rose" (a list label
        // before a lower-case word) and "(a) 2017, (b) 2018, (c) 2019" are not.
        rules.append(Rule.withContext(#"^[ \t]*\([cC]\)(?=[ \t]*(?:1\d{3}|20\d{2})(?:[ \t]*[-–][ \t]*\d{2,4})?(?:[ \t]*$|,|[ \t]+\p{Lu}))"#,
                                      options: .anchorsMatchLines) { m, s, context in
            let head = context.text(before: m.range, in: s, limit: 80)
            guard head.isEmpty || head.last?.isNewline == true else { return s.substring(with: m.range) }
            return "Copyright"
        })
        // "5‰" is "five per mille": the sign was silent, or an unknown sign when spaced.
        rules.append(Rule(#"(?<=\d)[ \t]?‰"#) { _, _ in " per mille" })
        // "№ 58", "N°5", "Nº 3": the number sign. № would otherwise become the letters "No".
        rules.append(Rule(#"(?<![\p{L}\p{N}])(?:№|[Nn][°º])[ \t]?(?=\d)"#) { _, _ in "number " })
        // "Nos. 3 and 4": numbers. ("No." is the tokenizer's: the gold lexicon reads it "number".)
        rules.append(Rule(#"(?<![\p{L}.])([Nn])os\.(?=[ \t]?#?\d)"#) { m, s in s.substring(with: m.range(at: 1)) == "N" ? "Numbers" : "numbers" })
        // "#1", "Issue #48": "number". Not a hashtag or a hex colour (the digits run into letters:
        // "#2020Vision", "#1e90ff"), a CSS grey ("#333"), a keypad code ("#31#"), "&#123;", or a "#"
        // after "No." (the tokenizer reads "No. #7" as "number seven").
        rules.append(Rule(#"(?<![\p{L}\p{N}#&/;])(?<![Nn]o\.\s|[Nn]os\.\s|[Nn]o\.|[Nn]os\.)#(?=(\d+)(?:[.,]\d+)?(?![\p{L}\d#*]))"#) { m, s in
            let digits = s.substring(with: m.range(at: 1))
            if digits.count == 3, Set(digits).count == 1 { return "#" }
            return "number "
        })
        // "The # of items" is "number" (group 1), even after a key verb ("Enter # of guests").
        // Otherwise the key, "Press # to continue", "the # key", is "pound" on American phones
        // and "hash" on British ones.
        let key = british ? "hash" : "pound"
        let keyVerbs = "press|presses|pressed|pressing|hit|hits|hitting|tap|taps|tapped|tapping|enter|enters|entered|entering|dial|dials|dialed|dialled|dialing|dialling"
        rules.append(Rule(#"(?<![\p{L}\p{N}#])(#)(?=[ \t]+of(?![\p{L}\p{N}]))|(?<=\b(?i:"# + keyVerbs + #")[ \t])#(?=\s|[.,;:!?)]|$)|(?<![\p{L}\p{N}#])#(?=[ \t]+(?i:key|keys|button|buttons)(?![\p{L}]))"#) { m, _ in
            m.range(at: 1).location != NSNotFound ? "number" : key
        })
        return rules
    }

    /// Nothing where a sign stood, or a space when it stood between two words or numbers
    /// ("Acme®Pro"), so they stay apart.
    private static func spaceBetween(_ range: NSRange, in s: NSString) -> String {
        func isWord(_ at: Int) -> Bool {
            guard at >= 0, at < s.length, let c = Unicode.Scalar(s.character(at: at)) else { return false }
            return Scalars.isLetterOrNumber(c)
        }
        return isWord(range.location - 1) && isWord(NSMaxRange(range)) ? " " : ""
    }

    /// "a 45° angle": after web addresses, before units' coordinates and Temperatures. After "a"
    /// or "an" and before a noun, the degree is an adjective, singular ("forty five degrees angle"
    /// was). "It was 30° yesterday" keeps the plural.
    static func degreeAdjective(british: Bool) -> [Rule] {
        [Rule(#"(?<=\b(?:a|an|A|An)[ \t])(\d+(?:\.\d+)?)[ \t]?°(?![ \t]?[CFcf](?!\p{L}))(?=[ \t]+\p{Ll})"#) { m, s in
            s.substring(with: m.range(at: 1)) + " degree"
        }]
    }

    /// "5~10" as a range, then "~" as "about": after dates' durations, before units' modifiers,
    /// the unit range rule, `units` and Ranges.
    static func tildes(british: Bool) -> [Rule] {
        var rules: [Rule] = []
        // "9~5", "10:00~18:00": a range, as East Asian text writes it.
        rules.append(Rule(#"(?<![\p{L}\p{N}~])(\d{1,2}(?::\d{2})?|\d+)[ \t]?~[ \t]?(\d{1,2}(?::\d{2})?|\d+)(?![\d~])"#) { m, s in
            s.substring(with: m.range(at: 1)) + " to " + s.substring(with: m.range(at: 2))
        })
        // "~5", "~ 10 km", "~-5°C", "~1,000": "about". Not a path ("~/Documents"), code ("~y"), a
        // semver range ("~4.17.21") or strikethrough ("~~"). Before money it's the money pass's.
        rules.append(Rule.withContext(#"(?<![\p{L}\p{N}~/\\])~[ \t]?(?=[-−]?\d)(?![ \t]?\d+\.\d+\.\d)"#) { m, s, context in
            let head = context.text(before: m.range, in: s, limit: 40)
            let opens = head.reversed().first { !($0 == " " || $0 == "\t" || "([{\"“‘'".contains($0)) }
            return opens == nil || opens?.isNewline == true || ".!?…".contains(opens!) ? "About " : "about "
        })
        return rules
    }

    private static let abbreviations: [(String, String)] = [
        ("e.g.", "for example"), ("E.g.", "For example"), ("i.e.", "that is"), ("I.e.", "That is"),
        ("approx.", "approximately"), ("Approx.", "Approximately"), ("incl.", "including"), ("Incl.", "Including"),
        ("Dept.", "Department"), ("dept.", "department"),
    ]

    /// Abbreviations whose period can also be the full stop ("…pens and misc."), so they keep it
    /// before the end or a usual sentence opener (`FullStop`). One rule reads them all.
    private static let endingAbbreviations = ["avg": "average", "Avg": "Average", "excl": "excluding", "Excl": "Excluding",
                                              "misc": "miscellaneous", "Misc": "Miscellaneous"]

    /// What "est." reads as, from what follows it (`estimate`): a founding year, then an amount,
    /// then a noun an estimate is usually of.
    private static let foundingYear = try! NSRegularExpression(pattern:
        #"^\s+(?:in\s+)?(?:1\d{3}|20\d{2})(?![\d,.]\d)(?=\s*$|\s*\p{P}|\s+(?:in|by|at|on|and|as|since|from)(?![\p{L}]))"#)
    private static let estimatedAmount = try! NSRegularExpression(pattern: #"^\s+[~≈]?[-−]?[$£€¥₹₩]?\d"#)
    private static let estimatedNoun = try! NSRegularExpression(pattern:
        #"^\s+(?:cost|costs|delivery|arrival|time|reading|total|value|price|wait|completion|date|budget|savings|population|duration|departure|shipping|tax|payment|revenue|attendance)(?![\p{L}])"#)

    /// After the "(s)" plural, near the end of the list: the abbreviations, then the bare forms
    /// (avg, approx), est., and ca. or c. as circa. Years are read by the lexicon, and dates'
    /// century rule needs an ordinal, so circa never meets it.
    static func abbreviationRules(british: Bool) -> [Rule] {
        var rules: [Rule] = []
        for (abbr, full) in abbreviations {
            rules.append(Rule("(?<![\\p{L}.])" + NSRegularExpression.escapedPattern(for: abbr) + "(?=\\s|$|[,;:)])") { _, _ in full })
        }
        rules.append(Rule.withContext("(?<![\\p{L}.])(" + endingAbbreviations.keys.sorted().joined(separator: "|") + ")\\.(?=\\s|$|[,;:)])") { m, s, context in
            endingAbbreviations[s.substring(with: m.range(at: 1))]!
                + FullStop.kept(before: context.text(after: m.range, in: s, limit: 40), next: .sentenceStarter)
        })
        // Without the period: "the class avg is 72" (not AVG the antivirus, or avg() in code),
        // and approx before a number.
        rules.append(Rule(#"(?<![\p{L}\p{N}_.])(avg|Avg)(?![\p{L}\p{N}_(.])"#) { m, s in
            s.substring(with: m.range(at: 1)) == "Avg" ? "Average" : "average"
        })
        rules.append(Rule(#"(?<![\p{L}\p{N}_.])(approx|Approx)(?=\s+[~≈]?[-−]?[$£€¥₹₩]?\d)"#) { m, s in
            s.substring(with: m.range(at: 1)) == "Approx" ? "Approximately" : "approximately"
        })
        // est.: "Est. 1892" is established; "est. 1500 attendees", "est. £2,000" and "Est.
        // delivery" are estimated. Anything else ("a free est. today", the time zone "9 pm EST.")
        // is left alone. All-caps EST. is only the sign's "EST. 1950", opening a line or after a
        // separator.
        rules.append(Rule.withContext(#"(?<![\p{L}\p{N}_.])(Est|est|EST)\.(?=\s)"#) { m, s, context in
            let written = s.substring(with: m.range(at: 1))
            let rest = context.text(after: m.range, in: s, limit: 60)
            let all = NSRange(location: 0, length: (rest as NSString).length)
            let word: String
            if foundingYear.firstMatch(in: rest, range: all) != nil {
                if written == "EST" {
                    let head = context.text(before: m.range, in: s, limit: 40)
                    let opens = head.reversed().first { $0 != " " && $0 != "\t" }
                    guard opens == nil || opens?.isNewline == true || ",·|—".contains(opens!) else { return s.substring(with: m.range) }
                }
                word = "established"
            } else if written != "EST", estimatedAmount.firstMatch(in: rest, range: all) != nil || estimatedNoun.firstMatch(in: rest, range: all) != nil {
                word = "estimated"
            } else {
                return s.substring(with: m.range)
            }
            return written == "est" ? word : word.prefix(1).uppercased() + word.dropFirst()
        })
        // Circa before a year: "built ca. 1850", "(c. 1650)". Only lower case: "C." is an
        // initial, and "c." before a number that isn't a year is a chapter ("1998 c. 42").
        rules.append(Rule(#"(?<![\p{L}\p{N}_.])ca\.[ \t]?(?=\d{3,4}(?![\d,]))|(?<![\p{L}\p{N}_.&])c\.[ \t]?(?=(?:1\d{3}|20\d{2})(?![\d,.]\d))"#) { _, _ in
            "circa "
        })
        return rules
    }
}
