import Foundation

/// The currencies the money pass knows, and how it says an amount in each.
extension MoneyPass {
    /// A currency as it's read: the unit and subunit words, and for dollars the country word
    /// ("Canadian") that tells them apart.
    struct Currency {
        /// The ISO code, which decides whether a code after an amount repeats its symbol ("€9.99
        /// EUR", silent) or names another currency ("$15 CAD"); "$" for a dollar with no country.
        let code: String
        let one: String
        let many: String
        /// The subunit, said alone under one unit ("eighty-five pence"); nil when nobody uses one
        /// (dong), so such an amount is read as a decimal.
        var sub: (one: String, many: String)?
        /// Said after a dollar price ("four ninety-nine Canadian") and before "dollars".
        var country: String?
        /// Dollars: "four ninety-nine", where other currencies say the unit between the two
        /// numbers ("four pounds ninety-nine").
        var priceStyle = false
        /// Crypto: always a decimal ("zero point two five bitcoin").
        var decimal = false

        init(_ code: String, _ one: String, _ many: String, sub: (String, String)? = nil, country: String? = nil,
             priceStyle: Bool = false, decimal: Bool = false) {
            self.code = code
            self.one = one
            self.many = many
            self.sub = sub.map { (one: $0.0, many: $0.1) }
            self.country = country
            self.priceStyle = priceStyle
            self.decimal = decimal
        }
    }

    static func dollars(_ code: String, _ country: String?) -> Currency {
        Currency(code, "dollar", "dollars", sub: ("cent", "cents"), country: country, priceStyle: true)
    }

    /// ISO codes, before or after an amount. Short names, with a country word only where the
    /// unit's name is shared (dollars, pesos, francs, kronor, kroner). US dollars are "U S":
    /// "US" alone reads as one word, and unshout can make a shouted "US" the pronoun.
    static let codes: [String: Currency] = {
        let yuan = Currency("CNY", "yuan", "yuan", sub: ("fen", "fen"))
        return [
            "USD": dollars("USD", "U S"), "CAD": dollars("CAD", "Canadian"), "AUD": dollars("AUD", "Australian"),
            "NZD": dollars("NZD", "New Zealand"), "HKD": dollars("HKD", "Hong Kong"), "SGD": dollars("SGD", "Singapore"),
            "TWD": dollars("TWD", "New Taiwan"),
            "EUR": Currency("EUR", "euro", "euros", sub: ("cent", "cents")),
            "GBP": Currency("GBP", "pound", "pounds", sub: ("penny", "pence")),
            "JPY": Currency("JPY", "yen", "yen", sub: ("sen", "sen")),
            "CNY": yuan, "RMB": yuan,
            "INR": Currency("INR", "rupee", "rupees", sub: ("paisa", "paise")),
            "KRW": Currency("KRW", "won", "won", sub: ("jeon", "jeon")),
            "CHF": Currency("CHF", "Swiss franc", "Swiss francs", sub: ("centime", "centimes")),
            "SEK": Currency("SEK", "Swedish krona", "Swedish kronor", sub: ("öre", "öre")),
            "NOK": Currency("NOK", "Norwegian krone", "Norwegian kroner", sub: ("øre", "øre")),
            "DKK": Currency("DKK", "Danish krone", "Danish kroner", sub: ("øre", "øre")),
            "MXN": Currency("MXN", "Mexican peso", "Mexican pesos", sub: ("centavo", "centavos")),
            "PHP": Currency("PHP", "Philippine peso", "Philippine pesos", sub: ("centavo", "centavos")),
            "BRL": Currency("BRL", "real", "reais", sub: ("centavo", "centavos")),
            "ZAR": Currency("ZAR", "rand", "rand", sub: ("cent", "cents")),
            "RUB": Currency("RUB", "ruble", "rubles", sub: ("kopeck", "kopecks")),
            "TRY": Currency("TRY", "lira", "lira", sub: ("kurus", "kurus")),
            "ILS": Currency("ILS", "shekel", "shekels", sub: ("agora", "agorot")),
            "PLN": Currency("PLN", "zloty", "zlotys", sub: ("grosz", "groszy")),
            "THB": Currency("THB", "baht", "baht", sub: ("satang", "satang")),
            "VND": Currency("VND", "dong", "dong"),
            "NGN": Currency("NGN", "naira", "naira", sub: ("kobo", "kobo")),
            "UAH": Currency("UAH", "hryvnia", "hryvnias", sub: ("kopiyka", "kopiykas")),
        ]
    }()

