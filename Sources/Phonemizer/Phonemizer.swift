import Foundation

/// English text → phonemes in misaki's notation, the symbols Kokoro was trained on.
///
/// Each word comes from the first source that knows it:
///   1. the custom lexicon (hand-written names, brands, tech terms),
///   2. misaki's gold lexicon (US or GB), with its rules for heteronyms, numbers,
///      plurals, past tenses and stress,
///   3. CMUdict, mapped from ARPAbet,
///   4. the mini-bart G2P model, for words in none of them.
/// Sources 3 and 4 are American; their output is converted for British voices.
/// No eSpeak NG code or data is involved.
///
/// Not thread-safe: use one instance per queue.
public final class Phonemizer {
    public let british: Bool
    private let g2p: EnglishG2P
    private let custom: CustomLexicon?
    private let normalizes: Bool

    /// - Parameters:
    ///   - normalize: rewrite units, times, dates, fractions and a few abbreviations into
    ///     words first (on by default; off reproduces the reference misaki pipeline).
    public init(british: Bool, data: G2PData, custom: CustomLexicon? = nil, normalize: Bool = true) {
        self.british = british
        self.custom = custom
        self.normalizes = normalize
        let lexicon = Lexicon(british: british, data: data)
        let inner = EnglishG2P(lexicon: lexicon, fallback: nil)
        g2p = EnglishG2P(lexicon: lexicon, fallback: Fallback(data: data, british: british, inner: { inner }))
    }

    /// Phonemes for `text`. Words that can't be pronounced at all are left out
    /// (or replaced by `unknown`).
    public func phonemize(_ text: String, unknown: String = "") -> String {
        var t = text
        if normalizes { t = TextNormalizer.linkLabels(t) }
        // Hand-written terms first, on the raw text; then normalize everything else.
        if let custom { t = custom.mark(t.precomposedStringWithCanonicalMapping, british: british) }
        if normalizes { t = TextNormalizer.normalize(t, skippingMarkedSpans: custom != nil) }
        return g2p.phonemize(t, unk: unknown).trimmingCharacters(in: .whitespaces)
    }
}
