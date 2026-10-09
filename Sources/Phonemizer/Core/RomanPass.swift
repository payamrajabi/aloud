import Foundation

/// Roman numerals (Core readings, FIN-889; area "roman"): monarchs and popes ("Henry the
/// Eighth"), world wars, document parts, classes and stages, sequels, teams and years.
///
/// The pass runs after the custom lexicon (its keys hold numerals: "SOC 2 Type II", "GTA V",
/// "Mac OS X") and before `unshout`, so a numeral in a shouted sentence is still in capitals.
/// It reads marks as their labels (`LabelView`) and never rewrites inside one.
enum RomanPass {
    typealias Rule = TextNormalizer.Rule

    /// The Roman pass, in `Phonemizer.phonemize` after `custom.mark` and before `unshout`,
    /// only when normalizing. Inserted words go through `ShoutedCasing`. It reads nothing
    /// yet: the FIN-877 reader below still does, from `readAfterUnshout`.
    static func apply(_ text: String, british: Bool) -> String {
        text
    }

    /// The FIN-877 reader, still called where it always ran: in `TextNormalizer.normalize`,
    /// after `unshout`, before `readStreets`. Once the pass above reads numerals, this
    /// returns the text unchanged.
    static func readAfterUnshout(_ text: String) -> String {
        readRomanNumerals(text)
    }

