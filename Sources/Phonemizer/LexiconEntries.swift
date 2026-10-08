import Foundation

/// One hand-written lexicon entry (a file in Lexicons/, or the user's own folder).
///
/// Two schemas are read. The original one is pronunciation only:
///
///     { "word": "Kubernetes", "match": "case-insensitive", "us": "kˌubəɹnˈɛTiz", "gb": "kˌuːbənˈɛtiːz" }
///
/// The larger list adds what dictation needs to write the term back:
///
///     { "word": "Supabase", "match": "case-insensitive", "us": "sˈupəbˌAs", "gb": "sˈuːpəbˌAs",
///       "dictation": "always", "spoken": ["super base", "superbase"], "spoken_context_only": [] }
///
/// - `spoken`: lowercase phrases the dictation engine writes when someone says the term.
/// - `spoken_context_only` (a subset of `spoken`): variants that are ordinary words or
///   names ("jason" for JSON), only rewritten when the dictation is clearly about tech.
/// - `dictation`: "always" (rewrite safe variants anywhere), "context" (only with tech
///   context) or "never" (pronunciation only). Entries without it are pronunciation only.
/// - `evidence: false`: never counts as tech context in dictation (Netflix, iPhone, ASAP:
///   everyday brands and words that turn up in any message).
/// - `unit: true`: a unit, read with this pronunciation only right after a number
///   ("16 GB", "3mm", "9 AM"; "mm, that's nice" is a word), never used by dictation.
/// - `caps_word: true`: an all-caps term that is also an ordinary word ("AM", "ART"):
///   left alone in a sentence written all in capitals ("I AM SO HAPPY").
/// Each of the three is optional; without it the entry behaves as before.
/// Unknown fields (sources, notes, categories) are ignored.
public struct LexiconEntry {
    public enum Dictation: String {
        case always, context, never
    }

    public var word: String
    /// "case-sensitive", "case-insensitive" or "exact" (case-sensitive, no plural/possessive endings).
    public var match: String
    public var us: String
    public var gb: String?
    /// nil for entries in the original schema: dictation leaves them alone.
    public var dictation: Dictation?
    public var spoken: [String]
    public var spokenContextOnly: [String]
    /// nil when the file doesn't say (the same as true).
    public var evidence: Bool?
    /// nil when the file doesn't say (the same as false).
    public var unit: Bool?
    /// nil when the file doesn't say (the same as false).
    public var capsWord: Bool?

    public init(word: String, match: String = "case-sensitive", us: String, gb: String? = nil,
                dictation: Dictation? = nil, spoken: [String] = [], spokenContextOnly: [String] = [],
                evidence: Bool? = nil, unit: Bool? = nil, capsWord: Bool? = nil) {
        // Keys are matched in NFC, like the text (plain ASCII already is).
        self.word = word.utf8.allSatisfy { $0 < 0x80 } ? word : word.precomposedStringWithCanonicalMapping
        self.match = match == "case-insensitive" || match == "case-sensitive" || match == "exact" ? match : match.lowercased()
        self.us = us
        self.gb = gb
        self.dictation = dictation
        self.spoken = spoken
        self.spokenContextOnly = spokenContextOnly
        self.evidence = evidence
        self.unit = unit
        self.capsWord = capsWord
    }

    /// As the original loader read it: "case-sensitive" and "exact" keep their casing,
    /// anything else (including unknown values) matches any casing.
    public var isCaseSensitive: Bool { match == "case-sensitive" || match == "exact" }
    public var isExact: Bool { match == "exact" }
    public var isEvidence: Bool { evidence != false }
    public var isUnit: Bool { unit == true }
    public var isCapsWord: Bool { capsWord == true }

    /// Entries with the same identity replace each other (a later file wins).
    var identity: String { isCaseSensitive ? "=" + word : "~" + word.lowercased() }
}

/// Every entry from a set of lexicon files, read once and shared by the reading side
/// (`CustomLexicon`) and the dictation side (`DictationCorrector`).
public struct LexiconSet {
    public private(set) var entries: [LexiconEntry] = []
    public private(set) var problems: [String] = []
    private var positions: [String: Int] = [:]

    public init() {}

    /// Loads every *.json file in each directory, in order: later files override
    /// earlier ones (so a user folder listed last wins over the app's own lists).
    public init(directories: [URL]) {
        let fm = FileManager.default
        for dir in directories {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names.sorted() where name.hasSuffix(".json") {
                load(dir.appendingPathComponent(name))
            }
        }
    }

