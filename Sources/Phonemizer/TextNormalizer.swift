import Foundation

/// Rewrites things misaki reads badly into words it reads well, before phonemizing:
/// units ("10 km" → "10 kilometers"), temperatures ("-5°C" → "-5 degrees Celsius"),
/// clock times ("6:00 am" → "6 A.M.", "10:05" → "10 oh 5"), dates ("Jan 5" →
/// "January 5th"), simple fractions and a few abbreviations. Numbers stay as digits;
/// the lexicon reads those.
enum TextNormalizer {
    /// A pattern and what each match reads as. A rule sees only the stretch of text it runs
    /// on (between the custom lexicon's marks); one that needs the words around it, such as a
    /// term the lexicon marked, is made `withContext` and reads them from its `RuleContext`.
    struct Rule {
        let regex: NSRegularExpression
        let replace: (NSTextCheckingResult, NSString, RuleContext) -> String
        init(_ pattern: String, options: NSRegularExpression.Options = [], _ replace: @escaping (NSTextCheckingResult, NSString) -> String) {
            regex = try! NSRegularExpression(pattern: pattern, options: options)
            self.replace = { m, s, _ in replace(m, s) }
        }
        private init(regex: NSRegularExpression, replace: @escaping (NSTextCheckingResult, NSString, RuleContext) -> String) {
            self.regex = regex
            self.replace = replace
        }
        static func withContext(_ pattern: String, options: NSRegularExpression.Options = [],
                                _ replace: @escaping (NSTextCheckingResult, NSString, RuleContext) -> String) -> Rule {
            Rule(regex: try! NSRegularExpression(pattern: pattern, options: options), replace: replace)
        }
    }

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

