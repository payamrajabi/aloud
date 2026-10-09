import Foundation

/// Addresses (Core readings, FIN-889; area "addresses"): house numbers, street types and
/// directions, units and boxes, route numbers, states and provinces, ZIP and postal codes, and
/// "St." as Saint, Street or Suite.
///
/// The pass runs after the phone pass (a ZIP or ZIP+4 is a shape phones reject) and before the
/// titles pass, so "Ocean Dr. Suite 3" is Drive before any title rule sees "Dr.". It runs before
/// the custom lexicon, whose marks include CA, GA, IL, MD, DR, Room, Box and SE. In a British
/// postcode it writes "zed" for the British voice (cross.json: addresses and titles).
enum AddressPass {
    typealias Rule = TextNormalizer.Rule

    /// The address pass: in `Phonemizer.phonemize` after the phone pass, only when normalizing.
    /// Its words go through `ShoutedCasing` and `SpokenNumbers`. It reads nothing yet.
    static func apply(_ text: String, british: Bool) -> String {
        text
    }

    /// Whether `head`, a sentence as Apple's splitter cut it (trimmed), ends in an abbreviation
    /// of this area that runs on into `next` ("Elm Rd." + "Suite 3", "Albany, N.Y." + "…"), so
    /// the two are read as one. nil leaves it to `Tokenizer.titleContinues`. Each one needs a
    /// chunk case in Tests/g2p/regression.json: the speech tests phonemize whole lines and never
    /// see the split.
    static func sentenceContinues(_ head: String, into next: String) -> Bool? {
        nil
    }

    /// Street-type and place abbreviations in TextNormalizer's abbreviation list, read where they
    /// always were, near the end of the rules ("Ave." is Avenue anywhere, "Mt." Mount).
    static func abbreviationRules(british: Bool) -> [Rule] {
        var rules: [Rule] = []
        for (abbr, full) in abbreviations {
            rules.append(Rule("(?<![\\p{L}.])" + NSRegularExpression.escapedPattern(for: abbr) + "(?=\\s|$|[,;:)])") { _, _ in full })
        }
        return rules
    }

    private static let abbreviations: [(String, String)] = [("Ave.", "Avenue"), ("Blvd.", "Boulevard"), ("Mt.", "Mount")]

    private static let saint = try! NSRegularExpression(pattern: #"(?<![\p{L}.])St\."#)
    private static let nameNext = try! NSRegularExpression(pattern: "^" + TextNormalizer.namePattern)
    private static let streetEnd = try! NSRegularExpression(pattern: #"^(?:(\s*$|\s+\p{Lu})|\s|[,;:)])"#)

    /// "St.": Saint before a name ("Mount St. Helens", "Yves St. Laurent", "to St. Louis"), unless
    /// it ends a street's name (`Tokenizer.isStreet`: "5th St.", "Park on Elm St. Bring cash.");
    /// any other "St." after a word is a street ("Main St."). At the end of a sentence its period
    /// is also the full stop, so that stays ("Street."). Read with the marked terms in view: "Elm"
    /// in "on Elm St." is a custom-lexicon term, and seen alone "St. Bring" was "Saint Bring".
    /// Called from `TextNormalizer.normalize`, after the arrows and Roman numerals are read.
    static func readStreets(_ text: String) -> String {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let matches = saint.matches(in: text, range: all)
        guard !matches.isEmpty else { return text }
        let marks = TextNormalizer.marked.matches(in: text, range: all).map(\.range)
        func plain(_ s: String) -> String {
            TextNormalizer.marked.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "$1")
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
}