    public init(files: [URL]) {
        for file in files { load(file) }
    }

    public var count: Int { entries.count }

    public mutating func load(_ url: URL) {
        let name = url.lastPathComponent
        do {
            let data = try Data(contentsOf: url)
            // The fast reader handles every well-formed lexicon; JSONSerialization the rest.
            if let objects = LexiconJSON.parse(data), !objects.contains(where: \.malformed) {
                entries.reserveCapacity(entries.count + objects.count)
                positions.reserveCapacity(positions.count + objects.count)
                for o in objects {
                    addItem(word: o.word, match: o.match, us: o.us, gb: o.gb, dictation: o.dictation,
                            spoken: o.spoken ?? o.spokenVariants ?? [], contextOnly: o.spokenContextOnly ?? [],
                            evidence: o.evidence, unit: o.unit, capsWord: o.capsWord, file: name)
                }
                return
            }
            let json = try JSONSerialization.jsonObject(with: data)
            let items: [Any]
            if let a = json as? [Any] {
                items = a
            } else if let d = json as? [String: Any], let a = (d["entries"] ?? d["words"]) as? [Any] {
                items = a
            } else {
                problems.append("\(name): expected a JSON array of entries")
                return
            }
            for case let item as [String: Any] in items {
                addItem(word: item["word"] as? String, match: item["match"] as? String, us: item["us"] as? String,
                        gb: item["gb"] as? String, dictation: item["dictation"] as? String,
                        spoken: Self.strings(item["spoken"] ?? item["spoken_variants"]),
                        contextOnly: Self.strings(item["spoken_context_only"]),
                        evidence: item["evidence"] as? Bool, unit: item["unit"] as? Bool, capsWord: item["caps_word"] as? Bool, file: name)
            }
        } catch {
            problems.append("\(name): \(error.localizedDescription)")
        }
    }

    private mutating func addItem(word: String?, match: String?, us: String?, gb: String?, dictation d: String?,
                                  spoken: [String], contextOnly: [String], evidence: Bool?, unit: Bool?, capsWord: Bool?,
                                  file: String) {
        guard let word = word.map(Self.trimmed), !word.isEmpty, let us = us.map(Self.trimmed), !us.isEmpty else {
            problems.append("\(file): entry without word/us: \(word ?? "?")")
            return
        }
        let gb = gb.map(Self.trimmed)
        var dictation: LexiconEntry.Dictation?
        if let d {
            dictation = LexiconEntry.Dictation(rawValue: d.lowercased())
            if dictation == nil {
                problems.append("\(file): \(word): unknown dictation value \"\(d)\" (treated as never)")
                dictation = .never
            }
        }
        // "spoken_variants" is the name the batch files use before they're merged.
        let spoken = spoken.map(Self.trimmed).filter { !$0.isEmpty }
        if dictation == nil, !spoken.isEmpty { dictation = .context }
        add(LexiconEntry(word: word, match: match ?? "case-sensitive", us: us, gb: gb?.isEmpty == false ? gb : nil,
                         dictation: dictation, spoken: spoken, spokenContextOnly: contextOnly.map(Self.trimmed),
                         evidence: evidence, unit: unit, capsWord: capsWord))
    }