    /// Currency signs, before or after an amount. "฿" is the baht (its Unicode name), not
    /// bitcoin; "₱" is the peso the Philippines writes with it, so it says "pesos" alone.
    static let symbols: [String: Currency] = [
        "$": dollars("$", nil), "£": codes["GBP"]!, "€": codes["EUR"]!, "¥": codes["JPY"]!, "₹": codes["INR"]!,
        "₩": codes["KRW"]!, "₽": codes["RUB"]!, "₺": codes["TRY"]!, "₪": codes["ILS"]!,
        "₱": Currency("PHP", "peso", "pesos", sub: ("centavo", "centavos")), "₫": codes["VND"]!, "₦": codes["NGN"]!,
        "฿": codes["THB"]!, "₴": codes["UAH"]!, "₡": Currency("CRC", "colón", "colones", sub: ("céntimo", "céntimos")),
        "₿": Currency("BTC", "bitcoin", "bitcoin", decimal: true),
    ]

    /// Dollar signs with a country before them ("C$4.99", "US$1.2bn"), and the two that aren't
    /// dollars: Mexican pesos and Brazilian reais. "C$" is also the córdoba; Canadian wins in
    /// English text.
    static let dollarPrefixed: [String: Currency] = [
        "US": codes["USD"]!, "C": codes["CAD"]!, "CA": codes["CAD"]!, "CAD": codes["CAD"]!, "Can": codes["CAD"]!,
        "A": codes["AUD"]!, "AU": codes["AUD"]!, "AUD": codes["AUD"]!, "NZ": codes["NZD"]!, "HK": codes["HKD"]!,
        "S": codes["SGD"]!, "SG": codes["SGD"]!, "NT": codes["TWD"]!, "MX": codes["MXN"]!, "Mex": codes["MXN"]!,
        "R": codes["BRL"]!,
    ]

    /// Currencies written as an abbreviation. "kr" doesn't say which country: "kroner"
    /// (Danish, Norwegian), the same word as Swedish "kronor" but for one vowel. "R" is the rand.
    static let currencyWords: [String: Currency] = [
        "Rs": codes["INR"]!, "Rs.": codes["INR"]!, "kr": Currency("kr", "krone", "kroner", sub: ("øre", "øre")),
        "kr.": Currency("kr", "krone", "kroner", sub: ("øre", "øre")), "zł": codes["PLN"]!,
        "Fr.": Currency("Fr", "franc", "francs", sub: ("centime", "centimes")), "SFr.": codes["CHF"]!, "R": codes["ZAR"]!,
    ]

    /// The currency an amount in `c` is in when `code` follows it: `c` itself when the code
    /// repeats it ("€9.99 EUR", "C$5 CAD"), the code's when it says which dollar ("$15 CAD") or
    /// which currency "$" or "¥" stands for ("$50 MXN", "¥80 CNY"); nil when they disagree
    /// ("£5 USD"), and the code is left to be read as it is.
    static func currency(_ c: Currency, before code: String) -> Currency? {
        guard let named = codes[code] else { return nil }
        if named.code == c.code { return c }
        if c.code == "$", named.priceStyle || named.code == "MXN" || named.code == "PHP" { return named }
        if c.code == "JPY", named.code == "CNY" { return named }
        return nil
    }

    /// Amount suffixes after a currency amount ("$40m", "£2.3bn", "₹2 crore"), as words.
    static let scaleWords: [String: String] = [
        "k": "thousand", "K": "thousand", "m": "million", "M": "million", "mn": "million", "mm": "million", "MM": "million",
        "mln": "million", "mil": "million", "bn": "billion", "b": "billion", "B": "billion", "bln": "billion", "tn": "trillion",
        "trn": "trillion", "T": "trillion", "thousand": "thousand", "million": "million", "billion": "billion",
        "trillion": "trillion", "lakh": "lakh", "crore": "crore",
    ]
    static let scaleValues: [String: Double] = ["thousand": 1e3, "million": 1e6, "billion": 1e9, "trillion": 1e12,
                                                "lakh": 1e5, "crore": 1e7]

