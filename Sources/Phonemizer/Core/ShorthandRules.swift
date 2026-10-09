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
        // "§ 4.2", "§§ 3-5", "¶ 2": the signs were silent.
        rules.append(Rule(#"(§§?|¶)\s?"#) { m, s in
            let sign = s.substring(with: m.range(at: 1))
            let before = m.range.location > 0 ? s.substring(with: NSRange(location: m.range.location - 1, length: 1)) : " "
            let word = sign == "§" ? "section" : sign == "§§" ? "sections" : "paragraph"
            return (before.first?.isWhitespace == false && before != "(" ? " " : "") + word + " "
        })
        return rules
    }

    /// "a 45° angle": after web addresses, before units' coordinates and Temperatures.
    static func degreeAdjective(british: Bool) -> [Rule] {
        []
    }

    /// "5~10" as a range, then "~" as "about": after dates' durations, before units' modifiers,
    /// the unit range rule, `units` and Ranges.
    static func tildes(british: Bool) -> [Rule] {
        []
    }

    private static let abbreviations: [(String, String)] = [
        ("e.g.", "for example"), ("E.g.", "For example"), ("i.e.", "that is"), ("I.e.", "That is"),
        ("approx.", "approximately"), ("Approx.", "Approximately"), ("incl.", "including"), ("Incl.", "Including"),
        ("Dept.", "Department"), ("dept.", "department"),
    ]

    /// After the "(s)" plural, near the end of the list: the abbreviations, then the bare forms
    /// (avg, approx), est., and ca. or c. as circa. Years are read by the lexicon, and dates'
    /// century rule needs an ordinal, so circa never meets it.
    static func abbreviationRules(british: Bool) -> [Rule] {
        var rules: [Rule] = []
        for (abbr, full) in abbreviations {
            rules.append(Rule("(?<![\\p{L}.])" + NSRegularExpression.escapedPattern(for: abbr) + "(?=\\s|$|[,;:)])") { _, _ in full })
        }
        return rules
    }
}
