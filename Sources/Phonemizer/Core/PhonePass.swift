import Foundation

/// Phone numbers (Core readings, FIN-889; area "phone"): North American, international "+"
/// and trunk-0 numbers, extensions, area codes, emergency and short codes, and the "*" key.
///
/// The pass runs after money (its start boundary already excludes "$") and before the
/// custom lexicon, whose keys "+1", "401" and "404" would split a run of digits, and before
/// the measures pass, so "x 214" after a number is an extension, not a size.
enum PhonePass {
    typealias Rule = TextNormalizer.Rule

    /// The phone pass, in `Phonemizer.phonemize` after the money pass, only when normalizing.
    /// It writes words (so no later digit rule touches a number it read), in capitals inside a
    /// shouted sentence (`ShoutedCasing`). It reads nothing yet: fix3's rule below still does.
    static func apply(_ text: String, british: Bool) -> String {
        text
    }

    /// fix3/reading's phone rule (a leading 0 or "+"), still in TextNormalizer's rules after
    /// the short year, where it always ran. The phone pass replaces it.
    static func legacyRules(british: Bool) -> [Rule] {
        var rules: [Rule] = []
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
        return rules
    }
}
