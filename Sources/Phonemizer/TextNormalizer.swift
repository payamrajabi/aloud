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

    /// Fraction words: "an eighth", "three eighths", "seven tenths".
    private static let fractionDenominators: [Int: (String, String)] = [
        2: ("half", "halves"), 3: ("third", "thirds"), 4: ("quarter", "quarters"), 5: ("fifth", "fifths"),
        6: ("sixth", "sixths"), 7: ("seventh", "sevenths"), 8: ("eighth", "eighths"), 9: ("ninth", "ninths"),
        10: ("tenth", "tenths"), 11: ("eleventh", "elevenths"), 12: ("twelfth", "twelfths"), 13: ("thirteenth", "thirteenths"),
        14: ("fourteenth", "fourteenths"), 15: ("fifteenth", "fifteenths"), 16: ("sixteenth", "sixteenths"),
        32: ("thirty-second", "thirty-seconds"), 64: ("sixty-fourth", "sixty-fourths"), 100: ("hundredth", "hundredths"),
    ]
    /// "n/d" is a fraction only before a measure ("1/8 cup", "7/10 of a mile") unless d is a
    /// power of two; elsewhere "9/11", "8/10" and "2/5" are dates, scores and ratings.
    private static let measureWords: Set<String> = [
        "cup", "cups", "c", "tsp", "tbsp", "Tbsp", "tbs", "teaspoon", "teaspoons", "tablespoon", "tablespoons", "oz", "ounce",
        "ounces", "lb", "lbs", "pound", "pounds", "inch", "inches", "in", "ft", "foot", "feet", "mile", "miles", "mi", "of",
        "gallon", "gallons", "quart", "quarts", "pint", "pints", "stick", "sticks", "liter", "liters", "litre", "litres",
        "kg", "g", "gram", "grams", "mm", "cm", "m", "km", "yard", "yards", "acre", "acres", "hour", "hours", "second",
        "seconds", "minute", "minutes", "pinch", "dash", "can", "cans", "jar", "bag", "box", "loaf", "pie", "slice",
    ]

    private static func fractionWords(_ n: Int, _ d: Int, mixed: Bool) -> String? {
        guard n >= 1, n < d, let words = fractionDenominators[d] else { return nil }
        if n == 1 {
            if mixed { return (d == 8 || d == 11 ? "an " : "a ") + words.0 }
            return d == 2 ? "one half" : "one " + words.0
        }
        return NumberWords.cardinal(n) + " " + words.1
    }

    /// Regnal and sequel numerals ("Henry VIII", "World War II"), up to LXXXIX. C, D and M are
    /// left out, so "MIX", "CD", "DC" and "MD" stay words and letters.
    private static let romanPattern = #"(?=[IVXL])(?:XL|L?X{0,3})(?:IX|IV|V?I{0,3})"#
    private static func romanValue(_ s: String) -> Int? {
        guard s.range(of: "^" + romanPattern + "$", options: .regularExpression) != nil else { return nil }
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50]
        var total = 0
        let chars = Array(s)
        for (i, c) in chars.enumerated() {
            let v = values[c]!
            if i + 1 < chars.count, v < values[chars[i + 1]]! { total -= v } else { total += v }
        }
        return total > 0 ? total : nil
    }
    /// Words after which a numeral is a number ("Part II", "Phase III", "Type I"), in lower case.
    private static let numeralNouns: Set<String> = [
        "part", "chapter", "phase", "volume", "vol", "vol.", "act", "scene", "book", "episode", "type", "stage", "level",
        "class", "tier", "grade", "section", "article", "title", "schedule", "appendix", "annex", "season", "series",
        "mark", "mk", "mk.", "model", "gen", "generation", "version", "round", "division", "league", "group", "category",
        "fantasy", "apollo", "psalm", "canto", "movement", "symphony", "unit", "track", "disc", "disk", "wave", "block",
        "zone", "sector", "form", "rule", "figure", "fig.", "table", "item", "step", "page", "number", "no.", "vatican",
        "plate", "list", "tome", "parts", "chapters", "exhibit", "room", "floor", "gate", "terminal", "year", "lot",
    ]
    /// Titles before a name whose single-letter numeral is an ordinal ("Queen Elizabeth I").
    private static let regnalTitles: Set<String> = [
        "King", "Queen", "Pope", "Emperor", "Empress", "Tsar", "Tsarina", "Czar", "Prince", "Princess", "Duke", "Duchess",
        "Pharaoh", "Sultan", "Kaiser", "Saint", "St.", "Archduke", "Shah", "Emir", "Grand",
    ]
    /// Numerals that are also common letters or sizes, read as numbers only after `numeralNouns`.
    private static let ambiguousNumerals: Set<String> = ["XL", "LV", "LX", "LI", "XX", "XXX"]
    /// Words after a single-letter "I" that make it the pronoun ("Part I want…").
    private static let pronounFollowers: Set<String> = [
        "am", "was", "have", "had", "think", "want", "will", "would", "can", "could", "do", "did", "know", "need",
        "like", "love", "see", "saw", "said", "say", "feel", "felt", "mean", "guess", "hope", "believe", "found", "get",
        "got", "just", "really", "also", "never", "always", "don't", "can't", "won't", "didn't", "must", "should",
        "may", "might", "went", "made", "agree", "wish", "remember", "learned", "learnt", "wrote", "read",
    ]

    /// "Elizabeth II" → "Elizabeth the second", "World War II" → "World War two". `prev` is the
    /// word before the numeral, `before` the text before that word.
    private static func readRoman(_ numeral: String, after prev: String, before: String, next: String) -> String? {
        // A lone "X" is a letter: "Malcolm X", "Model X", "Generation X".
        guard numeral != "X", let value = romanValue(numeral) else { return nil }
        let prevLower = prev.lowercased()
        let previousWords = before.split(whereSeparator: { $0.isWhitespace })
        let wordBefore = previousWords.last.map { String($0).trimmingCharacters(in: .punctuationCharacters) } ?? ""
        var cardinal = numeralNouns.contains(prevLower)
            || (prevLower == "war" && wordBefore.lowercased() == "world")
            || (prevLower == "bowl" && wordBefore.lowercased() == "super")
        if cardinal, numeral.count == 1 {
            // A lone "I" is the pronoun unless the noun is capitalised ("Part I", not "the level I
            // want") and no verb follows.
            let nextWord = next.lowercased().replacingOccurrences(of: "’", with: "'")
            cardinal = prev.first?.isUppercase == true && !(numeral == "I" && pronounFollowers.contains(nextWord))
        }
        if cardinal { return NumberWords.cardinal(value) }
        // After a name, not a size or a brand ("Size XL", "Louis Vuitton LV").
        guard let first = prev.first, first.isUppercase, prev.dropFirst().allSatisfy({ $0.isLowercase || $0 == "-" }),
              prev.count > 1, !Tokenizer.sentenceStarters.contains(prev), !ambiguousNumerals.contains(numeral) else { return nil }
        // A ruler ("Henry the eighth", "Queen Elizabeth the first", "Pope Leo the fourteenth") or
        // a family name after a first name ("John Smith the third") is an ordinal.
        let ruler = regnalNames.contains(prev) || regnalTitles.contains(wordBefore)
        let heir = regnalNames.contains(wordBefore) && wordBefore.first?.isUppercase == true
        if numeral.count == 1 {
            // "Henry V"; but "I" after a bare name is usually the pronoun ("Thanks Paul I owe you"),
            // so only after a title ("Queen Elizabeth I").
            guard numeral == "I" ? regnalTitles.contains(wordBefore) && !pronounFollowers.contains(next.lowercased()) : ruler
            else { return nil }
            return "the " + NumberWords.ordinal(value)
        }
        // After any other title, a number: "Rocky three", "Street Fighter two".
        return ruler || heir ? "the " + NumberWords.ordinal(value) : NumberWords.cardinal(value)
    }
    /// Given names of rulers and popes (and common first names before a family name).
    private static let regnalNames: Set<String> = [
        "Henry", "Edward", "George", "William", "Charles", "James", "Richard", "John", "Elizabeth", "Mary", "Anne",
        "Victoria", "Louis", "Philip", "Philippe", "Felipe", "Ferdinand", "Frederick", "Friedrich", "Wilhelm", "Ludwig",
        "Leopold", "Francis", "Franz", "Joseph", "Peter", "Ivan", "Nicholas", "Alexander", "Catherine", "Paul", "Pius",
        "Leo", "Gregory", "Benedict", "Clement", "Innocent", "Urban", "Boniface", "Sixtus", "Julius", "Adrian", "Alfonso",
        "Juan", "Carlos", "Gustav", "Gustavus", "Carl", "Christian", "Frederik", "Haakon", "Olav", "Harald", "Rama",
        "Ramesses", "Ramses", "Thutmose", "Amenhotep", "Constantine", "Justinian", "Otto", "Rudolf", "Albert", "Napoleon",
        "Mehmed", "Suleiman", "Selim", "Murad", "Abdullah", "Hussein", "Faisal", "Darius", "Xerxes", "Cyrus", "Ptolemy",
        "Malcolm", "David", "Robert", "Alfred", "Edmund", "Harold", "Stephen", "Pedro", "Manuel", "Sancho", "Casimir",
        "Sigismund", "Vladimir", "Matthias", "Maximilian", "Umberto", "Emmanuel", "Isabella", "Isabel", "Margaret",
        "Margrethe", "Christina", "Rainier", "Baudouin", "Willem", "Amadeus", "Michael", "Thomas", "Daniel", "Martin",
    ]

    /// Keyboard shortcuts ("Ctrl+C", "Cmd + Shift + 4"): their abbreviations and keys as words,
    /// joined with "plus". Given to the G2P whole, the group went to the guessers ("Ctrl+C" was
    /// "see tee tee ar el see").
    private static let modifierPattern = "Ctrl|CTRL|ctrl|Control|Cmd|CMD|cmd|Command|Alt|ALT|alt|Opt|OPT|Option|Shift|SHIFT|shift|Fn|Win|Super|Meta|Hyper"
    private static let keyNames: [String: String] = [
        "ctrl": "Control", "control": "Control", "cmd": "Command", "command": "Command", "alt": "Alt", "opt": "Option",
        "option": "Option", "shift": "Shift", "fn": "Function", "win": "Windows", "super": "Super", "meta": "Meta",
        "hyper": "Hyper", "del": "Delete", "esc": "Escape", "pgup": "Page Up", "pgdn": "Page Down", "ins": "Insert",
        "bksp": "Backspace", "spc": "Space", "/": "slash", "\\": "backslash", "-": "minus", "=": "equals",
        "[": "left bracket", "]": "right bracket", "`": "backtick", ";": "semicolon",
    ]
    private static func readKeys(_ combo: String) -> String {
        let keys = combo.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let words = keys.map { key -> String in
            if let name = keyNames[key.lowercased()] { return name }
            return key.count == 1 ? key.uppercased() : key
        }
        return words.joined(separator: " plus ") + (combo.trimmingCharacters(in: .whitespaces).hasSuffix("+") ? " plus " : "")
    }

    /// Web addresses and file paths are read out with "dot" and "slash" ("www.google.com" → "W W W
    /// dot google dot com", "src/App.tsx" → "S R C slash App dot T S X"). Given to the G2P whole,
    /// they went to the guessers as one made-up word.
    static let topLevelDomains = "com|org|net|io|ai|dev|app|co|uk|gov|edu|us|ca|de|fr|au|nz|ie|jp|cn|eu|info|biz|xyz|tv|ly|gg|sh|fm|nl|se|ch|dk|fi|pl|br|mx|ru|kr|za|sg|hk|ac"
    private static func readAddressPart(_ part: String, last: Bool) -> String {
        if part.lowercased() == "www" { return "W W W" }
        let letters = part.filter(\.isLetter)
        guard letters.count == part.count else { return part }
        // A country code ("uk", "io") or a short run of consonants ("bbc", "src", "tsx") is spelled.
        if (last && part.count == 2) || (part.count <= 4 && !part.lowercased().contains(where: { "aeiouy".contains($0) })) {
            return part.uppercased()
        }
        return part
    }
    private static func readDomain(_ domain: String) -> String {
        let parts = domain.split(separator: ".").map(String.init)
        return parts.enumerated().map { readAddressPart($0.element, last: $0.offset == parts.count - 1) }.joined(separator: " dot ")
    }
    private static func readPath(_ path: String) -> String {
        var out: [String] = []
        for (i, segment) in path.split(separator: "/", omittingEmptySubsequences: false).enumerated() {
            if i > 0 { out.append("slash") }
            if segment == "~" { out.append("tilde"); continue }
            if segment == "." || segment == ".." { out.append(segment == "." ? "dot" : "dot dot"); continue }
            guard !segment.isEmpty else { continue }
            let pieces = segment.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            out.append(pieces.enumerated().map { $0.element.isEmpty ? "" : readAddressPart($0.element, last: false) }
                .joined(separator: " dot ").trimmingCharacters(in: .whitespaces))
        }
        return out.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static let months = ["jan": "January", "feb": "February", "mar": "March", "apr": "April", "may": "May",
                                 "jun": "June", "jul": "July", "aug": "August", "sep": "September", "sept": "September",
                                 "oct": "October", "nov": "November", "dec": "December"]
    private static let monthsInOrder = ["January", "February", "March", "April", "May", "June", "July", "August",
                                        "September", "October", "November", "December"]

    private static func ordinalSuffix(_ day: Int) -> String {
        (11...13).contains(day % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][day % 10] ?? "th"
    }

    /// Vulgar fractions, on their own ("½ cup": one half) and after a whole number ("1½ cups":
    /// 1 and a half).
    private static let vulgarFractions: [Character: (String, String)] = [
        "½": ("one half", "a half"), "⅓": ("one third", "a third"), "⅔": ("two thirds", "two thirds"),
        "¼": ("one quarter", "a quarter"), "¾": ("three quarters", "three quarters"),
    ]

    /// Operators read only between two spaced operands ("a < b", "x -> y"): "<b>", "->" in
    /// code or a "> quote" stay silent. A comparison also needs a number or a single letter
    /// beside it, so a menu path ("Settings > Privacy") isn't "greater than".
    private static let spacedOperators = ["<=": "less than or equal to", ">=": "greater than or equal to",
                                          "!=": "not equal to", "==": "equals", "<": "less than", ">": "greater than",
                                          "->": "to", "=>": "to", "===": "equals", "!==": "not equal to", "−": "minus"]
    private static let comparisons: Set<String> = ["<", ">", "<=", ">="]
    private static func isOperand(_ s: String) -> Bool {
        let core = s.trimmingCharacters(in: .punctuationCharacters)
        return core.contains(where: \.isNumber) || (core.count == 1 && core.first!.isLetter)
    }

    private static let abbreviations: [(String, String)] = [
        ("e.g.", "for example"), ("E.g.", "For example"), ("i.e.", "that is"), ("I.e.", "That is"),
        ("approx.", "approximately"), ("Approx.", "Approximately"), ("incl.", "including"), ("Incl.", "Including"),
        ("Ave.", "Avenue"), ("Blvd.", "Boulevard"), ("Mt.", "Mount"), ("Dept.", "Department"), ("dept.", "department"),
    ]

    /// Titles, spelled out only before a name ("Sen. Warren" → Senator Warren). At the end
    /// of a sentence or before a lower-case word they're names or words ("Amartya Sen.").
    private static let titles = ["Sen": "Senator", "Gov": "Governor", "Prof": "Professor", "Gen": "General",
                                 "Rep": "Representative", "Rev": "Reverend"]

    private static func isOne(_ n: String) -> Bool { n == "1" || n == "-1" }

    /// "AM" or "PM" for a time written "9 am", "9 AM." or "5pm", leaving a period after it to end
    /// the sentence: written as "A.M." it took the full stop with it, and the sentence lost its
    /// final fall ("…at 9 AM. Bring…"). "A.M." for "9 a.m.", unless that period is also the
    /// full stop (the end of the text, or a capital that isn't a day, month or time zone).
    /// The letter is capture group `group`, then the inner and final dots of "a.m.".
    private static func meridiemWord(_ m: NSTextCheckingResult, at group: Int, in s: NSString) -> String {
        let letter = s.substring(with: m.range(at: group)).uppercased()
        guard m.range(at: group + 1).location != NSNotFound else { return letter + "M" }
        guard m.range(at: group + 2).location != NSNotFound else { return letter + ".M." }
        let rest = s.substring(from: NSMaxRange(m.range))
        let next = rest.drop { $0 == " " || $0 == "\t" }
        let word = String(next.prefix { $0.isLetter })
        let endsSentence = next.isEmpty || next.first?.isNewline == true
            || (next.count < rest.count && word.first?.isUppercase == true && word.contains(where: \.isLowercase) && !timeWords.contains(word))
        return letter + (endsSentence ? "M." : ".M.")
    }
    private static let timeWords = Set(["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "Mon",
                                        "Tue", "Tues", "Wed", "Thu", "Thurs", "Fri", "Sat", "Sun", "Eastern", "Pacific",
                                        "Central", "Mountain", "Atlantic", "Standard", "Daylight", "Time", "Local",
                                        "Greenwich", "Coordinated", "Universal"] + monthsInOrder + months.keys.map(\.capitalized))

    /// Whether "a-b" at `range` is a sum: an operator follows it ("10-5=5", "7-3 = 4"), or an
    /// "=" or other operator comes before a difference that can't be a range ("x = 10-5";
    /// "Duration = 5-10 minutes" is one).
    private static func isSum(_ range: NSRange, in s: NSString, goingUp: Bool) -> Bool {
        let after = s.substring(from: NSMaxRange(range)).drop { $0 == " " }.first
        let before = s.substring(to: range.location).reversed().drop { $0 == " " }.first
        return after.map { "=+*×÷<>≠≈≤≥−".contains($0) } == true || (!goingUp && before.map { "=+*×÷".contains($0) } == true)
    }

    /// What an arrow reads as. "→" between two words or values is "to" ("Go → next", "A→B",
    /// "5 → 10"), but a key after "press", "tap" or "hit" or before "key" ("Press → to go
    /// forward", "Use → and ← keys"). The others are always keys; elsewhere "→" is silent.
    private static let arrowNames: [String: String] = ["→": "right arrow", "←": "left arrow", "↑": "up arrow", "↓": "down arrow"]
    private static let keyVerbs: Set<String> = ["press", "presses", "pressed", "pressing", "tap", "taps", "tapped", "tapping",
                                                "hit", "hits", "hitting", "use", "using", "hold", "holding", "click", "clicking", "push"]
    private static let keyNouns: Set<String> = ["key", "keys", "arrow", "arrows", "button", "buttons"]
    private static func readArrow(_ range: NSRange, in s: NSString) -> String {
        let arrow = s.substring(with: range)
        // Words on either side (a term the custom lexicon marked counts as its words),
        // skipping other arrows and "and"/"or"/"then" in a list of keys.
        let skip = Set(["and", "or", "then", "&", ",", "/"] + arrowNames.keys)
        func words(_ text: String) -> [String] {
            let plain = marked.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "$1")
            let ns = plain as NSString
            return wordOrArrow.matches(in: plain, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range).lowercased() }
        }
        let start = max(0, range.location - 80), end = min(s.length, NSMaxRange(range) + 80)
        let before = words(s.substring(with: NSRange(location: start, length: range.location - start))).reversed().first { !skip.contains($0) }
        let after = words(s.substring(with: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range)))).first { !skip.contains($0) }
        let left = s.substring(to: range.location).last, right = s.substring(from: NSMaxRange(range)).first
        func spaced(_ words: String) -> String {
            (left.map { $0.isWhitespace } == false ? " " : "") + words
                + (right.map { $0.isWhitespace || ".,;:!?)…".contains($0) } == false ? " " : "")
        }
        if arrow != "→" || before.map(keyVerbs.contains) == true || after.map(keyNouns.contains) == true {
            return spaced(arrowNames[arrow]!)
        }
        // Between two words or values on one line: "to".
        let l = s.substring(to: range.location).reversed().drop { $0 == " " || $0 == "\t" }.first
        let r = s.substring(from: NSMaxRange(range)).drop { $0 == " " || $0 == "\t" }.first
        let opens = l.map { $0.isLetter || $0.isNumber || ")]}%'’\"”…".contains($0) } == true
        let continues = r.map { $0.isLetter || $0.isNumber || "([{$£€\"“'‘".contains($0) } == true
        if opens && continues { return spaced("to") }
        return left.map(\.isWhitespace) == false && right.map(\.isWhitespace) == false ? " " : ""
    }
    private static let wordOrArrow = try! NSRegularExpression(pattern: #"[\p{L}]+|[→←↑↓&,/]|[.!?;:]"#)
    private static let arrowPattern = try! NSRegularExpression(pattern: #"[→←↑↓]"#)

    /// Every arrow in `text`, read with the marked terms around it in view ("[Go](/ɡˈO/) →
    /// next" is "Go to next"); the rules below see only the text between marks.
    private static func readArrows(_ text: String) -> String {
        let ns = text as NSString
        let matches = arrowPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = "", last = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let words = readArrow(m.range, in: ns)
            // A silent arrow before punctuation takes its space with it ("Settings →.").
            if words.isEmpty, NSMaxRange(m.range) < ns.length,
               ".,;:!?)…".contains(ns.substring(with: NSRange(location: NSMaxRange(m.range), length: 1))) {
                while out.last == " " || out.last == "\t" { out.removeLast() }
            }
            out += words
            last = NSMaxRange(m.range)
        }
        return out + ns.substring(from: last)
    }

    private static let rules: [Rule] = {
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
        // A short year: "Class of '05" → "oh 5" (a leading zero is otherwise read digit by digit).
        rules.append(Rule(#"(?<![\p{L}\d])['’]0(\d)(?![\d\p{L}'’])"#) { m, s in "oh " + s.substring(with: m.range(at: 1)) })
        // Phone numbers that start with 0 or "+" ("07700 900123", "0412 345 678", "+44 20 7946
        // 0018"): digit by digit, a pause between groups. Read as values they were other numbers
        // ("seven thousand seven hundred, nine hundred thousand…").
        rules.append(Rule(#"(?<![\p{L}\d.,+\-/:])(?:(\+)(\d{1,3})((?:[ \-]\(?\d{1,4}\)?){2,5})|(\(?0\d{1,4}\)?)((?:[ \-]\d{2,6}){1,4}))(?![\d\p{L}]|[.,]\d|[\-/]\d)"#) { m, s in
            let whole = s.substring(with: m.range)
            guard whole.filter(\.isNumber).count >= 8 else { return whole }
            let groups = whole.split(whereSeparator: { $0 == " " || $0 == "-" }).map { group in
                group.filter(\.isNumber).map(String.init).joined(separator: " ")
            }
            return (m.range(at: 1).location != NSNotFound ? "plus " : "") + groups.joined(separator: ", ")
        })
        // A minus typeset as U+2212 (Wikipedia, weather, papers) or another dash form, before a
        // number: "−12 degrees", "−0.5", "−$50". Dropped, it turned negatives positive and lost
        // the decimal point ("−0.5" read "zero five"). Between two numbers ("5−3") the lexicon
        // reads it; spaced ("5 − 3"), the operator rule below does.
        rules.append(Rule(#"(?<![\p{L}\d])[−‐‑‒﹣－](?=[$£€¥₹₩]?\d)"#) { _, _ in "-" })
        // An en dash only where nothing could make it a range or a dash: "fell to –5", "(–3)".
        rules.append(Rule(#"(?:^|(?<=[(\[=\n])|(?<=[^\d\s]\s))–(?=\d)"#) { _, _ in "-" })
        // "-$50": the sign before a currency symbol was dropped with it ("fifty").
        rules.append(Rule(#"(?<![\p{L}\d])-(?=[$£€¥₹₩]\d)"#) { _, _ in "minus " })
        // Wiki headings ("== History ==") are just their text.
        rules.append(Rule(#"^(={2,})[ \t]*([^=\n]*?[^=\s][^=\n]*?)[ \t]*\1[ \t]*$"#, options: .anchorsMatchLines) { m, s in
            s.substring(with: m.range(at: 2))
        })
        // A run of three or more of the same symbol is a rule or decoration ("=====",
        // "-----", "*****"), read as nothing: "equals" forty times was. Hyphens joining two
        // words ("wait---what") are a dash, and "a === b" is the operator (below).
        rules.append(Rule(#"([=\-*+_~#^<>|/\\•])\1{2,}"#) { m, s in
            let run = s.substring(with: m.range)
            let before = m.range.location > 0 ? s.substring(with: NSRange(location: m.range.location - 1, length: 1)) : ""
            let end = NSMaxRange(m.range)
            let after = end < s.length ? s.substring(with: NSRange(location: end, length: 1)) : ""
            if run == "===", before == " ", after == " " { return run }
            if run.first == "-", before.first?.isLetter == true, after.first?.isLetter == true { return " — " }
            return " "
        })
        // "§ 4.2", "§§ 3-5", "¶ 2": the signs were silent.
        rules.append(Rule(#"(§§?|¶)\s?"#) { m, s in
            let sign = s.substring(with: m.range(at: 1))
            let before = m.range.location > 0 ? s.substring(with: NSRange(location: m.range.location - 1, length: 1)) : " "
            let word = sign == "§" ? "section" : sign == "§§" ? "sections" : "paragraph"
            return (before.first?.isWhitespace == false && before != "(" ? " " : "") + word + " "
        })
        // Keyboard shortcuts: "Ctrl+C" → "Control plus C", "Cmd+Shift+4".
        rules.append(Rule(#"(?<![\p{L}\d+])((?:(?:"# + modifierPattern + #")\s?\+\s?)+(?:[\p{L}\d]+|[/\\\-=\[\]`;])?)(?![\p{L}\d])"#) { m, s in
            readKeys(s.substring(with: m.range(at: 1)))
        })
        rules.append(Rule(#"(?<![\p{L}\d.])(Ctrl|CTRL|Cmd|CMD)(?![\p{L}\d.])"#) { m, s in
            s.substring(with: m.range(at: 1)).lowercased() == "ctrl" ? "Control" : "Command"
        })
        // "localhost:3000", "example.com:8080": the port after a colon.
        rules.append(Rule(#"(?<![\p{L}\d.\-/@])(localhost|[A-Za-z][\w\-]*(?:\.[\w\-]+)+|\d{1,3}(?:\.\d{1,3}){3}):(\d{2,5})(?![\d:])"#) { m, s in
            let host = s.substring(with: m.range(at: 1))
            return (host == "localhost" ? "local host" : host) + " colon " + s.substring(with: m.range(at: 2))
        })
        // File paths: "src/components/App.tsx", "/usr/local/bin", "~/Downloads".
        rules.append(Rule(#"(?<![\p{L}\d@./\\\-:~])(?:((?:~|\.{1,2})?(?:/[\w\-.]*[\w\-])+/?)|([\w\-]+(?:/[\w\-.]+)*/[\w\-.]*[\w\-]\.[A-Za-z][A-Za-z\d]{0,4}))(?![\p{L}\d/])"#) { m, s in
            // Right after a term the custom lexicon marked ("/usr", "node_modules"), a word apart.
            let joined = m.range.location == 0 || s.substring(with: NSRange(location: m.range.location - 1, length: 1)).first?.isWhitespace == false
            return (joined ? " " : "") + readPath(s.substring(with: m.range))
        })
        // Web addresses: "www.google.com", "bbc.co.uk", "name@example.com"; after a term the
        // custom lexicon has marked, the rest of it (".com").
        let domain = #"((?:[A-Za-z\d][A-Za-z\d\-]*\.)+(?:"# + topLevelDomains + #"))(?![\p{L}\d\-]|\.[\p{L}\d])"#
        rules.append(Rule(#"(?<![\p{L}\d./\-])"# + domain) { m, s in readDomain(s.substring(with: m.range(at: 1))) })
        rules.append(Rule(#"^((?:\.[A-Za-z\d][A-Za-z\d\-]*)*\.(?:"# + topLevelDomains + #"))(?![\p{L}\d\-]|\.[\p{L}\d])"#) { m, s in
            " dot " + readDomain(String(s.substring(with: m.range(at: 1)).dropFirst()))
        })
        // Temperatures: "-5°C", "72 °F", "30°".
        rules.append(Rule(#"(?<![\p{L}\d])([-−]?\d+(?:\.\d+)?)\s?°\s?([CFcf])?(?![\p{L}])"#) { m, s in
            let n = s.substring(with: m.range(at: 1)).replacingOccurrences(of: "−", with: "-")
            var out = n + (isOne(n) ? " degree" : " degrees")
            if m.range(at: 2).location != NSNotFound {
                out += s.substring(with: m.range(at: 2)).uppercased() == "C" ? " Celsius" : " Fahrenheit"
            }
            return out
        })
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
            return n + (isOne(n) ? " inch" : " inches")
        })
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
            return "\(n) \(power) \(isOne(n) ? unit.0 : unit.1)"
        })
        // Other powers: "x²" → "x squared", "mc²", "(a+b)³" (it was "x two"). Not after a longer
        // word, where it's a footnote ("the study² found").
        rules.append(Rule(#"(?:(?<![\p{L}\d])(\p{L}{1,2}|\d{1,3})|(\)))([²³])(?![\d²³])"#) { m, s in
            let base = s.substring(with: m.range(at: m.range(at: 1).location != NSNotFound ? 1 : 2))
            return base + (s.substring(with: m.range(at: 3)) == "²" ? " squared" : " cubed")
        })
        // A range written with its unit on both numbers: "5.25%-5.5%", "0.5mm-1.5mm", "1.5x-2.5x"
        // → "5.25% to 5.5%". The second number lost its decimal point and the "to".
        // (The custom lexicon may have put a space before a unit it knows: "0.5 mm-1.5 mm".)
        rules.append(Rule(#"(?<![\p{L}\d\-–−+./:#)])(\d+(?:[.,]\d+)*)(\s?)(%|[xX×]|[a-zA-Zμ]{1,4})\s?[-–]\s?(\d+(?:[.,]\d+)*)\2\3(?![\p{L}\d])"#) { m, s in
            let unit = s.substring(with: m.range(at: 2)) + s.substring(with: m.range(at: 3))
            return "\(s.substring(with: m.range(at: 1)))\(unit) to \(s.substring(with: m.range(at: 4)))\(unit)"
        })
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
            return "\(n) \(isOne(n) ? words.0 : words.1)"
        })
        let glued = Dictionary(gluedUnits.map { ($0.0, ($0.1, $0.2)) }, uniquingKeysWith: { a, _ in a })
        rules.append(Rule(#"(?<![\p{L}\d.,])(\d+(?:[.,]\d+)*)("# + gluedUnits.map(\.0).sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern).joined(separator: "|") + #")(?![\p{L}\d/])"#) { m, s in
            let n = s.substring(with: m.range(at: 1))
            let words = glued[s.substring(with: m.range(at: 2))]!
            return "\(n) \(isOne(n) ? words.0 : words.1)"
        })
        // ISO dates: "2024-03-15" → "March 15th, 2024".
        rules.append(Rule(#"(?<![\p{L}\d\-–−./:])(\d{4})-(\d{2})-(\d{2})(?![\p{L}\d\-–]|[.,:/]\d)"#) { m, s in
            let year = s.substring(with: m.range(at: 1))
            guard let month = Int(s.substring(with: m.range(at: 2))), let day = Int(s.substring(with: m.range(at: 3))),
                  (1...12).contains(month), (1...31).contains(day) else { return s.substring(with: m.range) }
            return "\(monthsInOrder[month - 1]) \(day)\(ordinalSuffix(day)), \(year)"
        })
        // Ranges: "5-10 minutes", "1990-2000", "18–25", "9:00-17:00" → "5 to 10". Not a third
        // group (phone numbers, "1-800-555-1234"), a leading zero ("007-123") or after a letter
        // ("COVID-19", "x86-64"); a spaced hyphen may be a minus ("10 - 5"), a spaced en dash isn't.
        // Going down, only a score ("3-2", "9-5") or a short year ("1990-95") is one: "FIPS 140-2"
        // isn't, and neither is "50-50". Nor is a phone number ("555-1234"), a part or ID number
        // ("1234-5678": both 3+ digits, unless both are years or round numbers, "100-200"), "24-7"
        // or a sum ("10-5=5" → "10 minus 5"); those were read "five fifty-five to twelve…".
        let number = #"(\d{1,2}:\d{2}|\d+(?:[.,]\d+)*)"#
        rules.append(Rule(#"(?<![\p{L}\d\-–−+./:#)])(?<!\)\s)"# + number + #"(?:-|\s?–\s?)"# + number + #"(?![\d\-–]|[.,:/]\d)"#) { m, s in
            let a = s.substring(with: m.range(at: 1)), b = s.substring(with: m.range(at: 2))
            let whole = s.substring(with: m.range)
            let leadingZero = [a, b].contains { $0.count > 1 && $0.hasPrefix("0") && !$0.hasPrefix("0.") && !$0.contains(":") }
            if leadingZero { return whole }
            func value(_ n: String) -> Double? { Double(n.replacingOccurrences(of: ",", with: "")) }
            guard let x = value(a), let y = value(b) else { return "\(a) to \(b)" }  // clock times
            if isSum(m.range, in: s, goingUp: y > x) { return "\(a) minus \(b)" }
            let da = a.filter(\.isNumber).count, db = b.filter(\.isNumber).count
            if !(a + b).contains(where: { $0 == "," || $0 == "." }) {
                if a == "24" && b == "7" { return whole }
                let round = x.truncatingRemainder(dividingBy: 10) == 0 && y.truncatingRemainder(dividingBy: 10) == 0
                let years = (1000...2099).contains(x) && (1000...2099).contains(y)
                if da >= 3 && db >= 3 && !years && !round {
                    // Two 3-digit numbers are pages, rooms or a vote ("pages 123-145", "218-212"):
                    // "to" either way. Left as they were, the G2P ran them together.
                    return da == 3 && db == 3 ? "\(a) to \(b)" : whole
                }
            }
            if y > x { return "\(a) to \(b)" }
            let score = y < x && da <= 2 && db <= 2
            let shortYear = (1000...2099).contains(x) && db == 2 && y > x.truncatingRemainder(dividingBy: 100)
            return score || shortYear ? "\(a) to \(b)" : whole
        })
        // UK times with a dot: "10.30am" → "10:30am" (it was "ten point three A M").
        rules.append(Rule(#"(?<![\d.,:])(\d{1,2})\.([0-5]\d)(?=\s?[AaPp](?:\.\s?[Mm]\.?|[Mm])(?![\p{L}]))"#) { m, s in
            let h = s.substring(with: m.range(at: 1))
            guard let hour = Int(h), (1...12).contains(hour) else { return s.substring(with: m.range) }
            return "\(hour):\(s.substring(with: m.range(at: 2)))"
        })
        // Clock times: "3:45 pm", "6:00", "10:05 a.m.".
        let meridiem = #"([AaPp])(?:(\.)\s?[Mm](\.)?|[Mm])(?![\p{L}])"#
        rules.append(Rule(#"(?<![\d:])(\d{1,2}):(\d{2})(?![\d:])(?:\s?"# + meridiem + #")?"#) { m, s in
            let h = s.substring(with: m.range(at: 1)), mm = s.substring(with: m.range(at: 2))
            let ampm = m.range(at: 3).location == NSNotFound ? nil : meridiemWord(m, at: 3, in: s)
            // "05:30" is "5 30": a number with a leading zero is otherwise read digit by digit.
            var out = Int(h).map(String.init) ?? h
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
        rules.append(Rule(#"(?<![\d:.,])(\d{1,2})\s?"# + meridiem) { m, s in
            s.substring(with: m.range(at: 1)) + " " + meridiemWord(m, at: 2, in: s)
        })
        // "Jan 5" / "January 5, 2024" → "January 5th".
        let monthNames = "Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sept|Sep|Oct|Nov|Dec|January|February|March|April|June|July|August|September|October|November|December"
        rules.append(Rule(#"\b("# + monthNames + #")\.?\s+(\d{1,2})(?![\d:]|st|nd|rd|th)\b"#) { m, s in
            let name = s.substring(with: m.range(at: 1))
            let month = months[name.lowercased()] ?? name
            let day = Int(s.substring(with: m.range(at: 2))) ?? 0
            return "\(month) \(day)\(ordinalSuffix(day))"
        })
        // "Feb." on its own → "February".
        rules.append(Rule(#"\b(Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sept|Sep|Oct|Nov|Dec)\.(?=\s|$)"#) { m, s in
            months[s.substring(with: m.range(at: 1)).lowercased()] ?? s.substring(with: m.range(at: 1))
        })
        // Fractions after a whole number: "1 1/2 cups" → "1 and a half cups" (it was "one one half").
        rules.append(Rule(#"(?<![\d/.,])(\d+) (\d{1,2})/(\d{1,3})(?![\d/]|[.,]\d)"#) { m, s in
            guard let n = Int(s.substring(with: m.range(at: 2))), let d = Int(s.substring(with: m.range(at: 3))),
                  let words = fractionWords(n, d, mixed: true) else { return s.substring(with: m.range) }
            return "\(s.substring(with: m.range(at: 1))) and \(words)"
        })
        // Fractions: "1/2", "3/4" and eighths or sixteenths anywhere; other denominators before a
        // measure ("7/10 of a mile", "2/5 cup"). "9/11", "24/7" and a rating ("8/10") stay.
        let fractions = ["1/2": "one half", "1/3": "one third", "2/3": "two thirds", "1/4": "one quarter", "3/4": "three quarters"]
        let dateWords: Set<String> = ["on", "by", "until", "till", "from", "since", "before", "after", "due", "dated", "born", "died", "starting", "ending"]
        rules.append(Rule(#"(?<![\d/])(\d{1,2})/(\d{1,3})(?![\d/]|[.,]\d)"#) { m, s in
            let whole = s.substring(with: m.range)
            if let words = fractions[whole] { return words }
            guard let n = Int(s.substring(with: m.range(at: 1))), let d = Int(s.substring(with: m.range(at: 2))),
                  let words = fractionWords(n, d, mixed: false) else { return whole }
            let next = s.substring(from: NSMaxRange(m.range)).drop { $0 == " " || $0 == "-" }.prefix { $0.isLetter }
            let previous = s.substring(to: m.range.location).split(separator: " ").last.map { $0.lowercased() } ?? ""
            if dateWords.contains(previous) || m.range.location > 0 && s.substring(to: m.range.location).last?.isLetter == true {
                return whole
            }
            return [8, 16, 32, 64].contains(d) || measureWords.contains(String(next)) ? words : whole
        })
        // "½ cup", "1½ cups".
        rules.append(Rule(#"(?<![\d.,/])(?:(\d+)\s?)?([½⅓⅔¼¾])"#) { m, s in
            let words = vulgarFractions[Character(s.substring(with: m.range(at: 2)))]!
            guard m.range(at: 1).location != NSNotFound else { return words.0 }
            return s.substring(with: m.range(at: 1)) + " and " + words.1
        })
        // "50¢" → "50 cents".
        rules.append(Rule(#"(?<![\p{L}\d.,])(\d+)\s?¢"#) { m, s in
            let n = s.substring(with: m.range(at: 1))
            return n + (isOne(n) ? " cent" : " cents")
        })
        // "a < b", "x -> y" (an operand can be a lexicon term, outside this span: "JOSE != José").
        let operators = spacedOperators.keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern).joined(separator: "|")
        rules.append(Rule(#"(?<=\S\s|^\s)("# + operators + #")(?=\s\S|\s$)"#) { m, s in
            let op = s.substring(with: m.range(at: 1))
            if comparisons.contains(op) {
                let before = s.substring(to: m.range.location).split(separator: " ").last.map(String.init) ?? ""
                let after = s.substring(from: NSMaxRange(m.range)).split(separator: " ").first.map(String.init) ?? ""
                guard isOperand(before) || isOperand(after) else { return op }
            }
            return spacedOperators[op]!
        })
        // A plural in brackets: "word(s)", "box(es)" → "words", "boxes" (not "word S").
        rules.append(Rule(#"(?<=\p{L})\((e?s)\)(?![\p{L}\d])"#) { m, s in s.substring(with: m.range(at: 1)) })
        // Abbreviations.
        for (abbr, full) in abbreviations {
            rules.append(Rule("(?<![\\p{L}.])" + NSRegularExpression.escapedPattern(for: abbr) + "(?=\\s|$|[,;:)])") { _, _ in full })
        }
        // Titles before a name: a capitalised word that isn't a usual sentence opener. ("St." is
        // read in `readStreets`, with the terms the custom lexicon marked in view.)
        rules.append(Rule(#"(?<![\p{L}.])("# + titles.keys.sorted().joined(separator: "|") + #")\."# + namePattern) { m, s in
            titles[s.substring(with: m.range(at: 1))]!
        })
        rules.append(Rule(#"(?<![\p{L}\d])WW(II|I|2|1)(?![\p{L}\d])"#) { m, s in
            ["II", "2"].contains(s.substring(with: m.range(at: 1))) ? "World War Two" : "World War One"
        })
        return rules
    }()

    private static let marked = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(/[^)]*/\)"#)

    /// A name next: a capitalised word that isn't a usual sentence opener.
    private static let namePattern = #"(?=\s+(?!(?:"# + Tokenizer.sentenceStarters.map(NSRegularExpression.escapedPattern).joined(separator: "|") + #")(?![\p{L}'’]))\p{Lu})"#
    private static let saint = try! NSRegularExpression(pattern: #"(?<![\p{L}.])St\."#)
    private static let nameNext = try! NSRegularExpression(pattern: "^" + namePattern)
    private static let streetEnd = try! NSRegularExpression(pattern: #"^(?:(\s*$|\s+\p{Lu})|\s|[,;:)])"#)

    /// "St.": Saint before a name ("Mount St. Helens", "Yves St. Laurent", "to St. Louis"), unless
    /// it ends a street's name (`Tokenizer.isStreet`: "5th St.", "Park on Elm St. Bring cash.");
    /// any other "St." after a word is a street ("Main St."). At the end of a sentence its period
    /// is also the full stop, so that stays ("Street."). Read with the marked terms in view: "Elm"
    /// in "on Elm St." is a custom-lexicon term, and seen alone "St. Bring" was "Saint Bring".
    private static func readStreets(_ text: String) -> String {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let matches = saint.matches(in: text, range: all)
        guard !matches.isEmpty else { return text }
        let marks = marked.matches(in: text, range: all).map(\.range)
        func plain(_ s: String) -> String {
            marked.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "$1")
        }
        var out = "", last = 0
        for m in matches where !marks.contains(where: { NSLocationInRange(m.range.location, $0) }) {
            let start = max(0, m.range.location - 120)
            let before = plain(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
            let after = plain(ns.substring(with: NSRange(location: NSMaxRange(m.range), length: min(160, ns.length - NSMaxRange(m.range)))))
            let a = after as NSString
            var words: String?
            if nameNext.firstMatch(in: after, range: NSRange(location: 0, length: a.length)) != nil, !Tokenizer.isStreet(before: before) {
                words = "Saint"
            } else if before.range(of: #"[\p{L}\d]\s$"#, options: .regularExpression) != nil,
                      let e = streetEnd.firstMatch(in: after, range: NSRange(location: 0, length: a.length)) {
                words = e.range(at: 1).location == NSNotFound ? "Street" : "Street."
            }
            guard let words else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + words
            last = NSMaxRange(m.range)
        }
        return out + ns.substring(from: last)
    }

    private static let romanCandidate = try! NSRegularExpression(pattern: #"(?<![\p{L}\d'’/\[])[IVXL]{1,7}(?=(?:['’]s)?(?![\p{L}\d'’\]]))"#)
    private static let wordBeforeSpace = try! NSRegularExpression(pattern: #"\p{L}[\p{L}'’.\-]*[ \t]+$"#)

    /// Roman numerals were spelled out ("World War I I", "Henry V I I I"): after a ruler's name
    /// they're ordinals ("Henry the eighth"), after "Part", "Phase", "World War" or a title they
    /// are numbers ("Phase three", "Street Fighter two"). `readRoman` decides, and leaves the
    /// pronoun "I" and words like "MIX". Read with the marked terms in view, as arrows are:
    /// "Apollo" in "Apollo XI" is a custom-lexicon term.
    private static func readRomanNumerals(_ text: String) -> String {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let matches = romanCandidate.matches(in: text, range: all)
        guard !matches.isEmpty else { return text }
        let marks = marked.matches(in: text, range: all).map(\.range)
        var out = "", last = 0
        for m in matches where !marks.contains(where: { NSLocationInRange(m.range.location, $0) }) {
            let start = max(0, m.range.location - 120)
            let window = ns.substring(with: NSRange(location: start, length: m.range.location - start))
            let before = marked.stringByReplacingMatches(in: window, range: NSRange(location: 0, length: (window as NSString).length), withTemplate: "$1")
            let bs = before as NSString
            guard let w = wordBeforeSpace.firstMatch(in: before, range: NSRange(location: 0, length: bs.length)) else { continue }
            let prev = bs.substring(with: w.range).trimmingCharacters(in: .whitespaces)
            let after = ns.substring(from: NSMaxRange(m.range))
            let next = String(after.drop { !$0.isLetter && !$0.isNewline }.prefix { $0.isLetter || $0 == "'" || $0 == "’" })
            guard let words = readRoman(ns.substring(with: m.range), after: prev, before: bs.substring(to: w.range.location), next: next)
            else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + words
            last = NSMaxRange(m.range)
        }
        return out + ns.substring(from: last)
    }

    /// Lexicon terms that are also units or clock words. After a number ("16 GB of RAM",
    /// "500 MB", "6:00 AM") the rules above read them ("16 gigabytes"), as they do "16GB",
    /// rather than the lexicon's letters ("G B").
    private static let unitTerms = Set(units.map(\.0)).union(["AM", "PM", "am", "pm", "A.M.", "P.M.", "a.m.", "p.m."])

    /// - Parameter skippingMarkedSpans: leave [text](/phonemes/) spans (pronunciations
    ///   already fixed by the custom lexicon) untouched, except a unit right after a number.
    static func normalize(_ text: String, skippingMarkedSpans: Bool) -> String {
        guard skippingMarkedSpans else { return normalize(text) }
        let text = readStreets(readRomanNumerals(readArrows(text)))
        let ns = text as NSString
        var out = ""
        var plain = ""
        var last = 0
        for m in marked.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            plain += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            last = NSMaxRange(m.range)
            let term = ns.substring(with: m.range(at: 1))
            if unitTerms.contains(term), plain.range(of: #"\d\s?$"#, options: .regularExpression) != nil {
                plain += term
                continue
            }
            out += applyRules(plain) + ns.substring(with: m.range)
            plain = ""
        }
        return out + applyRules(plain + ns.substring(from: last))
    }

    private static let link = try! NSRegularExpression(pattern: #"!?\[([^\]]*)\]\([^)]*\)"#)

    /// Markdown links in the text itself ("[Getting started](/guide/start/)") → their label.
    /// Runs before the custom lexicon marks its terms in the same syntax, so only those marks
    /// set a pronunciation: a link's path never reaches the voice as letters.
    static func linkLabels(_ text: String) -> String {
        link.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "$1")
    }

    static func normalize(_ text: String) -> String {
        applyRules(readStreets(readRomanNumerals(readArrows(text))))
    }

    /// `rules`, in order, on text whose arrows, numerals and "St." have been read.
    private static func applyRules(_ text: String) -> String {
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
