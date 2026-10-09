import Foundation

/// Money (Core readings, FIN-889; area "money"): prices, currency symbols and codes, magnitudes,
/// per-unit prices, ranges, signs, and "~" or "≈" before an amount.
///
/// The pass reads whole money expressions on the raw text, before the custom lexicon marks terms
/// inside them (CAD, EUR, USD, "Max", the unit entries mm, ms, GB and MB) and before the phone
/// pass, so "$911" and "$555" are already money when phone numbers are looked for. It writes
/// digits and words for the number reader ("$4.99 CAD" → "4 99 Canadian"). An amount the
/// lexicon already reads as it should ("$5", "$0.73", "£20", "$1,299.99") is left as written.
enum MoneyPass {
    typealias Rule = TextNormalizer.Rule

    /// The money pass: in `Phonemizer.phonemize` after the quarter-year split and before the
    /// phone pass, only when normalizing. Words it inserts into a sentence written in capitals go
    /// through `ShoutedCasing`, because `unshout` runs after it.
    static func apply(_ text: String, british: Bool) -> String {
        guard text.utf8.contains(where: { $0 >= 0x30 && $0 <= 0x39 }) else { return text }
        let ns = text as NSString
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var casing: ShoutedCasing?
        var out = ""
        var last = 0
        for m in matches where m.range.location >= last {
            guard let (range, words) = read(m, in: ns) else { continue }
            out += ns.substring(with: NSRange(location: last, length: range.location - last))
            if casing == nil { casing = ShoutedCasing(text) }
            out += casing!.cased(words, at: range.location)
            last = NSMaxRange(range)
        }
        return casing == nil ? text : out + ns.substring(from: last)
    }

    /// The money pass reads every price, range, per-unit price and magnitude itself, before the
    /// custom lexicon; fix3's rules that did it in TextNormalizer's list are retired.
    static func legacyRules(british: Bool) -> [Rule] { [] }

    /// The money pass reads every sign before a currency ("-$", "−£", "-C$"); the U+2212 and en
    /// dash rules stay in TextNormalizer's list for bare numbers.
    static func signRules(british: Bool) -> [Rule] { [] }

    // MARK: - Patterns

    /// The space a currency may have before or after its amount: a space, or the no-break spaces
    /// French and German typography put before "€".
    private static let gap = #"[ \x{00A0}\x{202F}]?"#
    private static let symbolClass = "[$£€¥₹₩₽₺₪₱₫₦฿₴₡₿]"
    private static let dollarPrefixes = "US|CAD|CA|Can|C|AUD|AU|A|NZ|HK|SG|S|NT|MX|Mex|R"
    /// Codes read before an amount. PHP, TRY, ALL and TOP are words too often ("PHP 8", "TRY 3
    /// TIMES"), and VND, NGN and UAH are never written that way.
    private static let codesBefore = "USD|EUR|GBP|JPY|CNY|RMB|INR|AUD|NZD|CAD|HKD|SGD|TWD|CHF|SEK|NOK|DKK|MXN|BRL|ZAR|KRW|RUB|PLN|THB"
    private static let codesAfter = "USD|CAD|AUD|NZD|HKD|SGD|TWD|EUR|GBP|JPY|CNY|RMB|INR|KRW|CHF|SEK|NOK|DKK|MXN|PHP|BRL|ZAR|RUB|TRY|ILS|PLN|THB|VND|NGN|UAH"
    /// Codes that are also something else (CAD software, CHF heart failure, CNY Chinese New
    /// Year, ILS the landing system, the INR blood test): after a bare number they need a price
    /// cue or a money-shaped number.
    private static let ambiguousCodes: Set<String> = ["CAD", "CHF", "CNY", "ILS", "AUD", "INR", "PHP"]

