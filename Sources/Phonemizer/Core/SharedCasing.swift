import Foundation

/// Writes the words a Core pass inserts in the case of the sentence around them.
///
/// The passes before the custom lexicon (money, phones, addresses, titles, shorthand, measures)
/// and the Roman pass run before `Phonemizer.unshout`. Unshout reads a sentence written all in
/// capitals ("CALL 555-0100 NOW", "PRICE: $5 EACH") word by word in lower case, but only while
/// the sentence has no lower-case letter (`ShoutedSentences`). One inserted lower-case word
/// ("dollars", "extension") ends that, and every shouted word around it is spelled out. So a
/// pass writes its words in capitals inside a shouted sentence, and unshout reads them with
/// the rest. It decides with `ShoutedSentences` itself, so the two never disagree.
///
/// Make one per text a pass rewrites, only once the pass has a match, and ask it in order of
/// position: it remembers the last sentence it looked at.
struct ShoutedCasing {
    /// The text as unshout sees it: the reading, with marks as their labels.
    private let scalars: [Unicode.Scalar]
    /// For each UTF-16 offset of the text, its offset in `scalars`; nil when they're the same
    /// (no character outside the Basic Multilingual Plane).
    private let scalarOffsets: [Int]?
    /// No two capitals in a row anywhere, so no sentence can be shouted.
    private let calm: Bool
    /// The marked text offsets come from, for the Roman pass; nil before the custom lexicon.
    private var view: LabelView?
    private var sentences = ShoutedSentences()

    /// For text with no marks: a pass before the custom lexicon.
    init(_ text: String) {
        let scalars = Array(text.unicodeScalars)
        self.scalars = scalars
        var calm = true
        var previousUpper = false
        for c in scalars {
            let upper = Scalars.isUppercase(c)
            if upper && previousUpper { calm = false; break }
            previousUpper = upper
        }
        self.calm = calm
        let utf16Count = text.utf16.count
        if utf16Count == scalars.count {
            scalarOffsets = nil
        } else {
            var offsets: [Int] = []
            offsets.reserveCapacity(utf16Count + 1)
            for (i, c) in scalars.enumerated() {
                offsets.append(i)
                if c.value > 0xFFFF { offsets.append(i) }
            }
            offsets.append(scalars.count)
            scalarOffsets = offsets
        }
    }

    /// For marked text (the Roman pass): offsets are in `view.text`, and a mark counts as its
    /// label, as it does for unshout.
    init(_ view: LabelView) {
        self.init(view.reading as String)
        self.view = view
    }

    /// Whether the sentence holding `location` (UTF-16, in the text this was made with) is
    /// written all in capitals.
    mutating func isShouted(at location: Int) -> Bool {
        guard !calm else { return false }
        let inReading = view?.readingLocation(location) ?? location
        let i = scalarOffsets.map { $0[min(max(0, inReading), $0.count - 1)] } ?? min(max(0, inReading), scalars.count)
        return sentences.contains(i, in: scalars)
    }

    /// `words` as a pass should write them at `location`: in capitals inside a shouted sentence,
    /// as given elsewhere.
    mutating func cased(_ words: String, at location: Int) -> String {
        isShouted(at: location) ? words.uppercased() : words
    }
}
