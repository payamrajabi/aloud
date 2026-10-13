import Foundation

/// Number words for the Core passes that write words instead of digits (phones, addresses,
/// Roman numerals, dates), written as the number reader says the same digits.
///
/// `NumberWords` follows num2words: "ninety-nine", "one hundred and five", "one million, two
/// hundred thousand". The lexicon reads digits from those words with the hyphens, commas and
/// "and" dropped, and a hyphenated compound is one word to the stack, with other stress than
/// the same number in digits ("ninety-nine" is nˈIndinˌIn in the US voice, "99" nˈIndi nˈIn).
/// So every rule writes number words without them (cross.json, conflict 1; DECISIONS 9), and
/// the British voice keeps the number reader's reading, with no "and" (DECISIONS 2).
enum SpokenNumbers {
    /// "one hundred twenty three".
    static func cardinal(_ n: Int) -> String { plain(NumberWords.cardinal(n)) }

    /// "twenty third".
    static func ordinal(_ n: Int) -> String { plain(NumberWords.ordinal(n)) }

    /// As the lexicon reads a four-digit year: "nineteen oh five", "twenty twenty four", "two
    /// thousand five".
    static func year(_ n: Int) -> String { plain(NumberWords.year(n)) }

    /// Digit by digit, with `zero` for 0 ("oh" in phone and house numbers): "four oh one".
    static func digits<S: StringProtocol>(_ s: S, zero: String = "oh") -> String {
        s.compactMap(\.wholeNumberValue).map { $0 == 0 ? zero : NumberWords.cardinal($0) }.joined(separator: " ")
    }

    /// `words` without hyphens, commas or "and": "one hundred and twenty-three" → "one hundred
    /// twenty three".
    static func plain(_ words: String) -> String {
        words.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "," })
            .filter { $0 != "and" }
            .joined(separator: " ")
    }
}