    static func ordinalSuffix(_ day: Int) -> String {
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

    static func isOne(_ n: String) -> Bool { n == "1" || n == "-1" }

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
                                        "Greenwich", "Coordinated", "Universal"] + CalendarNames.monthsInOrder + CalendarNames.months.keys.map(\.capitalized))

    /// Whether "a-b" at `range` is a sum: an operator follows it ("10-5=5", "7-3 = 4"), or an
    /// "=" or other operator comes before a difference that can't be a range ("x = 10-5";
    /// "Duration = 5-10 minutes" is one).
    static func isSum(_ range: NSRange, in s: NSString, goingUp: Bool) -> Bool {
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

    /// The rules for each voice, built once. Several Core readings differ between the voices
    /// (dates' "the fifteenth of March", the "#" key), so the voice is fixed when a list is
    /// built, rather than read from a shared flag: phonemizers run on different queues.
    private static let rulesUS = makeRules(british: false)
    private static let rulesGB = makeRules(british: true)

    /// The rules, in the order the Core readings need (FIN-889). Each Core area adds its rules
    /// through its own hooks (Sources/Phonemizer/Core), never by editing this list. Rules an
    /// area is replacing have moved to its file and still run here, where they always ran.
    private static func makeRules(british: Bool) -> [Rule] {
        var rules: [Rule] = []
        // fix3's money rules (per-unit, range, scale), until the money pass reads them first.
        rules += MoneyPass.legacyRules(british: british)
        // A short year: "Class of '05" → "oh 5" (a leading zero is otherwise read digit by digit).
        rules.append(Rule(#"(?<![\p{L}\d])['’]0(\d)(?![\d\p{L}'’])"#) { m, s in "oh " + s.substring(with: m.range(at: 1)) })
        // fix3's phone rule (a leading 0 or "+"), until the phone pass reads numbers first.
        rules += PhonePass.legacyRules(british: british)
        // A minus typeset as U+2212 (Wikipedia, weather, papers) or another dash form, before a
        // number: "−12 degrees", "−0.5", "−$50". Dropped, it turned negatives positive and lost
        // the decimal point ("−0.5" read "zero five"). Between two numbers ("5−3") the lexicon
        // reads it; spaced ("5 − 3"), the operator rule below does.
        rules.append(Rule(#"(?<![\p{L}\d])[−‐‑‒﹣－](?=[$£€¥₹₩]?\d)"#) { _, _ in "-" })
        // An en dash only where nothing could make it a range or a dash: "fell to –5", "(–3)".
        rules.append(Rule(#"(?:^|(?<=[(\[=\n])|(?<=[^\d\s]\s))–(?=\d)"#) { _, _ in "-" })
        rules += MoneyPass.signRules(british: british)
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
        // § and ¶, then ™, ®, ©, ‰, №, and "#": number, "# of", then the key.
        rules += ShorthandRules.sectionSigns(british: british)
        rules += ShorthandRules.signs(british: british)
        // Keyboard shortcuts: "Ctrl+C" → "Control plus C", "Cmd+Shift+4".
        rules.append(Rule(#"(?<![\p{L}\d+])((?:(?:"# + modifierPattern + #")\s?\+\s?)+(?:[\p{L}\d]+|[/\\\-=\[\]`;])?)(?![\p{L}\d])"#) { m, s in
            readKeys(s.substring(with: m.range(at: 1)))
        })
        rules.append(Rule(#"(?<![\p{L}\d.])(Ctrl|CTRL|Cmd|CMD)(?![\p{L}\d.])"#) { m, s in
            s.substring(with: m.range(at: 1)).lowercased() == "ctrl" ? "Control" : "Command"
        })
        // Numeric dates, then slash compounds ("kWh/yr"): both before ports, paths and ranges.
        rules += DateRules.numericDates(british: british)
        rules += UnitRules.slashCompounds(british: british)
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
        // "a 45° angle" and coordinates take the degree sign before Temperatures does.
        rules += ShorthandRules.degreeAdjective(british: british)
        rules += UnitRules.coordinates(british: british)
        // Temperatures: "-5°C", "72 °F", "30°".
        rules.append(Rule(#"(?<![\p{L}\d])([-−]?\d+(?:\.\d+)?)\s?°\s?([CFcf])?(?![\p{L}])"#) { m, s in
            let n = s.substring(with: m.range(at: 1)).replacingOccurrences(of: "−", with: "-")
            var out = n + (isOne(n) ? " degree" : " degrees")
            if m.range(at: 2).location != NSNotFound {
                out += s.substring(with: m.range(at: 2)).uppercased() == "C" ? " Celsius" : " Fahrenheit"
            }
            return out
        })
        // fix3's heights and inch marks, until the measures pass reads them first.
        rules += MeasuresPass.legacyRules(british: british)
        // m/s², square and cubic units ("50 km²"), before other powers.
        rules += UnitRules.areaRules(british: british)
        // Other powers: "x²" → "x squared", "mc²", "(a+b)³" (it was "x two"). Not after a longer
        // word, where it's a footnote ("the study² found").
        rules.append(Rule(#"(?:(?<![\p{L}\d])(\p{L}{1,2}|\d{1,3})|(\)))([²³])(?![\d²³])"#) { m, s in
            let base = s.substring(with: m.range(at: m.range(at: 1).location != NSNotFound ? 1 : 2))
            return base + (s.substring(with: m.range(at: 3)) == "²" ? " squared" : " cubed")
        })
        // H:MM:SS, "5m ago" and "1h 30m", then "~": before the unit rules, clock and Ranges.
        rules += DateRules.durations(british: british)
        rules += ShorthandRules.tildes(british: british)
        // "a 10-km run", "½ tsp": before the range below and the fraction rules.
        rules += UnitRules.modifiers(british: british)
        // A range written with its unit on both numbers: "5.25%-5.5%", "0.5mm-1.5mm", "1.5x-2.5x"
        // → "5.25% to 5.5%". The second number lost its decimal point and the "to".
        // (The custom lexicon may have put a space before a unit it knows: "0.5 mm-1.5 mm".)
        rules.append(Rule(#"(?<![\p{L}\d\-–−+./:#)])(\d+(?:[.,]\d+)*)(\s?)(%|[xX×]|[a-zA-Zμ]{1,4})\s?[-–]\s?(\d+(?:[.,]\d+)*)\2\3(?![\p{L}\d])"#) { m, s in
            let unit = s.substring(with: m.range(at: 2)) + s.substring(with: m.range(at: 3))
            return "\(s.substring(with: m.range(at: 1)))\(unit) to \(s.substring(with: m.range(at: 4)))\(unit)"
        })
        // Conditional units, `units`, glued units, then single letters: before Ranges.
        rules += UnitRules.unitRules(british: british)
        // ISO and written dates, weekdays, centuries: before Ranges, clock and fractions.
        rules += DateRules.calendarDates(british: british)
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
        // "Jan 5" and "Feb.".
        rules += DateRules.monthDays(british: british)
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
        // Abbreviations, est. and circa.
        rules += ShorthandRules.abbreviationRules(british: british)
        // The title and "WW2" rules, until the titles and Roman passes read them first.
        rules += TitlePass.legacyRules(british: british)
        rules += RomanPass.legacyRules(british: british)
        return rules
    }

    static let marked = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(/[^)]*/\)"#)

    /// A name next: a capitalised word that isn't a usual sentence opener.
    static let namePattern = #"(?=\s+(?!(?:"# + Tokenizer.sentenceStarters.map(NSRegularExpression.escapedPattern).joined(separator: "|") + #")(?![\p{L}'’]))\p{Lu})"#

    /// - Parameter skippingMarkedSpans: leave [text](/phonemes/) spans (pronunciations
    ///   already fixed by the custom lexicon) untouched, except a unit right after a number.
    static func normalize(_ text: String, skippingMarkedSpans: Bool, british: Bool) -> String {
        guard skippingMarkedSpans else { return normalize(text, british: british) }
        let text = AddressPass.readStreets(RomanPass.readAfterUnshout(readArrows(text)))
        let ns = text as NSString
        let marks = marked.matches(in: text, range: NSRange(location: 0, length: ns.length))
        // The rules run on one stretch between marks at a time; the view shows them the rest.
        let view = LabelView(text, marks: marks)
        var out = ""
        var plain = ""
        var last = 0
        var start = 0  // where `plain` starts in `view.reading`
        for m in marks {
            plain += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            last = NSMaxRange(m.range)
            let term = ns.substring(with: m.range(at: 1))
            if UnitRules.readsMarkedTerm(term, after: plain) {
                plain += term
                continue
            }
            let stretch = NSRange(location: start, length: (plain as NSString).length)
            out += applyRules(plain, british: british, in: RuleContext(view, stretch)) + ns.substring(with: m.range)
            start = NSMaxRange(stretch) + (term as NSString).length
            plain = ""
        }
        plain += ns.substring(from: last)
        return out + applyRules(plain, british: british, in: RuleContext(view, NSRange(location: start, length: (plain as NSString).length)))
    }

    private static let link = try! NSRegularExpression(pattern: #"!?\[([^\]]*)\]\([^)]*\)"#)

    /// Markdown links in the text itself ("[Getting started](/guide/start/)") → their label.
    /// Runs before the custom lexicon marks its terms in the same syntax, so only those marks
    /// set a pronunciation: a link's path never reaches the voice as letters.
    static func linkLabels(_ text: String) -> String {
        link.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "$1")
    }

    static func normalize(_ text: String, british: Bool) -> String {
        let text = AddressPass.readStreets(RomanPass.readAfterUnshout(readArrows(text)))
        return applyRules(text, british: british, in: RuleContext(text))
    }

    /// The voice's rules, in order, on text whose arrows, numerals and "St." have been read.
    private static func applyRules(_ text: String, british: Bool, in context: RuleContext) -> String {
        apply(british ? rulesGB : rulesUS, to: text, in: context)
    }

    /// `rules`, in order, each on what the one before left. A Core pass can run its own rules
    /// on the raw text with it.
    static func apply(_ rules: [Rule], to text: String, in context: RuleContext? = nil) -> String {
        let context = context ?? RuleContext(text)
        var s = text
        for rule in rules {
            let ns = s as NSString
            let matches = rule.regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            var out = ""
            var last = 0
            for m in matches {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                out += rule.replace(m, ns, context)
                last = NSMaxRange(m.range)
            }
            out += ns.substring(from: last)
            s = out
        }
        return s
    }
}
