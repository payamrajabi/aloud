import Foundation

/// Rewrites things misaki reads badly into words it reads well, before phonemizing:
/// units ("10 km" → "10 kilometers"), temperatures ("-5°C" → "-5 degrees Celsius"),
/// clock times ("6:00 am" → "6 A.M.", "10:05" → "10 oh 5"), dates ("Jan 5" →
/// "January 5th"), simple fractions and a few abbreviations. Numbers stay as digits;
/// the lexicon reads those.
enum TextNormalizer {
    private struct Rule {
        let regex: NSRegularExpression
        let replace: (NSTextCheckingResult, NSString) -> String
        init(_ pattern: String, options: NSRegularExpression.Options = [], _ replace: @escaping (NSTextCheckingResult, NSString) -> String) {
            regex = try! NSRegularExpression(pattern: pattern, options: options)
            self.replace = replace
        }
    }

    // (abbreviation, singular, plural), matched case-sensitively right after a number.
    private static let units: [(String, String, String)] = [
        ("km/h", "kilometer per hour", "kilometers per hour"), ("kph", "kilometer per hour", "kilometers per hour"),
        ("kmh", "kilometer per hour", "kilometers per hour"), ("mph", "mile per hour", "miles per hour"),
        ("m/s", "meter per second", "meters per second"),
        ("km", "kilometer", "kilometers"), ("cm", "centimeter", "centimeters"), ("mm", "millimeter", "millimeters"),
        ("kg", "kilogram", "kilograms"), ("mg", "milligram", "milligrams"), ("lbs", "pound", "pounds"), ("lb", "pound", "pounds"),
        ("oz", "ounce", "ounces"), ("ft", "foot", "feet"), ("mi", "mile", "miles"), ("ml", "milliliter", "milliliters"),
        ("mL", "milliliter", "milliliters"), ("TB", "terabyte", "terabytes"), ("GB", "gigabyte", "gigabytes"),
        ("MB", "megabyte", "megabytes"), ("KB", "kilobyte", "kilobytes"), ("kB", "kilobyte", "kilobytes"),
        ("GHz", "gigahertz", "gigahertz"), ("MHz", "megahertz", "megahertz"), ("kHz", "kilohertz", "kilohertz"),
        ("Hz", "hertz", "hertz"), ("kWh", "kilowatt hour", "kilowatt hours"), ("kW", "kilowatt", "kilowatts"),
        ("ms", "millisecond", "milliseconds"), ("secs", "second", "seconds"), ("sec", "second", "seconds"),
        ("mins", "minute", "minutes"), ("min", "minute", "minutes"), ("hrs", "hour", "hours"), ("hr", "hour", "hours"),
    ]

    private static let months = ["jan": "January", "feb": "February", "mar": "March", "apr": "April", "may": "May",
                                 "jun": "June", "jul": "July", "aug": "August", "sep": "September", "sept": "September",
                                 "oct": "October", "nov": "November", "dec": "December"]

    private static let abbreviations: [(String, String)] = [
        ("e.g.", "for example"), ("E.g.", "For example"), ("i.e.", "that is"), ("I.e.", "That is"),
        ("approx.", "approximately"), ("Approx.", "Approximately"), ("incl.", "including"), ("Incl.", "Including"),
        ("Ave.", "Avenue"), ("Blvd.", "Boulevard"), ("Mt.", "Mount"), ("Prof.", "Professor"), ("Gov.", "Governor"),
        ("Sen.", "Senator"), ("Dept.", "Department"), ("dept.", "department"),
    ]

    private static func isOne(_ n: String) -> Bool { n == "1" || n == "-1" }

