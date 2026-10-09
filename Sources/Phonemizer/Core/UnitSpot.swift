import Foundation

/// One unit after a number, as a unit rule sees it: the text before the number, the text after
/// the unit and the sentence, all read with the custom lexicon's marks as their labels
/// (`RuleContext`), so "65 W USB-C charger" still has its "USB-C" though the rule's own text
/// stops at "65 W ". Each is worked out only when a rule first asks, and only for a match.
final class UnitSpot {
    /// The number as written ("2,000", "1.5"), without a sign.
    let number: String
    private let s: NSString
    private let range: NSRange
    private let numberRange: NSRange
    private let context: RuleContext

    /// - Parameter group: the capture group that holds the number.
    init(_ m: NSTextCheckingResult, number group: Int, in s: NSString, _ context: RuleContext) {
        self.s = s
        range = m.range
        numberRange = m.range(at: group)
        number = s.substring(with: numberRange)
        self.context = context
    }

    /// The text before the number.
    lazy var before: String = context.text(before: numberRange, in: s)
    /// The text after the unit.
    lazy var after: String = context.text(after: range, in: s)
    /// The sentence that holds the match.
    lazy var sentence: String = context.sentence(around: range, in: s)

    /// The sentence's words, as written ("AM", "XL") and lower-cased.
    lazy var written: Set<String> = {
        let ns = sentence as NSString
        return Set(Self.word.matches(in: sentence, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) })
    }()
    lazy var words: Set<String> = Set(written.map { $0.lowercased() })

    /// The word right before the number ("Room" in "Room 12 L"), when only spaces part them,
    /// and where it starts in `before`.
    private lazy var lastWord: (word: String, start: Int)? = {
        let ns = before as NSString
        // Only the end of the text can hold it: look at a short tail.
        let start = max(0, ns.length - 40)
        return Self.trailingWord.firstMatch(in: before, options: .withTransparentBounds, range: NSRange(location: start, length: ns.length - start))
            .map { (ns.substring(with: $0.range(at: 1)), $0.range(at: 1).location) }
    }()
    var wordBefore: String? { lastWord?.word }
    /// Up to `count` words before the number, nearest first, lower-cased; a symbol or a number
    /// between them stops the list ("loads in under" before "3s": under, in, loads).
    func wordsBefore(_ count: Int) -> [String] { Self.trailingWords(before, count: count) }
    /// The word right after the unit ("bulb" in "60 W bulb"), when only spaces part them.
    lazy var nextWord: String? = {
        let ns = after as NSString
        return Self.leadingWord.firstMatch(in: after, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }()

    /// Whether the sentence has any of `words` (lower case).
    func has(_ any: Set<String>) -> Bool { !words.isDisjoint(with: any) }

    /// Whether the sentence has a word starting with any of `stems` ("invest", "pull").
    func hasStem(_ stems: [String]) -> Bool { words.contains { w in stems.contains { w.hasPrefix($0) } } }

    /// Whether the unit is said in the singular: for one ("1 kg", "-1 V"), and before the noun
    /// it measures ("a 60 W bulb", "Our 5 yr plan", "the 2,000 sq ft office": a 60 watt bulb).
    /// Before "of", "per" or another little word, the plural stands ("a 5 kg or larger bag").
    var singular: Bool { singular(unit: "") }

    /// `singular`, knowing the unit as written ("mm", "lb", "oz"), for the units that modify a
    /// noun with nothing before them: a size in millimeters ("Buy 35mm film"), a heavy weight
    /// before a plural ("2,000lb bombs") and a container's size ("16 oz bottles").
    func singular(unit: String) -> Bool {
        if TextNormalizer.isOne(number) { return true }
        guard let next = nextWord, Self.isNoun(next) else { return false }
        if hasDeterminer { return true }
        // A count or a range before the number keeps the plural ("2 x 20cm round tins",
        // "0.5mm-1.5mm gap").
        if let w = Self.trailingWords(before, count: 1).first, ["x", "×", "to", "and", "or"].contains(w) { return false }
        if before.last == "-" || before.last == "–" { return false }
        switch unit {
        case "mm", "cm": return next.first?.isLowercase == true
        case "lb", "lbs":
            guard let n = Double(number.replacingOccurrences(of: ",", with: "")), n >= 100 else { return false }
            return Self.isPlural(next)
        case "oz", "floz", "ml", "mL", "L", "l": return Self.containers.contains(next.lowercased())
        // Before the thing it powers: "9V batteries", "12 V adapters", "60W bulbs".
        case "V", "W": return next.first?.isLowercase == true
        default: return false
        }
    }

    /// Whether the noun the unit measures has a determiner, a count or "x" before the number,
    /// past a hedge: "a 60 W bulb", "Our 5 yr plan", "a less than 5 min fix", "twelve 12 oz
    /// cans", "2 x 90 min sessions". A count or "x" only before a plural ("twelve 12 oz cans";
    /// "Add two 2 cups" is no noun).
    var hasDeterminer: Bool {
        let words = Self.trailingWords(before, count: 4)
        var i = 0
        if i < words.count, Self.hedges.contains(words[i]) { i += 1 }
        if i < words.count, words[i] == "than", i + 1 < words.count, ["less", "more", "fewer"].contains(words[i + 1]) { i += 2 }
        guard i < words.count else { return false }
        if Self.determiners.contains(words[i]) { return true }
        guard let next = nextWord, Self.isPlural(next) else { return false }
        return Self.counts.contains(words[i])
    }

    /// Whether `word` (as written) can be the noun a unit measures: a lower-case word that isn't
    /// a little word, an adverb or a past participle, or an acronym ("USB-C", "HDMI", "DC").
    static func isNoun(_ word: String) -> Bool {
        if word.first?.isLowercase == true {
            let w = word.lowercased()
            return !notNouns.contains(w) && !w.hasSuffix("ly") && !w.hasSuffix("ed")
        }
        let letters = word.filter(\.isLetter)
        return letters.count >= 2 && letters.allSatisfy(\.isUppercase)
    }

    /// Whether `word` looks like a plural noun: "bombs", "cans", "sessions"; not "is" or "this".
    static func isPlural(_ word: String) -> Bool {
        let w = word.lowercased()
        guard w.count >= 3, w.hasSuffix("s"), !w.hasSuffix("ss"), !w.hasSuffix("us"), !w.hasSuffix("is") else { return false }
        return !notNouns.contains(w)
    }

    /// The last `count` words of `text`, nearest first, lower-cased; a symbol between them ("x",
    /// "~", "<") counts as a word, so "2 x 90" has "x" before 90.
    private static func trailingWords(_ text: String, count: Int) -> [String] {
        var words: [String] = []
        var current = ""
        for c in text.reversed().prefix(48) {
            if c.isLetter || c == "'" || c == "’" || c == "×" {
                current = String(c) + current
                continue
            }
            if !current.isEmpty { words.append(current.lowercased()); current = "" }
            if words.count == count { return words }
            if c.isNumber || ".,;:!?()\"“”\n".contains(c) { return words }
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words
    }

    private static let determiners: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "my", "our", "your", "his", "her", "their", "its", "each", "every",
        "another", "any", "one",
    ]
    /// A count or "x" before the number: "twelve 12 oz cans", "2 x 90 min sessions".
    private static let counts: Set<String> = [
        "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "dozen", "x", "×", "several",
        "some", "many", "few",
    ]
    /// Hedges between a determiner and its number: "a nearly 5 kg bag", "an under 5 min fix".
    private static let hedges: Set<String> = ["about", "around", "nearly", "almost", "roughly", "approximately", "under", "over", "just", "only"]
    /// Containers a fluid's size names: "12 oz cans", "500 ml bottles".
    private static let containers: Set<String> = [
        "can", "cans", "bottle", "bottles", "jar", "jars", "cup", "cups", "glass", "glasses", "carton", "cartons", "tub", "tubs",
        "mug", "mugs", "pouch", "pouches", "pack", "packs", "steak", "steaks", "jug", "jugs", "tin", "tins",
    ]

    /// Whether the word before the number labels it ("Room 12 L", "Sector 7 W", "Take Route
    /// 9 W"): a label word, or any capitalised word that doesn't start the sentence. A letter
    /// after a label is part of a name, never a unit.
    var afterLabel: Bool {
        guard let found = lastWord else { return false }
        if Self.labelWords.contains(found.word.lowercased()) { return true }
        guard found.word.first?.isUppercase == true else { return false }
        // At the start of the sentence a word is capitalised anyway ("Walk 1 m to the left").
        let head = (before as NSString).substring(to: found.start)
        guard let last = head.last(where: { !$0.isWhitespace }) else { return false }
        return !".!?…:\"“(".contains(last)
    }

    /// Words that follow a unit without being the noun it measures: little words, verbs and
    /// adverbs of place and time ("the 5 km between them", "the 10 minutes left", "a 3 km walk
    /// away" stays "walk").
    private static let notNouns: Set<String> = [
        "of", "per", "each", "or", "and", "to", "in", "a", "an", "the", "for", "at", "on", "by", "from", "with", "without",
        "into", "onto", "over", "under", "between", "behind", "ahead", "before", "after", "since", "until", "till", "through",
        "across", "along", "around", "past", "via", "than", "as", "so", "but", "nor", "if", "when", "while", "because",
        "is", "are", "was", "were", "be", "been", "being", "has", "have", "had", "will", "would", "can", "could", "should",
        "may", "might", "must", "do", "does", "did", "it", "he", "she", "we", "they", "you", "i", "this", "that", "there",
        "here", "away", "ago", "later", "earlier", "left", "remaining", "more", "less", "total", "apart", "back", "off", "out",
        "up", "down", "too", "very", "already", "still", "just", "only", "then", "now", "today", "tonight", "yesterday",
        "tomorrow", "overnight", "apiece", "extra", "plus", "minus", "times", "x", "every", "which", "who", "whose", "what",
        "where", "how", "why", "all", "both", "either", "neither", "vs", "versus", "late", "early", "instead", "again", "fewer",
        "ish",
    ]

    /// Words that label the number after them (rooms, seats, routes, grades), lower-cased. A
    /// word that also measures ("a track 400 m long", "a tower 30 m high") isn't one. Numbered
    /// fittings are labels too, though their sentence is about electricity: "Plug the lamp into
    /// outlet 4 A" is outlet four A, not four amps.
    private static let labelWords: Set<String> = [
        "room", "rooms", "apartment", "apt", "suite", "ste", "unit", "floor", "gate", "platform", "terminal", "seat",
        "grade", "size", "sizes", "route", "highway", "hwy", "studio", "section", "chapter", "page", "phase", "type",
        "vitamin", "class", "lot", "bus", "sector", "wing", "level", "pier", "dock", "hall", "concourse", "aisle",
        "locker", "slot", "exit", "junction", "zone", "ward", "cabin", "berth", "item", "model", "version", "no",
        "booth", "row", "plan", "tier", "group", "division", "outlet", "socket", "circuit", "bay", "channel",
        // Codes: "Use code 2L", "Booking ref 4W".
        "code", "ref", "reference", "promo", "coupon", "voucher", "booking", "confirmation", "pin", "id",
    ]

    private static let word = try! NSRegularExpression(pattern: #"\p{L}+"#)
    private static let leadingWord = try! NSRegularExpression(pattern: #"^\h+(\p{L}[\p{L}\d'’\-]*)"#)
    private static let trailingWord = try! NSRegularExpression(pattern: #"(?<![\p{L}\d])(\p{L}+)\h+$"#)
}
