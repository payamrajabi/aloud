import Foundation

/// Money (Core readings, FIN-889; area "money"): prices, currency symbols and codes, magnitudes,
/// per-unit prices, ranges, signs, and "~" or "≈" before an amount.
///
/// The pass reads whole money expressions on the raw text, before the custom lexicon marks terms
/// inside them (CAD, EUR, USD, "Max", the unit entries mm, ms, GB and MB) and before the phone
/// pass, so "$911" and "$555" are already money when phone numbers are looked for. It writes
/// digits and words for the number reader.
enum MoneyPass {
    typealias Rule = TextNormalizer.Rule

    /// The money pass: in `Phonemizer.phonemize` after the quarter-year split and before the
    /// phone pass, only when normalizing. Words it inserts into a sentence written in capitals go
    /// through `ShoutedCasing`, because `unshout` runs after it. It reads nothing yet: fix3's
    /// rules below still do, in TextNormalizer's list.
    static func apply(_ text: String, british: Bool) -> String {
        text
    }

    /// Currency symbols, with the word read after an amount ("2.3 billion pounds").
    private static let currencyWords: [String: String] = ["$": "dollars", "£": "pounds", "€": "euros", "¥": "yen",
                                                           "₹": "rupees", "₩": "won"]
    /// Amount suffixes after a currency amount ("$40m", "£2.3bn", "€45k").
    private static let scaleWords: [String: String] = [
        "k": "thousand", "K": "thousand", "m": "million", "M": "million", "mn": "million", "mm": "million", "MM": "million",
        "bn": "billion", "b": "billion", "B": "billion", "tn": "trillion", "trn": "trillion", "T": "trillion",
        "thousand": "thousand", "million": "million", "billion": "billion", "trillion": "trillion",
    ]
    /// What "/…" after an amount is per ("$9.99/month", "£50/hr").
    private static let perUnits: [String: String] = [
        "month": "month", "mo": "month", "mth": "month", "hour": "hour", "hr": "hour", "h": "hour", "year": "year",
        "yr": "year", "annum": "annum", "week": "week", "wk": "week", "day": "day", "night": "night", "person": "person",
        "head": "head", "user": "user", "seat": "seat", "unit": "unit", "item": "item", "piece": "piece", "kg": "kilogram",
        "lb": "pound", "gallon": "gallon", "gal": "gallon", "litre": "litre", "liter": "liter", "mile": "mile",
        "minute": "minute", "min": "minute", "visit": "visit", "session": "session", "ticket": "ticket", "share": "share",
    ]

    /// fix3/reading's money rules (per-unit, range and scale), first in TextNormalizer's list,
    /// where they always ran: after the custom lexicon and `unshout`, which is why "$4.99 CAD"
    /// still ends "cad". The money pass replaces them; until it does, today's readings hold.
    static func legacyRules(british: Bool) -> [Rule] {
        var rules: [Rule] = []
        // Money with an amount suffix, a "per" unit or a range: the G2P gives a number its
        // currency only when nothing follows it, so "$40m" was "forty M", "$9.99/month" lost its
        // dollars and "$10-$20" was "ten twenty".
        let currencies = "[$£€¥₹₩]"
        let amount = #"(\d+(?:,\d{3})*(?:\.\d+)?)"#
        // Two groups: a suffix written against the amount ("40m", "2.3bn"), or a longer one
        // that may follow a space ("2.3 bn", "1.5 million").
        let scale = #"(?:([kKmMbBT]|mm|MM)|\s?(mn|bn|tn|trn|thousand|million|billion|trillion))(?![\p{L}\d])"#
        func scaleWord(_ m: NSTextCheckingResult, _ s: NSString, _ a: Int, _ b: Int) -> String? {
            for g in [a, b] where m.range(at: g).location != NSNotFound { return scaleWords[s.substring(with: m.range(at: g))] }
            return nil
        }
        let perUnitPattern = perUnits.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        // "$9.99/month" → "$9.99 per month", "£2m/yr" → "2 million pounds per year".
        rules.append(Rule(#"(?<![\p{L}\d])("# + currencies + ")" + amount + "(?:" + scale + #")?\s?/\s?("# + perUnitPattern + #")(?![\p{L}\d])"#) { m, s in
            let symbol = s.substring(with: m.range(at: 1)), n = s.substring(with: m.range(at: 2))
            let per = "per " + perUnits[s.substring(with: m.range(at: 5))]!
            if let scale = scaleWord(m, s, 3, 4) { return "\(n) \(scale) \(currencyWords[symbol]!) \(per)" }
            return "\(symbol)\(n) \(per)"
        })
        // "$10-$20" → "$10 to $20"; "$1.5-$2.5 million" → "1.5 to 2.5 million dollars".
        rules.append(Rule(#"(?<![\p{L}\d\-–−+./])("# + currencies + ")" + amount + "(?:" + scale + #")?\s?[-–]\s?("# + currencies
                          + ")?" + amount + "(?:" + scale + #")?(?![\d\-–]|[.,]\d)"#) { m, s in
            let symbol = s.substring(with: m.range(at: 1))
            if m.range(at: 5).location != NSNotFound, s.substring(with: m.range(at: 5)) != symbol { return s.substring(with: m.range) }
            let a = s.substring(with: m.range(at: 2)), b = s.substring(with: m.range(at: 6))
            let scaleA = scaleWord(m, s, 3, 4), scaleB = scaleWord(m, s, 7, 8)
            guard scaleA != nil || scaleB != nil else { return "\(symbol)\(a) to \(symbol)\(b)" }
            let first = scaleA.map { $0 != scaleB ? "\(a) \($0)" : a } ?? a
            return "\(first) to \(b) \(scaleB ?? scaleA!) \(currencyWords[symbol]!)"
        })
        // "$40m" → "40 million dollars", "£2.3bn" → "2.3 billion pounds".
        rules.append(Rule(#"(?<![\p{L}\d])("# + currencies + ")" + amount + scale) { m, s in
            let symbol = s.substring(with: m.range(at: 1))
            return "\(s.substring(with: m.range(at: 2))) \(scaleWord(m, s, 3, 4)!) \(currencyWords[symbol]!)"
        })
        return rules
    }

    /// The sign before a currency symbol, in TextNormalizer's list after the U+2212 and en dash
    /// rules (which stay there for bare numbers). The money pass takes over every sign before a
    /// currency ("-$", "−€", "-C$"); then this returns no rules.
    static func signRules(british: Bool) -> [Rule] {
        var rules: [Rule] = []
        // "-$50": the sign before a currency symbol was dropped with it ("fifty").
        rules.append(Rule(#"(?<![\p{L}\d])-(?=[$£€¥₹₩]\d)"#) { _, _ in "minus " })
        return rules
    }
}
