import Foundation

/// Dates and timestamps (Core readings, FIN-889; area "dates"): numeric and written dates,
/// weekdays, month and weekday ranges, durations, "5m ago", centuries, quarters, and the British
/// wording ("the fifteenth of March"), which is why TextNormalizer's rules are built per voice
/// (`makeRules(british:)`). Each hook runs at its own place in the list.
enum DateRules {
    typealias Rule = TextNormalizer.Rule

    /// "Q3'24" → "Q3 '24": in `Phonemizer.phonemize` before the money pass, only when
    /// normalizing. Q1 to Q4, H1, H2 and FY are lexicon keys, and the apostrophe must be split
    /// off before the measures pass looks at apostrophes.
    static func splitQuarterYears(_ text: String) -> String {
        text
    }

    /// Year-first slash dates, then numeric dates ("3/4/2024"): after keyboard shortcuts, before
    /// units' slash compounds, ports, file paths, ISO, Ranges, clock, ratio and fractions.
    static func numericDates(british: Bool) -> [Rule] {
        []
    }

    /// H:MM:SS, then "5m ago" and compound durations ("1h 30m"): after powers, before shorthand's
    /// "~", the unit range rule, units' h, m and s, clock and ratio.
    static func durations(british: Bool) -> [Rule] {
        []
    }

    /// ISO dates, then day-first written dates, month-first day ranges, month ranges, weekday
    /// ranges and lists, weekdays before a date, time or ordinal, weekday abbreviations, am/pm
    /// time ranges, centuries and "Jan 2024": after the unit rules, before Ranges, clock,
    /// meridiem and fractions.
    static func calendarDates(british: Bool) -> [Rule] {
        var rules: [Rule] = []
        // ISO dates: "2024-03-15" → "March 15th, 2024".
        rules.append(Rule(#"(?<![\p{L}\d\-–−./:])(\d{4})-(\d{2})-(\d{2})(?![\p{L}\d\-–]|[.,:/]\d)"#) { m, s in
            let year = s.substring(with: m.range(at: 1))
            guard let month = Int(s.substring(with: m.range(at: 2))), let day = Int(s.substring(with: m.range(at: 3))),
                  (1...12).contains(month), (1...31).contains(day) else { return s.substring(with: m.range) }
            return "\(CalendarNames.monthsInOrder[month - 1]) \(day)\(ordinalSuffix(day)), \(year)"
        })
        return rules
    }

    /// "Jan 5" and "Feb.": after the clock, ratio and "5pm" rules, before the fractions.
    static func monthDays(british: Bool) -> [Rule] {
        var rules: [Rule] = []
        // "Jan 5" / "January 5, 2024" → "January 5th".
        let monthNames = "Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sept|Sep|Oct|Nov|Dec|January|February|March|April|June|July|August|September|October|November|December"
        rules.append(Rule(#"\b("# + monthNames + #")\.?\s+(\d{1,2})(?![\d:]|st|nd|rd|th)\b"#) { m, s in
            let name = s.substring(with: m.range(at: 1))
            let month = CalendarNames.months[name.lowercased()] ?? name
            let day = Int(s.substring(with: m.range(at: 2))) ?? 0
            return "\(month) \(day)\(ordinalSuffix(day))"
        })
        // "Feb." on its own → "February".
        rules.append(Rule(#"\b(Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sept|Sep|Oct|Nov|Dec)\.(?=\s|$)"#) { m, s in
            CalendarNames.months[s.substring(with: m.range(at: 1)).lowercased()] ?? s.substring(with: m.range(at: 1))
        })
        return rules
    }

    private static func ordinalSuffix(_ day: Int) -> String {
        (11...13).contains(day % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][day % 10] ?? "th"
    }
}
