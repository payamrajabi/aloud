import Foundation

/// Everyday shorthand (Core readings, FIN-889; area "shorthand"): the slash forms (w/, w/o,
/// b/c, c/o), Attn, and min. and max. before a number. The signs and the other
/// abbreviations are rules in TextNormalizer's list (`ShorthandRules`).
///
/// The pass runs before the custom lexicon, because "Max" is a case-sensitive key and the
/// lexicon never matches right after "/", and after money, so "est." and "min." still see
/// the digits of "2,000 pounds".
enum ShorthandPass {
    typealias Rule = TextNormalizer.Rule

    /// The shorthand pass, in `Phonemizer.phonemize` after the titles pass, only when
    /// normalizing. Inserted words go through `ShoutedCasing`. It reads nothing yet.
    static func apply(_ text: String, british: Bool) -> String {
        text
    }

    /// Whether `head`, a sentence as Apple's splitter cut it, ends in shorthand of this area
    /// that runs on into `next` ("Attn." + "Maria Lopez", "c." + "1650"), so the two are read
    /// as one. nil leaves it to `Tokenizer.titleContinues`. Each one needs a chunk case in the
    /// regression tests: the speech tests phonemize whole lines and never see the split.
    static func sentenceContinues(_ head: String, into next: String) -> Bool? {
        nil
    }
}
