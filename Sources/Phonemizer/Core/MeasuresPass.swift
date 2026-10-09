import Foundation

/// Heights, sizes and multipliers (Core readings, FIN-889; area "dimensions"): feet and inches
/// ("6'2\"", "6 ft 2 in"), inch and foot marks, sizes with x or × ("2x4", "10 x 12 ft") and x as
/// a multiplier ("3x faster", "3x champion", "Combo x2!").
///
/// The pass runs last before the custom lexicon (its "10x", "1X" and "X" keys), after the phone
/// pass (so a phone extension "x 214" is already read) and after money: an operand with a
/// currency next to it (`CurrencyNames`) is left alone. It owns ft, in. and the marks; units'
/// rules leave those out.
///
/// It writes digits and words ("6 foot 2", "1280 by 7 20", "3 times faster", "27 inch") and
/// leaves the numbers to the number reader. Quotes are the hazard: a straight " or ' after a
/// number is far more often a closing quote than a mark ("Give me 5", 'Plan 9' long before),
/// so a mark counts only where the quotes on its line say it can't be one (`Lines`).
enum MeasuresPass {
    typealias Rule = TextNormalizer.Rule

    /// The measures pass: in `Phonemizer.phonemize` after the shorthand pass and before the
    /// custom lexicon, only when normalizing. Its words go through `ShoutedCasing`. The rules
    /// run in this order, each on what the one before wrote: abbreviated feet and inches, marked
    /// feet and inches, a hyphenated unit, "N in." before an adjective, sizes, single marks,
    /// title counts, multipliers, game multipliers.
    static func apply(_ text: String, british: Bool) -> String {
        // Every reading here starts from a digit or a vulgar fraction ("¼\"").
        guard text.utf16.contains(where: { $0 >= 0x30 && $0 <= 0x39 || (0xBC...0xBE).contains($0) || (0x2153...0x215E).contains($0) })
        else { return text }
        var s = text
        s = rewrite(s, abbreviatedHeight, readAbbreviatedHeight)
        s = rewrite(s, markedHeight, readMarkedHeight)
        s = rewrite(s, hyphenatedUnit, readHyphenatedUnit)
        s = rewrite(s, inchesBeforeAdjective, readInchesBeforeAdjective)
        s = rewrite(s, gluedInches, readGluedInches)
        s = rewrite(s, jeansSize) { m, s, _ in s.substring(with: m.range(at: 1)) + " W by " + s.substring(with: m.range(at: 2)) + " L" }
        s = rewrite(s, size, readSize)
        s = rewrite(s, singleMark, readSingleMark)
        s = rewrite(s, fractionInch, readFractionInch)
        s = rewrite(s, statedHeight, readStatedHeight)
        s = rewrite(s, platinum) { m, s, _ in
            let n = s.substring(with: m.range(at: 1))
            return ["2": "double", "3": "triple", "4": "quadruple"][n] ?? n + " times"
        }
        s = rewrite(s, titleCount) { m, s, _ in s.substring(with: m.range(at: 1)) + " time" }
        s = rewrite(s, multiplier) { m, s, _ in s.substring(with: m.range(at: 1)) + " times" }
        s = rewrite(s, listCount) { m, s, _ in s.substring(with: m.range(at: 1)) + " " }
        s = rewrite(s, settledMultiplier, readSettledMultiplier)
        s = rewrite(s, statusClass) { m, s, _ in s.substring(with: m.range(at: 1)) + " XX" }
        s = rewrite(s, repeatCount) { m, s, _ in "times " + s.substring(with: m.range(at: 1)) }
        s = rewrite(s, gameMultiplier, readGameMultiplier)
        s = rewrite(s, receiptCount, readReceiptCount)
        return s
    }

    /// fix3/reading's height rule and three inch rules ran here, in TextNormalizer's list after
    /// Temperatures. The pass reads all of them first, with guards those rules lacked: they read
    /// "3'45\"" as "three foot forty-five", "40°26′46″N" as feet and inches, "Kane 9' 2-0" as
    /// "nine foot two to zero" and "6'0\"" as "six foot zero".
    static func legacyRules(british: Bool) -> [Rule] {
        []
    }

    /// What a rule reads a match as, or nil to leave it as written. `Lines` answers questions
    /// about the match's line and sentence; ask it in order of position.
    private typealias Reading = (NSTextCheckingResult, NSString, inout Lines) -> String?