    private static let rules: [Rule] = {
        var rules: [Rule] = []
        // Temperatures: "-5°C", "72 °F", "30°".
        rules.append(Rule(#"(?<![\p{L}\d])([-−]?\d+(?:\.\d+)?)\s?°\s?([CFcf])?(?![\p{L}])"#) { m, s in
            let n = s.substring(with: m.range(at: 1)).replacingOccurrences(of: "−", with: "-")
            var out = n + (isOne(n) ? " degree" : " degrees")
            if m.range(at: 2).location != NSNotFound {
                out += s.substring(with: m.range(at: 2)).uppercased() == "C" ? " Celsius" : " Fahrenheit"
            }
            return out
        })
        // Units right after a number.
        let alternatives = units.map(\.0).sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern).joined(separator: "|")
        let table = Dictionary(units.map { ($0.0, ($0.1, $0.2)) }, uniquingKeysWith: { a, _ in a })
        rules.append(Rule(#"(?<![\p{L}\d.,])(\d+(?:[.,]\d+)*)\s?("# + alternatives + #")(?![\p{L}\d/])"#) { m, s in
            let n = s.substring(with: m.range(at: 1))
            let words = table[s.substring(with: m.range(at: 2))]!
            return "\(n) \(isOne(n) ? words.0 : words.1)"
        })
        // Clock times: "3:45 pm", "6:00", "10:05 a.m.".
        rules.append(Rule(#"(?<![\d:])(\d{1,2}):(\d{2})(?![\d:])(?:\s?([AaPp])\.?\s?[Mm]\.?(?![\p{L}]))?"#) { m, s in
            let h = s.substring(with: m.range(at: 1)), mm = s.substring(with: m.range(at: 2))
            let ampm = m.range(at: 3).location == NSNotFound ? nil : s.substring(with: m.range(at: 3)).uppercased() + ".M."
            var out = h
            if mm == "00" {
                if ampm == nil { out += (Int(h) ?? 0) > 12 ? " hundred" : " o'clock" }
            } else if mm.hasPrefix("0") {
                out += " oh " + String(mm.dropFirst())
            } else {
                out += " " + mm
            }
            if let ampm { out += " " + ampm }
            return out
        })
        // Ratios: "1:1", "16:9" (a single digit after the colon can't be a clock time).
        rules.append(Rule(#"(?<![\d:])(\d{1,3}):(\d)(?![\d:])"#) { m, s in
            s.substring(with: m.range(at: 1)) + " to " + s.substring(with: m.range(at: 2))
        })
        // "5pm", "5 p.m."
        rules.append(Rule(#"(?<![\d:.,])(\d{1,2})\s?([AaPp])\.?[Mm]\.?(?![\p{L}])"#) { m, s in
            s.substring(with: m.range(at: 1)) + " " + s.substring(with: m.range(at: 2)).uppercased() + ".M."
        })
        // "Jan 5" / "January 5, 2024" → "January 5th".
        let monthNames = "Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sept|Sep|Oct|Nov|Dec|January|February|March|April|June|July|August|September|October|November|December"
        rules.append(Rule(#"\b("# + monthNames + #")\.?\s+(\d{1,2})(?![\d:]|st|nd|rd|th)\b"#) { m, s in
            let name = s.substring(with: m.range(at: 1))
            let month = months[name.lowercased()] ?? name
            let day = Int(s.substring(with: m.range(at: 2))) ?? 0
            let suffix = (11...13).contains(day % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][day % 10] ?? "th"
            return "\(month) \(day)\(suffix)"
        })
        // "Feb." on its own → "February".
        rules.append(Rule(#"\b(Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sept|Sep|Oct|Nov|Dec)\.(?=\s|$)"#) { m, s in
            months[s.substring(with: m.range(at: 1)).lowercased()] ?? s.substring(with: m.range(at: 1))
        })
        // Simple fractions.
        let fractions = ["1/2": "one half", "1/3": "one third", "2/3": "two thirds", "1/4": "one quarter", "3/4": "three quarters"]
        rules.append(Rule(#"(?<![\d/])([123])/([234])(?![\d/])"#) { m, s in
            fractions[s.substring(with: m.range)] ?? s.substring(with: m.range)
        })
        // Abbreviations.
        for (abbr, full) in abbreviations {
            rules.append(Rule("(?<![\\p{L}.])" + NSRegularExpression.escapedPattern(for: abbr) + "(?=\\s|$|[,;:)])") { _, _ in full })
        }
        return rules
    }()

    private static let marked = try! NSRegularExpression(pattern: #"\[[^\]]+\]\(/[^)]*/\)"#)

    /// - Parameter skippingMarkedSpans: leave [text](/phonemes/) spans (pronunciations
    ///   already fixed by the custom lexicon) untouched.
    static func normalize(_ text: String, skippingMarkedSpans: Bool) -> String {
        guard skippingMarkedSpans else { return normalize(text) }
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in marked.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += normalize(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            out += ns.substring(with: m.range)
            last = NSMaxRange(m.range)
        }
        return out + normalize(ns.substring(from: last))
    }

    static func normalize(_ text: String) -> String {
        var s = text
        for rule in rules {
            let ns = s as NSString
            let matches = rule.regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            var out = ""
            var last = 0
            for m in matches {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                out += rule.replace(m, ns)
                last = NSMaxRange(m.range)
            }
            out += ns.substring(from: last)
            s = out
        }
        return s
    }
}
