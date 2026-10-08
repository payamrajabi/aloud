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
    ]

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
                if da >= 3 && db >= 3 && !years && !round { return whole }
            }
            if y > x { return "\(a) to \(b)" }
            let score = y < x && da <= 2 && db <= 2
            let shortYear = (1000...2099).contains(x) && db == 2 && y > x.truncatingRemainder(dividingBy: 100)
            return score || shortYear ? "\(a) to \(b)" : whole
        })
        // Clock times: "3:45 pm", "6:00", "10:05 a.m.".
        let meridiem = #"([AaPp])(?:(\.)\s?[Mm](\.)?|[Mm])(?![\p{L}])"#
        rules.append(Rule(#"(?<![\d:])(\d{1,2}):(\d{2})(?![\d:])(?:\s?"# + meridiem + #")?"#) { m, s in
            let h = s.substring(with: m.range(at: 1)), mm = s.substring(with: m.range(at: 2))
            let ampm = m.range(at: 3).location == NSNotFound ? nil : meridiemWord(m, at: 3, in: s)
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
        // Simple fractions.
        let fractions = ["1/2": "one half", "1/3": "one third", "2/3": "two thirds", "1/4": "one quarter", "3/4": "three quarters"]
        rules.append(Rule(#"(?<![\d/])([123])/([234])(?![\d/])"#) { m, s in
            fractions[s.substring(with: m.range)] ?? s.substring(with: m.range)
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
        // Titles and "St." before a name: a capitalised word that isn't a usual sentence opener.
        let name = #"(?=\s+(?!(?:"# + Tokenizer.sentenceStarters.map(NSRegularExpression.escapedPattern).joined(separator: "|") + #")(?![\p{L}'’]))\p{Lu})"#
        rules.append(Rule(#"(?<![\p{L}.])("# + titles.keys.sorted().joined(separator: "|") + #")\."# + name) { m, s in
            titles[s.substring(with: m.range(at: 1))]!
        })
        rules.append(Rule(#"(?<![\p{L}.])St\."# + name) { m, s in
            // "Mount St. Helens", "Yves St. Laurent"; but "5th St." is a street (the next rule).
            Tokenizer.isStreet(before: s.substring(to: m.range.location)) ? "St." : "Saint"
        })
        // Any other "St." after a word is a street ("Main St."); at the end of a sentence its
        // period is also the full stop, so that stays.
        rules.append(Rule(#"(?<=[\p{L}\d]\s)St\.(?=(\s*$|\s+\p{Lu})|\s|[,;:)])"#) { m, _ in
            m.range(at: 1).location == NSNotFound ? "Street" : "Street."
        })
        return rules
    }()

    private static let marked = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(/[^)]*/\)"#)

    /// Lexicon terms that are also units or clock words. After a number ("16 GB of RAM",
    /// "500 MB", "6:00 AM") the rules above read them ("16 gigabytes"), as they do "16GB",
    /// rather than the lexicon's letters ("G B").
    private static let unitTerms = Set(units.map(\.0)).union(["AM", "PM", "am", "pm", "A.M.", "P.M.", "a.m.", "p.m."])

    /// - Parameter skippingMarkedSpans: leave [text](/phonemes/) spans (pronunciations
    ///   already fixed by the custom lexicon) untouched, except a unit right after a number.
    static func normalize(_ text: String, skippingMarkedSpans: Bool) -> String {
        guard skippingMarkedSpans else { return normalize(text) }
        let text = readArrows(text)
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
            out += normalize(plain) + ns.substring(with: m.range)
            plain = ""
        }
        return out + normalize(plain + ns.substring(from: last))
    }

    private static let link = try! NSRegularExpression(pattern: #"!?\[([^\]]*)\]\([^)]*\)"#)

    /// Markdown links in the text itself ("[Getting started](/guide/start/)") → their label.
    /// Runs before the custom lexicon marks its terms in the same syntax, so only those marks
    /// set a pronunciation: a link's path never reaches the voice as letters.
    static func linkLabels(_ text: String) -> String {
        link.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "$1")
    }

    static func normalize(_ text: String) -> String {
        var s = readArrows(text)
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