    /// An amount as written: "1,299.99", "12,50" (a decimal comma, before a currency after it),
    /// "1,00,000" (Indian grouping), ".73", with its magnitude ("2.5" and "M").
    struct Amount {
        /// The digits with a decimal comma as a point, for the number reader: "1,299.99", "12.50".
        let digits: String
        /// Before the point, as written: "1,299", "" for ".73".
        let whole: String
        /// `whole` as a number; nil when too big for one.
        let units: Int?
        let fraction: String?
        /// "million", "lakh crore"; empty for none.
        let magnitude: [String]
        /// Groups of two digits before the last three ("12,50,000"): lakh and crore with rupees.
        let indian: Bool
        /// A thousands separator or a decimal comma.
        let separated: Bool

        init(_ written: String, magnitude: String?) {
            // "1.234,56": dots between thousands and a decimal comma, read as "1,234.56".
            // "1'250": Swiss apostrophes between thousands, read as "1,250".
            var written = written.replacingOccurrences(of: "'", with: ",")
            if let dot = written.lastIndex(of: "."), let comma = written.lastIndex(of: ","), comma > dot {
                written = written.map { $0 == "." ? "," : $0 == "," ? "." : $0 }.reduce(into: "") { $0.append($1) }
            }
            let groups = written.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let commaGroups = groups[0].split(separator: ",", omittingEmptySubsequences: false)
            if groups.count == 1, commaGroups.count == 2, commaGroups[1].count == 2 {
                // "12,50 €": one comma and two digits is a decimal comma; English groups have three.
                whole = String(commaGroups[0])
                fraction = String(commaGroups[1])
                indian = false
            } else {
                whole = String(groups[0])
                fraction = groups.count > 1 ? String(groups[1]) : nil
                indian = commaGroups.count > 2 && commaGroups.dropFirst().dropLast().allSatisfy { $0.count == 2 }
            }
            digits = whole + (fraction.map { "." + $0 } ?? "")
            units = whole.isEmpty ? 0 : Int(whole.replacingOccurrences(of: ",", with: ""))
            separated = written.contains(",")
            self.magnitude = (magnitude ?? "").split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "\u{00A0}" })
                .map { MoneyPass.scaleWords[String($0)] ?? String($0) }
        }

        /// Money-shaped: a separator, exactly two decimals or a magnitude. A code or "R" before a
        /// plain number needs a price cue instead ("Wichita USD 259", "The R100 airship").
        var moneyShaped: Bool { separated || fraction?.count == 2 || !magnitude.isEmpty }

        /// No cents, or cents of zero ("$4.00").
        var isWhole: Bool { fraction.map { $0.allSatisfy { $0 == "0" } } ?? true }

        /// The value, scaled by `magnitude` (or by `shared`, a range's magnitude written only on
        /// its second number: "$5–10M").
        func value(sharing shared: [String] = []) -> Double {
            let n = Double(digits.replacingOccurrences(of: ",", with: "")) ?? 0
            return (magnitude.isEmpty ? shared : magnitude).reduce(n) { $0 * (MoneyPass.scaleValues[$1] ?? 1) }
        }
    }

    /// How an amount was said, so a range can say its currency once ("ten to twenty dollars").
    struct Reading {
        enum Kind { case whole, magnitude, cents, price, full, british, decimal }
        /// The number ("4 99", "10", "2.5 million"), or the whole reading when the currency sits
        /// inside it (`full`, `british`).
        let number: String
        /// What follows the number: "dollars", "Canadian dollars", "cents", or "" for a dollar price.
        let currency: String
        let kind: Kind
        var words: String { currency.isEmpty ? number : number + " " + currency }
    }

    /// `a` in `c`, in digits and words for the number reader. `singular` is for an amount used
    /// before a noun ("a five dollar bill").
    static func reading(_ a: Amount, _ c: Currency, singular: Bool) -> Reading {
        let country = c.country.map { $0 + " " } ?? ""
        func unit(_ count: Int?) -> String { singular || count == 1 ? c.one : c.many }
        if !a.magnitude.isEmpty {
            return Reading(number: a.digits + " " + a.magnitude.joined(separator: " "), currency: country + unit(nil), kind: .magnitude)
        }
        if a.indian, c.code == "INR", let units = a.units {
            let lakh = indianWords(units)
            guard let f = a.fraction, !a.isWhole, f.count == 2, let paise = Int(f) else {
                return Reading(number: lakh, currency: c.many, kind: .whole)
            }
            return Reading(number: "\(lakh) \(c.many) \(paise)", currency: "", kind: .british)
        }
        if a.isWhole {
            return Reading(number: a.whole.isEmpty ? "0" : a.whole, currency: country + unit(a.units), kind: .whole)
        }
        // One decimal in money is tens of cents: "$10.5" is ten fifty.
        if let f = a.fraction.map({ $0.count == 1 ? $0 + "0" : $0 }), f.count == 2, !c.decimal, let units = a.units, let cents = Int(f) {
            if units == 0, let sub = c.sub {
                // "$0.73": cents only, with the country after them ("ninety-nine cents Canadian").
                return Reading(number: String(cents), currency: (singular || cents == 1 ? sub.one : sub.many)
                               + (c.country.map { " " + $0 } ?? ""), kind: .cents)
            }
            if c.priceStyle, units > 0 {
                // "$4.99" is "four ninety-nine" and "$4.05" "four oh five". From $1,000, and on a
                // whole hundred ("$200.75" would sound like $275), the full form, as people say it.
                guard units >= 1000 || units % 100 == 0, let sub = c.sub else {
                    return Reading(number: a.whole + " " + (cents < 10 ? "oh \(cents)" : String(cents)),
                                   currency: c.country ?? "", kind: .price)
                }
                return Reading(number: "\(a.whole) \(country)\(units == 1 ? c.one : c.many) and \(cents) "
                               + (cents == 1 ? sub.one : sub.many), currency: "", kind: .full)
            }
            if units > 0, c.sub != nil {
                // "£4.99" is "four pounds ninety-nine": the unit word marks where the pence start,
                // so there's no "and" and no "pence", and "£1.05" is "one pound five".
                return Reading(number: "\(a.whole) \(units == 1 ? c.one : c.many) \(cents)", currency: "", kind: .british)
            }
        }
        // One decimal, three or more, or crypto: the number as written ("two point five dollars").
        return Reading(number: a.digits, currency: country + c.many, kind: .decimal)
    }

    /// Indian grouping in lakh and crore: 1,25,00,000 is "1 crore 25 lakh".
    static func indianWords(_ n: Int) -> String {
        var parts: [String] = []
        if n >= 10_000_000 { parts.append("\(n / 10_000_000) crore") }
        for (value, name) in [(100_000, "lakh"), (1000, "thousand")] where (n / value) % 100 > 0 {
            parts.append("\((n / value) % 100) \(name)")
        }
        if n % 1000 > 0 || parts.isEmpty { parts.append(String(n % 1000)) }
        return parts.joined(separator: " ")
    }

    /// What the dash between two amounts is.
    enum Dash {
        /// A range: the second amount is at least the first.
        case to
        /// An operator follows: "$20 - $5 = $15".
        case minus
        /// A falling pair with no operator: each amount is read whole, and the dash stays as written.
        case written(String)
    }

    /// Two amounts joined by a dash: "ten to twenty dollars", with the currency said once where
    /// both read it the same way; "four pounds ninety-nine to nine pounds ninety-nine" where it
    /// sits inside each. A magnitude written only on the second applies to both ("$5–10M"), and
    /// the same one on both is said once ("$85K–$95K").
    static func rangeWords(_ a: Amount, _ b: Amount, _ c: Currency, singular: Bool, dash: Dash) -> String {
        let second = reading(b, c, singular: singular)
        switch dash {
        case .minus: return reading(a, c, singular: false).words + " minus " + second.words
        case .written(let d): return reading(a, c, singular: false).words + " \(d) " + second.words
        case .to: break
        }
        if !a.magnitude.isEmpty || !b.magnitude.isEmpty {
            let shared = a.magnitude.isEmpty || a.magnitude == b.magnitude
            return a.digits + (shared ? "" : " " + a.magnitude.joined(separator: " ")) + " to " + second.words
        }
        let first = reading(a, c, singular: singular)
        if first.kind == second.kind, first.kind != .full, first.kind != .british {
            return first.number + " to " + second.words
        }
        return first.words + " to " + second.words
    }
}
