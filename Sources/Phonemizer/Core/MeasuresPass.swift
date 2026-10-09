import Foundation

/// Heights, sizes and multipliers (Core readings, FIN-889; area "dimensions"): feet and
/// inches ("6'2\"", "6 ft 2 in"), inch and foot marks, sizes with x or × ("2x4", "10 x 12
/// ft") and x as a multiplier ("3x faster", "3x champion").
///
/// The pass runs before the custom lexicon (its "10x", "1X" and "X" keys), after the phone
/// pass (so a phone extension "x 214" is gone) and after money; an operand with a currency
/// next to it is left alone.
enum MeasuresPass {
    typealias Rule = TextNormalizer.Rule

    /// The measures pass, in `Phonemizer.phonemize` after the shorthand pass and before the
    /// custom lexicon, only when normalizing. Inserted words go through `ShoutedCasing`. It
    /// reads nothing yet: fix3's rules below still do.
    static func apply(_ text: String, british: Bool) -> String {
        text
    }

    /// fix3/reading's height rule and three inch rules, still in TextNormalizer's rules right
    /// after Temperatures, where they always ran. The measures pass replaces them all.
    static func legacyRules(british: Bool) -> [Rule] {
        var rules: [Rule] = []
        // Heights: 5'11" → "5 foot 11" (it was "five hundred eleven").
        rules.append(Rule(#"(?<![\d.,'’])(\d{1,2})\s?['’′]\s?(\d{1,2})(?:\s?(?:"|″|”|''))?(?![\d'’\p{L}])"#) { m, s in
            "\(s.substring(with: m.range(at: 1))) foot \(s.substring(with: m.range(at: 2)))"
        })
        // Inches: 9" x 13" → "9 by 13 inches"; "a 13" laptop" → "a 13 inch laptop"; 27″.
        rules.append(Rule(#"(?<![\d.,])(\d+(?:\.\d+)?)\s?["″”]\s?[x×]\s?(\d+(?:\.\d+)?)\s?["″”](\s+\p{Ll})?"#) { m, s in
            let noun = m.range(at: 3).location != NSNotFound
            return "\(s.substring(with: m.range(at: 1))) by \(s.substring(with: m.range(at: 2))) inch\(noun ? "" : "es")"
                + (noun ? s.substring(with: m.range(at: 3)) : "")
        })
        rules.append(Rule(#"(?<=\b(?:a|an|the|my|our|your|his|her|their|this|that|new|old)\s)(\d+(?:\.\d+)?)["″”](?=\s\p{Ll})"#,
                          options: .caseInsensitive) { m, s in
            "\(s.substring(with: m.range(at: 1))) inch"
        })
        rules.append(Rule(#"(?<![\d.,])(\d+(?:\.\d+)?)\s?″"#) { m, s in
            let n = s.substring(with: m.range(at: 1))
            return n + (TextNormalizer.isOne(n) ? " inch" : " inches")
        })
        return rules
    }
}