    /// Trims spaces, without the cost of a Foundation call when there's nothing to trim.
    private static func trimmed(_ s: String) -> String {
        if let first = s.utf8.first, let last = s.utf8.last, first > 0x20, first < 0x80, last > 0x20, last < 0x80 { return s }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Adds an entry, replacing an earlier one with the same word (and case rule). A
    /// replacement without dictation fields keeps the earlier entry's, so fixing a
    /// pronunciation in your own file doesn't switch off its dictation fix; the same goes
    /// for `evidence`, `unit` and `caps_word` (fixing how "AM" sounds keeps it a unit).
    public mutating func add(_ entry: LexiconEntry) {
        let id = entry.identity
        if let i = positions[id] {
            var e = entry
            let old = entries[i]
            if e.dictation == nil, e.spoken.isEmpty {
                e.dictation = old.dictation
                e.spoken = old.spoken
                e.spokenContextOnly = old.spokenContextOnly
            }
            e.evidence = e.evidence ?? old.evidence
            e.unit = e.unit ?? old.unit
            e.capsWord = e.capsWord ?? old.capsWord
            entries[i] = e
        } else {
            positions[id] = entries.count
            entries.append(entry)
        }
    }

    private static func strings(_ value: Any?) -> [String] {
        guard let a = value as? [Any] else { return [] }
        return a.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

/// Character tests shared by the lexicon matchers. They work on Unicode scalars and
/// mirror the ICU regex classes the original matcher used (\w, \p{L}, \p{N}, \d).
enum Scalars {
    /// ICU's \w: letters, marks, decimal digits, connector punctuation, ZWNJ/ZWJ.
    static func isWord(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if v < 0x80 {
            return (v >= 0x61 && v <= 0x7A) || (v >= 0x41 && v <= 0x5A) || (v >= 0x30 && v <= 0x39) || v == 0x5F
        }
        if v == 0x200C || v == 0x200D { return true }
        let p = s.properties
        if p.isAlphabetic { return true }
        switch p.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .connectorPunctuation: return true
        default: return false
        }
    }

    /// \p{L} or \p{N}.
    static func isLetterOrNumber(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if v < 0x80 { return (v >= 0x61 && v <= 0x7A) || (v >= 0x41 && v <= 0x5A) || (v >= 0x30 && v <= 0x39) }
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    static func isDigit(_ s: Unicode.Scalar) -> Bool {
        s.value < 0x80 ? (s.value >= 0x30 && s.value <= 0x39) : s.properties.generalCategory == .decimalNumber
    }

    static func isLetter(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if v < 0x80 { return (v >= 0x61 && v <= 0x7A) || (v >= 0x41 && v <= 0x5A) }
        return s.properties.isAlphabetic
    }

    static func isUppercase(_ s: Unicode.Scalar) -> Bool {
        s.value < 0x80 ? (s.value >= 0x41 && s.value <= 0x5A) : s.properties.isUppercase
    }

    static func isLowercase(_ s: Unicode.Scalar) -> Bool {
        s.value < 0x80 ? (s.value >= 0x61 && s.value <= 0x7A) : s.properties.isLowercase
    }

    /// A space, tab or line break (no-break and thin spaces included).
    static func isSpace(_ s: Unicode.Scalar) -> Bool {
        s.value < 0x80 ? (s.value == 0x20 || (s.value >= 0x09 && s.value <= 0x0D)) : s.properties.isWhitespace
    }

    /// Simple one-to-one lower-casing, so offsets in the folded text match the original.
    static func fold(_ s: Unicode.Scalar) -> UInt32 {
        let v = s.value
        if v < 0x80 { return (v >= 0x41 && v <= 0x5A) ? v + 32 : v }
        let lower = s.properties.lowercaseMapping.unicodeScalars
        return lower.count == 1 ? lower.first!.value : v
    }

    static func fold(_ scalars: [Unicode.Scalar]) -> [UInt32] {
        scalars.map(fold)
    }
}

/// Which sentences are written all in capitals ("I AM SO HAPPY.", "BIG NEWS TODAY"):
/// at least two words of two or more letters, and no lowercase letter. There an all-caps
/// term that is also a word ("AM", "ART") is just the word, shouted. Each sentence is
/// looked at once, and only when a `caps_word` entry matches in it.
struct ShoutedSentences {
    private var range = 0..<0
    private var shouted = false

    /// Whether the sentence holding offset `i` of `s` is all capitals.
    mutating func contains(_ i: Int, in s: [Unicode.Scalar]) -> Bool {
        if range.contains(i) { return shouted }
        var start = i
        while start > 0, !Self.endsSentence(s, at: start - 1) { start -= 1 }
        var end = i
        while end < s.count, !Self.endsSentence(s, at: end) { end += 1 }
        range = start..<min(s.count, end + 1)
        var words = 0, letters = 0
        shouted = true
        for c in s[range] {
            if Scalars.isUppercase(c) {
                letters += 1
                if letters == 2 { words += 1 }
            } else if Scalars.isLowercase(c) {
                shouted = false
                break
            } else {
                letters = 0
            }
        }
        shouted = shouted && words >= 2
        return shouted
    }

    /// A line break, or a full stop, question or exclamation mark before a space or the end.
    private static func endsSentence(_ s: [Unicode.Scalar], at p: Int) -> Bool {
        switch s[p] {
        case "\n", "\r": return true
        case ".", "!", "?", "\u{2026}": return p + 1 == s.count || Scalars.isSpace(s[p + 1])
        default: return false
        }
    }
}
