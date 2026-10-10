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
        var digit = false, sign = false
        for b in text.utf8 {
            if b >= 0x30 && b <= 0x39 { digit = true }
            // "$", and the lead bytes of £ ¥ (C2) and € ₹ (E2).
            if b == 0x24 || b == 0xC2 || b == 0xE2 { sign = true }
            if digit && sign { break }
        }
        var t = text
        if digit && sign {
            // "fr. $99", "Rooms Fr. £49": from (before a bare number "Fr." is the franc).
            t = rewrite(t, fromPrice) { m, s in s.substring(with: m.range(at: 1)) == "F" ? "From" : "from" }
            // "two $20s", "Bring $1s": the bills by name.
            t = rewrite(t, pluralBills) { m, s in billNames[s.substring(with: m.range(at: 1))] }
            // "Earn 1 pt/$1", "2 miles/$1": per dollar.
            t = rewrite(t, perOne) { m, s in s.substring(with: m.range(at: 1)) == "$" ? " per dollar" : " per pound" }
        }
        if digit {
            t = readAmounts(t)
            t = rewrite(t, smallChange) { m, s in readSmallChange(m, in: s) }
        }
        if sign { t = rewrite(t, bareSign) { m, s in readBareSign(m, in: s) } }
        return t
    }

    /// Every money expression in `text`, read.
    private static func readAmounts(_ text: String) -> String {
        let ns = text as NSString
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var casing: ShoutedCasing?
        var out = ""
        var last = 0
        for m in matches where m.range.location >= last {
            guard let (range, words) = read(m, in: ns), range.location >= last else { continue }
            out += ns.substring(with: NSRange(location: last, length: range.location - last))
            if casing == nil { casing = ShoutedCasing(text) }
            out += casing!.cased(words, at: range.location)
            last = NSMaxRange(range)
        }
        return casing == nil ? text : out + ns.substring(from: last)
    }

    /// `text` with each match of `regex` replaced by what `read` gives (nil leaves it), in the
    /// case of its sentence (`ShoutedCasing`).
    private static func rewrite(_ text: String, _ regex: NSRegularExpression, _ read: (NSTextCheckingResult, NSString) -> String?) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var casing: ShoutedCasing?
        var out = "", last = 0, changed = false
        for m in matches {
            guard let words = read(m, ns) else { continue }
            if casing == nil { casing = ShoutedCasing(text) }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + casing!.cased(words, at: m.range.location)
            last = NSMaxRange(m.range)
            changed = true
        }
        return changed ? out + ns.substring(from: last) : text
    }

    /// Cents glued to a number: "Bananas are 50c each", "99c!". Not a label ("Room 4c") or a
    /// temperature ("40c today" in a heatwave). Pence stay as written: "99p" is "ninety-nine
    /// p", as Britons say it (money.json).
    private static let smallChange = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}.,$£€¥:])(\d{1,2})(c)(?![\p{L}\p{N}'’&*+\-/])"#)
    private static let changeLabels: Set<String> = ["room", "apt", "flat", "unit", "seat", "row", "grade", "type", "size", "level", "suite", "gate", "platform", "studio", "vitamin", "bus", "route"]
    private static let heatWords: Set<String> = ["hot", "heat", "heatwave", "temperature", "temperatures", "degrees", "warm", "cold", "weather", "forecast"]

    private static func readSmallChange(_ m: NSTextCheckingResult, in s: NSString) -> String? {
        let n = s.substring(with: m.range(at: 1))
        let previous = word(before: m.range.location, in: s) ?? ""
        if changeLabels.contains(previous) { return nil }
        if !Set(words(before: m.range.location, in: s)).isDisjoint(with: heatWords) { return nil }
        return n + (n == "1" ? " cent" : " cents")
    }

    /// "fr." or "Fr." right before a currency sign: "Flights fr. $99 each way".
    private static let fromPrice = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_.])([Ff])r\.(?=[ \t]?[$£€¥₹])"#)
    /// Bills by their value: "$20s", "£5s" (the lexicon said "twenty dollarses").
    private static let pluralBills = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}$£.,])[$£](1|2|5|10|20|50|100)s(?![\p{L}\p{N}'’])"#)
    private static let billNames = ["1": "ones", "2": "twos", "5": "fives", "10": "tens", "20": "twenties", "50": "fifties", "100": "hundreds"]
    /// A rate per dollar or pound after a word: "1 pt/$1".
    private static let perOne = try! NSRegularExpression(pattern: #"(?<=\p{L})[ \t]?/[ \t]?([$£])1(?![\p{N}.,])"#)

    /// A currency sign on its own, as a word: "Is that in $ or €?", "The £ is weak", "The $ sign".
    /// Only between words (or a word and punctuation), never opening a line ("$ npm install").
    private static let bareSign = try! NSRegularExpression(pattern: #"(?<=\p{L}[ \t])([$£€¥₹])(?=[ \t]+\p{L}|[ \t]*[?!.,;:)])"#)
    private static let signNames: [String: (String, String)] = ["$": ("dollar", "dollars"), "£": ("pound", "pounds"), "€": ("euro", "euros"),
                                                                "¥": ("yen", "yen"), "₹": ("rupee", "rupees")]

    private static func readBareSign(_ m: NSTextCheckingResult, in s: NSString) -> String? {
        let names = signNames[s.substring(with: m.range(at: 1))]!
        let previous = word(before: m.range.location, in: s) ?? ""
        return ["the", "a", "this", "that"].contains(previous) ? names.0 : names.1
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
    /// After a currency sign, a European amount too: a decimal comma ("€12,99") and dots between
    /// thousands ("€1.234,56"), or Swiss apostrophes between them ("CHF 1'250").
    private static let amountPattern = #"(?:\d{1,2}(?:,\d{2})+,\d{3}(?:\.\d{1,2})?|\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d{1,3}(?:'\d{3})+(?:\.\d{2})?|\d{1,3}(?:\.\d{3})+,\d{2}|\d+,\d{2}|\d+(?:\.\d+)?|\.\d{2})(?!\d|[.,]\d)"#
    /// A magnitude after an amount: glued ("$40m", "$5MM"), spaced ("$1.5 bn", "₹2 crore", "₹1.5
    /// lakh crore") or hyphenated ("$5-million"). Never before a superscript: "€12m²" is an area.
    private static let magnitudePattern = #"(?:[ \x{00A0}]?(?:thousand|million|billion|trillion|mln|bln|trn|bn|mn|tn|mil)|mm|MM|[kKmMbBT]|(?: (?:lakh|crore))+|-(?:thousand|million|billion|trillion))(?![\p{L}\p{N}²³])"#

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
            + symbolClass + ")" + gap + #"|(?<![\p{L}\p{N}])(?<code>"# + codesBefore + ")" + gap + #"(?<codeSign>\$)?"#
            + #"|(?<![\p{L}\p{N}$])(?<word>Rs\.?|S?Fr\.|kr\.?|R)"# + gap + ")"
            + "(?<amount>" + amountPattern + ")(?<magnitude>" + magnitudePattern + ")?"
        let after = #"(?<![\p{L}\p{N}.,$£€¥₹₩₽₺₪₱₫₦฿₴₡₿])(?<suffixAmount>\d+,\d{2}(?!\d|[.,]\d)|"# + amountPattern
            + ")(?<suffixMagnitude>" + magnitudePattern + ")?" + gap + #"(?<suffix>[€₽₺₪₱₫₦฿₴₡₿$]|kr\.?|zł|S?Fr\.|"#
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
        "TB": "terabyte", "m²": "square meter", "sq ft": "square foot", "sqft": "square foot", "cup": "cup", "stay": "stay",
        "room": "room", "nt": "night", "pp": "person", "bbl": "barrel", "barrel": "barrel", "ea": "each",
        "mi": "mile", "doz": "dozen", "dozen": "dozen", "trip": "trip", "axle": "axle", "bottle": "bottle", "pack": "pack",
        "box": "box", "bag": "bag", "case": "case", "pair": "pair", "ride": "ride", "lesson": "lesson", "class": "class",
        "game": "game", "car": "car", "vehicle": "vehicle", "pet": "pet", "slice": "slice", "scoop": "scoop", "glass": "glass",
        "pint": "pint", "serving": "serving", "portion": "portion", "load": "load", "sheet": "sheet", "roll": "roll",
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
    private static let lowerWordAhead = try! NSRegularExpression(pattern: #"[ \t]+\p{Ll}"#)
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
                     "valuation", "round", "offer", "bid", "salary", "stipend", "plan", "subscription", "tier", "question",
                     "verdict", "fare", "footlong", "song", "extension", "lunch", "meal", "dinner", "item", "burger",
                     "sandwich", "haircut", "shirt", "upgrade", "lawsuit", "judgment", "award", "scholarship", "wager",
                     "jackpot", "bribe", "ransom", "app", "pass", "membership", "entry", "admission"]
        let plurals = nouns.map { $0 + "s" } + ["taxes", "levies", "subsidies", "surpluses"]
        return Set(nouns + plurals + ["tax", "levy", "subsidy", "surplus"])
    }()
    /// Bills, notes and coins need no determiner: "in $20 bills".
    private static let currencyNotes: Set<String> = ["bills", "notes", "coins"]
    private static let determiners: Set<String> = ["a", "an", "the", "this", "that", "these", "those", "each", "every", "another",
                                                   "its", "their", "our", "your", "his", "her", "my", "one", "two", "three",
                                                   "four", "five", "six", "seven", "eight", "nine", "ten"]
    private static let attributiveNoun = try! NSRegularExpression(pattern: #"[ ]+(\p{L}+)(?![\p{L}\p{N}'’])"#)
    /// A word (or a quoted word) after an amount: what "a $5bn" is used before.
    private static let nounAhead = try! NSRegularExpression(pattern: #"[ ]+["“'‘]?\p{L}"#)
    /// Words after an amount that can't be an adjective before its noun: "$5 off orders", "$5
    /// for lunch".
    private static let notAdjectives: Set<String> = [
        "off", "of", "for", "in", "on", "at", "to", "per", "each", "and", "or", "from", "with", "by", "into", "over", "under",
        "is", "was", "are", "were", "will", "can", "could", "would", "should", "back", "more", "less", "extra", "plus",
    ]
    /// A determiner and a hyphenated modifier before an amount: "a 5-yr, ", "a 4-year, ".
    private static let modifierBehind = try! NSRegularExpression(pattern: #"(?:^|[\s(])(\p{L}+)[ \t]+[\d.]+-\p{L}+,?[ \t]+$"#)
    /// "2/" or "3 x " right before an amount.
    private static let countBehind = try! NSRegularExpression(pattern: #"(?<![\p{L}\d.,/])(\d{1,3})/$|(?<![\p{L}\d.,])\d{1,3}[ \t]?([xX×])[ \t]?$"#)
    /// The end of a receipt's line after an amount: spaces, then the end, a line break or "each".
    private static let lineEnd = try! NSRegularExpression(pattern: #"[ \t]*(?:$|\n|(?:each|ea|apiece|per)(?![\p{L}]))"#)
    /// A number later in the sentence: digits or a number word.
    private static let numberAhead = try! NSRegularExpression(pattern: #"\d|(?i:\b(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|billion|dozen|half)\b)"#)
    /// A spaced tail a price list writes after an amount: " ea.", " pp", " pcm", " pw", " pa".
    private static let spacedTail = try! NSRegularExpression(pattern: #"[ ]+(ea|pp|pcm|pw|pa|p\.a\.)(\.)?(?![\p{L}\p{N}])"#)
    private static let tails = ["ea": " each", "pp": " per person", "pcm": " per calendar month", "pw": " per week",
                                "pa": " per annum", "p.a.": " per annum"]

    /// Words that make the amount after them a price, for a currency that is also a word, a
    /// course or a name ("It costs CAD 100", "The fare is Fr. 20", but "Take CAD 101", "Upgrade
    /// from R12 to R13"). Bare prepositions ("for", "from", "about") aren't cues.
    private static let priceCues: Set<String> = [
        "cost", "costs", "costing", "price", "prices", "priced", "pay", "pays", "paying", "paid", "fee", "fees", "fare",
        "fares", "worth", "earn", "earns", "earned", "spend", "spends", "spent", "save", "saves", "saved", "charge",
        "charges", "charged", "total", "subtotal", "balance", "deposit", "budget", "salary", "rent", "refund", "owe",
        "owes", "owed", "limit", "allowance", "cap",
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
                // "CAD $45": a dollar code before a dollar sign is that dollar.
                let signed = text("codeSign") != nil
                if signed, !(codes[code]!.priceStyle || code == "MXN") { return nil }
                guard signed || shaped || hasPriceCue(before: start, in: s) || attributiveNoun(after: end, in: s).map(attributiveNouns.contains) == true,
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
                // Cents written with "EUR" say whose: "1 USD = 0.92 EUR" is ninety-two euro cents.
                if suffix == "EUR" { currency.sub = ("euro cent", "euro cents") }
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
            // An abbreviation's point before a lower-case word isn't the full stop: "$3.19/gal.
            // nationwide".
            if character(at: end, in: s) == ".", match(lowerWordAhead, at: end + 1, in: s) != nil { end += 1 }
        }
        var compound: String?
        if per.isEmpty, let c = match(perCompound, at: end, in: s) {
            compound = s.substring(with: c.range(at: 1)) + " " + s.substring(with: c.range(at: 2))
            end = NSMaxRange(c.range)
        }
        // A spaced tail a price list writes: "$2.50 ea.", "$40 pp", "£2,250 pcm".
        var tail = ""
        if per.isEmpty, compound == nil, let t = match(spacedTail, at: end, in: s) {
            tail = tails[s.substring(with: t.range(at: 1))]!
            end = NSMaxRange(t.range)
            // The abbreviation's point goes, unless it was also the full stop.
            if t.range(at: 2).location != NSNotFound, FullStop.ends(before: s.substring(from: end), next: .capital) { tail += "." }
        }
        // "$1,000+", "orders of $35+": "or more". "$12ish": the dollars, then "ish".
        var after = ""
        if per.isEmpty, tail.isEmpty, let next = character(at: end, in: s) {
            if next == "+", character(at: end + 1, in: s).map({ $0.isLetter || $0.isNumber }) != true {
                after = " or more"
                end += 1
            } else if s.substring(from: end).hasPrefix("ish"), character(at: end + 3, in: s).map(\.isLetter) != true {
                after = " ish"
                end += 3
            } else if s.substring(from: end).hasPrefix("-ish"), character(at: end + 4, in: s).map(\.isLetter) != true {
                // "$200-ish a night": the dollars, then "ish".
                after = " ish"
                end += 4
            }
        }
        // Before a noun the currency is singular: "a $5 bill", "in $20 bills", "the $20/month plan",
        // "They got $2,000 checks", "a £22bn black hole", "a 5-yr, $200M extension".
        if tail.isEmpty, after.isEmpty, let noun = attributiveNoun(after: end, in: s) {
            if currencyNotes.contains(noun) || attributiveNouns.contains(noun)
                && (noun.hasSuffix("s") && !noun.hasSuffix("ss") || hasDeterminer(before: start, in: s)) {
                singular = true
            }
        }
        // Right after "a" or "an", an amount can only be used before its noun: "a $1.9 trillion
        // stimulus", "a £22bn 'black hole'", "a $5bn rescue". "a $1M view" is "a million dollar view".
        var article = false
        if lead.isEmpty, tail.isEmpty, after.isEmpty, per.isEmpty, compound == nil, ["a", "an"].contains(word(before: start, in: s) ?? ""),
           match(nounAhead, at: end, in: s) != nil {
            singular = true
            article = amount.whole == "1" && amount.fraction == nil && !amount.magnitude.isEmpty
        }
        // "2/$25", "3/$4": two for twenty-five dollars. "3 x $4.99" on a receipt: three at four ninety-nine.
        var rangeStart = start
        var count = ""
        if lead.isEmpty, let c = countBefore(start, in: s) {
            // "3 x $4.99" is a receipt's line; before a noun ("Buy 2 x $5 tickets") the x is a
            // count of things, left as written.
            let endsLine = character(at: end, in: s).map { !$0.isLetter && !$0.isNumber && $0 != " " } ?? true
                || match(lineEnd, at: end, in: s) != nil
            if c.words.hasSuffix("for ") || endsLine {
                count = c.words
                rangeStart = c.location
            }
        }
        // What the lexicon already reads right stays as written, unless a number comes later in
        // the sentence: the lexicon took it for this amount's ("$40 two days ago" was "forty-two
        // dollars days ago", "$43,210 (96%)" "ninety-six dollars percent").
        if lead.isEmpty, count.isEmpty, tail.isEmpty, after.isEmpty, let prefix, lexiconSymbols.contains(prefix), amount.magnitude.isEmpty,
           second == nil, !coded, per.isEmpty, compound == nil, !singular, lexiconReads(amount, currency), !numberFollows(end, in: s) {
            return nil
        }
        var words = count + lead + (second.map { rangeWords(amount, $0, currency, singular: singular, dash: dash) }
            ?? reading(amount, currency, singular: singular).words)
        if article, second == nil, words.hasPrefix("1 ") { words = String(words.dropFirst(2)) }
        if per == ["each"] {
            words += " each"
        } else if per.count == 1, !writtenPer, timeUnits.contains(per[0]) {
            words += (per[0] == "hour" ? " an " : " a ") + per[0]
        } else {
            words += per.map { " per " + $0 }.joined()
        }
        words += tail + after
        if let compound { words += " " + compound }
        // "60 kr." at the end of a sentence keeps its full stop.
        if fullStop { words += FullStop.kept(before: s.substring(from: end), next: .capital) }
        return (NSRange(location: rangeStart, length: end - rangeStart), words)
    }

    /// Whether the lexicon reads `a` in `c` the way the pass would: a whole amount ("$5"), cents
    /// alone ("$0.73"), or dollars in full ("$1,299.99", "$200.75"); not lakh and crore.
    private static func lexiconReads(_ a: Amount, _ c: Currency) -> Bool {
        if a.indian && c.code == "INR" { return false }
        // "$.99" was "dollars point nine nine".
        if a.whole.isEmpty { return false }
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
    /// punctuation, a word from `codeFollowers`, a money noun ("$4.99 CAD fee", "$15 CAD
    /// deposit": a code that is also a word never comes before one), or a per-unit price
    /// ("CAD/month").
    private static func codeEnds(at i: Int, in s: NSString) -> Bool {
        guard let c = character(at: i, in: s) else { return true }
        if c.isNewline || ".,;:!?)]\"'”’".contains(c) { return true }
        // An exchange rate: "1 USD = 0.92 EUR".
        if c == " ", character(at: i + 1, in: s) == "=" { return true }
        if c == "/" || c == "-" { return match(perStep, at: i, in: s) != nil || match(perCompound, at: i, in: s) != nil }
        guard c == " " else { return false }
        var j = i
        while let c = character(at: j, in: s), c == " " { j += 1 }
        var word = ""
        while let c = character(at: j, in: s), c.isLetter {
            word.append(c)
            j += c.utf16.count
        }
        let w = word.lowercased()
        return codeFollowers.contains(w) || attributiveNouns.contains(w) || currencyNotes.contains(w)
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

    /// The noun after an amount, past one adjective ("a £22bn black hole"), lower-cased.
    private static func attributiveNoun(after i: Int, in s: NSString) -> String? {
        guard let n = match(attributiveNoun, at: i, in: s) else { return nil }
        let first = s.substring(with: n.range(at: 1))
        let noun = first.lowercased()
        if attributiveNouns.contains(noun) || currencyNotes.contains(noun) { return noun }
        // One lower-case adjective, then a noun from the list ("black hole"; not "off orders").
        guard first.first?.isLowercase == true, !determiners.contains(noun), !notAdjectives.contains(noun),
              let second = match(attributiveNoun, at: NSMaxRange(n.range), in: s) else {
            return noun
        }
        let next = s.substring(with: second.range(at: 1)).lowercased()
        return attributiveNouns.contains(next) ? next : noun
    }

    /// Whether a determiner comes before an amount at `i`, past a hyphenated modifier and its
    /// comma ("a 5-yr, $200M extension") or a sentence start ("GBP 50 deposit").
    private static func hasDeterminer(before i: Int, in s: NSString) -> Bool {
        let from = max(0, i - 40)
        let head = s.substring(with: NSRange(location: from, length: i - from)) as NSString
        if let m = modifierBehind.firstMatch(in: head as String, range: NSRange(location: 0, length: head.length)) {
            return determiners.contains(head.substring(with: m.range(at: 1)).lowercased())
        }
        if let w = word(before: i, in: s) { return determiners.contains(w) }
        // The start of a line or sentence: "GBP 50 deposit, refundable."
        let trimmed = (head as String).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        return trimmed.isEmpty || trimmed.last.map { "\n.!?:".contains($0) } == true
    }

    /// A count before an amount: "2/$25" ("2 for "), "3 x $4.99" ("3 at "); where it starts.
    private static func countBefore(_ i: Int, in s: NSString) -> (location: Int, words: String)? {
        let from = max(0, i - 12)
        let head = s.substring(with: NSRange(location: from, length: i - from))
        guard let m = countBehind.firstMatch(in: head, range: NSRange(location: 0, length: (head as NSString).length)) else { return nil }
        let ns = head as NSString
        if m.range(at: 1).location != NSNotFound {
            return (from + m.range.location, ns.substring(with: m.range(at: 1)) + " for ")
        }
        return (from + m.range(at: 2).location, "at ")
    }

    /// Whether a number (digits or a number word) comes later in the sentence after `i`.
    private static func numberFollows(_ i: Int, in s: NSString) -> Bool {
        let rest = s.substring(with: NSRange(location: i, length: min(160, s.length - i)))
        let sentence = rest.prefix { $0 != "\n" && $0 != "!" && $0 != "?" }
        let cut = sentence.range(of: ". ").map { sentence[..<$0.lowerBound] } ?? sentence
        return numberAhead.firstMatch(in: String(cut), range: NSRange(location: 0, length: (String(cut) as NSString).length)) != nil
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
