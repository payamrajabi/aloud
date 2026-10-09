import Foundation

/// Units after numbers (Core readings, FIN-889; area "units"): the unit tables, slash
/// compounds ("kWh/yr"), coordinates, square and cubic forms, hyphenated modifiers ("a 10-km
/// run"), conditional units (nm, carat, knots, pt, cal, psi, in.) and single letters (m, g,
/// L, V, W, h, s, A). Each hook runs at its own place in the list
/// (`TextNormalizer.makeRules`); a context check that needs words a lexicon mark holds
/// ("65 W USB-C charger") reads them from the rule's `RuleContext`.
enum UnitRules {
    typealias Rule = TextNormalizer.Rule

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
        ("yrs", "year", "years"), ("yr", "year", "years"), ("bn", "billion", "billion"),
        // Recipes: "2 tbsp" was spelled out ("T B S P").
        ("tbsp", "tablespoon", "tablespoons"), ("Tbsp", "tablespoon", "tablespoons"), ("tbs", "tablespoon", "tablespoons"),
        ("tsp", "teaspoon", "teaspoons"), ("qt", "quart", "quarts"), ("gal", "gallon", "gallons"), ("doz", "dozen", "dozen"),
        // Micro units, with μ (U+03BC; the micro sign U+00B5 is folded into it before this runs).
        ("μg", "microgram", "micrograms"), ("mcg", "microgram", "micrograms"), ("μL", "microliter", "microliters"),
        ("μl", "microliter", "microliters"), ("μF", "microfarad", "microfarads"), ("μA", "microamp", "microamps"),
        ("μV", "microvolt", "microvolts"), ("μW", "microwatt", "microwatts"),
        ("kΩ", "kilohm", "kilohms"), ("MΩ", "megohm", "megohms"), ("Ω", "ohm", "ohms"),
    ]

    /// Units the custom lexicon reads anywhere ("in px", "in Mbps"), so it no longer takes them
    /// glued to a number, where "16px" and "100Mbps" lost their number to the G2P model. Read
    /// here only glued ("16px"); with a space ("16 px") the lexicon's reading stands.
    private static let gluedUnits: [(String, String, String)] = [
        ("px", "pixel", "pixels"), ("THz", "terahertz", "terahertz"), ("Tbps", "terabit per second", "terabits per second"),
        ("Gbps", "gigabit per second", "gigabits per second"), ("Mbps", "megabit per second", "megabits per second"),
        ("kbps", "kilobit per second", "kilobits per second"), ("TiB", "tebibyte", "tebibytes"),
        ("GiB", "gibibyte", "gibibytes"), ("MiB", "mebibyte", "mebibytes"), ("KiB", "kibibyte", "kibibytes"),
        ("μs", "microsecond", "microseconds"), ("µs", "microsecond", "microseconds"),
        ("μm", "micrometer", "micrometers"), ("µm", "micrometer", "micrometers"),
        // Written in lower case against the number ("16gb of RAM", "2ghz"), these are units too;
        // the G2P model turned them into a guessed word and the number was lost. Spaced ("500
        // mb") they're left alone: "mb" is also millibars.
        ("tb", "terabyte", "terabytes"), ("gb", "gigabyte", "gigabytes"), ("mb", "megabyte", "megabytes"),
        ("kb", "kilobyte", "kilobytes"), ("Gb", "gigabit", "gigabits"), ("Mb", "megabit", "megabits"),
        ("ghz", "gigahertz", "gigahertz"), ("mhz", "megahertz", "megahertz"), ("khz", "kilohertz", "kilohertz"),
        ("hz", "hertz", "hertz"), ("tn", "trillion", "trillion"),
    ]

    /// Lexicon terms that are also units or clock words. After a number ("16 GB of RAM",
    /// "500 MB", "6:00 AM") the rules above read them ("16 gigabytes"), as they do "16GB",
    /// rather than the lexicon's letters ("G B").
    private static let unitTerms = Set(units.map(\.0)).union(["AM", "PM", "am", "pm", "A.M.", "P.M.", "a.m.", "p.m."])

    /// Whether a term the custom lexicon marked ("GB" in "16 GB") goes back into the text for
    /// the unit rules to read, instead of keeping the lexicon's reading ("G B").
    static func readsMarkedTerm(_ term: String, after plain: String) -> Bool {
        unitTerms.contains(term) && plain.range(of: #"\d\s?$"#, options: .regularExpression) != nil
    }

    /// Slash compounds read with "per" ("300 kWh/yr"): after numeric dates, before ports,
    /// file paths and the area rules.
    static func slashCompounds(british: Bool) -> [Rule] {
        []
    }

    /// Coordinates ("40°42'46\"N"), before Temperatures.
    static func coordinates(british: Bool) -> [Rule] {
        []
    }

    /// m/s², then the square and cubic forms ("50 km²", and "sq ft" to come), before powers.
    static func areaRules(british: Bool) -> [Rule] {
        var rules: [Rule] = []
        // Area and volume: "50 km²" → "50 square kilometers", "9.8 m/s²".
        rules.append(Rule(#"(?<![\p{L}\d.,])(\d+(?:[.,]\d+)*)\s?m/s²(?![\p{L}\d])"#) { m, s in
            "\(s.substring(with: m.range(at: 1))) meters per second squared"
        })
        let areaUnits: [String: (String, String)] = ["km": ("kilometer", "kilometers"), "cm": ("centimeter", "centimeters"),
                                                     "mm": ("millimeter", "millimeters"), "m": ("meter", "meters"),
                                                     "ft": ("foot", "feet"), "in": ("inch", "inches"), "yd": ("yard", "yards"),
                                                     "mi": ("mile", "miles"), "μm": ("micrometer", "micrometers")]
        rules.append(Rule(#"(?<![\p{L}\d.,])(\d+(?:[.,]\d+)*)\s?(km|cm|mm|μm|m|ft|in|yd|mi)([²³])(?![\p{L}\d])"#) { m, s in
            let n = s.substring(with: m.range(at: 1))
            let unit = areaUnits[s.substring(with: m.range(at: 2))]!
            let power = s.substring(with: m.range(at: 3)) == "²" ? "square" : "cubic"
            return "\(n) \(power) \(TextNormalizer.isOne(n) ? unit.0 : unit.1)"
        })
        return rules
    }

    /// Hyphenated modifiers ("a 10-km run") and a vulgar fraction before a unit ("½ tsp"):
    /// after dates' durations and "~", before the unit range rule, `units`, Ranges and the
    /// fraction rules.
    static func modifiers(british: Bool) -> [Rule] {
        []
    }

    /// The conditional units (nm, carat, knots, pt, cal, psi, in.), then `units` and
    /// `gluedUnits`, then the single letters with A last: after the unit range rule, before
    /// ISO dates and Ranges.
    static func unitRules(british: Bool) -> [Rule] {
        var rules: [Rule] = []
        // Units right after a number.
        let alternatives = units.map(\.0).sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern).joined(separator: "|")
        let table = Dictionary(units.map { ($0.0, ($0.1, $0.2)) }, uniquingKeysWith: { a, _ in a })
        rules.append(Rule(#"(?<![\p{L}\d.,])(\d+(?:[.,]\d+)*)\s?("# + alternatives + #")(?![\p{L}\d/])"#) { m, s in
            let n = s.substring(with: m.range(at: 1))
            let words = table[s.substring(with: m.range(at: 2))]!
            // After a fraction it's one: "1/8 tsp" is an eighth of a teaspoon; "1 1/2 tsp" is more.
            let before = s.substring(to: m.range.location)
            if before.range(of: #"(?<![\d/])\d{1,2}/$"#, options: .regularExpression) != nil {
                return "\(n) \(before.range(of: #"\d\s\d{1,2}/$"#, options: .regularExpression) != nil ? words.1 : words.0)"
            }
            return "\(n) \(TextNormalizer.isOne(n) ? words.0 : words.1)"
        })
        let glued = Dictionary(gluedUnits.map { ($0.0, ($0.1, $0.2)) }, uniquingKeysWith: { a, _ in a })
        rules.append(Rule(#"(?<![\p{L}\d.,])(\d+(?:[.,]\d+)*)("# + gluedUnits.map(\.0).sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern).joined(separator: "|") + #")(?![\p{L}\d/])"#) { m, s in
            let n = s.substring(with: m.range(at: 1))
            let words = glued[s.substring(with: m.range(at: 2))]!
            return "\(n) \(TextNormalizer.isOne(n) ? words.0 : words.1)"
        })
        return rules
    }
}
