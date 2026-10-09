import Foundation

/// Units after numbers (Core readings, FIN-889; area "units"): the unit tables, slash compounds
/// ("kWh/yr"), coordinates, square and cubic forms, hyphenated modifiers ("a 10-km run"),
/// fractions before a unit, conditional units (nm, carat, knots, pt, cal, psi, in.) and single
/// letters (m, g, L, V, W, h, s, and A last). Each hook runs at its own place in
/// TextNormalizer's list (`makeRules`). A context check that needs the words a lexicon mark
/// holds ("65 W USB-C charger") reads them through `UnitSpot`, from the rule's `RuleContext`.
/// ft, in. and the inch and foot marks belong to the measures pass; a hyphenated "10-ft" and
/// the inch marks are left to it.
///
/// A unit is said in the singular for one, and before the noun it measures after "a" or "an"
/// ("a 60 W bulb": a sixty watt bulb). Single letters and symbols that are also words or
/// abbreviations (m, A, atm, hp, nm, kt, pt) are read only where their sentence settles it, and
/// otherwise left as written: a miss is safer than a wrong unit.
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
        ("TBSP", "tablespoon", "tablespoons"), ("tbsps", "tablespoon", "tablespoons"), ("tblsp", "tablespoon", "tablespoons"),
        ("tsp", "teaspoon", "teaspoons"), ("tsps", "teaspoon", "teaspoons"), ("qt", "quart", "quarts"), ("qts", "quart", "quarts"),
        ("gal", "gallon", "gallons"), ("doz", "dozen", "dozen"), ("floz", "fluid ounce", "fluid ounces"),
        ("cl", "centiliter", "centiliters"), ("cL", "centiliter", "centiliters"), ("dl", "deciliter", "deciliters"),
        ("dL", "deciliter", "deciliters"), ("pkg", "package", "packages"), ("pkgs", "package", "packages"),
        // Micro units, with μ (U+03BC; the micro sign U+00B5 is folded into it before this runs).
        ("μg", "microgram", "micrograms"), ("mcg", "microgram", "micrograms"), ("μL", "microliter", "microliters"),
        ("μl", "microliter", "microliters"), ("μF", "microfarad", "microfarads"), ("μA", "microamp", "microamps"),
        ("μV", "microvolt", "microvolts"), ("μW", "microwatt", "microwatts"),
        ("kΩ", "kilohm", "kilohms"), ("MΩ", "megohm", "megohms"), ("Ω", "ohm", "ohms"),
        // Mass, length and time. Weeks and months belong here, not to the dates ("Ships in 2 wks").
        ("ng", "nanogram", "nanograms"), ("Gt", "gigaton", "gigatons"), ("yd", "yard", "yards"), ("yds", "yard", "yards"),
        ("nmi", "nautical mile", "nautical miles"), ("nm", "nanometer", "nanometers"), ("ns", "nanosecond", "nanoseconds"),
        ("wk", "week", "weeks"), ("wks", "week", "weeks"), ("mo", "month", "months"), ("mos", "month", "months"),
        ("mth", "month", "months"), ("mths", "month", "months"),
        // Pressure.
        ("hPa", "hectopascal", "hectopascals"), ("kPa", "kilopascal", "kilopascals"), ("MPa", "megapascal", "megapascals"),
        ("GPa", "gigapascal", "gigapascals"), ("Pa", "pascal", "pascals"), ("mbar", "millibar", "millibars"),
        ("atm", "atmosphere", "atmospheres"), ("inHg", "inch of mercury", "inches of mercury"),
        ("mmHg", "millimeter of mercury", "millimeters of mercury"),
        // Energy, power and electricity. Not MJ or GJ: the lexicon reads "megajoules" wrong yet.
        ("mAh", "milliamp hour", "milliamp hours"), ("Ah", "amp hour", "amp hours"), ("Wh", "watt hour", "watt hours"),
        ("MWh", "megawatt hour", "megawatt hours"), ("GWh", "gigawatt hour", "gigawatt hours"),
        ("TWh", "terawatt hour", "terawatt hours"), ("mW", "milliwatt", "milliwatts"), ("MW", "megawatt", "megawatts"),
        ("GW", "gigawatt", "gigawatts"), ("kJ", "kilojoule", "kilojoules"), ("kcal", "kilocalorie", "kilocalories"),
        ("mV", "millivolt", "millivolts"), ("kV", "kilovolt", "kilovolts"), ("mA", "milliamp", "milliamps"),
        ("nF", "nanofarad", "nanofarads"), ("pF", "picofarad", "picofarads"),
        // Force and engines.
        ("Nm", "newton meter", "newton meters"), ("lbft", "pound foot", "pound feet"), ("kN", "kilonewton", "kilonewtons"),
        ("hp", "horsepower", "horsepower"),
        // Sound, light, fuel, speed and concentration.
        ("dB", "decibel", "decibels"), ("lm", "lumen", "lumens"), ("lx", "lux", "lux"),
        ("mpg", "mile per gallon", "miles per gallon"), ("MPG", "mile per gallon", "miles per gallon"),
        ("kts", "knot", "knots"), ("kn", "knot", "knots"),
        ("ppm", "part per million", "parts per million"), ("ppb", "part per billion", "parts per billion"),
    ]

    /// Units written with a space, hyphen or dot inside ("fl. oz", "lb-ft", "N·m", "m.p.h"), as
    /// patterns. A match is looked up without those (`key`): "floz", "lbft", "Nm", "mph".
    private static let spelledUnits = [#"fl\.?\s?oz"#, #"lb[\s-]ft"#, #"N·m"#, #"m\.p\.h"#]

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

    /// Single letters, read by their own rules (and in hyphenated modifiers and slash compounds).
    private static let letters: [String: (String, String)] = [
        "m": ("meter", "meters"), "g": ("gram", "grams"), "L": ("liter", "liters"), "l": ("liter", "liters"),
        "V": ("volt", "volts"), "W": ("watt", "watts"), "h": ("hour", "hours"), "s": ("second", "seconds"),
    ]

    private static let table = Dictionary(units.map { ($0.0, ($0.1, $0.2)) }, uniquingKeysWith: { a, _ in a })
    private static let gluedTable = Dictionary(gluedUnits.map { ($0.0, ($0.1, $0.2)) }, uniquingKeysWith: { a, _ in a })

    /// A unit as written → its key in `table`: "fl. oz" → "floz", "lb-ft" → "lbft", "N·m" → "Nm".
    private static func key(_ written: String) -> String {
        table[written] != nil ? written : written.filter { !".-·".contains($0) && !$0.isWhitespace }
    }

    /// `symbols` as one alternation, longest first (the regex takes the first that fits).
    private static func alternation(_ symbols: [String]) -> String {
        symbols.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern).joined(separator: "|")
    }

    /// The table's units, the spelled forms first.
    private static let unitPattern = (spelledUnits + [alternation(units.map(\.0))]).joined(separator: "|")

    /// After the unit: an abbreviation's period that isn't the full stop ("2 tbsp. of oil", "3
    /// lbs., then"), which goes with it; then not a word, a digit, "&" ("PB&J") or a "/word" left
    /// for the slash rule.
    private static let unitEnd = #"(\.(?=\s+\p{Ll}|,))?(?![\p{L}\d&]|/\p{L})"#

    // MARK: Lexicon marks

    /// Clock words the lexicon marks ("6:00 AM"), read by the meridiem rules.
    private static let clockTerms: Set<String> = ["AM", "PM", "am", "pm", "A.M.", "P.M.", "a.m.", "p.m."]

    /// Whether a term the custom lexicon marked ("GB" in "16 GB") goes back into the text for the
    /// rules to read, instead of keeping the lexicon's reading ("G B"). Asked by
    /// `TextNormalizer.normalize(_:skippingMarkedSpans:british:)` for each mark, with the plain
    /// text before it. Only a term a unit rule will then read: a unit in the table right after a
    /// number ("16 GB", "300 kWh/yr", "a 95-dB mower"), which the table, slash and modifier rules
    /// read whatever follows; a clock word after one; and the "FT" of "3,000 SQ FT". Unwrapped
    /// and left unread, "300 kWh/yr" was "three hundred kwer". PB stays the lexicon's ("2
    /// PB&J"), and so do KT and the other letters (ATM, HP) the table has only in lower case.
    ///
    /// Also "bp" after a number ("cut rates by 25 bp": basis points, not "B P"), and a lower-case
    /// "5g" the lexicon took for the network, after a nutrient or before "of" or "per" ("Sugar 5g
    /// per bar", "5g of protein"), for the gram rule to read.
    static func readsMarkedTerm(_ term: String, after plain: String, followedBy rest: @autoclosure () -> String = "") -> Bool {
        if clockTerms.contains(term) { return endsInNumber(plain, hyphen: false) }
        if table[term] != nil { return endsInNumber(plain, hyphen: true) }
        if term == "bp" { return endsInNumber(plain, hyphen: false) }
        if term.utf16.count == 2, term.hasSuffix("g"), let n = term.first?.wholeNumberValue, (2...6).contains(n) {
            if let last = plain.unicodeScalars.last, Scalars.isLetter(last) || Scalars.isDigit(last) { return false }
            let word = plain.reversed().drop { $0 == " " || $0 == "\t" }.prefix { $0.isLetter }
            return UnitWords.nutrients.contains(String(word.reversed()).lowercased()) || matches(gramsAhead, rest())
        }
        if term == "FT" {
            let ns = plain as NSString
            let start = max(0, ns.length - 24)
            return areaWordBefore.firstMatch(in: plain, range: NSRange(location: start, length: ns.length - start)) != nil
        }
        return false
    }

    private static let areaWordBefore = try! NSRegularExpression(pattern: #"\d\s?(?i:sq|cu)\.?\s?$"#)
    private static let gramsAhead = try! NSRegularExpression(pattern: #"^[ \t]+(?:of|per)(?![\p{L}])"#)

    /// Whether `plain` ends with a number of its own ("16", "1.5", "2,000"; not the tail of "A16"
    /// or "x86", which no unit rule reads), then at most a space, or a hyphen when `hyphen`.
    private static func endsInNumber(_ plain: String, hyphen: Bool) -> Bool {
        let s = plain.unicodeScalars
        var i = s.endIndex
        guard i > s.startIndex else { return false }
        let last = s[s.index(before: i)]
        if (Scalars.isSpace(last) && last != "\n") || (hyphen && last == "-") { i = s.index(before: i) }
        guard i > s.startIndex, Scalars.isDigit(s[s.index(before: i)]) else { return false }
        while i > s.startIndex {
            let j = s.index(before: i)
            if Scalars.isDigit(s[j]) { i = j; continue }
            if s[j] == "." || s[j] == ",", j > s.startIndex, Scalars.isDigit(s[s.index(before: j)]) { i = j; continue }
            return !Scalars.isLetter(s[j])
        }
        return true
    }

    // MARK: Slash compounds

    /// What a unit before a slash is called: the tables, plus single letters and moles.
    private static let numerators: [String: (String, String)] = {
        var all = gluedTable
        for (k, v) in table where !k.contains("/") { all[k] = v }
        for (k, v) in letters where k != "h" && k != "s" { all[k] = v }
        // Points of a score or an estimate: "40 pts/sprint" (pt alone is also a pint).
        all["pts"] = ("point", "points")
        all["mmol"] = ("millimole", "millimoles")
        all["mol"] = ("mole", "moles")
        all["μmol"] = ("micromole", "micromoles")
        return all
    }()

    /// What a unit after a slash is called, in the singular ("per kilogram").
    private static let denominators: [String: String] = [
        "s": "second", "sec": "second", "s²": "second squared", "min": "minute", "h": "hour", "hr": "hour", "d": "day",
        "day": "day", "wk": "week", "mo": "month", "yr": "year", "g": "gram", "kg": "kilogram", "mg": "milligram",
        "L": "liter", "l": "liter", "mL": "milliliter", "ml": "milliliter", "dL": "deciliter", "dl": "deciliter",
        "m": "meter", "km": "kilometer", "cm": "centimeter", "mi": "mile", "ft": "foot", "gal": "gallon",
        "m²": "square meter", "m³": "cubic meter", "cm³": "cubic centimeter", "kWh": "kilowatt hour", "serving": "serving",
    ]

    /// Slash compounds read with "per" ("300 kWh/yr", "mg/kg/day"): after dates' numeric dates,
    /// before ports, file paths, the area rules and `units`.
    static func slashCompounds(british: Bool) -> [Rule] {
        var rules: [Rule] = []
        // Fuel use: "6.5 L/100km" → "6.5 liters per hundred kilometers".
        rules.append(Rule.withContext(#"(?<![\p{L}\d.,/$£€¥₹₩])(\d+(?:[.,]\d+)*)\s?[Ll]/100\s?km(?![\p{L}\d/])"#) { m, s, context in
            let spot = UnitSpot(m, number: 1, in: s, context)
            return "\(spot.number) \(spot.singular ? "liter" : "liters") per hundred kilometers"
        })
        // A rate per a short unit of time after a number or "%": "1.5% per mo.", "churn
        // 1.8%/mo" → "per month". Before file paths, which took "/mo" for one.
        rules.append(Rule(#"(?<=[\d%])(?:[ \t]+per[ \t]+|[ \t]?/[ \t]?)(mos|mo|mths|mth|yrs|yr|wks|wk|hrs|hr|mins|min|secs|sec)(\.(?=[ \t]+\p{Ll}|,))?(?![\p{L}\d/])"#) { m, s in
            " per " + rateUnits[s.substring(with: m.range(at: 1))]!
        })
        // A runner's pace: "7:30/mi" → "7:30 per mile" (the clock rule reads the time).
        rules.append(Rule(#"(?<![\d:.])(\d{1,2}:[0-5]\d)[ \t]?/[ \t]?(mi|mile|km|k)(?![\p{L}\d/])"#) { m, s in
            s.substring(with: m.range(at: 1)) + " per " + (s.substring(with: m.range(at: 2)).hasPrefix("m") ? "mile" : "kilometer")
        })
        // A unit, then one or more "/unit" from the table ("5.5 mmol/L", "7GB/s", "7.8 g/cm³") or a
        // plain word ("20 ms/frame"): "5 milligrams per kilogram per day". The lexicon's "7 GB/s"
        // already reads so; glued, or after a unit it has no entry for, the slash was lost or read
        // as letters ("five m S", "G B S"). km/h and m/s keep the table's reading, and m/s² the
        // area rule's.
        let numerator = alternation(Array(numerators.keys))
        let denominator = alternation(Array(denominators.keys)) + #"|\p{Ll}{3,}"#
        rules.append(Rule.withContext(#"(?<![\p{L}\d.,/$£€¥₹₩])(\d+(?:[.,]\d+)*)\s?("# + numerator + #")((?:/(?:"# + denominator + #"))+)(?![\p{L}\d/²³])"#) { m, s, context in
            let whole = s.substring(with: m.range)
            let unit = s.substring(with: m.range(at: 2)), rest = s.substring(with: m.range(at: 3))
            if ["m/s", "km/h", "m/s²"].contains(unit + rest) { return whole }
            var per: [String] = []
            for part in rest.split(separator: "/").map(String.init) {
                if let word = denominators[part] {
                    per.append(word)
                } else if table[part] == nil, gluedTable[part] == nil, numerators[part] == nil {
                    per.append(part)   // "frame", "dose", "person": a plain word
                } else {
                    return whole       // "kg/lbs": a choice of units, not a rate
                }
            }
            guard let words = numerators[unit] else { return whole }
            let spot = UnitSpot(m, number: 1, in: s, context)
            return "\(spot.number) \(spot.singular ? words.0 : words.1) per " + per.joined(separator: " per ")
        })
        return rules
    }

    // MARK: Coordinates

    private static let compass = ["N": "north", "S": "south", "E": "east", "W": "west"]

    /// Coordinates ("40°42'46\"N", "45°30′N", "51.5° N"): after shorthand's "a 45° angle", before
    /// Temperatures, which took the degrees and left the letter ("forty-five N", "zero point one
    /// degrees double-u"), and before the inch marks took "42'46\"" as a height. The numbers stay
    /// digits; each unit is singular only for exactly 1.
    static func coordinates(british: Bool) -> [Rule] {
        [Rule(#"(?<![\p{L}\d.])(\d{1,3}(?:\.\d+)?)\s?°\s?(?:(\d{1,2}(?:\.\d+)?)\s?[′'’]\s?(?:(\d{1,2}(?:\.\d+)?)\s?(?:″|"|”|′′|'')\s?)?)?([NSEW])(?![\p{L}\d])"#) { m, s in
            func part(_ group: Int, _ one: String, _ many: String) -> String? {
                guard m.range(at: group).location != NSNotFound else { return nil }
                let n = s.substring(with: m.range(at: group))
                return "\(n) \(TextNormalizer.isOne(n) ? one : many)"
            }
            let direction = compass[s.substring(with: m.range(at: 4))]!
            return [part(1, "degree", "degrees"), part(2, "minute", "minutes"), part(3, "second", "seconds"), direction]
                .compactMap { $0 }.joined(separator: " ")
        }]
    }

    // MARK: Square and cubic

    private static let areaUnits: [String: (String, String)] = [
        "km": ("kilometer", "kilometers"), "cm": ("centimeter", "centimeters"), "mm": ("millimeter", "millimeters"),
        "m": ("meter", "meters"), "ft": ("foot", "feet"), "in": ("inch", "inches"), "yd": ("yard", "yards"),
        "mi": ("mile", "miles"), "μm": ("micrometer", "micrometers"),
    ]

    /// m/s², then the square and cubic forms: the word forms ("800 sq ft", "20 cu ft"), "m^2",
    /// "50 km²" and a lower-case "85 m2", before the other powers.
    static func areaRules(british: Bool) -> [Rule] {
        var rules: [Rule] = []
        // Area and volume: "50 km²" → "50 square kilometers", "9.8 m/s²".
        rules.append(Rule(#"(?<![\p{L}\d.,])(\d+(?:[.,]\d+)*)\s?m/s²(?![\p{L}\d])"#) { m, s in
            "\(s.substring(with: m.range(at: 1))) meters per second squared"
        })
        func area(_ m: NSTextCheckingResult, _ s: NSString, _ context: RuleContext, unit: String, cubic: Bool) -> String {
            let spot = UnitSpot(m, number: 1, in: s, context)
            let words = areaUnits[unit]!
            return "\(spot.number) \(cubic ? "cubic" : "square") \(spot.singular ? words.0 : words.1)"
        }
        // The word forms: "800 sq ft", "2,000 sq. ft. of space", "3,000 Sq Ft", "500 sqm", "20 cu ft"
        // (they read "S Q ft" and "cue ft"). "cu" needs its space or period ("5 cum" isn't one).
        // The last period goes only before a lower-case word or a comma; elsewhere it's the full stop.
        rules.append(Rule.withContext(#"(?<![\p{L}\d.,])(\d+(?:[.,]\d+)*)\s?(?:((?i:sq))(?:\.\s?|\s?)|((?i:cu))(?:\.\s?|\s))((?i:ft|km|mi|in|yd|m))(\.(?=\s+\p{Ll}|,))?(?![\p{L}\d²³])"#) { m, s, context in
            area(m, s, context, unit: s.substring(with: m.range(at: 4)).lowercased(), cubic: m.range(at: 3).location != NSNotFound)
        })
        // "10 m^2", "3 ft^3".
        rules.append(Rule.withContext(#"(?<![\p{L}\d.,])(\d+(?:[.,]\d+)*)\s?(km|cm|mm|μm|m|ft|in|yd|mi)\^([23])(?!\d)"#) { m, s, context in
            area(m, s, context, unit: s.substring(with: m.range(at: 2)), cubic: s.substring(with: m.range(at: 3)) == "3")
        })
        // "50 km²", and "12 ft.²" with the abbreviation's period.
        rules.append(Rule.withContext(#"(?<![\p{L}\d.,])(\d+(?:[.,]\d+)*)\s?(km|cm|mm|μm|m|ft|in|yd|mi)(?:(?<=ft|in)\.)?([²³])(?![\p{L}\d])"#) { m, s, context in
            area(m, s, context, unit: s.substring(with: m.range(at: 2)), cubic: s.substring(with: m.range(at: 3)) == "³")
        })
        // A lower-case "m2"/"m3", as European listings write it ("The flat is 85 m2."): only at an
        // end or before a word for a place or "of"/"per", and never near M.2 drives ("2 m2 slots").
        rules.append(Rule.withContext(#"(?<![\p{L}\d.,])(\d+(?:[.,]\d+)*)\s?m([23])(?![\p{L}\d])"#) { m, s, context in
            let spot = UnitSpot(m, number: 1, in: s, context)
            let next = spot.after.first
            let ends = next == nil || ".,;:!?)".contains(next!) || spot.after.allSatisfy(\.isWhitespace)
            guard ends || spot.nextWord.map({ UnitWords.areaNouns.contains($0) }) == true,
                  spot.written.isDisjoint(with: UnitWords.driveWords) else { return s.substring(with: m.range) }
            return area(m, s, context, unit: "m", cubic: s.substring(with: m.range(at: 2)) == "3")
        })
        return rules
    }

    // MARK: Units after numbers

    /// The symbols a hyphenated modifier can have ("a 10-km run", "a 60-W bulb"): the table's,
    /// but not ft (the measures pass reads "a 10-ft pole"), and the letters but A and s.
    private static let modifierPattern = alternation(units.map(\.0).filter { $0 != "ft" && $0 != "floz" && $0 != "lbft" }
        + ["m", "g", "L", "V", "W", "h"])

    /// After dates' durations and shorthand's "~", before dates' calendar rules and Ranges, in
    /// this order: hyphenated number-unit modifiers ("a 10-km run"), a fraction before a unit
    /// ("½ tsp"), the range with a unit on both numbers, the conditional units (nm, carat and
    /// knots, pt, cal, psi, in.), `units` and `gluedUnits`, then the single letters, A last.
    static func unitRules(british: Bool) -> [Rule] {
        var rules: [Rule] = []
        // Ages: "Our 3-yr-old" → "Our 3 year old", "6-mo-olds".
        let ages = ["yr": "year", "yrs": "year", "mo": "month", "mos": "month", "mth": "month", "mths": "month",
                    "wk": "week", "wks": "week"]
        rules.append(Rule(#"(?<![\p{L}\d.,/\-–])(\d+)-(yrs?|mos?|mths?|wks?)-(olds?)(?![\p{L}\d])"#) { m, s in
            "\(s.substring(with: m.range(at: 1))) \(ages[s.substring(with: m.range(at: 2))]!) \(s.substring(with: m.range(at: 3)))"
        })
        // A blood pressure: "128/82 mmHg", and in a sentence about blood pressure "BP 120/80" →
        // "1 28 over 82", as a nurse says it.
        rules.append(Rule.withContext(#"(?<![\d/.,])(\d{2,3})/(\d{2,3})(?![\d/]|[.,]\d)([ \t]?mm[ \t]?Hg(?![\p{L}]))?"#) { m, s, context in
            let whole = s.substring(with: m.range)
            let unit = m.range(at: 3).location != NSNotFound
            guard unit || matches(bloodPressure, context.sentence(around: m.range, in: s)) else { return whole }
            let top = s.substring(with: m.range(at: 1))
            let said = top.count == 3 && !top.hasSuffix("00") ? String(top.prefix(1)) + " " + top.dropFirst() : top
            return said + " over " + s.substring(with: m.range(at: 2)) + (unit ? " millimeters of mercury" : "")
        })
        // Ages: "My 5 yo", "a 5 y/o" → "5 year old".
        rules.append(Rule(#"(?<![\p{L}\d.,/])(\d+)[ \t]?(?:yo|y/o|y\.o\.)(?![\p{L}\d/])"#) { m, s in
            s.substring(with: m.range(at: 1)) + " year old"
        })
        // A minute of a match: "in the 90th min" → "90th minute".
        rules.append(Rule(#"(?<![\p{L}\d.,])(\d+(?:st|nd|rd|th))[ \t]mins?\.?(?![\p{L}\d])"#) { m, s in
            s.substring(with: m.range(at: 1)) + " minute"
        })
        // Hyphenated modifiers: "a 10-km run" → "a 10 kilometer run", "a 5-lb bag", "a 12-hr shift"
        // (they lost their number: "ten kay kay em run"). Before a noun the unit is singular, and
        // an abbreviation's period goes with it ("a 5-lb. bag"). Not before one, only a word the
        // table reads ("It was 95-dB."); a letter stays ("W-2" is never matched: the number
        // comes first).
        rules.append(Rule.withContext(#"(?<![\p{L}\d.,/\-–])(\d+(?:[.,]\d+)?)-("# + modifierPattern + #")(\.(?=\s+\p{Ll}))?(?![\p{L}\d])"#) { m, s, context in
            let whole = s.substring(with: m.range)
            let symbol = s.substring(with: m.range(at: 2))
            let letter = letters[symbol]
            guard let words = letter ?? table[symbol] else { return whole }
            let spot = UnitSpot(m, number: 1, in: s, context)
            if skips(symbol, spot) || (letter != nil && spot.afterLabel) { return whole }
            if spot.nextWord?.first?.isLowercase == true { return "\(spot.number) \(words.0)" }
            // Coordinated with the next modifier: "a 5-yr, $200M extension".
            if spot.after.hasPrefix(","), ["a", "an", "the"].contains(spot.wordBefore?.lowercased() ?? "") { return "\(spot.number) \(words.0)" }
            return letter != nil ? whole : "\(spot.number) \(spot.singular ? words.0 : words.1)"
        })
        // Half a unit: "½ tsp" and "1/2 lb" → "half a teaspoon", "half a pound" (it was "one half
        // pound", and "one half T S P").
        rules.append(Rule(#"(?<![\d.,/\-])(?<!\d\s)1/2\s?("# + unitPattern + #")"# + unitEnd) { m, s in
            half(table[key(s.substring(with: m.range(at: 1)))]!.0)
        })
        // A vulgar fraction before a unit: "1½ tsp" → "1 and a half teaspoons"; "¼ tsp" → "one
        // quarter teaspoon", as "¼ cup" reads; after "a" it's "a quarter pound burger".
        rules.append(Rule.withContext(#"(?<![\d.,/])(?:(\d+)\s?)?("# + vulgarClass + #")\s?("# + unitPattern + #")"# + unitEnd) { m, s, context in
            let words = table[key(s.substring(with: m.range(at: 3)))]!
            let fraction = vulgarFractions[Character(s.substring(with: m.range(at: 2)))]!
            guard m.range(at: 1).location != NSNotFound else {
                let article = ["a", "an"].contains(UnitSpot(m, number: 2, in: s, context).wordBefore?.lowercased() ?? "")
                if article, fraction.1.hasPrefix("a ") || fraction.1.hasPrefix("an ") {
                    return String(fraction.1.drop { $0 != " " }.dropFirst()) + " " + words.0
                }
                return fraction.0 == "one half" ? half(words.0) : "\(fraction.0) \(words.0)"
            }
            return "\(s.substring(with: m.range(at: 1))) and \(fraction.1) \(words.1)"
        })
        // A range written with its unit on both numbers: "5.25%-5.5%", "0.5mm-1.5mm", "1.5x-2.5x"
        // → "5.25% to 5.5%". The second number lost its decimal point and the "to".
        // (The custom lexicon may have put a space before a unit it knows: "0.5 mm-1.5 mm".)
        rules.append(Rule(#"(?<![\p{L}\d\-–−+./:#)])(\d+(?:[.,]\d+)*)(\s?)(%|[xX×]|[a-zA-Zμ]{1,4})\s?[-–]\s?(\d+(?:[.,]\d+)*)\2\3(?![\p{L}\d])"#) { m, s in
            let unit = s.substring(with: m.range(at: 2)) + s.substring(with: m.range(at: 3))
            return "\(s.substring(with: m.range(at: 1)))\(unit) to \(s.substring(with: m.range(at: 4)))\(unit)"
        })
        rules += conditionalUnits
        // Units right after a number.
        rules.append(Rule.withContext(#"(?<![\p{L}\d.,])(\d+(?:[.,]\d+)*)\s?("# + unitPattern + #")"# + unitEnd) { m, s, context in
            let whole = s.substring(with: m.range)
            let symbol = key(s.substring(with: m.range(at: 2)))
            guard let words = table[symbol] else { return whole }
            let spot = UnitSpot(m, number: 1, in: s, context)
            if skips(symbol, spot) { return whole }
            // After a fraction it's one: "1/8 tsp" is an eighth of a teaspoon; "1 1/2 tsp" is more.
            if let mixed = fractionBefore(spot.before) { return "\(spot.number) \(mixed ? words.1 : words.0)" }
            return "\(spot.number) \(spot.singular(unit: symbol) ? words.0 : words.1)"
        })
        rules.append(Rule.withContext(#"(?<![\p{L}\d.,])(\d+(?:[.,]\d+)*)("# + alternation(gluedUnits.map(\.0)) + #")(?![\p{L}\d/])"#) { m, s, context in
            let symbol = s.substring(with: m.range(at: 2))
            let words = gluedTable[symbol]!
            let spot = UnitSpot(m, number: 1, in: s, context)
            return "\(spot.number) \(spot.singular(unit: symbol) ? words.0 : words.1)"
        })
        rules += letterUnits
        // A compass point after a distance: "30 km SW of the capital" → "30 kilometers southwest
        // of", "20 mi NE of Anchorage". Spelled out, the letters were "S W".
        rules.append(Rule(#"(?<=\d[ \t](?:kilometers|kilometer|miles|mile|meters|meter|feet|foot|yards|yard|km|mi))[ \t]+(NNE|ENE|ESE|SSE|SSW|WSW|WNW|NNW|NE|NW|SE|SW|N|S|E|W)(?=[ \t]+of(?![\p{L}]))"#) { m, s in
            " " + s.substring(with: m.range(at: 1)).map { compassWords[$0]! }.joined(separator: " ")
                .replacingOccurrences(of: "north east", with: "northeast").replacingOccurrences(of: "north west", with: "northwest")
                .replacingOccurrences(of: "south east", with: "southeast").replacingOccurrences(of: "south west", with: "southwest")
        })
        return rules
    }

    private static let compassWords: [Character: String] = ["N": "north", "S": "south", "E": "east", "W": "west"]

    /// Whether an m, M or B with nothing counted after it is millions or billions: a decimal for
    /// m; in a sentence about money or people ("The UK's population hit 68.3m"), or, for m and
    /// M, beside another count in millions ("Labour won 9.7m votes, Reform 4.1m").
    private static func countsBare(_ letter: String, _ spot: UnitSpot) -> Bool {
        if letter == "m", !spot.number.contains(".") { return false }
        if spot.has(UnitWords.moneyWords) || spot.hasStem(["invest"]) { return true }
        return letter != "B" && matches(countInMillions, spot.sentence)
    }

    /// Another count in millions in the sentence: "9.7m votes", "3 million users".
    private static let countInMillions = try! NSRegularExpression(pattern:
        #"(?<![\p{L}\d.,])\d+(?:[.,]\d+)?[ \t]?[mM][ \t]+(?i:"# + alternation(Array(UnitWords.countNouns.union(UnitWords.irregularPlurals)))
            + #")(?![\p{L}])|(?<![\p{L}])millions?(?![\p{L}])"#)

    /// "half a teaspoon", "half an ounce", "half an hour".
    private static func half(_ unit: String) -> String {
        "half " + ("aeio".contains(unit.first!) || unit.hasPrefix("hour") ? "an " : "a ") + unit
    }

    /// Vulgar fractions on their own and after a whole number, as TextNormalizer reads them.
    private static let vulgarFractions = TextNormalizer.vulgarFractions
    private static let vulgarClass = "[" + String(TextNormalizer.vulgarFractions.keys) + "]"

    private static let fractionEnd = try! NSRegularExpression(pattern: #"(?<![\d/])(?:(\d\s)?)\d{1,2}/$"#)

    /// Whether the number follows a fraction's slash ("1/8 tsp": nil if not), and if so whether
    /// the fraction is mixed ("1 1/2 tsp": true), so the unit is plural.
    private static func fractionBefore(_ before: String) -> Bool? {
        let ns = before as NSString
        let start = max(0, ns.length - 8)
        guard let m = fractionEnd.firstMatch(in: before, options: .withTransparentBounds, range: NSRange(location: start, length: ns.length - start))
        else { return nil }
        return m.range(at: 1).location != NSNotFound
    }

    /// Table units that are also words or other abbreviations, left as written where their
    /// sentence says so.
    private static func skips(_ symbol: String, _ spot: UnitSpot) -> Bool {
        switch symbol {
        case "hp": return spot.has(UnitWords.gameWords)                           // "heals 50 hp"
        case "atm": return !spot.has(UnitWords.pressureWords)                     // "only 2 atm"
        case "kn": return !spot.has(UnitWords.windWords) && !spot.has(UnitWords.seaWords)  // kuna
        case "MW": return spot.written.contains("AM") || spot.written.contains("FM") || spot.has(UnitWords.radioWords)
        case "ppm": return spot.has(UnitWords.printWords) || spot.hasStem(["print", "scan"])
        case "mo", "mos", "mth", "mths":
            // "Give me 1 mo, I'm on the phone": a moment.
            return spot.number == "1" && matches(momentEnd, spot.after)
        // "650 TB deaths", "4,800 TB cases": tuberculosis, not terabytes.
        case "TB": return spot.nextWord.map { UnitWords.diseaseNouns.contains($0.lowercased()) } == true || spot.has(UnitWords.diseaseWords)
        // "3 gal pals": a friend, not a gallon.
        case "gal": return spot.nextWord.map { UnitWords.galNouns.contains($0.lowercased()) } == true
        default: return false
        }
    }

    /// "2 m behind schedule", "2 m ahead of plan": a reader's "M" (months, or millions), never meters.
    private static let behindSchedule = try! NSRegularExpression(pattern: #"^\s+(?:behind|ahead)\s+(?:of\s+)?(?:schedule|on|plan|target|budget|in)(?![\p{L}])"#)
    /// A drink within three words after a pint, past its period ("1 pt. heavy cream").
    private static let drinkAhead = try! NSRegularExpression(pattern: #"^\.?\s+(?:\p{L}+\s+){0,2}(?:milk|cream|water|beer|ale|lager|stout|cider|stock|broth|juice|wine)(?![\p{L}])"#, options: .caseInsensitive)
    /// Pounds after a weight in stone: "12 st 4 lb".
    private static let poundsAhead = try! NSRegularExpression(pattern: #"^\s+\d+\s?(?:lb|lbs|pounds?)(?![\p{L}])"#)
    /// Another temperature written without its sign in the sentence: "-40F", "40.3C".
    private static let markedTemperature = try! NSRegularExpression(pattern: #"(?:[-−]\d+|\d+\.\d+)[CF](?![\p{L}\d])"#)
    /// The word after the next one: "10K paying teams".
    private static let secondWord = try! NSRegularExpression(pattern: #"^\h+\p{L}+\h+(\p{L}+)"#)
    /// "blood pressure" or "BP" in a sentence with a reading in it.
    private static let bloodPressure = try! NSRegularExpression(pattern: #"(?i:blood\s+pressure)|\bBP\b"#)
    /// A short unit of time after "per" or a slash, said in full.
    private static let rateUnits = ["mos": "month", "mo": "month", "mths": "month", "mth": "month", "yrs": "year", "yr": "year",
                                    "wks": "week", "wk": "week", "hrs": "hour", "hr": "hour", "mins": "minute", "min": "minute",
                                    "secs": "second", "sec": "second"]

    private static func firstMatch(_ regex: NSRegularExpression, _ text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static let momentEnd = try! NSRegularExpression(pattern: #"^\s*(?:[,!]|[.?]?\s*$)"#)

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    // MARK: Conditional units and single letters

    /// A number a unit can follow: not inside a word, a version or a price ("v1.2", "$15K").
    private static let number = #"(?<![\p{L}\d.,$£€¥₹₩])(\d+(?:[.,]\d+)*)"#

    private static let gemAfter = try! NSRegularExpression(pattern:
        #"^\s+(?:(?:white|yellow|rose|solid|pure)\s+)?(?:gold|platinum|diamonds?|ruby|rubies|sapphires?|emeralds?|gems?|gemstones?|stones?|solitaire|rings?|band|chain|necklace|bracelet|earrings|pendant)(?![\p{L}])"#)
    private static let goldNumbers: Set<String> = ["9", "10", "12", "14", "18", "22", "24"]
    private static let inchesAfter = try! NSRegularExpression(pattern: #"^(?:[ \t]+\p{Ll}|\s*[x×\d,;)])"#)
    private static let fontBefore = try! NSRegularExpression(pattern: #"(?i)(?<![\p{L}])(?:font|type)(?![\p{L}])"#)

    /// Units that need their next word or their sentence to be read at all, before `units`:
    /// nm near the sea, carats and knots, pt, cal, psi and "in.".
    private static let conditionalUnits: [Rule] = {
        var rules: [Rule] = []
        // nm near the sea or in the air is nautical miles ("12 nm offshore"); elsewhere `units`
        // reads nanometers ("a 3 nm process"), where it was "twelve nanometers offshore".
        rules.append(Rule.withContext(number + #"\s?nm(?![\p{L}\d&/])"#) { m, s, context in
            let spot = UnitSpot(m, number: 1, in: s, context)
            guard spot.has(UnitWords.seaWords) else { return s.substring(with: m.range) }
            return "\(spot.number) \(spot.singular ? "nautical mile" : "nautical miles")"
        })
        // ct is a count ("60 ct.", "a 48 ct pack", "120 ct. bottle"), or carats before a gem or
        // gold ("1 ct diamond"). Read as letters, the lexicon made it "court".
        rules.append(Rule.withContext(number + #"\s?ct(\.(?=\s+\p{Ll}))?(?![\p{L}\d'’&*+\-/])"#) { m, s, context in
            let spot = UnitSpot(m, number: 1, in: s, context)
            return spot.number + (matches(gemAfter, spot.after) ? " carat" : " count")
        })
        // st is stone where the sentence is about weight ("He weighs 12 st 4 lb", "Lost 2 st",
        // "He weighed 18st"), or before pounds. Never "21st" (an ordinal), and elsewhere it was
        // "street".
        rules.append(Rule.withContext(number + #"(\s?)st(?![\p{L}\d'’&/]|\.[\p{L}\d])"#) { m, s, context in
            let whole = s.substring(with: m.range)
            let spot = UnitSpot(m, number: 1, in: s, context)
            if m.range(at: 2).length == 0, let n = Int(spot.number), n % 10 == 1, n % 100 != 11 { return whole }
            guard spot.has(UnitWords.weightWords) || matches(poundsAhead, spot.after) else { return whole }
            return spot.number + " stone"
        })
        // ha is hectares in a sentence about land ("12,000 acres (4,856 ha)"); elsewhere it laughs.
        rules.append(Rule.withContext(number + #"\s?ha(?![\p{L}\d'’&/]|\.\p{L})"#) { m, s, context in
            let spot = UnitSpot(m, number: 1, in: s, context)
            guard spot.has(UnitWords.landWords) || spot.nextWord == "of" else { return s.substring(with: m.range) }
            return "\(spot.number) \(spot.singular ? "hectare" : "hectares")"
        })
        // A temperature without its degree sign: "40.3C", "-40F", "It's 72 F and sunny". The
        // letter is also a seat, a flat or a grade ("Seat 14C", "Room 4C", "4C hair"), so only
        // with a minus or a decimal, or in a sentence about the weather or heat, or beside another
        // temperature ("100F in Dallas and -40F in Fairbanks"); never after a label.
        rules.append(Rule.withContext(#"(?<![\p{L}\d.,/$£€¥₹₩])([-−]?)(\d+(?:\.\d+)?)([ \t]?)([CF])(?![\p{L}\d'’&*+\-/°]|\.\p{L})"#) { m, s, context in
            let whole = s.substring(with: m.range)
            let spot = UnitSpot(m, number: 2, in: s, context)
            if spot.afterLabel { return whole }
            let signed = m.range(at: 1).length > 0
            let glued = m.range(at: 3).length == 0
            var temperature = spot.has(UnitWords.temperatureWords)
            if !temperature, glued {
                temperature = signed || spot.number.contains(".") || matches(markedTemperature, spot.sentence)
            }
            guard temperature else { return whole }
            let scale = s.substring(with: m.range(at: 4)) == "C" ? "Celsius" : "Fahrenheit"
            return (signed ? "-" : "") + spot.number + (TextNormalizer.isOne(spot.number) ? " degree " : " degrees ") + scale
        })
        // Carats before gold, a gem or a piece of jewellery: "18kt gold ring", "1 ct diamond"
        // ("eighteen carat"; carat and karat sound the same, and never change for more). kt, K
        // and k are gold, so only its fineness (9 to 24); with game words "10k gold" is ten
        // thousand. kt is knots with wind, sea or aircraft words and nothing explosive ("15 kt
        // winds"; "a yield of 21 kt" is kilotons). Elsewhere ct, kt and K stay as written.
        rules.append(Rule.withContext(number + #"\s?(kt|Kt|KT|ct|K|k)(?![\p{L}\d'’&*+\-/])"#) { m, s, context in
            let whole = s.substring(with: m.range)
            let symbol = s.substring(with: m.range(at: 2))
            let spot = UnitSpot(m, number: 1, in: s, context)
            if matches(gemAfter, spot.after) {
                if symbol == "ct" { return "\(spot.number) carat" }
                if goldNumbers.contains(spot.number), symbol.lowercased() == "kt" || !spot.has(UnitWords.gameGoldWords) {
                    return "\(spot.number) carat"
                }
                return whole
            }
            guard symbol == "kt", spot.has(UnitWords.windWords), !spot.has(UnitWords.blastWords) else { return whole }
            let noun = spot.nextWord.map { UnitWords.windNouns.contains($0) } ?? false
            return "\(spot.number) \(spot.singular || noun ? "knot" : "knots")"
        })
        // A count in millions, billions or thousands: "1.2m people", "70M savers", "2B users",
        // "100k members", "10K paying teams" → "1.2 million people". k and K before a plural (or
        // a word and a plural), so "a 5k run", "4K TV" stay; races and screens keep them, and
        // "401k" is the plan. m, M and B only before something counted in millions (`countNouns`):
        // before other plurals they are as often a length, a size or a brand ("1.5m strips", "8.5M
        // sneakers", "3M hooks"). A lower-case m needs a decimal. With nothing counted after it, a
        // decimal m and an M or B are millions and billions only in a sentence about money or
        // people ("population hit 68.3m", "We hit 2B in revenue") or beside another count in
        // millions ("9.7m votes, Reform 4.1m and the Tories 6.8m").
        rules.append(Rule.withContext(number + #"([ \t]?)([mMkKB])(?![\p{L}\d'’&*+\-²³°/]|\.\p{L})"#) { m, s, context in
            let whole = s.substring(with: m.range)
            let spot = UnitSpot(m, number: 1, in: s, context)
            let letter = s.substring(with: m.range(at: 3))
            if ["401", "403", "457"].contains(spot.number) { return whole }
            let glued = m.range(at: 2).length == 0
            let next = spot.nextWord?.lowercased()
            // A baby's size in months: "12M pajamas", "18M onesies".
            if letter == "M", glued, ["0", "3", "6", "9", "12", "18", "24"].contains(spot.number),
               let next, UnitWords.babyClothes.contains(next) {
                return spot.number + " month"
            }
            // A length of something: "1.5m strips", "two 2.4m boards" (a meter each).
            if letter == "m", let next, UnitWords.lengthNouns.contains(next) { return spot.number + " meter" }
            let millions = letter == "m" || letter == "M" || letter == "B"
            let scale = letter == "B" ? " billion" : letter.lowercased() == "m" ? " million" : " thousand"
            guard var noun = next else {
                return millions && countsBare(letter, spot) ? spot.number + scale : whole
            }
            if !UnitSpot.isPlural(noun), !UnitWords.countNouns.contains(noun), UnitSpot.isNoun(noun),
               let second = firstMatch(secondWord, spot.after) {
                noun = (spot.after as NSString).substring(with: second.range(at: 1)).lowercased()
            }
            let counted = UnitWords.countNouns.contains(noun) || UnitWords.irregularPlurals.contains(noun)
            if millions {
                if !counted {
                    // Nothing counted after it ("Reform 4.1m and the Tories…"); another noun is
                    // what it measures or names ("3M hooks", "8.5M sneakers").
                    guard let next, !UnitSpot.isNoun(next), countsBare(letter, spot) else { return whole }
                    return spot.number + scale
                }
                if spot.afterLabel { return whole }
                // A whole number and a glued or spaced m stays as written ("2m downloads", "3 m
                // viewers": units.json keeps "M" there); with a decimal it's a count ("1.2m people").
                if letter == "m", !spot.number.contains(".") { return whole }
                return spot.number + scale
            }
            if spot.afterLabel { return whole }
            guard counted || UnitSpot.isPlural(noun) else { return whole }
            if UnitWords.raceNouns.contains(noun) || UnitWords.screenNouns.contains(noun) || spot.has(UnitWords.raceWords) { return whole }
            return spot.number + scale
        })
        // pt and pts: pints of something to drink or cook with ("1 pt of cream", "1 pt. heavy
        // cream"); otherwise points, of type ("12 pt type") or of a score or a poll ("a 10-pt
        // lead", "by 18 pts", "a 3 pt story"). In a clinic "12 pt" are patients, left as letters.
        rules.append(Rule.withContext(number + #"([ \t]|-)?(pts|pt)(\.(?=\s+\p{Ll}|,))?(?![\p{L}\d'’&/])"#) { m, s, context in
            let spot = UnitSpot(m, number: 1, in: s, context)
            let plural = s.substring(with: m.range(at: 3)) == "pts"
            if spot.nextWord.map({ UnitWords.pintWords.contains($0.lowercased()) }) == true || spot.has(UnitWords.drinkWords)
                || matches(drinkAhead, spot.after) {
                return "\(spot.number) \(spot.singular && !plural ? "pint" : "pints")"
            }
            if spot.has(UnitWords.clinicWords) { return s.substring(with: m.range) }
            return "\(spot.number) \(plural ? "points" : "point")"
        })
        // Recipe shorthand before an ingredient: "1 c. flour", "1 T. butter", "1 t. salt".
        rules.append(Rule.withContext(number + #"[ \t](c|T|t)\.(?=[ \t]+\p{Ll})"#) { m, s, context in
            let spot = UnitSpot(m, number: 1, in: s, context)
            guard let next = spot.nextWord, UnitSpot.isNoun(next) else { return s.substring(with: m.range) }
            let words = ["c": ("cup", "cups"), "T": ("tablespoon", "tablespoons"), "t": ("teaspoon", "teaspoons")][s.substring(with: m.range(at: 2))]!
            return "\(spot.number) \(TextNormalizer.isOne(spot.number) ? words.0 : words.1)"
        })
        // pc: per cent glued to a number, as British papers write it ("29pc", "a 2pc rise"), unless
        // a piece goes before the noun ("a 3pc suit"); spaced or hyphenated before a noun it's a
        // piece ("8-pc chicken bucket", "8 pc nuggets"), and pcs are pieces ("40 pcs").
        rules.append(Rule.withContext(number + #"([ \t]|-)?(pcs|pc)(?![\p{L}\d'’&/]|\.\p{L})"#) { m, s, context in
            let whole = s.substring(with: m.range)
            let spot = UnitSpot(m, number: 1, in: s, context)
            let one = TextNormalizer.isOne(spot.number)
            if s.substring(with: m.range(at: 3)) == "pcs" { return spot.number + (one ? " piece" : " pieces") }
            let next = spot.nextWord?.lowercased()
            if m.range(at: 2).length == 0, !(next.map(UnitWords.pieceNouns.contains) ?? false) { return spot.number + " per cent" }
            guard let next, UnitSpot.isNoun(next) else { return whole }
            return spot.number + " piece"
        })
        // Finance: "25bp", "50 bps" → basis points, "0.25pp" → percentage points; bps is bits per
        // second in a sentence about a connection ("a 300 bps modem"), and a whole number of pp
        // is pages in a sentence about a document ("The Q2 board deck is 40 pp.").
        rules.append(Rule.withContext(number + #"[ \t]?(bps|bp|pp)(?![\p{L}\d'’&/]|\.[\p{L}\d])"#) { m, s, context in
            let spot = UnitSpot(m, number: 1, in: s, context)
            let one = TextNormalizer.isOne(spot.number)
            switch s.substring(with: m.range(at: 2)) {
            case "pp" where !spot.number.contains(".") && spot.has(UnitWords.documentWords):
                return spot.number + (one ? " page" : " pages")
            case "pp": return spot.number + (one ? " percentage point" : " percentage points")
            case "bps" where spot.has(UnitWords.connectionWords): return spot.number + (one ? " bit per second" : " bits per second")
            default: return spot.number + (one ? " basis point" : " basis points")
            }
        })

        // cal is calories only per serving or a day ("100 cal per serving"); "the 50 cal." is a
        // calibre. kcal is the table's.
        rules.append(Rule(number + #"\s?cal(?:/(serving|day)(?![\p{L}\d/])|(?=\s+(?:per|a\s+day)(?![\p{L}])))"#) { m, s in
            let n = s.substring(with: m.range(at: 1))
            let per = m.range(at: 2).location == NSNotFound ? "" : " per " + s.substring(with: m.range(at: 2))
            return "\(n) \(TextNormalizer.isOne(n) ? "calorie" : "calories")\(per)"
        })
        // psi, as drivers say it: "35 psi" → "35 P S I" (it was the Greek letter, "sigh").
        rules.append(Rule(number + #"\s?(?:psi|PSI)(?![\p{L}\d])"#) { m, s in
            "\(s.substring(with: m.range(at: 1))) P S I"
        })
        // "in." is inches before a lower-case word, "x", a digit or a comma ("12 in. wide"). Before a
        // capital or at the end, the period is the full stop and "in" the word ("Put 2 in. Then
        // stir."); without the period it's always the word ("5 in a row"). The measures pass
        // reads it first once it lands; then this finds nothing.
        rules.append(Rule.withContext(number + #"\s?in\.(?![\p{L}\d])"#) { m, s, context in
            let spot = UnitSpot(m, number: 1, in: s, context)
            let inches = "\(spot.number) \(spot.singular ? "inch" : "inches")"
            if matches(inchesAfter, spot.after) { return inches }
            // The second size of "12 in. x 8 in.": its period may also be the full stop.
            if matches(dimensionBefore, spot.before) { return inches + FullStop.kept(before: spot.after, next: .capital) }
            return s.substring(with: m.range)
        })
        return rules
    }()

    private static let dimensionAfter = try! NSRegularExpression(pattern: #"^\s*[x×]"#)
    private static let dimensionBefore = try! NSRegularExpression(pattern: #"[x×]\s*$"#)
    /// A W-number then an L-number, with at most a D- or T-number between: a record ("10 W, 3 L",
    /// "3W 2D 1L") or a pair of jeans ("32W 34L"). Only whole numbers next to each other, so a
    /// kettle's "1.7 L … 3,000 W" still reads liters and watts.
    private static let winLoss = try! NSRegularExpression(pattern:
        #"(?<![\p{L}\d.,])\d{1,3}\s?W(?:[\s,;/–-]+\d{1,3}\s?[DT])?[\s,;/–-]+\d{1,3}\s?L(?![\p{L}\d])"#)
    private static let timesNumber = try! NSRegularExpression(pattern: #"^\s*[x×]\s*\d"#)
    private static let numberNext = try! NSRegularExpression(pattern: #"^\s+\d"#)
    /// A clothing size on its own ("2 L and 3 XL"), not a letter of "U.S." or "M&Ms".
    private static let clothingSize = try! NSRegularExpression(pattern: #"(?<![\p{L}\d.&'’])(?:XS|S|M|XL|XXL|XXXL)(?![\p{L}\d.&'’])"#)
    private static let notAmps = try! NSRegularExpression(pattern: #"^\s+(?:grades?|levels?|stars?|Day)(?![\p{L}])"#)
    private static let electricalUnit = try! NSRegularExpression(pattern: #"\d\s?(?:V|W|mA|mAh|Ah|kW|Wh|Ω|Hz|kHz)(?![\p{L}\d])"#)

    /// The single letters, then A. A letter right after a number is a unit only when nothing
    /// says otherwise: not after a label ("Room 12 L", "Take Route 9 W"), not followed by a
    /// letter, a digit, an apostrophe, "*", "+", a hyphen or a slash ("5 W's", "V8", "5 A*",
    /// "L-shaped", "5W-30", "m/f"; but "230 V/50 Hz" is two values), not after a price, and for
    /// W and L not in a size ("20 W x 30 L") or a win-loss record ("32W 34L", "10 W, 3 L").
    private static let letterUnits: [Rule] = {
        let start = #"(?<![\p{L}\d.,/$£€¥₹₩])(?<!\p{L}[-–])(\d+(?:[.,]\d+)*)(\s?)"#
        let end = #"(?![\p{L}\d'’&*+\-²³°]|/(?!\d))(?!\.\p{L})"#
        var rules: [Rule] = []
        rules.append(Rule.withContext(start + "([mgLlVWhs])" + end) { m, s, context in
            let letter = s.substring(with: m.range(at: 3))
            let spot = UnitSpot(m, number: 1, in: s, context)
            guard let words = letterUnit(letter, glued: m.range(at: 2).length == 0, spot) else { return s.substring(with: m.range) }
            return "\(spot.number) \(spot.singular(unit: letter) ? words.0 : words.1)"
        })
        // A capital A is amps only in a sentence about electricity ("5 V at 3 A", "a 13 A fuse"):
        // otherwise it's a grade, a seat or a flat ("4 A grades", "Seat 12A", "the current tally
        // is 5 A"). Last, so the V and W just read count.
        rules.append(Rule.withContext(start + "A" + end) { m, s, context in
            let spot = UnitSpot(m, number: 1, in: s, context)
            guard !spot.afterLabel, !matches(notAmps, spot.after),
                  spot.has(UnitWords.electricalWords) || matches(electricalUnit, spot.sentence) else { return s.substring(with: m.range) }
            return "\(spot.number) \(spot.singular ? "amp" : "amps")"
        })
        return rules
    }()

    /// What a single letter after a number is called, or nil when it isn't a unit there.
    private static func letterUnit(_ letter: String, glued: Bool, _ spot: UnitSpot) -> (String, String)? {
        // A nutrient labels its grams without making them a name ("Carbs 30g", "Trans Fat 0g").
        let nutrient = letter == "g" && spot.wordBefore.map { UnitWords.nutrients.contains($0.lowercased()) } == true
        if spot.afterLabel && !nutrient { return nil }
        if letter == "W" || letter == "L" {
            if matches(dimensionAfter, spot.after) || matches(dimensionBefore, spot.before) { return nil }
            if matches(winLoss, spot.sentence) { return nil }
        }
        let next = spot.nextWord?.lowercased()
        switch letter {
        case "m":
            // Spaced, meters unless counted ("3 m viewers") or minutes ("5 m ago"). Glued, only
            // before a size word ("30m high", "2m apart"): "I'm 5m away" is minutes, "the 100m
            // final" a race, "2m downloads" millions. "2 m behind schedule" is a reader's "M".
            if glued {
                guard next.map(UnitWords.sizeWords.contains) == true || matches(timesNumber, spot.after) else { return nil }
            } else {
                if let next, UnitWords.notMeters.contains(next) || UnitWords.countNouns.contains(next) { return nil }
                if spot.has(UnitWords.moneyWords) || spot.hasStem(["invest"]) { return nil }
                if matches(behindSchedule, spot.after) { return nil }
            }
        case "g":
            // "4g in the village", "the 5g rollout": a network; "pull 9 g": g-force.
            if glued, let n = Int(spot.number), (2...6).contains(n), spot.has(UnitWords.networkWords) { return nil }
            if spot.has(UnitWords.gForceWords) || spot.hasStem(["pull"]) { return nil }
        case "L", "l":
            // Clothing ("2 L and 3 XL"), a Long suit ("42L"), a law student ("As a 1L").
            if matches(clothingSize, spot.sentence) || spot.has(["size", "sizes"]) { return nil }
            if glued, letter == "L", let n = Int(spot.number) {
                if (30...60).contains(n), let next, UnitWords.suitWords.contains(next) { return nil }
                if (1...4).contains(n), let owner = spot.wordBefore?.lowercased(), UnitWords.lawStudentOwners.contains(owner),
                   !(next.map(UnitWords.containers.contains) ?? false) { return nil }
            }
        case "V":
            // Not before a number: "1 V 1" is one versus one.
            if matches(numberNext, spot.after) { return nil }
        case "W":
            // Not before a number or a name ("9 W 3rd St", "500 W Madison"), unless it's a
            // charger's or a lamp's ("65 W USB-C charger", "a 9 W LED").
            if matches(numberNext, spot.after) { return nil }
            if let word = spot.nextWord, word.first?.isUppercase == true, !UnitWords.wattNames.contains(word) { return nil }
        case "h":
            // A European clock hour ("until 18h") or a code after a capitalised word ("INT 21h").
            if let n = Double(spot.number.replacingOccurrences(of: ",", with: "")), n <= 24,
               let word = spot.wordBefore?.lowercased(), UnitWords.clockWords.contains(word) { return nil }
            if let word = spot.wordBefore, word.count >= 2, word.allSatisfy(\.isUppercase), !["ETA", "ETD"].contains(word) { return nil }
        case "s":
            // Seconds spaced ("30 s") or after a decimal ("1.5s"); "the 1990s" and "her 20s" are
            // decades. A comparison makes it a time too ("more than 2s", "in under 3s"), but not
            // an age group ("Over 65s will lose…", "for under 5s").
            if glued && !spot.number.contains(".") {
                let words = spot.wordsBefore(2)
                guard let word = words.first else { return nil }
                if UnitWords.comparisons.contains(word) { break }
                guard word == "under" || word == "over", words.count > 1, UnitWords.timedBefore.contains(words[1]) else { return nil }
            }
        default:
            break
        }
        return letters[letter]
    }
}
