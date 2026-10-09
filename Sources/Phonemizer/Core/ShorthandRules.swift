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
        rules.append(Rule(#"(§§?|¶¶?(?=\s?\d))\s?(?:(?<=§|§\s)(\d{3})(?![\d.,]))?|[ \t]*¶+(?!¶|\s?\d)"#) { m, s in
            guard m.range(at: 1).location != NSNotFound else { return spaceBetween(m.range, in: s) }
            let sign = s.substring(with: m.range(at: 1))
            let before = m.range.location > 0 ? s.substring(with: NSRange(location: m.range.location - 1, length: 1)) : " "
            let word = ["§": "section", "§§": "sections", "¶": "paragraph", "¶¶": "paragraphs"][sign]!
            // A three-digit section is said in pairs, as lawyers say it: "§230" is "section two
            // thirty", "§ 101" "section one oh one".
            var number = ""
            if m.range(at: 2).location != NSNotFound {
                let d = Array(s.substring(with: m.range(at: 2)))
                number = d[1] == "0" && d[2] == "0" ? String(d) : d[1] == "0" ? "\(d[0]) oh \(d[2])" : "\(d[0]) \(d[1])\(d[2])"
            }
            return (before.first?.isWhitespace == false && before != "(" ? " " : "") + word + " " + number
        })
        // A middle dot between two parts of a line ("Thu, Oct 9 · 2:00 – 2:30pm") is a pause; read,
        // it was an unknown sign.
        rules.append(Rule(#"[ \t]+·[ \t]+"#) { _, _ in ", " })
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
        // A keypad code ended with the key: "Gate code 1234#", "PIN: 312 554 917#" → "1 2 3 4
        // pound" (GB "hash"), digit by digit and a pause between groups, as it's keyed in. The
        // key was silent and the code a number ("twelve thirty-four").
        let key = british ? "hash" : "pound"
        rules.append(Rule(#"(?<![\p{L}\p{N}#*.,:/\-])(\d{3,}(?:[ \t]\d{2,})*)#(?![\p{L}\p{N}#*])"#) { m, s in
            s.substring(with: m.range(at: 1)).split(separator: " ").map { SpokenNumbers.digits($0) }.joined(separator: ", ") + ", " + key
        })
        // "#1", "Issue #48": "number". Not a hashtag or a hex colour (the digits run into letters:
        // "#2020Vision", "#1e90ff"), a CSS grey ("#333"), a keypad code ("#31#"), "&#123;", or a "#"
        // after "No." (the tokenizer reads "No. #7" as "number seven"). Five digits or more are an
        // ID, read digit by digit ("Badge #1234567"; it was "one million two hundred…").
        rules.append(Rule(#"(?<![\p{L}\p{N}#&/;])(?<![Nn]o\.\s|[Nn]os\.\s|[Nn]o\.|[Nn]os\.)#(?=(\d+)(?:[.,]\d+)?(?![\p{L}\d#*]))(?:(\d{5,})(?![.,]\d))?"#) { m, s in
            let digits = s.substring(with: m.range(at: 1))
            if digits.count == 3, Set(digits).count == 1 { return "#" }
            if m.range(at: 2).location != NSNotFound { return "number " + SpokenNumbers.digits(digits) }
            return "number "
        })
        // "The # of items" is "number" (group 1), even after a key verb ("Enter # of guests").
        // Otherwise the key, "Press # to continue", "the # key", is "pound" on American phones
        // and "hash" on British ones.
        let keyVerbs = "press|presses|pressed|pressing|hit|hits|hitting|tap|taps|tapped|tapping|enter|enters|entered|entering|dial|dials|dialed|dialled|dialing|dialling"
        rules.append(Rule(#"(?<![\p{L}\p{N}#])(#)(?=[ \t]+of(?![\p{L}\p{N}]))|(?<=\b(?i:"# + keyVerbs + #")[ \t])#(?=\s|[.,;:!?)]|$)|(?<![\p{L}\p{N}#])#(?=[ \t]+(?i:key|keys|button|buttons)(?![\p{L}]))"#) { m, _ in
            m.range(at: 1).location != NSNotFound ? "number" : key
        })
        // The key again later in a list of presses: "Press 1, then 3, then #." Only in a
        // sentence that presses or dials.
        rules.append(Rule.withContext(#"(?<=\b(?:then|or|and)[ \t])#(?=\s|[.,;:!?)]|$)"#) { m, s, context in
            matches(keyVerbPattern, context.sentence(around: m.range, in: s)) ? key : "#"
        })
        // A star key before a code ("Dial *67"), and a rating ("a 5* hotel") → "star".
        rules.append(Rule(#"(?<=\b(?i:"# + keyVerbs + #")[ \t])\*(?=\d)"#) { _, _ in "star " })
        rules.append(Rule(#"(?<![\p{L}\p{N}.*])(\d(?:\.\d)?)\*(?![\d*\p{L}])(?=[ \t]+\p{L})"#) { m, s in
            s.substring(with: m.range(at: 1)) + " star"
        })
        return rules
    }

    private static let keyVerbPattern = try! NSRegularExpression(pattern: #"(?i)\b(?:press|presses|pressed|pressing|dial|dials|dialed|dialled|dialing|dialling|enter|hit|tap)\b"#)

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
        // "a ~2 hr drive": "about a 2 hr drive", as it's said (it was "a about").
        rules.append(Rule(#"(?<![\p{L}\p{N}])([Aa]n?)[ \t]+~[ \t]?(?=\d)"#) { m, s in
            let article = s.substring(with: m.range(at: 1))
            return (article.first == "A" ? "About " : "about ") + article.lowercased() + " "
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
        ("approx.", "approximately"), ("Approx.", "Approximately"),
        ("Dept.", "Department"), ("dept.", "department"),
    ]

    /// Abbreviations whose period can also be the full stop ("…pens and misc."), so they keep it
    /// before the end or a usual sentence opener (`FullStop`). One rule reads them all.
    private static let endingAbbreviations = ["avg": "average", "Avg": "Average", "misc": "miscellaneous", "Misc": "Miscellaneous",
                                              "esp": "especially", "Esp": "Especially"]

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
        // incl. and excl. before what they take in: "including VAT", "excluding food"; with
        // nothing after them in their clause, the participle ("Wi-Fi & parking incl.", "Taxes
        // excl.": included, excluded), keeping a full stop.
        rules.append(Rule.withContext(#"(?<![\p{L}.])([Ii]ncl|[Ee]xcl)\.(?=\s|$|[,;:)])"#) { m, s, context in
            let found = s.substring(with: m.range(at: 1))
            let stem = (found.first == "I" ? "Includ" : found.first == "i" ? "includ" : found.first == "E" ? "Exclud" : "exclud")
            let after = context.text(after: m.range, in: s, limit: 40)
            if FullStop.ends(before: after, next: .sentenceStarter) || after.first.map({ ",;:)".contains($0) }) == true {
                return stem + "ed" + FullStop.kept(before: after, next: .sentenceStarter)
            }
            return stem + "ing"
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
        // Before an amount it's "around": "The Treasury expects c.£4bn" (the money pass has read
        // "4 billion pounds").
        rules.append(Rule(#"(?<![\p{L}\p{N}_.&])c\.[ \t]?(?=[~≈]?\d[\d,.]*(?:[ \t]+(?:thousand|million|billion|trillion))?[ \t]+(?:"#
                          + CurrencyNames.words.sorted().joined(separator: "|") + #")(?![\p{L}]))"#) { _, _ in "around " })
        // Before a time it's "around": "Results are expected c. 2am" (the clock rules have read
        // the time already: "c. 2 AM").
        rules.append(Rule(#"(?<![\p{L}\p{N}_.&])c\.[ \t]?(?=\d{1,2}(?:[: ]\d{2})?[ \t](?:AM|PM|A\.M\.|P\.M\.|o'clock)(?![\p{L}]))"#) { _, _ in
            "around "
        })
        // "Wk 42", "Pg 4" without the point (lower case "pg" is the lexicon's PG).
        rules.append(Rule(#"(?<![\p{L}\p{N}_.&])(Wk|Pg)[ \t](?=\d)"#) { m, s in labels[s.substring(with: m.range(at: 1))]! + " " })
        // "col. B" in a spreadsheet: a column (a single capital after it). Capitalised, "Col." is
        // as often the title, and stays.
        rules.append(Rule(#"(?<![\p{L}\p{N}_.&])col\.[ \t]?(?=\p{Lu}(?![\p{L}\p{N}]))"#) { _, _ in "column " })
        // Labels before a number: "p. 12", "pp. 14-17", "Fig. 2", "Vol. 3", "Art. 5", "col. 4",
        // "Pt. 2", "Wk. 9", "Sec. 4.2", "Ch. 3" → "page 12", "pages 14 to 17", "Figure 2"… They
        // were letters or a made-up word ("fig", "vol", "sek"). Only before a number, or for pages
        // a Roman numeral ("pp. i–xii"), and never after one ("30 sec. 4 more", "1 pt. cream").
        rules.append(Rule(#"(?<![\p{L}\p{N}_.&])(?<!\d[ \t])(pp|p|Figs|figs|Fig|fig|Vols|Vol|vol|Arts|Art|art|Col|col|Pt|pt|Wk|wk|Secs|Sec|sec|Ch|ch|Pg)\.[ \t]?(?=\d|(?<=pp\.|pp\.[ \t])[ivxlcIVXLC]+(?:[–-][ivxlcIVXLC]+)?(?![\p{L}]))"#) { m, s in
            (labels[s.substring(with: m.range(at: 1))] ?? s.substring(with: m.range(at: 1))) + " "
        })
        // Shorthand that is never a word: "Qty" quantity, "ppl" people, "mgr" manager, "mgmt",
        // "Mtg", "Govt", "pls", "thx", "tmrw", "Utd" United, "Natl." National,
        // "intl." international, "Bros." Brothers, "Aus. Open" Australian.
        rules.append(Rule.withContext(#"(?<![\p{L}\p{N}_.&/@])(Qty|QTY|qty|ppl|Mgr|mgr|Mgmt|mgmt|Mtgs|mtgs|Mtg|mtg|Govt|govt|Pls|pls|Plz|plz|Thx|thx|Thnx|thnx|Tmrw|tmrw|Utd|Natl|natl|Intl|intl|Bros|Aus(?=\.[ \t]+Open\b))(\.)?(?![\p{L}\p{N}_/@]|\.\p{L})"#) { m, s, context in
            let found = s.substring(with: m.range(at: 1))
            let dotted = m.range(at: 2).location != NSNotFound
            // Natl, Intl, Bros and Aus need their point; the rest are whole words.
            if !dotted, ["Natl", "natl", "Intl", "intl", "Bros", "Aus"].contains(found) { return s.substring(with: m.range) }
            let after = context.text(after: m.range, in: s, limit: 40)
            // "Mgr." before a name stays ("Ofc. Mgr. Linda Park"). ("Asst. Mgr" is the titles pass's.)
            if found == "Mgr", dotted, matches(nameAhead, after) { return s.substring(with: m.range) }
            // The older words keep a full stop before any capital ("Natl." ends "…the Natl."); the
            // rest only before a usual sentence opener ("Asst. Mgr" is one title).
            let next: FullStop.Next = capitalStops.contains(found) ? .capital : .sentenceStarter
            return shorthandWords[found]! + (dotted ? FullStop.kept(before: after, next: next) : "")
        })
        // "med." before a speed, a heat or what a recipe sizes: "Mix on med. speed" (not "med.
        // school").
        rules.append(Rule(#"(?<![\p{L}\p{N}_.&])med\.(?=[ \t]+(?:speed|heat|high|low|setting|size|bowl|saucepan|pan|pot|skillet|onions?|potato(?:es)?|carrots?|eggs?|tomato(?:es)?|apples?|lemons?|limes?)(?![\p{L}]))"#) { _, _ in "medium" })
        // "Co." after a name is a company ("Ford Motor Co. said", "& Co."), and "Co" before an
        // Irish county the county ("A farm in Co Tyrone", "Co. Cork").
        rules.append(Rule(#"(?<![\p{L}\p{N}_.])Co\.?(?=[ \t]+(?:"# + irishCounties + #")(?![\p{L}]))"#) { _, _ in "County" })
        rules.append(Rule.withContext(#"(?<=\p{L}[ \t]|&[ \t])Co\.(?![\p{L}\p{N}])"#) { m, s, context in
            // A company only after a name ("Motor", "Smith &").
            let before = context.text(before: m.range, in: s, limit: 40)
            let word = before.reversed().drop { $0 == " " || $0 == "\t" }.prefix { $0.isLetter || $0 == "&" }
            guard word.last == "&" || word.last?.isUppercase == true else { return s.substring(with: m.range) }
            let after = context.text(after: m.range, in: s)
            // A county where the sentence counts votes or a county's office follows: "Ballots in
            // Clark Co. were still being counted", "the Clark Co. Sheriff".
            if word.last != "&", matches(countyAhead, after) || matches(electionWords, context.sentence(around: m.range, in: s)) {
                return "County" + FullStop.kept(before: after, next: .sentenceStarter)
            }
            return "Company" + FullStop.kept(before: after, next: .sentenceStarter)
        })
        // A life in brackets: "(b. 1924, d. 2024)", "(b. 8 Jan 1947)", "(r. 1837-1901)" → born,
        // died, reigned. Only after a bracket or a comma, before a year or a date.
        rules.append(Rule(#"(?<=[(\[]|[(\[][ \t]|,[ \t])([bdr])\.[ \t]?(?=(?:c\.|ca\.)?[ \t]?\d{3,4}(?![\d,.]\d)|\d{1,2}(?:st|nd|rd|th)?[ \t]+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)|the[ \t]\d|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\p{L}*\.?[ \t]\d)"#) { m, s in
            ["b": "born ", "d": "died ", "r": "reigned "][s.substring(with: m.range(at: 1))]!
        })
        // "inc." before what a price includes: "£29.99 inc. VAT", and after a comma, before what a
        // list takes in: "All Cabinet ministers, inc. the Chancellor". ("Inc." after a name is the
        // company's.)
        rules.append(Rule.withContext(#"(?<![\p{L}\p{N}_.])inc\.(?=[ \t])"#) { m, s, context in
            let after = context.text(after: m.range, in: s, limit: 30)
            guard matches(includedAhead, after) || context.text(before: m.range, in: s, limit: 4).hasSuffix(", ")
                    && matches(listAhead, after) else { return s.substring(with: m.range) }
            return "including"
        })
        // "re:" inside a sentence: "said nothing re: the winter fuel payment" → "regarding".
        // ("RE:" opening an email's subject stays.)
        rules.append(Rule(#"(?<=\p{L}[ \t])re:(?=[ \t]+[\p{L}\p{N}"“'‘])"#) { _, _ in "regarding" })
        // "aka" and "a.k.a." between a name and another: "Hunter Biden, aka 'the First Son'".
        rules.append(Rule(#"(?<![\p{L}\p{N}_.])(?:aka|a\.k\.a\.)(?=[ \t]+[\p{L}"“'‘(])"#) { _, _ in "also known as" })
        // A fixture written "v" between two names: "England v Australia" → "versus". (A law
        // case's "v.", "Roe v. Wade", is said as the letter too, and stays.)
        rules.append(Rule(#"(?<=\p{Lu}\p{L}{0,30}[ \t])v(?=[ \t]+\p{Lu})"#) { _, _ in "versus" })
        // "No 10 said", "a No 10 source", "close to No 11", and "No.1 priority" with its point
        // glued on: "Number". The tokenizer reads only "No." and a space so. At the start of a
        // sentence only Downing Street's 10 and 11 ("No 2 people are alike").
        rules.append(Rule.withContext(#"(?<![\p{L}\p{N}_.])No(?:\.(?=\d)|[ \t](?=(\d{1,3})(?![\d,.]?\d|[\p{L}%])))"#) { m, s, context in
            if m.range(at: 1).location != NSNotFound {
                let head = context.text(before: m.range, in: s, limit: 40)
                let opens = head.reversed().first { $0 != " " && $0 != "\t" && !"\"“‘'(".contains($0) }
                if opens == nil || ".!?…:\n".contains(opens!), !["10", "11"].contains(s.substring(with: m.range(at: 1))) {
                    return s.substring(with: m.range)
                }
            }
            return "Number "
        })
        // A timetable: "Arr. 14:05, Dep. 16:40" → "Arrives", "Departs" (the clock rule has read the time).
        rules.append(Rule(#"(?<![\p{L}\p{N}_.])(Arr|Dep|arr|dep)\.(?=[ \t]?\d)"#) { m, s in
            ["Arr": "Arrives", "Dep": "Departs", "arr": "arrives", "dep": "departs"][s.substring(with: m.range(at: 1))]!
        })
        // Featuring: "(feat. Billy Ray Cyrus)", and "ft." between a title and a name ("Despacito ft.
        // Justin Bieber"); after a number "ft." is feet.
        rules.append(Rule(#"(?<![\p{L}\p{N}_.])(?:([Ff])eat\.|(?<=\p{L}[ \t])ft\.)(?=[ \t]+\p{Lu})"#) { m, s in
            m.range(at: 1).location != NSNotFound && s.substring(with: m.range(at: 1)) == "F" ? "Featuring" : "featuring"
        })
        // "No. of nights": "number of" (the tokenizer leaves "No." before a word as the word no).
        rules.append(Rule(#"(?<![\p{L}\p{N}_.])([Nn])o\.(?=[ \t]+of(?![\p{L}]))"#) { m, s in
            s.substring(with: m.range(at: 1)) == "N" ? "Number" : "number"
        })
        // "A/C" is air conditioning, said as the letters ("uh C" with the A as the article).
        rules.append(Rule(#"(?<![\p{L}\p{N}/])A/C(?![\p{L}\p{N}/])"#) { _, _ in "AC" })
        // "bc" between two words in chat, before the clause it opens: "because" ("Can't go bc I'm
        // sick"). Not the calculator ("pipe it to bc and print", "| bc").
        rules.append(Rule(#"(?<=\p{Ll}[ \t])bc(?=[ \t]+(?i:i|i'm|i’m|im|it|it's|it’s|its|he|she|they|we|you|u|the|my|your|there|this|that)(?![\p{L}]))"#) { _, _ in "because" })
        // "dia." after a size: "2.5 inches dia." → "in diameter".
        rules.append(Rule(#"(?<=\b(?:inches|inch|in|cm|mm|centimeters|millimeters|meters|feet|ft)\.?[ \t])dia\.?(?![\p{L}])"#) { _, _ in
            "in diameter"
        })
        return rules
    }

    /// A name after a title: a capital and a lower-case letter.
    private static let nameAhead = try! NSRegularExpression(pattern: #"^[ \t]+\p{Lu}\p{Ll}"#)
    /// Shorthand whose point stays a full stop before any capital, as it always did.
    private static let capitalStops: Set<String> = ["Qty", "QTY", "qty", "ppl", "mgr", "Utd", "Natl", "natl", "Intl", "intl", "Bros", "Aus"]
    /// Labels before a number, written out.
    private static let labels = [
        "pp": "pages", "p": "page", "Figs": "Figures", "figs": "figures", "Fig": "Figure", "fig": "figure", "Vols": "Volumes",
        "Vol": "Volume", "vol": "volume", "Arts": "Articles", "Art": "Article", "art": "article", "Col": "Column",
        "col": "column", "Pt": "Part", "pt": "part", "Wk": "Week", "wk": "week", "Secs": "Sections", "Sec": "Section",
        "sec": "section", "Ch": "Chapter", "ch": "chapter", "Pg": "Page",
    ]
    private static let shorthandWords = [
        "Qty": "Quantity", "QTY": "QUANTITY", "qty": "quantity", "ppl": "people", "Mgr": "Manager", "mgr": "manager",
        "Mgmt": "Management", "mgmt": "management", "Mtg": "Meeting",
        "mtg": "meeting", "Mtgs": "Meetings", "mtgs": "meetings", "Govt": "Government", "govt": "government",
        "Pls": "Please", "pls": "please", "Plz": "Please", "plz": "please", "Thx": "Thanks", "thx": "thanks",
        "Thnx": "Thanks", "thnx": "thanks", "Tmrw": "Tomorrow", "tmrw": "tomorrow",
        "Utd": "United", "Natl": "National", "natl": "national", "Intl": "International", "intl": "international",
        "Bros": "Brothers", "Aus": "Australian",
    ]
    /// The counties "Co" names before them in Ireland, and Durham in England.
    private static let irishCounties = "Antrim|Armagh|Carlow|Cavan|Clare|Cork|Derry|Donegal|Down|Dublin|Fermanagh|Galway|Kerry|Kildare|Kilkenny|Laois|Leitrim|Limerick|Longford|Louth|Mayo|Meath|Monaghan|Offaly|Roscommon|Sligo|Tipperary|Tyrone|Waterford|Westmeath|Wexford|Wicklow|Durham"
    /// What a list takes in after ", inc.": "the Chancellor", "all four".
    private static let listAhead = try! NSRegularExpression(pattern: #"^[ \t]+(?:the|all|both|a|an|its|their|our|his|her|\p{Lu})"#)
    /// A county's office or people after "Co.": "the Clark Co. Sheriff", "Cook Co. voters".
    private static let countyAhead = try! NSRegularExpression(pattern: #"^[ \t]+(?i:sheriff|sheriff's|commissioners?|commission|residents|voters|officials|board|jail|courthouse|clerk|fair|deputies|prosecutor|coroner|schools|election|elections|supervisors?)(?![\p{L}])"#)
    /// A sentence about an election, where "X Co." is a county: "Ballots in Clark Co. were still being counted".
    private static let electionWords = try! NSRegularExpression(pattern: #"(?i)(?<![\p{L}])(?:ballots?|votes|voters?|voting|counted|precincts?|elections?|turnout|recount|canvass|polling)(?![\p{L}])"#)
    /// What a price includes after "inc.".
    private static let includedAhead = try! NSRegularExpression(pattern: #"^[ \t]+(?:VAT|vat|GST|tax|taxes|delivery|postage|P&P|p&p|shipping|tip|service|fees|breakfast)(?![\p{L}])"#)

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }
}
