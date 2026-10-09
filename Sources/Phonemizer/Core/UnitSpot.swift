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
    /// it measures after "a" or "an" ("a 60 W bulb", "a 4 min mile": a 60 watt bulb). After
    /// "the", or before "of", "per" or another little word, the plural stands ("the 65 W
    /// charger", "a 5 kg or larger bag").
    var singular: Bool { TextNormalizer.isOne(number) || modifiesNoun }

    /// After "a"/"an", before a lower-case noun. Only a lower-case article for now: a sentence
    /// that opens "A 3mm screw." keeps the plural that regression.json's lexicon cases still
    /// expect ("A 3mm screw.", "A 100Mbps link."), until those are brought in line.
    var modifiesNoun: Bool {
        guard let next = nextWord, next.first?.isLowercase == true, !Self.notNouns.contains(next),
              let article = wordBefore, article == "a" || article == "an" else { return false }
        return true
    }

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

    /// Words that follow a unit without being the noun it measures.
    private static let notNouns: Set<String> = ["of", "per", "each", "or", "and", "to", "in", "a", "an", "the", "for"]

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
    ]

    private static let word = try! NSRegularExpression(pattern: #"\p{L}+"#)
    private static let leadingWord = try! NSRegularExpression(pattern: #"^\h+(\p{L}[\p{L}\d'’\-]*)"#)
    private static let trailingWord = try! NSRegularExpression(pattern: #"(?<![\p{L}\d])(\p{L}+)\h+$"#)
}
