import Foundation

/// Shorthand and signs read by TextNormalizer's rules (Core readings, FIN-889; area
/// "shorthand"): §, ¶, ™, ®, ©, ‰, №, "#", "~", the adjectival degree and the abbreviations.
/// Each hook runs at its own place in the list (`TextNormalizer.makeRules`).
enum ShorthandRules {
    typealias Rule = TextNormalizer.Rule

    /// After the wiki-heading and symbol-run rules.
    static func sectionSigns(british: Bool) -> [Rule] {
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

    /// Right after the section signs: ™, ® and © (with Lexicon.symbols), ‰, №, N°, Nos., and
    /// "#" as "number", then "# of", then the "#" key ("pound" in US, "hash" in GB).
    static func signs(british: Bool) -> [Rule] {
        []
    }

    /// "a 45° angle", before units' coordinates and Temperatures.
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
        ("Ave.", "Avenue"), ("Blvd.", "Boulevard"), ("Mt.", "Mount"), ("Dept.", "Department"), ("dept.", "department"),
    ]

    /// Last but the legacy title and Roman rules: the abbreviations, then the bare forms
    /// (avg, approx), est. and circa. Years are read by the lexicon, and dates' century rule
    /// needs an ordinal, so circa never meets it.
    static func abbreviationRules(british: Bool) -> [Rule] {
        var rules: [Rule] = []
        // Abbreviations.
        for (abbr, full) in abbreviations {
            rules.append(Rule("(?<![\\p{L}.])" + NSRegularExpression.escapedPattern(for: abbr) + "(?=\\s|$|[,;:)])") { _, _ in full })
        }
        return rules
    }
}
