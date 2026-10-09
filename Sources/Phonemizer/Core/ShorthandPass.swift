import Foundation

/// Everyday shorthand (Core readings, FIN-889; area "shorthand"), the part read before the
/// custom lexicon: the slash forms (w/, w/o, b/c, c/o), Attn, and min. and max. before a number.
/// The signs and the other abbreviations are rules in TextNormalizer's list (`ShorthandRules`).
///
/// The pass runs before the custom lexicon, because "Max" is a case-sensitive key and the
/// lexicon never matches right after "/", and after money, so "est." and "min." still see the
/// digits of "2,000 pounds". It is the only owner of c/o (cross.json: addresses and shorthand).
enum ShorthandPass {
    typealias Rule = TextNormalizer.Rule

    /// The shorthand pass: in `Phonemizer.phonemize` after the titles pass, only when
    /// normalizing. Its words go through `ShoutedCasing`. It reads nothing yet.
    static func apply(_ text: String, british: Bool) -> String {
        text
    }

    /// Whether `head`, a sentence as Apple's splitter cut it (trimmed), ends in shorthand of this
    /// area that runs on into `next` ("Attn." + "Maria Lopez", "built ca." + "1850"), so the two
    /// are read as one. nil leaves it to `Tokenizer.titleContinues`. Each one needs a chunk case
    /// in Tests/g2p/regression.json: the speech tests phonemize whole lines and never see the split.
    static func sentenceContinues(_ head: String, into next: String) -> Bool? {
        nil
    }
}
