import Foundation

/// English number words, matching Python's num2words (lang "en"), which misaki uses.
/// (The number reader in MisakiSwift read 2026 as "twenty six" and 22nd as "second".)
enum NumberWords {
    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                               "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
                               "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    private static let scales = ["", "thousand", "million", "billion", "trillion", "quadrillion", "quintillion"]

    /// num2words(n): "one million, two hundred and thirty-four thousand, five hundred and sixty-seven".
    static func cardinal(_ n: Int) -> String {
        if n < 0 { return "minus " + cardinal(-n) }
        if n < 1000 { return belowThousand(n) }
        var groups: [Int] = []
        var rest = n
        while rest > 0 { groups.append(rest % 1000); rest /= 1000 }
        var parts: [String] = []
        for (i, g) in groups.enumerated().reversed() where g > 0 {
            if i == 0 {
                // num2words joins a final part under 100 with "and", otherwise with a comma.
                if g < 100, !parts.isEmpty {
                    parts[parts.count - 1] += " and " + belowThousand(g)
                } else {
                    parts.append(belowThousand(g))
                }
            } else {
                parts.append(belowThousand(g) + " " + scales[i])
            }
        }
        return parts.joined(separator: ", ")
    }

    private static func belowThousand(_ n: Int) -> String {
        if n < 20 { return ones[n] }
        if n < 100 { return tens[n / 10] + (n % 10 == 0 ? "" : "-" + ones[n % 10]) }
        let r = n % 100
        return ones[n / 100] + " hundred" + (r == 0 ? "" : " and " + belowThousand(r))
    }

    /// num2words(n, to="ordinal").
    static func ordinal(_ n: Int) -> String {
        let words = cardinal(n)
        // Only the last word changes: "twenty-two" → "twenty-second".
        let separators = CharacterSet(charactersIn: " -")
        guard let r = words.rangeOfCharacter(from: separators, options: .backwards) else { return ordinalWord(words) }
        return String(words[..<r.upperBound]) + ordinalWord(String(words[r.upperBound...]))
    }

    private static func ordinalWord(_ w: String) -> String {
        let irregular = ["one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth",
                         "nine": "ninth", "twelve": "twelfth"]
        if let o = irregular[w] { return o }
        if w.hasSuffix("y") { return w.dropLast() + "ieth" }
        return w + "th"
    }

    /// num2words(n, to="year"): 2026 → "twenty twenty-six", 1905 → "nineteen oh-five", 2005 → "two thousand and five".
    static func year(_ value: Int) -> String {
        let val = abs(value)
        let high = val / 100, low = val % 100
        var text: String
        if high == 0 || (high % 10 == 0 && low < 10) || high >= 100 {
            text = cardinal(val)
        } else {
            let lowText = low == 0 ? "hundred" : low < 10 ? "oh-" + cardinal(low) : cardinal(low)
            text = cardinal(high) + " " + lowText
        }
        if value < 0 { text += " BC" }
        return text
    }

    /// Digit by digit, for a number too big to read whole: "one two three".
    static func digits(_ s: String) -> String {
        s.compactMap { $0.wholeNumberValue }.map { ones[$0] }.joined(separator: " ")
    }

    /// num2words(float(s)) for a decimal string such as "3.14" or "0.5": "three point one four".
    static func decimal(_ s: String) -> String? {
        guard let d = Double(s), d.isFinite else { return nil }
        // Written out plainly ("3.10", "9.50", "2.0"), every digit after the point is read: Python
        // reads the float, so "Python 3.10" became 3.1, a different release, and "1.00" just "one".
        if let m = s.range(of: #"^-?\d+\.\d+$"#, options: .regularExpression), m == s.startIndex..<s.endIndex {
            let negative = s.hasPrefix("-")
            let parts = s.dropFirst(negative ? 1 : 0).split(separator: ".")
            let whole = Int(parts[0]).map(cardinal) ?? digits(String(parts[0]))
            return (negative ? "minus " : "") + whole + " point " + digits(String(parts[1]))
        }
        if d == d.rounded(), abs(d) < 1e15 { return cardinal(Int(d)) }  // num2words(3.0) is "three"
        // Python reads the float's shortest repr, so "4.50" becomes 4.5. One in exponent form
        // ("1e-22", "1.2345678901234568e+29") is read from the digits as written instead:
        // reformatting it rounded tiny numbers to zero and overflowed big ones.
        var repr = "\(d)"
        if repr.contains("e") { repr = s.replacingOccurrences(of: #"(\.\d*?)0+$"#, with: "$1", options: .regularExpression) }
        let parts = repr.split(separator: ".", omittingEmptySubsequences: false)
        let negative = repr.hasPrefix("-")
        let intDigits = parts[0].replacingOccurrences(of: "-", with: "")
        var text = (negative ? "minus " : "") + (Int(intDigits).map(cardinal) ?? digits(intDigits))
        if parts.count > 1, !parts[1].isEmpty {
            text += " point " + digits(String(parts[1]))
        }
        return text
    }
}
