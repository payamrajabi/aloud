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

    public init(word: String, match: String = "case-sensitive", us: String, gb: String? = nil,
                dictation: Dictation? = nil, spoken: [String] = [], spokenContextOnly: [String] = []) {
        // Keys are matched in NFC, like the text (plain ASCII already is).
        self.word = word.utf8.allSatisfy { $0 < 0x80 } ? word : word.precomposedStringWithCanonicalMapping
        self.match = match == "case-insensitive" || match == "case-sensitive" || match == "exact" ? match : match.lowercased()
        self.us = us
        self.gb = gb
        self.dictation = dictation
        self.spoken = spoken
        self.spokenContextOnly = spokenContextOnly
    }

    /// As the original loader read it: "case-sensitive" and "exact" keep their casing,
    /// anything else (including unknown values) matches any casing.
    public var isCaseSensitive: Bool { match == "case-sensitive" || match == "exact" }
    public var isExact: Bool { match == "exact" }

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
                            spoken: o.spoken ?? o.spokenVariants ?? [], contextOnly: o.spokenContextOnly ?? [], file: name)
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
                        contextOnly: Self.strings(item["spoken_context_only"]), file: name)
            }
        } catch {
            problems.append("\(name): \(error.localizedDescription)")
        }
    }

    private mutating func addItem(word: String?, match: String?, us: String?, gb: String?, dictation d: String?,
                                  spoken: [String], contextOnly: [String], file: String) {
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
                         dictation: dictation, spoken: spoken, spokenContextOnly: contextOnly.map(Self.trimmed)))
    }

    /// Trims spaces, without the cost of a Foundation call when there's nothing to trim.
    private static func trimmed(_ s: String) -> String {
        if let first = s.utf8.first, let last = s.utf8.last, first > 0x20, first < 0x80, last > 0x20, last < 0x80 { return s }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Adds an entry, replacing an earlier one with the same word (and case rule). A
    /// replacement without dictation fields keeps the earlier entry's, so fixing a
    /// pronunciation in your own file doesn't switch off its dictation fix.
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
