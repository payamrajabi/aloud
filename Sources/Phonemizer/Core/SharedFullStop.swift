import Foundation

/// Whether the period of an abbreviation a Core rule expands ("Jr.", "St.", "kr.", "in.",
/// "Dec.", "misc.") is also its sentence's full stop.
///
/// Written out, the abbreviation loses its period ("Junior", "inches"). When that period was
/// also the full stop, the sentence loses its final fall and runs into the next, so the
/// expansion keeps one ("Junior."). The areas agree on the end of the text or a line, and
/// differ only in which next word starts a new sentence (`Next`).
enum FullStop {
    /// The word after the period (past spaces) that makes the period a full stop.
    enum Next {
        /// Any capitalised word, as `readStreets` decides "Street." ("Main St. Then…"): money's
        /// "kr.", units' and measures' "in.", addresses' street types and states.
        case capital
        /// A capitalised word that isn't a weekday, month or time word (`CalendarNames.timeWords`),
        /// as the meridiem rule decides "A.M.": dates' "Dec." and "Tues.", centuries' "c.".
        case capitalNotTimeWord
        /// A usual sentence opener (`Tokenizer.sentenceStarters`): titles' "Jr." and "Sr.",
        /// where "Sr. Mary" is a name and "…Jr. He" ends the sentence.
        case sentenceStarter
    }

    /// Whether a period followed by `rest` (the text after it) ends the sentence: nothing but
    /// spaces before the end of the text or a line break, or spaces and then a word `next` takes.
    static func ends<S: StringProtocol>(before rest: S, next: Next) -> Bool {
        var i = rest.startIndex
        while i < rest.endIndex, rest[i] == " " || rest[i] == "\t" { i = rest.index(after: i) }
        guard i < rest.endIndex else { return true }
        if rest[i].isNewline { return true }
        guard i > rest.startIndex, rest[i].isUppercase else { return false }
        var e = i
        while e < rest.endIndex, rest[e].isLetter || rest[e] == "'" || rest[e] == "’" { e = rest.index(after: e) }
        let word = String(rest[i..<e]).replacingOccurrences(of: "’", with: "'")
        switch next {
        case .capital: return true
        case .capitalNotTimeWord: return word.contains(where: \.isLowercase) && !CalendarNames.timeWords.contains(word)
        case .sentenceStarter: return sentenceStarters.contains(word)
        }
    }

    /// What an expansion keeps of the abbreviation's period: "." when it ends the sentence,
    /// otherwise nothing.
    static func kept<S: StringProtocol>(before rest: S, next: Next) -> String {
        ends(before: rest, next: next) ? "." : ""
    }

    private static let sentenceStarters = Set(Tokenizer.sentenceStarters)
}