    /// An amount: Indian grouping ("12,50,000"), thousands ("1,299.99"), plain ("4.99") or
    /// cents alone ("$.73"), and no more digits after it.
    private static let amountPattern = #"(?:\d{1,2}(?:,\d{2})+,\d{3}(?:\.\d{1,2})?|\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?|\.\d{2})(?!\d|[.,]\d)"#
    /// A magnitude after an amount: glued ("$40m", "$5MM"), spaced ("$1.5 bn", "₹2 crore", "₹1.5
    /// lakh crore") or hyphenated ("$5-million"). Never before a superscript: "€12m²" is an area.
    private static let magnitudePattern = #"(?:[ \x{00A0}]?(?:thousand|million|billion|trillion|mln|bln|trn|bn|mn|tn)|mm|MM|[kKmMbBT]|(?: (?:lakh|crore))+|-(?:thousand|million|billion|trillion))(?![\p{L}\p{N}²³])"#

    /// A minus, an approximation or an "under-" before the amount; then a currency before it (a
    /// country dollar, a currency sign, a code or an abbreviation), or one after it. A dollar
    /// prefix starts the text or follows a space, an opening bracket or quote, a minus or a
    /// slash, so spreadsheet references ("=A$1*2", "$A$1") never count; a currency sign doesn't
    /// follow a letter, digit, "$" or "_" ("Ke$ha", "$$"). An amount with a currency after it
    /// doesn't follow a letter, a digit, a point or a currency sign.
    private static let expression: NSRegularExpression = {
        let lead = #"(?:(?<sign>(?<![\p{L}\p{N}])[-−‐‑‒﹣－]|(?:^|(?<=[(\[=\n])|(?<=[^\d\s]\s))–)|(?<approx>(?<![\p{L}\p{N}/~])[~≈])"#
            + gap + #"|(?<compound>(?<=\b(?:under|over|sub|Under|Over|Sub|UNDER|OVER|SUB))-))?"#
        let before = #"(?:(?<![^\s(\["'“‘~≈\-−–—/])(?<dollarPrefix>"# + dollarPrefixes + #")\$|(?<![\p{L}\p{N}$_])(?<symbol>"#
            + symbolClass + ")" + gap + #"|(?<![\p{L}\p{N}])(?<code>"# + codesBefore + ")" + gap
            + #"|(?<![\p{L}\p{N}$])(?<word>Rs\.?|S?Fr\.|kr\.?|R)"# + gap + ")"
            + "(?<amount>" + amountPattern + ")(?<magnitude>" + magnitudePattern + ")?"
        let after = #"(?<![\p{L}\p{N}.,$£€¥₹₩₽₺₪₱₫₦฿₴₡₿])(?<suffixAmount>\d+,\d{2}(?!\d|[.,]\d)|"# + amountPattern
            + ")(?<suffixMagnitude>" + magnitudePattern + ")?" + gap + #"(?<suffix>[€₽₺₪₱₫₦฿₴₡₿]|kr\.?|zł|S?Fr\.|"#
            + codesAfter + #")(?![\p{L}\p{N}])"#
        return try! NSRegularExpression(pattern: lead + "(?:" + before + "|" + after + ")")
    }()

