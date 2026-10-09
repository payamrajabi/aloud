import Foundation

/// Titles and name suffixes (Core readings, FIN-889; area "titles"): ranks and offices before a
/// name ("Lt. Col. Smith"), "Gen." as a generation, Jr. and Sr., Esq., "Lt." as light, and the
/// period of a title that is also the full stop.
///
/// The pass runs on the raw text before the custom lexicon, so a name the lexicon would mark is
/// still in view and the tech entries CPL, ENS, SNR and LTS don't take a title first. It runs
/// after the address pass, so "Ocean Dr. Suite 3" is already Drive. It owns Jr and Sr (the Roman
/// area's R3 is deleted in favour of T5).
enum TitlePass {
    typealias Rule = TextNormalizer.Rule

    /// The titles pass: in `Phonemizer.phonemize` after the address pass, only when normalizing.
    /// Its words go through `ShoutedCasing`. It reads nothing yet: the rule below still does,
    /// in TextNormalizer's list.
    static func apply(_ text: String, british: Bool) -> String {
        text
    }

    /// Whether `head`, a sentence as Apple's splitter cut it (trimmed), ends in a title of this
    /// area that runs on into `next` ("Det." + "Benson called.", "Rt. Rev." + "Holmes"), so the
    /// two are read as one. nil leaves it to `Tokenizer.titleContinues`. Each one needs a chunk
    /// case in Tests/g2p/regression.json: the speech tests phonemize whole lines and never see
    /// the split.
    static func sentenceContinues(_ head: String, into next: String) -> Bool? {
        nil
    }

    /// Titles, spelled out only before a name ("Sen. Warren" → Senator Warren). At the end
    /// of a sentence or before a lower-case word they're names or words ("Amartya Sen.").
    private static let titles = ["Sen": "Senator", "Gov": "Governor", "Prof": "Professor", "Gen": "General",
                                 "Rep": "Representative", "Rev": "Reverend"]

    /// The title rule, near the end of TextNormalizer's list, where it always ran. The titles
    /// pass replaces it (T0); then this returns no rules.
    static func legacyRules(british: Bool) -> [Rule] {
        var rules: [Rule] = []
        // Titles before a name: a capitalised word that isn't a usual sentence opener. ("St." is
        // read in `readStreets`, with the terms the custom lexicon marked in view.)
        rules.append(Rule(#"(?<![\p{L}.])("# + titles.keys.sorted().joined(separator: "|") + #")\."# + TextNormalizer.namePattern) { m, s in
            titles[s.substring(with: m.range(at: 1))]!
        })
        return rules
    }
}