    /// Regnal and sequel numerals ("Henry VIII", "World War II"), up to LXXXIX. C, D and M are
    /// left out, so "MIX", "CD", "DC" and "MD" stay words and letters.
    private static let romanPattern = #"(?=[IVXL])(?:XL|L?X{0,3})(?:IX|IV|V?I{0,3})"#
    private static func romanValue(_ s: String) -> Int? {
        guard s.range(of: "^" + romanPattern + "$", options: .regularExpression) != nil else { return nil }
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50]
        var total = 0
        let chars = Array(s)
        for (i, c) in chars.enumerated() {
            let v = values[c]!
            if i + 1 < chars.count, v < values[chars[i + 1]]! { total -= v } else { total += v }
        }
        return total > 0 ? total : nil
    }
    /// Words after which a numeral is a number ("Part II", "Phase III", "Type I"), in lower case.
    private static let numeralNouns: Set<String> = [
        "part", "chapter", "phase", "volume", "vol", "vol.", "act", "scene", "book", "episode", "type", "stage", "level",
        "class", "tier", "grade", "section", "article", "title", "schedule", "appendix", "annex", "season", "series",
        "mark", "mk", "mk.", "model", "gen", "generation", "version", "round", "division", "league", "group", "category",
        "fantasy", "apollo", "psalm", "canto", "movement", "symphony", "unit", "track", "disc", "disk", "wave", "block",
        "zone", "sector", "form", "rule", "figure", "fig.", "table", "item", "step", "page", "number", "no.", "vatican",
        "plate", "list", "tome", "parts", "chapters", "exhibit", "room", "floor", "gate", "terminal", "year", "lot",
    ]
    /// Titles before a name whose single-letter numeral is an ordinal ("Queen Elizabeth I").
    private static let regnalTitles: Set<String> = [
        "King", "Queen", "Pope", "Emperor", "Empress", "Tsar", "Tsarina", "Czar", "Prince", "Princess", "Duke", "Duchess",
        "Pharaoh", "Sultan", "Kaiser", "Saint", "St.", "Archduke", "Shah", "Emir", "Grand",
    ]
    /// Numerals that are also common letters or sizes, read as numbers only after `numeralNouns`.
    private static let ambiguousNumerals: Set<String> = ["XL", "LV", "LX", "LI", "XX", "XXX"]
    /// Words after a single-letter "I" that make it the pronoun ("Part I want…").
    private static let pronounFollowers: Set<String> = [
        "am", "was", "have", "had", "think", "want", "will", "would", "can", "could", "do", "did", "know", "need",
        "like", "love", "see", "saw", "said", "say", "feel", "felt", "mean", "guess", "hope", "believe", "found", "get",
        "got", "just", "really", "also", "never", "always", "don't", "can't", "won't", "didn't", "must", "should",
        "may", "might", "went", "made", "agree", "wish", "remember", "learned", "learnt", "wrote", "read",
    ]

    /// "Elizabeth II" → "Elizabeth the second", "World War II" → "World War two". `prev` is the
    /// word before the numeral, `before` the text before that word.
    private static func readRoman(_ numeral: String, after prev: String, before: String, next: String) -> String? {
        // A lone "X" is a letter: "Malcolm X", "Model X", "Generation X".
        guard numeral != "X", let value = romanValue(numeral) else { return nil }
        let prevLower = prev.lowercased()
        let previousWords = before.split(whereSeparator: { $0.isWhitespace })
        let wordBefore = previousWords.last.map { String($0).trimmingCharacters(in: .punctuationCharacters) } ?? ""
        var cardinal = numeralNouns.contains(prevLower)
            || (prevLower == "war" && wordBefore.lowercased() == "world")
            || (prevLower == "bowl" && wordBefore.lowercased() == "super")
        if cardinal, numeral.count == 1 {
            // A lone "I" is the pronoun unless the noun is capitalised ("Part I", not "the level I
            // want") and no verb follows.
            let nextWord = next.lowercased().replacingOccurrences(of: "’", with: "'")
            cardinal = prev.first?.isUppercase == true && !(numeral == "I" && pronounFollowers.contains(nextWord))
        }
        if cardinal { return NumberWords.cardinal(value) }
        // After a name, not a size or a brand ("Size XL", "Louis Vuitton LV").
        guard let first = prev.first, first.isUppercase, prev.dropFirst().allSatisfy({ $0.isLowercase || $0 == "-" }),
              prev.count > 1, !Tokenizer.sentenceStarters.contains(prev), !ambiguousNumerals.contains(numeral) else { return nil }
        // A ruler ("Henry the eighth", "Queen Elizabeth the first", "Pope Leo the fourteenth") or
        // a family name after a first name ("John Smith the third") is an ordinal.
        let ruler = regnalNames.contains(prev) || regnalTitles.contains(wordBefore)
        let heir = regnalNames.contains(wordBefore) && wordBefore.first?.isUppercase == true
        if numeral.count == 1 {
            // "Henry V"; but "I" after a bare name is usually the pronoun ("Thanks Paul I owe you"),
            // so only after a title ("Queen Elizabeth I").
            guard numeral == "I" ? regnalTitles.contains(wordBefore) && !pronounFollowers.contains(next.lowercased()) : ruler
            else { return nil }
            return "the " + NumberWords.ordinal(value)
        }
        // After any other title, a number: "Rocky three", "Street Fighter two".
        return ruler || heir ? "the " + NumberWords.ordinal(value) : NumberWords.cardinal(value)
    }
    /// Given names of rulers and popes (and common first names before a family name).
    private static let regnalNames: Set<String> = [
        "Henry", "Edward", "George", "William", "Charles", "James", "Richard", "John", "Elizabeth", "Mary", "Anne",
        "Victoria", "Louis", "Philip", "Philippe", "Felipe", "Ferdinand", "Frederick", "Friedrich", "Wilhelm", "Ludwig",
        "Leopold", "Francis", "Franz", "Joseph", "Peter", "Ivan", "Nicholas", "Alexander", "Catherine", "Paul", "Pius",
        "Leo", "Gregory", "Benedict", "Clement", "Innocent", "Urban", "Boniface", "Sixtus", "Julius", "Adrian", "Alfonso",
        "Juan", "Carlos", "Gustav", "Gustavus", "Carl", "Christian", "Frederik", "Haakon", "Olav", "Harald", "Rama",
        "Ramesses", "Ramses", "Thutmose", "Amenhotep", "Constantine", "Justinian", "Otto", "Rudolf", "Albert", "Napoleon",
        "Mehmed", "Suleiman", "Selim", "Murad", "Abdullah", "Hussein", "Faisal", "Darius", "Xerxes", "Cyrus", "Ptolemy",
        "Malcolm", "David", "Robert", "Alfred", "Edmund", "Harold", "Stephen", "Pedro", "Manuel", "Sancho", "Casimir",
        "Sigismund", "Vladimir", "Matthias", "Maximilian", "Umberto", "Emmanuel", "Isabella", "Isabel", "Margaret",
        "Margrethe", "Christina", "Rainier", "Baudouin", "Willem", "Amadeus", "Michael", "Thomas", "Daniel", "Martin",
    ]

    private static let romanCandidate = try! NSRegularExpression(pattern: #"(?<![\p{L}\d'’/\[])[IVXL]{1,7}(?=(?:['’]s)?(?![\p{L}\d'’\]]))"#)
    private static let wordBeforeSpace = try! NSRegularExpression(pattern: #"\p{L}[\p{L}'’.\-]*[ \t]+$"#)

    /// Roman numerals were spelled out ("World War I I", "Henry V I I I"): after a ruler's name
    /// they're ordinals ("Henry the eighth"), after "Part", "Phase", "World War" or a title they
    /// are numbers ("Phase three", "Street Fighter two"). `readRoman` decides, and leaves the
    /// pronoun "I" and words like "MIX". Read with the marked terms in view, as arrows are:
    /// "Apollo" in "Apollo XI" is a custom-lexicon term.
    private static func readRomanNumerals(_ text: String) -> String {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let matches = romanCandidate.matches(in: text, range: all)
        guard !matches.isEmpty else { return text }
        let marks = TextNormalizer.marked.matches(in: text, range: all).map(\.range)
        var out = "", last = 0
        for m in matches where !marks.contains(where: { NSLocationInRange(m.range.location, $0) }) {
            let start = max(0, m.range.location - 120)
            let window = ns.substring(with: NSRange(location: start, length: m.range.location - start))
            let before = TextNormalizer.marked.stringByReplacingMatches(in: window, range: NSRange(location: 0, length: (window as NSString).length), withTemplate: "$1")
            let bs = before as NSString
            guard let w = wordBeforeSpace.firstMatch(in: before, range: NSRange(location: 0, length: bs.length)) else { continue }
            let prev = bs.substring(with: w.range).trimmingCharacters(in: .whitespaces)
            let after = ns.substring(from: NSMaxRange(m.range))
            let next = String(after.drop { !$0.isLetter && !$0.isNewline }.prefix { $0.isLetter || $0 == "'" || $0 == "’" })
            guard let words = readRoman(ns.substring(with: m.range), after: prev, before: bs.substring(to: w.range.location), next: next)
            else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + words
            last = NSMaxRange(m.range)
        }
        return out + ns.substring(from: last)
    }

    /// The "WW2" rule, still last in TextNormalizer's rules. The Roman pass replaces it.
    static func legacyRules(british: Bool) -> [Rule] {
        var rules: [Rule] = []
        rules.append(Rule(#"(?<![\p{L}\d])WW(II|I|2|1)(?![\p{L}\d])"#) { m, s in
            ["II", "2"].contains(s.substring(with: m.range(at: 1))) ? "World War Two" : "World War One"
        })
        return rules
    }
}