    /// A dash and a second amount: "$10–20", "$10-$20", "$20 - $25", "$5–10M".
    private static let rangeTail = try! NSRegularExpression(pattern: "( ?)([-–])( ?)(?:(" + dollarPrefixes + #")\$|("#
        + symbolClass + "))?(" + amountPattern + ")(" + magnitudePattern + ")?(?![-–])")
    /// A code after an amount with a currency sign: "$15 CAD", "€9.99 EUR".
    private static let codeAfter = try! NSRegularExpression(pattern: " ?(" + codesAfter + #")(?![\p{L}\p{N}])"#)

    /// What a price can be per, as said after "per", "a" or "an" (always singular). A closed
    /// list: "$5/free over $50" is no per-unit price.
    static let perUnits: [String: String] = [
        "mo": "month", "mth": "month", "month": "month", "hr": "hour", "hour": "hour", "h": "hour", "yr": "year",
        "year": "year", "annum": "annum", "wk": "week", "week": "week", "day": "day", "night": "night", "min": "minute",
        "minute": "minute", "qtr": "quarter", "quarter": "quarter", "user": "user", "seat": "seat", "person": "person",
        "head": "head", "adult": "adult", "child": "child", "kid": "kid", "guest": "guest", "share": "share",
        "unit": "unit", "item": "item", "piece": "piece", "ticket": "ticket", "license": "license", "licence": "licence",
        "visit": "visit", "session": "session", "page": "page", "word": "word", "mile": "mile", "km": "kilometer",
        "lb": "pound", "kg": "kilogram", "g": "gram", "oz": "ounce", "gal": "gallon", "gallon": "gallon", "L": "liter",
        "l": "liter", "liter": "liter", "litre": "litre", "kWh": "kilowatt hour", "GB": "gigabyte", "MB": "megabyte",
        "TB": "terabyte", "m²": "square meter", "sq ft": "square foot", "sqft": "square foot",
    ]
    /// Units of time: one alone after a slash is "a month" or "an hour", as a price is said.
    /// Rates of other units say "per" ("per pound"), and so do two or more ("per user per month").
    private static let timeUnits: Set<String> = ["month", "hour", "year", "week", "day", "night", "minute", "quarter"]
    /// `perUnits` by lower-cased key, so a shouted price reads too ("$10/ADULT"). No two keys
    /// differ only in case and mean different units.
    private static let perUnitsFolded = Dictionary(perUnits.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
    private static let unitAlternation = perUnits.keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern).joined(separator: "|")
    /// "/month", " / seat", " per user".
    private static let perStep = try! NSRegularExpression(pattern: #"(?:[ ]?(/)[ ]?|[ ]+(per)[ ]+)("# + unitAlternation + #")(?![\p{L}\p{N}²³])"#,
                                                          options: .caseInsensitive)
    /// "-a-month", "-an-hour": a price used before a noun ("a $10-a-month plan").
    private static let perCompound = try! NSRegularExpression(pattern: #"-(an?)-(month|year|week|day|night|hour)(?![\p{L}\p{N}])"#,
                                                              options: .caseInsensitive)

    /// Nouns an amount is used before ("a $5 bill", "a $5-million contract"), where the currency
    /// is singular. No verb lookalikes ("The $5 can buy you lunch").
    private static let attributiveNouns: Set<String> = {
        let nouns = ["bill", "note", "coin", "fee", "fine", "charge", "surcharge", "deposit", "refund", "rebate", "discount",
                     "credit", "voucher", "coupon", "gift", "card", "prize", "bonus", "tip", "raise", "bet", "budget", "deal",
                     "loan", "payment", "donation", "grant", "investment", "contract", "settlement", "fund", "check", "cheque",
                     "ticket", "purchase", "order", "increase", "cut", "hole", "shortfall", "deficit", "package", "bailout",
                     "valuation", "round", "offer", "bid", "salary", "stipend", "plan", "subscription", "tier"]
        let plurals = nouns.map { $0 + "s" } + ["taxes", "levies", "subsidies", "surpluses"]
        return Set(nouns + plurals + ["tax", "levy", "subsidy", "surplus"])
    }()
    /// Bills, notes and coins need no determiner: "in $20 bills".
    private static let currencyNotes: Set<String> = ["bills", "notes", "coins"]
    private static let determiners: Set<String> = ["a", "an", "the", "this", "that", "these", "those", "each", "every", "another",
                                                   "its", "their", "our", "your", "his", "her", "my", "one", "two", "three",
                                                   "four", "five", "six", "seven", "eight", "nine", "ten"]
    private static let attributiveNoun = try! NSRegularExpression(pattern: #"[ ]+(\p{L}+)(?![\p{L}\p{N}'’])"#)

    /// Words that make the amount after them a price, for a currency that is also a word, a
    /// course or a name ("It costs CAD 100", "The fare is Fr. 20", but "Take CAD 101", "Upgrade
    /// from R12 to R13"). Bare prepositions ("for", "from", "about") aren't cues.
    private static let priceCues: Set<String> = [
        "cost", "costs", "costing", "price", "prices", "priced", "pay", "pays", "paying", "paid", "fee", "fees", "fare",
        "fares", "worth", "earn", "earns", "earned", "spend", "spends", "spent", "save", "saves", "saved", "charge",
        "charges", "charged", "total", "subtotal", "balance", "deposit", "budget", "salary", "rent", "refund", "owe",
        "owes", "owed",
    ]
    /// Words that may come between a cue and the amount: "fare is", "costs about", "up to".
    private static let cueLinks: Set<String> = ["is", "was", "of"]
    private static let cueModifiers: Set<String> = ["about", "around", "roughly", "only", "just", "nearly", "almost", "under", "over"]
    /// What may follow a code after an amount ("$15 CAD.", "50 GBP for it", "$20 USD a month"),
    /// so that a code that is also a word stays one ("$20 CAD templates", "3 PHP developers").
    private static let codeFollowers: Set<String> = [
        "per", "a", "an", "each", "every", "for", "in", "on", "at", "to", "from", "or", "and", "plus", "with", "without",
        "including", "excluding", "only", "net", "gross", "total", "is", "was", "are", "were", "will", "would", "which",
        "that", "back", "off", "more", "less", "here", "there", "now", "today", "apiece", "upfront", "monthly", "yearly",
        "annually",
    ]
    /// The currency signs the lexicon reads itself, the same way the pass would for a whole
    /// amount, cents alone or a dollar amount in full.
    private static let lexiconSymbols: Set<String> = ["$", "£", "€", "¥", "₹", "₩"]

    // MARK: - Reading

    /// The range of text a money match covers (with its range, code and per-unit tail) and
    /// what it reads as; nil when it isn't money after all, or the lexicon reads it right.
    private static func read(_ m: NSTextCheckingResult, in s: NSString) -> (NSRange, String)? {
        func text(_ name: String) -> String? {
            let r = m.range(withName: name)
            return r.location == NSNotFound ? nil : s.substring(with: r)
        }
        let start = m.range.location
        var end = NSMaxRange(m.range)
        var lead = ""
        if text("sign") != nil {
            lead = "minus "
        } else if let approx = text("approx") {
            lead = approx.hasPrefix("~") ? "about " : "approximately "
        } else if text("compound") != nil {
            lead = " "
        }
        var singular = text("compound") != nil

        var currency: Currency
        let amount: Amount
        // The currency sign before the amount, which a range's second amount may repeat ("$10-$20").
        var prefix: String?
        var fullStop = false
        if let written = text("amount") {
            amount = Amount(written, magnitude: text("magnitude"))
            if let p = text("dollarPrefix") {
                // "C$2:C$10" and "A$1B" are spreadsheet ranges.
                if let next = character(at: end, in: s), next == ":" || next.isLetter && character(at: end + 1, in: s)?.isNumber == true {
                    return nil
                }
                currency = dollarPrefixed[p]!
                prefix = p + "$"
            } else if let symbol = text("symbol") {
                currency = symbols[symbol]!
                prefix = symbol
            } else if let code = text("code") {
                // "CHF 4.50", "USD1,500", and "CAD 100" after "costs"; never "CNY 2025" or
                // "Wichita USD 259". Two decimals don't make INR money ("INR 2.50" is a test result).
                let shaped = code == "INR" ? amount.separated || !amount.magnitude.isEmpty : amount.moneyShaped
                guard shaped || hasPriceCue(before: start, in: s),
                      !(code == "CNY" && amount.fraction == nil && (1900...2099).contains(amount.units ?? 0)) else { return nil }
                currency = codes[code]!
            } else {
                let word = text("word")!
                currency = currencyWords[word]!
                if word == "R" {
                    // "R1,500" and "costs R80", but not "R2-D2", "The R100 airship" or "R12 to R13".
                    if let next = character(at: end, in: s), next.isLetter || next == "-" { return nil }
                    guard amount.moneyShaped || hasPriceCue(before: start, in: s) else { return nil }
                } else if word.hasSuffix("Fr.") {
                    // "Fr." is also a fragment ("Sappho Fr. 31") or a priest ("Fr. Brown").
                    guard amount.moneyShaped || hasPriceCue(before: start, in: s) else { return nil }
                }
            }
        } else {
            amount = Amount(text("suffixAmount")!, magnitude: text("suffixMagnitude"))
            let suffix = text("suffix")!
            if let c = symbols[suffix] {
                currency = c
            } else if let c = currencyWords[suffix] {
                currency = c
                if suffix.hasSuffix("Fr.") {
                    guard amount.moneyShaped || hasPriceCue(before: start, in: s) else { return nil }
                }
                fullStop = suffix.hasSuffix(".")
            } else {
                // "It costs 100 CAD.", "We paid 50 GBP for it", but not "3 CAD models", "Module 3 CAD
                // for beginners" or "Happy 2025 CNY to all".
                guard codeEnds(at: end, in: s),
                      !ambiguousCodes.contains(suffix) || amount.moneyShaped || hasPriceCue(before: start, in: s) else { return nil }
                currency = codes[suffix]!
            }
        }

        // A range: "$10–20", "$10-$20", "£5–£10", "$5–10M". An operator after it makes the dash a
        // minus ("$20 - $5 = $15"); a falling pair isn't a range, and keeps its dash.
        var second: Amount?
        var dash = Dash.to
        if text("amount") != nil, let t = match(rangeTail, at: end, in: s),
           s.substring(with: t.range(at: 1)) == s.substring(with: t.range(at: 3)) {
            let repeated = t.range(at: 4).location != NSNotFound ? s.substring(with: t.range(at: 4)) + "$"
                : t.range(at: 5).location != NSNotFound ? s.substring(with: t.range(at: 5)) : nil
            if repeated == nil || repeated == prefix {
                let b = Amount(s.substring(with: t.range(at: 6)),
                               magnitude: t.range(at: 7).location == NSNotFound ? nil : s.substring(with: t.range(at: 7)))
                if isOperator(after: NSMaxRange(t.range), in: s) {
                    dash = .minus
                } else if b.value() < amount.value(sharing: b.magnitude) {
                    dash = .written(s.substring(with: t.range(at: 2)))
                }
                second = b
                end = NSMaxRange(t.range)
            }
        }

        // A code after a sign: "$15 CAD", "€9.99 EUR" (silent), "¥80 CNY" (yuan).
        var coded = false
        if prefix != nil, let c = match(codeAfter, at: end, in: s), codeEnds(at: NSMaxRange(c.range), in: s),
           let named = MoneyPass.currency(currency, before: s.substring(with: c.range(at: 1))) {
            currency = named
            coded = true
            end = NSMaxRange(c.range)
        }
        // "/mo", "/user/month", " per seat"; "-a-month".
        var per: [String] = []
        var writtenPer = false
        while let p = match(perStep, at: end, in: s) {
            writtenPer = writtenPer || p.range(at: 2).location != NSNotFound
            per.append(perUnitsFolded[s.substring(with: p.range(at: 3)).lowercased()]!)
            end = NSMaxRange(p.range)
        }
        var compound: String?
        if per.isEmpty, let c = match(perCompound, at: end, in: s) {
            compound = s.substring(with: c.range(at: 1)) + " " + s.substring(with: c.range(at: 2))
            end = NSMaxRange(c.range)
        }
        // Before a noun the currency is singular: "a $5 bill", "in $20 bills", "the $20/month plan".
        if let n = match(attributiveNoun, at: end, in: s) {
            let noun = s.substring(with: n.range(at: 1)).lowercased()
            if currencyNotes.contains(noun)
                || attributiveNouns.contains(noun) && determiners.contains(word(before: start, in: s) ?? "") {
                singular = true
            }
        }
        // What the lexicon already reads right stays as written.
        if lead.isEmpty, let prefix, lexiconSymbols.contains(prefix), amount.magnitude.isEmpty, second == nil, !coded,
           per.isEmpty, compound == nil, !singular, lexiconReads(amount, currency) {
            return nil
        }
        var words = lead + (second.map { rangeWords(amount, $0, currency, singular: singular, dash: dash) }
            ?? reading(amount, currency, singular: singular).words)
        if per.count == 1, !writtenPer, timeUnits.contains(per[0]) {
            words += (per[0] == "hour" ? " an " : " a ") + per[0]
        } else {
            words += per.map { " per " + $0 }.joined()
        }
        if let compound { words += " " + compound }
        // "60 kr." at the end of a sentence keeps its full stop.
        if fullStop { words += FullStop.kept(before: s.substring(from: end), next: .capital) }
        return (NSRange(location: start, length: end - start), words)
    }

    /// Whether the lexicon reads `a` in `c` the way the pass would: a whole amount ("$5"), cents
    /// alone ("$0.73"), or dollars in full ("$1,299.99", "$200.75"); not lakh and crore.
    private static func lexiconReads(_ a: Amount, _ c: Currency) -> Bool {
        if a.indian && c.code == "INR" { return false }
        if a.isWhole { return true }
        guard a.fraction?.count == 2, let units = a.units else { return false }
        return units == 0 || c.priceStyle && (units >= 1000 || units % 100 == 0)
    }

    // MARK: - Context

    private static func match(_ regex: NSRegularExpression, at i: Int, in s: NSString) -> NSTextCheckingResult? {
        guard i < s.length else { return nil }
        return regex.firstMatch(in: s as String, options: [.anchored, .withTransparentBounds], range: NSRange(location: i, length: s.length - i))
    }

    private static func character(at i: Int, in s: NSString) -> Character? {
        guard i < s.length else { return nil }
        return Character(s.substring(with: s.rangeOfComposedCharacterSequence(at: i)))
    }

    /// Whether an operator follows a range's second amount, making its dash a minus.
    private static func isOperator(after i: Int, in s: NSString) -> Bool {
        var j = i
        while let c = character(at: j, in: s), c == " " { j += 1 }
        return character(at: j, in: s).map { "=+*×÷<>≠≈≤≥−".contains($0) } == true
    }

    /// Whether what follows a code after an amount lets it be the currency: the end, closing
    /// punctuation, a word from `codeFollowers`, or a per-unit price ("CAD/month").
    private static func codeEnds(at i: Int, in s: NSString) -> Bool {
        guard let c = character(at: i, in: s) else { return true }
        if c.isNewline || ".,;:!?)]\"'”’".contains(c) { return true }
        if c == "/" || c == "-" { return match(perStep, at: i, in: s) != nil || match(perCompound, at: i, in: s) != nil }
        guard c == " " else { return false }
        var j = i
        while let c = character(at: j, in: s), c == " " { j += 1 }
        var word = ""
        while let c = character(at: j, in: s), c.isLetter {
            word.append(c)
            j += c.utf16.count
        }
        return codeFollowers.contains(word.lowercased())
    }

    /// The word just before `i`, past spaces, lower-cased; nil after punctuation.
    private static func word(before i: Int, in s: NSString) -> String? {
        var j = i - 1
        while j >= 0, s.character(at: j) == 0x20 { j -= 1 }
        var word = ""
        while j >= 0, let c = Unicode.Scalar(s.character(at: j)), Character(c).isLetter {
            word = String(c) + word
            j -= 1
        }
        return word.isEmpty ? nil : word.lowercased()
    }

    /// Up to four words before `i` in its sentence, nearest first, lower-cased.
    private static func words(before i: Int, in s: NSString) -> [String] {
        let from = max(0, i - 60)
        let text = s.substring(with: NSRange(location: from, length: i - from))
        var words: [String] = []
        var current = ""
        for c in text.reversed() {
            if c.isLetter || c == "'" || c == "’" {
                current = String(c) + current
                continue
            }
            if !current.isEmpty { words.append(current.lowercased()); current = "" }
            if words.count == 4 || ".!?\n".contains(c) { return words }
        }
        if !current.isEmpty, from == 0 { words.append(current.lowercased()) }
        return words
    }

    /// Whether a price cue comes just before `i`: "costs", "fare is", "paid about", "sold for",
    /// "salary of up to".
    private static func hasPriceCue(before i: Int, in s: NSString) -> Bool {
        let w = words(before: i, in: s)
        var k = 0
        if w.count > 1, w[0] == "to", w[1] == "up" {
            k = 2
        } else if let first = w.first, cueModifiers.contains(first) {
            k = 1
        }
        if k < w.count, cueLinks.contains(w[k]) { k += 1 }
        guard k < w.count else { return false }
        if priceCues.contains(w[k]) { return true }
        return w[k] == "for" && k + 1 < w.count && ["sold", "bought", "sells"].contains(w[k + 1])
    }
}