    /// `regex`'s matches in `text`, read by `read`. The words go in the case of their sentence
    /// (`Lines.cased`).
    private static func rewrite(_ text: String, _ regex: NSRegularExpression, _ read: Reading) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var lines = Lines(ns)
        var out = "", last = 0, changed = false
        for m in matches {
            guard let words = read(m, ns, &lines) else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += lines.cased(words, at: m.range.location)
            last = NSMaxRange(m.range)
            changed = true
        }
        guard changed else { return text }
        return out + ns.substring(from: last)
    }

    // MARK: Feet and inches

    /// Words after which inches end a height ("5 ft 6 in tall", "6ft 2 and"): before any other
    /// word, a spaced "in" is the preposition ("5 ft 6 in heels").
    private static let adjectives = "tall|high|long|wide|deep|thick|square|across"

    /// "6 ft 2 in", "6ft 2in", "6ft2", "5ft 10", "5 ft. 4 in.". Only lower-case ft and in: "FT" is
    /// the Financial Times and "Ft." Fort.
    private static let abbreviatedHeight = regex(#"(?<![\p{L}\p{N}.,])(\d{1,2})[ \t]?ft\.?[ \t]?(\d|1[01])(?!\d|\.\d)([ \t]?in\.?(?!\p{L}))?"#)
    /// After inches with no "in": the words that let them end the height ("6 ft 2 with", not
    /// "6 ft 2 boards").
    private static let afterBareInches = regex(#"[ \t]+(?:in|and|or|but|with|without|wearing|barefoot)\b"#)
    /// After a spaced "in" with no period: the words that make it "inches", not "in".
    private static let afterSpacedIn = regex(#"[ \t]+(?:and|or|but|"# + adjectives + #")\b"#)

    private static func readAbbreviatedHeight(_ m: NSTextCheckingResult, _ s: NSString, _ lines: inout Lines) -> String? {
        let height = feetAndInches(s.substring(with: m.range(at: 1)), s.substring(with: m.range(at: 2)))
        let end = NSMaxRange(m.range)
        guard m.range(at: 3).location != NSNotFound else {
            return endsPhrase(s, at: end) || follows(afterBareInches, in: s, at: end) ? height : nil
        }
        let inch = s.substring(with: m.range(at: 3))
        // "4 in." is inches anywhere; its period may also be the full stop ("He is 6 ft 2 in.").
        if inch.hasSuffix(".") { return height + FullStop.kept(before: window(s, after: end), next: .capital) }
        // Glued ("2in") it's always inches.
        guard inch.first == " " || inch.first == "\t" else { return height }
        if endsPhrase(s, at: end) || follows(afterSpacedIn, in: s, at: end) { return height }
        // After a determiner the height describes the noun after it: "A 6 ft 4 in centre-back".
        if let before = previousToken(s, before: m.range.location), determiners.contains(before.word.lowercased()) { return height }
        return height + inch
    }

    /// "6'2\"", "5′11″", "6’2”", "5' 11\"", "6'2", "6'0\"": a number, a feet mark, inches up to
    /// 11 (with decimals), an optional inch mark. Not after a degree sign, prime or quote mark
    /// (coordinates: "40°26′46″N"), nor a digit, separator or "#" ("CHF 1'250").
    private static let markedHeight = regex(##"(?<![\p{L}\p{N}.,°′'’‘#"“])(\d{1,2})['’′]([ \t]?)(\d|1[01])(\.\d+)?(?!\d)(''|’’|["”″])?"##)
    /// A duration, a score or a time after inches with no mark ("4'05", "Kane 9' 2-0").
    private static let rangeAfter = regex(#"\s*[-–:/]\s*\d"#)

    private static func readMarkedHeight(_ m: NSTextCheckingResult, _ s: NSString, _ lines: inout Lines) -> String? {
        let feet = s.substring(with: m.range(at: 1))
        let end = NSMaxRange(m.range)
        if m.range(at: 5).location != NSNotFound {
            if end < s.length, isLetterOrNumber(s.character(at: end)) { return nil }
        } else {
            // With no inch mark it could be a duration or a quote: one-digit feet only, inches
            // glued to the mark (or spaced only before punctuation), and nothing after them
            // but a space or punctuation.
            guard feet.count == 1, feet != "0" else { return nil }
            if m.range(at: 2).length > 0, !endsPhrase(s, at: end) { return nil }
            if end < s.length {
                let c = s.character(at: end)
                guard isSpace(c) || ",.;:!?)".utf16.contains(c) else { return nil }
            }
            if follows(rangeAfter, in: s, at: end) { return nil }
        }
        let decimals = m.range(at: 4).location == NSNotFound ? "" : s.substring(with: m.range(at: 4))
        return feetAndInches(feet, s.substring(with: m.range(at: 3)) + decimals)
    }

    /// "F foot M", or "F foot" for zero inches ("6'0\"" is "six foot").
    private static func feetAndInches(_ feet: String, _ inches: String) -> String {
        feet + " foot" + (inches == "0" ? "" : " " + inches)
    }

    /// "a 10-ft pole", "a 12-in. skillet": the hyphen makes it a modifier, always singular. "in"
    /// counts only with its period, so "2-in-1" stays.
    private static let hyphenatedUnit = regex(#"(?<![\p{L}\p{N}.,])(\d+(?:\.\d+)?)-(ft\.?|in\.)(?=\s+[\p{L}\p{N}])"#)

    private static func readHyphenatedUnit(_ m: NSTextCheckingResult, _ s: NSString, _ lines: inout Lines) -> String? {
        s.substring(with: m.range(at: 1)) + (s.substring(with: m.range(at: 2)).hasPrefix("ft") ? " foot" : " inch")
    }

    /// "30 in. wide": with its period and before a dimension, "in." is inches. Without the
    /// period or before any other word it stays a preposition ("6 in the morning", "6 in 10").
    private static let inchesBeforeAdjective = regex(#"(?<![\p{L}\p{N}.,])(\d+(?:\.\d+)?)[ \t]?in\.(?=\s+(?:"# + adjectives + #"|in diameter)\b)"#)

    private static func readInchesBeforeAdjective(_ m: NSTextCheckingResult, _ s: NSString, _ lines: inout Lines) -> String? {
        let n = s.substring(with: m.range(at: 1))
        // A fraction's denominator ("3/4 in. thick"): "three quarters of an inch thick".
        if m.range.location > 0, s.character(at: m.range.location - 1) == 0x2F { return n + " of an inch" }
        return n + (TextNormalizer.isOne(n) ? " inch" : " inches")
    }

    /// "18in of snow", "a 24in monitor": "in" glued to a number is inches (it was the word
    /// "in"), and spaced before another "in" ("10 in in parts of Texas").
    private static let gluedInches = regex(#"(?<![\p{L}\p{N}.,])(\d+(?:\.\d+)?)(?:in|[ \t]in(?=[ \t]+in\b))(?![\p{L}\p{N}])"#)

    private static func readGluedInches(_ m: NSTextCheckingResult, _ s: NSString, _ lines: inout Lines) -> String? {
        let n = s.substring(with: m.range(at: 1))
        return n + (isAttributive(s, m.range.location, NSMaxRange(m.range), number: n, &lines) ? " inch" : " inches")
    }

    /// A pair of jeans: "32W x 30L" → "32 W by 30 L" (the x was "ex").
    private static let jeansSize = regex(#"(?<![\p{L}\p{N}.,])(\d{2})W[ \t]?[xX×][ \t]?(\d{2})L(?![\p{L}\p{N}])"#)

    // MARK: Sizes

    private static let number = #"\d+(?:,\d{3})*(?:\.\d+)?"#
    /// A length after an operand: a mark, or (after an optional space) a written unit. A bare
    /// "in" only where it can't be the preposition ("4 x 6 in", "2 x 4 in the garage" stays);
    /// "pt" is never one (font points or pints). No letter follows it but a glued separator
    /// ("a 4'x8' sheet").
    private static let lengthUnit = #"(?:''|’’|["”″'’′]|[ \t]?(?:mm|cm|km|m|in\.|in(?=$|[,;:!?)]|\.|[ \t][xX×][ \t])|ft\.|ft|yd|px|µm|μm))(?!(?![xX]\d)\p{L})"#
    /// x, X or ×, glued on both sides or with one space on each.
    private static let separator = #"(?:[xX×]|[ \t][xX×][ \t])"#
    /// "2x4", "1920×1080", "10 x 12 ft", "35 cm x 48 cm", "9\" x 13\" x 2\"", "2x4x8", "2x4s".
    /// Not inside a name, a number, a path, a handle, a range or a quote ("_1920x1080", "#2x4").
    private static let size = regex(##"(?<![\p{L}\p{N}.,_@#/\-–'’‘"“])("## + number + ")(" + lengthUnit + ")?((?:" + separator + number + "(?:"
                                    + lengthUnit + ")?)+)(s?)")
    /// One separator and the operand after it, inside a size's group 3.
    private static let sizePart = regex("(" + separator + ")(" + number + ")(" + lengthUnit + ")?")

    /// After a size, what makes it something else: a word or number glued on ("8x7B"), a file
    /// name ("1920x1080.png"), a time or range ("2x4:30", "3x3-1"), a power ("3x3^2", "2x2²").
    private static let gluedAfterSize = regex(#"[\p{L}\p{N}]|\.[\p{L}\p{N}]|:\d|\^|[-–]\d"#)
    /// A weight or volume after the last operand: a count of packs ("2 x 400g").
    private static let weightAfter = regex(#"[ \t]?(?:g|kg|mg|ml|mL|l|L|oz|lbs?|tbsp|tsp)\b"#)
    /// A time after the last operand: a count of shifts ("3 x 12 hour shifts").
    private static let timeAfter = regex(#"[ \t]*-?[ \t]*(?:hours?|hrs?|minutes?|mins?|seconds?|secs?|days?|nights?|weeks?|months?|years?|shifts?|sessions?)\b"#)
    /// A plural container within three words: a count, not a size ("2 x 20cm round cake tins").
    private static let containerAfter = regex(#"(?:[ \t]+\S+){0,2}?[ \t]+(?:tins|pans|trays|dishes|cans|jars|packs|ramekins|moulds|molds|bottles|bags|pots|boxes|cartons|tubs|tablets|capsules|sachets|pouches)\b"#)
    /// The word before a score written with x ("Brazil won 2 x 1").
    private static let scoreVerbs: Set<String> = ["won", "lost", "beat", "beats", "drew", "tied", "lead", "leads", "led", "trail",
                                                  "trails", "trailed", "score", "scored", "scores", "ended", "finished", "final"]
    /// Codes that name a currency before an amount ("USD 2 x 3").
    private static let currencyCodes: Set<String> = ["USD", "EUR", "GBP", "CAD", "AUD", "NZD", "CHF", "JPY", "CNY", "INR", "KRW",
                                                     "HKD", "SGD", "SEK", "NOK", "DKK", "MXN", "BRL", "ZAR"]
    /// A word after the last operand, for the currency test ("2 x 5 dollars", once money has read "$5").
    private static let wordAfter = regex(#"[ \t]+(\p{L}+)"#)

    /// After a size, what makes it a product: "= 56", "≈", a spaced "^", a spaced operator and
    /// a number, or "equals" and a number.
    private static let productAfter = regex(#"[ \t]*[=≈^]|[ \t]+[-+−÷/][ \t]+\d|[ \t]+equals[ \t]+\d"#)
    /// "is", "makes" or "gives" and a number: a product only when the number is the product
    /// ("3 x 3 is 9"; "a 2x4 is 1.5 x 3.5" is a size).
    private static let resultAfter = regex(#"[ \t]+(?:is|makes|gives)[ \t]+("# + number + #")(?!\d|\.\d)"#)
    /// Before a size, what makes it a product: "=" or a spaced operator ("10 - 2 x 3").
    private static let operatorBefore = regex(#"(?:=|[ \t][-+−÷/])[ \t]*$"#)
    /// A question or instruction right before the first operand ("What is 7 x 8?", "Calculate
    /// 12 x 12"). Not at the start of the clause: "What is a 2x4?" and "Calculate the area of a
    /// 10 x 12 room" are sizes. "multiply" isn't one: "multiply twelve by twelve" is English.
    private static let questionBefore = regex(#"(?<![^\s(])(?:what[ \t]+is|what['’]s|how[ \t]+much[ \t]+is|calculate|compute)[ \t]+$"#,
                                              options: .caseInsensitive)

    private static func readSize(_ m: NSTextCheckingResult, _ s: NSString, _ lines: inout Lines) -> String? {
        let start = m.range.location, end = NSMaxRange(m.range)
        let plural = m.range(at: 4).length > 0
        // The operands, each with its unit and where that unit is, and the separators.
        var operands = [Operand(s.substring(with: m.range(at: 1)), m.range(at: 2), in: s)]
        var spaced = false, firstGlued = true
        for (i, p) in sizePart.matches(in: s as String, options: .withTransparentBounds, range: m.range(at: 3)).enumerated() {
            let sep = s.substring(with: p.range(at: 1))
            if sep.count > 1 { spaced = true }
            if i == 0 { firstGlued = sep.count == 1 && sep != "×" }
            operands.append(Operand(s.substring(with: p.range(at: 2)), p.range(at: 3), in: s))
        }
        guard operands.count > 1 else { return nil }
        let units = operands.map(\.unit)

        // Boundaries: what follows can make it a name, a file, a time or a power.
        if end < s.length {
            if plural ? isLetterOrNumber(s.character(at: end)) : follows(gluedAfterSize, in: s, at: end) { return nil }
        }
        // Hex ("0x1F", "0x10").
        if firstGlued, operands[0].number == "0" { return nil }
        // A count of things that aren't lengths: weights, volumes, times, containers, scores.
        if follows(weightAfter, in: s, at: end) || follows(timeAfter, in: s, at: end) { return nil }
        if operands.count == 2, spaced, units[0].isEmpty, !operands[0].number.contains("."),
           let n = Int(operands[0].number.replacingOccurrences(of: ",", with: "")), n <= 12,
           follows(containerAfter, in: s, at: end) { return nil }
        if operands.count == 2, spaced, units.allSatisfy(\.isEmpty),
           let before = previousToken(s, before: start), scoreVerbs.contains(before.word.lowercased()) { return nil }
        // Money: "$2 x 3", "USD 2 x 3", "2 x 5 dollars" (the money pass has read "$5"), unless an
        // "=" after the money makes it a sum on a receipt ("3 x $14 = $42": three times fourteen
        // dollars).
        if isCurrencyBefore(s, start) { return nil }
        if units.last!.isEmpty, let w = match(wordAfter, in: s, at: end),
           CurrencyNames.words.contains(s.substring(with: w.range(at: 1)).lowercased()) {
            guard operands.count == 2, follows(productAfter, in: s, at: NSMaxRange(w.range)) else { return nil }
            return operands.map(\.number).joined(separator: " times ")
        }
        // Algebra: an x next to an operator on the line ("Factor 3x2 + 5x + 2").
        if lines.isAlgebra(at: start) { return nil }
        // An inch mark that is really a closing quote ("Type \"9 x 12\" in the box").
        for o in operands where o.unit == "\"" || o.unit == "”" {
            if !lines.isInchMark(at: o.unitLocation) { return nil }
        }

        let before = window(s, before: start)
        if follows(productAfter, in: s, at: end) || matches(operatorBefore, before) || matches(questionBefore, before)
            || isResult(s, after: end, of: operands) {
            return operands.map { $0.number + $0.written }.joined(separator: " times ") + (plural ? "s" : "")
        }

        // A size: each separator is "by".
        let singular = isAttributive(s, start, end, number: "", &lines)
        let marks = units.filter { !$0.isEmpty }
        let kinds = Set(marks.compactMap { unitWords[$0]?.singular })
        if !marks.isEmpty, marks.allSatisfy(Self.marks.contains), kinds.count == 1, !units.last!.isEmpty {
            // Marks of one kind: the unit once, after the last number ("12 by 14 feet", "9 by 13 by 2 inch pan").
            let words = unitWords[units.last!]!
            return operands.map { halves($0.number) }.joined(separator: " by ") + " " + (singular ? words.singular : words.plural)
                + (plural ? "s" : "")
        }
        // Pixels: no unit but px and every side 100 or more, read in pairs as people say
        // resolutions ("1280 by 7 20").
        let pixels = units.allSatisfy { $0.isEmpty || $0 == "px" }
            && operands.allSatisfy { $0.number.allSatisfy(\.isASCII) && $0.number.allSatisfy(\.isNumber) && Int($0.number).map { $0 >= 100 } == true }
        var words: [String] = []
        for (i, o) in operands.enumerated() {
            var w = pixels ? pairs(o.number) : halves(o.number)
            if let unit = unitWords[o.unit] {
                w += " " + (singular || TextNormalizer.isOne(o.number) ? unit.singular : unit.plural)
                // "4 x 6 in." and "10 x 12 ft." may end the sentence with their period.
                if i == operands.count - 1, o.written.hasSuffix(".") {
                    w += FullStop.kept(before: window(s, after: end), next: .capital)
                }
            }
            words.append(w)
        }
        return words.joined(separator: " by ") + (plural ? "s" : "")
    }

    /// One side of a size: its number and unit ("12", "'"; "35", "cm").
    private struct Operand {
        let number: String
        /// The unit as a key of `unitWords` (no space or period), or "".
        let unit: String
        /// The unit as written.
        let written: String
        let unitLocation: Int

        init(_ number: String, _ unitRange: NSRange, in s: NSString) {
            self.number = number
            if unitRange.location == NSNotFound {
                unit = ""
                written = ""
                unitLocation = NSNotFound
            } else {
                written = s.substring(with: unitRange)
                let trimmed = written.trimmingCharacters(in: .whitespaces)
                unit = trimmed.count > 1 && trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
                unitLocation = unitRange.location + (written as NSString).length - (trimmed as NSString).length
            }
        }
    }

    private static let marks: Set<String> = ["'", "’", "′", "\"", "”", "″", "''", "’’"]
    /// The unit words this pass writes itself, singular and plural: the units rule is always
    /// plural, and "a 20 x 30cm tin" is a "centimeter tin".
    private static let unitWords: [String: (singular: String, plural: String)] = [
        "mm": ("millimeter", "millimeters"), "cm": ("centimeter", "centimeters"), "m": ("meter", "meters"),
        "km": ("kilometer", "kilometers"), "in": ("inch", "inches"), "ft": ("foot", "feet"), "yd": ("yard", "yards"),
        "px": ("pixel", "pixels"), "µm": ("micrometer", "micrometers"), "μm": ("micrometer", "micrometers"),
        "'": ("foot", "feet"), "’": ("foot", "feet"), "′": ("foot", "feet"),
        "\"": ("inch", "inches"), "”": ("inch", "inches"), "″": ("inch", "inches"), "''": ("inch", "inches"), "’’": ("inch", "inches"),
    ]

    /// "8.5" in a size is "8 and a half" ("eight and a half by eleven paper").
    private static func halves(_ n: String) -> String {
        guard n.hasSuffix(".5"), let first = n.first, first != "0", n.dropLast(2).allSatisfy(\.isNumber) else { return n }
        return String(n.dropLast(2)) + " and a half"
    }

    /// A three-digit side of a resolution as a pair ("7 20", "2 50", "1 oh 5"); four digits the
    /// number reader already pairs ("1920").
    private static func pairs(_ n: String) -> String {
        let d = Array(n)
        guard d.count == 3, !n.hasSuffix("00") else { return n }
        return d[1] == "0" ? "\(d[0]) oh \(d[2])" : "\(d[0]) \(d[1])\(d[2])"
    }

    /// Whether "is", "makes" or "gives" after a size of bare numbers states their product.
    private static func isResult(_ s: NSString, after end: Int, of operands: [Operand]) -> Bool {
        guard operands.allSatisfy({ $0.unit.isEmpty }), let r = match(resultAfter, in: s, at: end),
              let result = Double(s.substring(with: r.range(at: 1)).replacingOccurrences(of: ",", with: "")) else { return false }
        var product = 1.0
        for o in operands {
            guard let v = Double(o.number.replacingOccurrences(of: ",", with: "")) else { return false }
            product *= v
        }
        return abs(product - result) < 1e-9
    }

    /// A currency sign, an "X$" prefix or a currency code right before `location`.
    private static func isCurrencyBefore(_ s: NSString, _ location: Int) -> Bool {
        var i = location
        while i > 0, s.character(at: i - 1) == 0x20 { i -= 1 }
        guard i > 0 else { return false }
        if let c = Unicode.Scalar(s.character(at: i - 1)), CurrencyNames.symbols.contains(Character(c)) { return true }
        return previousToken(s, before: location).map { currencyCodes.contains($0.word) } ?? false
    }

    // MARK: Single marks

    /// "27\" monitor", "6′ fence", "8' high", "6-8\" of snow": a number and a mark. Not after a
    /// degree sign or prime (coordinates), "#", a separator, or an opening quote ("'6' key").
    private static let singleMark = regex(##"(?<![\p{L}\p{N}.,°′#"“'‘])(\d+(?:\.\d+)?)(''|’’|["”″'’′])"##)
    /// After a straight or curly single quote, the words that make it feet ("8' high"):
    /// anywhere else it's a quote, a minute or a plural ("Kane 9'", "the 80's").
    private static let afterFootMark = regex(#"[ \t]?(?:"# + adjectives + #"|away|apart|below|above)\b"#)
    private static let wordNext = regex(#"[ \t]+\p{L}"#)

    /// A vulgar fraction and an inch mark: "Roll the dough ¼\" thick" → "a quarter inch thick".
    private static let fractionInch = regex(##"(?<![\p{L}\p{N}.,/])([½¼¾⅓⅔⅛⅜⅝⅞])(["”″])"##)
    private static let fractionInchWords: [String: (alone: String, after: String)] = [
        "½": ("a half", "half"), "¼": ("a quarter", "quarter"), "¾": ("three quarter", "three quarter"),
        "⅓": ("a third", "third"), "⅔": ("two thirds", "two thirds"), "⅛": ("an eighth", "eighth"),
        "⅜": ("three eighths", "three eighths"), "⅝": ("five eighths", "five eighths"), "⅞": ("seven eighths", "seven eighths"),
    ]

    private static func readFractionInch(_ m: NSTextCheckingResult, _ s: NSString, _ lines: inout Lines) -> String? {
        if NSMaxRange(m.range) < s.length, isLetterOrNumber(s.character(at: NSMaxRange(m.range))) { return nil }
        guard lines.isInchMark(at: m.range(at: 2).location), let words = fractionInchWords[s.substring(with: m.range(at: 1))] else { return nil }
        // After a determiner the article is already there: "a ½\" bolt" is "a half inch bolt".
        let determined = previousToken(s, before: m.range.location).map { determiners.contains($0.word.lowercased()) } == true
        return (determined ? words.after : words.alone) + " inch"
    }

    private static func readSingleMark(_ m: NSTextCheckingResult, _ s: NSString, _ lines: inout Lines) -> String? {
        let end = NSMaxRange(m.range)
        if end < s.length, isLetterOrNumber(s.character(at: end)) { return nil }
        let mark = s.substring(with: m.range(at: 2))
        let at = m.range(at: 2).location
        switch mark {
        case "\"", "”", "″":
            guard lines.isInchMark(at: at) else { return nil }
        case "'", "’":
            // Feet before an adjective ("8' high"), or before the noun they measure after a
            // determiner ("An 8' Christmas tree", "The 10' ceilings", "a 12' ladder").
            let measured = previousToken(s, before: m.range.location).map { determiners.contains($0.word.lowercased()) } == true
                && follows(wordNext, in: s, at: end)
            guard follows(afterFootMark, in: s, at: end) || measured, !lines.opensSingleQuote(before: at) else { return nil }
        default: break
        }
        let n = s.substring(with: m.range(at: 1))
        let words = unitWords[mark]!
        return n + " " + (isAttributive(s, m.range.location, end, number: n, &lines) ? words.singular : words.plural)
    }

    // MARK: Multipliers

    /// "3x champion", "4x Grammy winner", "2X Super Bowl MVP": a closed list of titles, so "3x
    /// player" keeps "ex".
    private static let titleCount = regex(#"(?<![\p{L}\p{N}.,_@#/])(\d{1,2})[xX](?=\s+(?:(?!(?i:more|less|fewer|as|the|than|a|an)\b)\p{L}[\w-]*\s+){0,2}(?i:champions?|champ|winners?|medall?ists?|Olympians?|All-Stars?|MVP|finalists?|nominees?|laureates?|Bowlers?|All-Pros?|All-Americans?|founders?|entrepreneurs?|winners?)\b)"#)
    /// "2x platinum", "3x gold": a record's certification, "double platinum", "triple gold".
    private static let platinum = regex(#"(?<![\p{L}\p{N}.,_@#/])(\d{1,2})[xX](?=\s+(?i:platinum|diamond|gold|silver)\b)"#)
    /// A count in a list of contents: "In the box: 1x charger, 2x USB cables", "• 2x pillows":
    /// the x is silent. Only after a colon, comma, semicolon, bullet, dash or the start of a
    /// line, and before a word ("2x USB-C" in a sentence keeps "ex").
    /// Not before "the" or a comparison ("2x the fun") or "and" ("Sizes 1X, 2X and 3X").
    private static let listCount = regex(#"(?:^|(?<=[:;,•·\-–][ \t])|(?<=[:;,•·][ \t]{2}))(\d{1,2})[xX×][ \t]+(?=\p{L})(?!(?i:the|as|and|or|more|less)\b)"#, options: .anchorsMatchLines)
    /// HTTP status classes: "5xx errors", "4XX" → "five XX".
    private static let statusClass = regex(#"(?<![\p{L}\p{N}])([1-5])(?:xx|XX)(?![\p{L}\p{N}])"#)
    /// "Repeat x2": times two, after a verb of repeating.
    private static let repeatCount = regex(#"(?<=\b(?i:repeat|repeats|repeated|do|does|did)[ \t])x(\d{1,2})(?![\p{L}\p{N}])"#)

    /// A multiplier the sentence settles as "times" though no comparison follows it: "Revenue
    /// grew 1.5x", "outraised Democrats nearly 2x", "Retry up to 3x", "2x the budget", "1.5x
    /// what it was", "2x face value", "won Wimbledon 8x". Payam's "2x speed" (a noun after it) and
    /// "Set it to 2x" (a player's speed) keep "ex": the noun rule above and "to"/"at" leave them.
    private static let settledMultiplier = regex(#"(?<![\p{L}\p{N}.,_@#/])(\d+(?:\.\d+)?)[xX×](?![\p{L}\p{N}])"#)
    /// After "the": whatever is multiplied ("2x the budget", "1.25x the usual rate", "2x the fun",
    /// "Earn 2x the points").
    private static let theQuantity = regex(#"\s+the\s+\p{L}"#)
    private static let otherQuantity = regex(#"\s+(?:what\b|face\s+value\b|that\s+of\b)"#)
    /// Words before a lone multiplier that make it "times": growth and repetition, and hedges.
    private static let multiplierCues: Set<String> = [
        "grew", "grow", "grows", "growing", "rose", "risen", "rise", "rises", "increased", "increase", "increases", "jumped",
        "climbed", "surged", "soared", "expanded", "multiplied", "outraised", "outspent", "outsold", "outperformed",
        "outpaced", "outnumbered", "outgrew", "won", "wins", "retry", "retried", "repeated", "tried", "called", "told",
        "asked", "visited", "happened", "ran", "nearly", "almost", "roughly", "approximately", "only", "up", "about",
        "around", "over",
    ]
    /// What may follow a lone multiplier read as "times": the end, punctuation, a little word
    /// or an acronym ("YoY").
    private static let afterLoneMultiplier = regex(#"(?:\s*$|\s*[.,;:!?)]|\s+(?:in|between|since|than|this|last|then|and|or|from|before|after|during|year|YoY|QoQ|MoM|over)\b)"#)

    private static func readSettledMultiplier(_ m: NSTextCheckingResult, _ s: NSString, _ lines: inout Lines) -> String? {
        let n = s.substring(with: m.range(at: 1))
        let end = NSMaxRange(m.range)
        if isCurrencyBefore(s, m.range.location) { return nil }
        // The words before it, nearest first, past a hedge ("nearly", "up to"). A speed is set
        // "to" or watched "at" a multiple ("I watch lectures at 2x the whole time").
        let before = window(s, before: m.range.location).lowercased()
        let words = before.split(whereSeparator: { !$0.isLetter }).suffix(4).reversed().map(String.init)
        if let first = words.first, ["to", "at", "set", "speed", "zoom"].contains(first), !(first == "to" && words.dropFirst().first == "up") {
            return nil
        }
        if follows(theQuantity, in: s, at: end) || follows(otherQuantity, in: s, at: end) { return n + " times" }
        guard follows(afterLoneMultiplier, in: s, at: end), words.first != nil else { return nil }
        return words.prefix(3).contains(where: multiplierCues.contains) ? n + " times" : nil
    }

    /// A basketball player's height with a dash: "Durant is listed at 6-10", "He's 6-7 with a
    /// 7-foot wingspan" → "6 10". Only after a word that states a height, and before the end, a
    /// comma or "and", "with", "tall".
    private static let statedHeight = regex(#"(?<=\b(?i:listed at|stands|standing|measures|measuring|he's|she's|he is|she is)[ \t])([4-7])-(\d|1[01])(?=[ \t]*(?:$|[,.;)]|(?:and|with|tall)\b))"#)

    private static func readStatedHeight(_ m: NSTextCheckingResult, _ s: NSString, _ lines: inout Lines) -> String? {
        s.substring(with: m.range(at: 1)) + " " + s.substring(with: m.range(at: 2))
    }

    /// "3x faster", "10x more", "3x as much", "4X the price", "3x over.", "3x a week", "2x daily",
    /// "3x in a row", "3x/week": x is "times" only before a comparison or a frequency. Before a
    /// noun or on its own it keeps "ex" ("2x speed", "3x zoom", "Set it to 2x"). The number may
    /// follow a range dash ("2-3x faster"), which the range rule reads.
    private static let multiplier = regex(#"(?<![\p{L}\p{N}.,_@#/])(\d+(?:\.\d+)?)[xX×](?![\p{L}\p{N}])(?=\s+(?i:"#
        + #"(?:more|less|fewer|faster|slower|quicker|bigger|smaller|larger|cheaper|higher|lower|better|worse|longer|shorter|"#
        + #"stronger|weaker|harder|easier|greater|lighter|heavier|wider|narrower|thinner|thicker|deeper|louder|quieter|"#
        + #"brighter|safer|hotter|colder|warmer|cooler|denser|closer|further|farther|older|younger|richer|sooner|smarter|"#
        + #"sharper|likelier|taller)\b"#
        + #"|as\s+(?:much|many|fast|slow|quick|quickly|big|large|small|long|high|low|likely|good|bad|often|strong|heavy|"#
        + #"expensive|cheap|far|hard|easy|bright|loud|efficient|powerful|effective)\b"#
        + #"|the\s+(?:price|cost|size|amount|number|speed|rate|power|performance|value|capacity|memory|storage|weight|"#
        + #"volume|damage|resolution|bandwidth|traffic|work|effort|money|time|length|distance|energy|output|revenue|risk)\b"#
        + #"|over(?=[,.;:!?)]|$)"#
        + #"|(?:a|an|per|each|every)\s+(?:day|week|month|year|night|hour|session|game)\b"#
        + #"|(?:daily|weekly|monthly|yearly|annually|nightly|hourly)\b"#
        + #"|in\s+a\s+row\b)"#
        + #"|/(?i:day|week|month|year|hour|night)\b)"#)

    /// "Combo x2!", "COINS x3!": a game's multiplier, only before "!" and at the start of a line
    /// or after a capitalised word. Elsewhere "x2" is a variable ("Now solve for x2!", "Plot x1
    /// against x2.") or a receipt line ("Latte x2").
    private static let gameMultiplier = regex(#"(?:^|(?<=\p{L} ))x(\d{1,2})(?=!)"#, options: .anchorsMatchLines)

    private static func readGameMultiplier(_ m: NSTextCheckingResult, _ s: NSString, _ lines: inout Lines) -> String? {
        // After a space (not at the start of a line), the word before must be capitalised.
        if m.range.location > 0, s.character(at: m.range.location - 1) == 0x20,
           let before = previousToken(s, before: m.range.location),
           let first = before.word.unicodeScalars.first, !Scalars.isUppercase(first) { return nil }
        return "times " + s.substring(with: m.range(at: 1))
    }

    /// A receipt's quantity at the end of its line, after an item's name: "Latte x2", "Muffin
    /// x1, Latte x2" → "times 2". After a lower-case word "x2" stays a variable ("Plot x1 against
    /// x2.", "solve for x2").
    private static let receiptCount = regex(#"(?<=\p{L}[ \t])x(\d{1,2})(?=[ \t]*(?:$|[,;]))"#, options: .anchorsMatchLines)

    private static func readReceiptCount(_ m: NSTextCheckingResult, _ s: NSString, _ lines: inout Lines) -> String? {
        guard let before = previousToken(s, before: m.range.location), let first = before.word.unicodeScalars.first,
              Scalars.isUppercase(first), !lines.isAlgebra(at: m.range.location) else { return nil }
        return "times " + s.substring(with: m.range(at: 1))
    }

    // MARK: Singular or plural

    private static let determiners: Set<String> = ["a", "an", "the", "this", "that", "each", "every", "one", "our", "my", "your",
                                                   "his", "her", "their", "its"]
    /// Words before which a length is a quantity ("8 feet high", "2 inches between", "4 inches
    /// overnight"), not a modifier ("a 27 inch monitor"), along with comparatives and -ly adverbs.
    private static let functionWords: Set<String> = [
        "tall", "high", "long", "wide", "deep", "thick", "square", "across", "diagonal", "diagonally", "away", "apart",
        "below", "above", "under", "over", "of", "in", "on", "at", "from", "by", "x", "and", "or", "but", "to", "with",
        "between", "each", "apiece", "per", "is", "are", "was", "were", "plus", "minus", "than", "too", "more", "less",
        "off", "into", "onto", "out", "up", "down", "past", "beyond", "around", "behind", "beneath", "along", "through",
        "for", "overnight", "today", "tonight", "yesterday", "tomorrow", "ago", "already", "now", "total", "so", "then",
        "if", "as", "when", "before", "after", "since", "until", "while", "because", "about", "instead", "short",
    ]
    private static let comparatives: Set<String> = [
        "more", "less", "fewer", "faster", "slower", "quicker", "bigger", "smaller", "larger", "cheaper", "higher", "lower",
        "better", "worse", "longer", "shorter", "stronger", "weaker", "harder", "easier", "greater", "lighter", "heavier",
        "wider", "narrower", "thinner", "thicker", "deeper", "louder", "quieter", "brighter", "safer", "hotter", "colder",
        "warmer", "cooler", "denser", "closer", "further", "farther", "older", "younger", "richer", "sooner", "smarter",
        "sharper", "likelier", "taller",
    ]
    private static let nextWord = regex(#"[ \t]+([\p{L}\p{N}][\w'’-]*)"#)

    /// Whether a length from `start` to `end` modifies the word after it, and so is singular:
    /// "a 27 inch monitor", "a 6 foot high fence", "the iMac 24 inch", "a 9 by 13 inch pan". It
    /// is a quantity, and plural, before punctuation or a function word ("It measures 27
    /// inches.", "8 feet high", "2 inches between rows"). `number` is a single length's number:
    /// 1 is always singular.
    private static func isAttributive(_ s: NSString, _ start: Int, _ end: Int, number: String, _ lines: inout Lines) -> Bool {
        if TextNormalizer.isOne(number) { return true }
        if let before = previousToken(s, before: start) {
            if determiners.contains(before.word.lowercased()) { return true }
            // A product name before it ("iMac 24\"", "MacBook Pro 16\" is heavy"), unless it opens
            // the sentence or every word is in capitals ("THE ROOM IS 12' X 14'").
            if before.word.unicodeScalars.contains(where: Scalars.isUppercase), !lines.isShouted(at: start),
               let last = before.word.unicodeScalars.last, Scalars.isLetterOrNumber(last),
               let head = before.head, !".!?:".unicodeScalars.contains(head) { return true }
        }
        guard let next = match(nextWord, in: s, at: end) else { return false }
        let w = s.substring(with: next.range(at: 1)).lowercased()
        return !(functionWords.contains(w) || comparatives.contains(w) || w.hasSuffix("ly"))
    }

    // MARK: Text helpers

    private static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// `regex` matched right at `location`, seeing the text on both sides of it.
    private static func match(_ regex: NSRegularExpression, in s: NSString, at location: Int) -> NSTextCheckingResult? {
        regex.firstMatch(in: s as String, options: [.anchored, .withTransparentBounds],
                         range: NSRange(location: location, length: s.length - location))
    }

    /// Whether `regex` matches right at `location`.
    private static func follows(_ regex: NSRegularExpression, in s: NSString, at location: Int) -> Bool {
        match(regex, in: s, at: location) != nil
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// Up to 64 UTF-16 units of `s` before `location`: enough for the words a rule looks back at,
    /// without a scan back to the start of a long text for every match.
    private static func window(_ s: NSString, before location: Int) -> String {
        let start = max(0, location - 64)
        return s.substring(with: NSRange(location: start, length: location - start))
    }

    /// Up to 64 UTF-16 units of `s` from `location`.
    private static func window(_ s: NSString, after location: Int) -> String {
        s.substring(with: NSRange(location: location, length: min(64, s.length - location)))
    }

    /// The end of the text or a line, or ", . ; : ! ? )" at `location`.
    private static func endsPhrase(_ s: NSString, at location: Int) -> Bool {
        guard location < s.length else { return true }
        let c = s.character(at: location)
        return c == 0x0A || c == 0x0D || ",.;:!?)".utf16.contains(c)
    }

    /// The run of non-space characters before `location` (past any spaces), and the last
    /// character before that run (past spaces), or nil when the run opens the text. It looks
    /// back 64 UTF-16 units at most: a longer run is no word a rule asks about, and a long run
    /// of matches with no space ("2x3;2x3;…") mustn't scan back over itself for each one.
    private static func previousToken(_ s: NSString, before location: Int) -> (word: String, head: Unicode.Scalar?)? {
        let floor = max(0, location - 64)
        var end = location
        while end > floor, isSpace(s.character(at: end - 1)) { end -= 1 }
        var start = end
        while start > floor, !isSpace(s.character(at: start - 1)) { start -= 1 }
        guard start < end, start == 0 || isSpace(s.character(at: start - 1)) else { return nil }
        var h = start
        while h > floor, isSpace(s.character(at: h - 1)) { h -= 1 }
        let head = h > 0 ? Unicode.Scalar(s.character(at: h - 1)) : nil
        return (s.substring(with: NSRange(location: start, length: end - start)), head)
    }

    fileprivate static func isSpace(_ c: unichar) -> Bool {
        Unicode.Scalar(c).map(Scalars.isSpace) ?? false
    }

    fileprivate static func isLetter(_ c: unichar) -> Bool {
        Unicode.Scalar(c).map(Scalars.isLetter) ?? false
    }

    private static func isLetterOrNumber(_ c: unichar) -> Bool {
        Unicode.Scalar(c).map(Scalars.isLetterOrNumber) ?? false
    }
}

/// What a match's line and sentence say about it, read in one pass as a rule's matches come in
/// order: the quotes opened before it, whether the line is about photography (30" is a shutter
/// speed) or algebra, and whether the sentence is written in capitals. A straight " after a
/// number is an inch mark only when the nearest " before it on its line doesn't open a quote
/// ("Give me 5\"" closes one); a ” only when every “ before it is closed; a ' only when no
/// opening ' or ‘ before it is still open ('Plan 9' long before).
private struct Lines {
    private let s: NSString
    /// Made when first asked, once a rule has a match to read.
    private var casing: ShoutedCasing?
    /// Everything before this has been read.
    private var next = 0
    private var lineStart = 0
    /// Whether the last straight " on the line so far opens a quote; nil when there's none.
    private var straightOpens: Bool?
    private var curlyOpen = 0, curlyClose = 0
    private var singleOpen = 0, singleClose = 0
    private var photo: Bool?
    private var algebra: Bool?

    init(_ s: NSString) { self.s = s }

    /// Whether the sentence holding `location` is written all in capitals (`ShoutedCasing`).
    mutating func isShouted(at location: Int) -> Bool {
        if casing == nil { casing = ShoutedCasing(s as String) }
        return casing!.isShouted(at: location)
    }

    /// `words` as a rule writes them at `location`: in capitals inside a shouted sentence, since
    /// `unshout` runs after this pass.
    mutating func cased(_ words: String, at location: Int) -> String {
        if casing == nil { casing = ShoutedCasing(s as String) }
        return casing!.cased(words, at: location)
    }

    /// A line about a camera's settings, where 30" is a shutter speed in seconds.
    private static let photography = try! NSRegularExpression(pattern: #"(?i:\b(?:shutter|exposure)\b)|\bISO\b|\bf/\d"#)
    /// An x next to an operator: algebra ("Factor 3x2 + 5x + 2", "If 3x = 12"), where no x on
    /// the line is a size. A power written flat ("x2 + 3x2 = 4") counts before an operator only
    /// when a term follows it, so a receipt's "Latte x2 - extra hot" doesn't; "2x2 = 4" isn't
    /// one, since the x of a power has no digit before it.
    private static let algebraPattern = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])\d*x(?![\p{L}\p{N}])\s*[-+=*/^]"#
        + #"|[-+=*/^]\s*(?:\d*x|x\d+)(?![\p{L}\p{N}])|(?<![\p{L}\p{N}])x\d+\s*[-+=*/^]\s*[\dx(]"#)

    /// Whether ", ” or ″ at `location` can be an inch mark rather than a closing quote.
    mutating func isInchMark(at location: Int) -> Bool {
        let c = s.character(at: location)
        if c == 0x2033 { return true }  // ″
        read(upTo: location)
        if isPhotography { return false }
        if c == 0x201D { return curlyOpen <= curlyClose }
        return straightOpens != true
    }

    /// Whether an opening ' or ‘ before `location` on its line is still open.
    mutating func opensSingleQuote(before location: Int) -> Bool {
        read(upTo: location)
        return singleOpen > singleClose
    }

    /// Whether the line holding `location` has an x next to an operator.
    mutating func isAlgebra(at location: Int) -> Bool {
        read(upTo: location)
        if let algebra { return algebra }
        let found = Self.algebraPattern.firstMatch(in: s as String, range: line) != nil
        algebra = found
        return found
    }

    private var isPhotography: Bool {
        mutating get {
            if let photo { return photo }
            let found = Self.photography.firstMatch(in: s as String, range: line) != nil
            photo = found
            return found
        }
    }

    /// The line being read, up to its break.
    private var line: NSRange {
        var end = lineStart
        while end < s.length, !Self.isBreak(s.character(at: end)) { end += 1 }
        return NSRange(location: lineStart, length: end - lineStart)
    }

    private static func isBreak(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D }

    /// Counts the quotes from where it stopped up to `location`; behind it (never, in order),
    /// it starts again from that line.
    private mutating func read(upTo location: Int) {
        if location < next {
            var start = location
            while start > 0, !Self.isBreak(s.character(at: start - 1)) { start -= 1 }
            next = start
            startLine(at: start)
        }
        while next < location {
            let c = s.character(at: next)
            if Self.isBreak(c) {
                startLine(at: next + 1)
            } else {
                count(c, at: next)
            }
            next += 1
        }
    }

    private mutating func startLine(at location: Int) {
        lineStart = location
        straightOpens = nil
        curlyOpen = 0; curlyClose = 0
        singleOpen = 0; singleClose = 0
        photo = nil
        algebra = nil
    }

    private mutating func count(_ c: unichar, at k: Int) {
        let previous: unichar? = k > lineStart ? s.character(at: k - 1) : nil
        let following: unichar? = k + 1 < s.length ? s.character(at: k + 1) : nil
        switch c {
        case 0x22:  // "
            // Opening: at the start of the line or after a space or opening punctuation, with
            // something after it.
            let after = previous.map { MeasuresPass.isSpace($0) || "([{:—–-/=".utf16.contains($0) } ?? true
            straightOpens = after && following.map { !MeasuresPass.isSpace($0) } == true
        case 0x201C: curlyOpen += 1
        case 0x201D: curlyClose += 1
        case 0x27, 0x2018, 0x2019:  // ' ‘ ’
            let spaceBefore = previous.map { MeasuresPass.isSpace($0) || $0 == 0x28 || $0 == 0x5B } ?? true
            let letterAfter = following.map(MeasuresPass.isLetter) ?? false
            if spaceBefore && letterAfter {
                singleOpen += 1
            } else if !(previous.map(MeasuresPass.isSpace) ?? true) && !letterAfter {
                singleClose += 1
            }
        default: break
        }
    }
}
