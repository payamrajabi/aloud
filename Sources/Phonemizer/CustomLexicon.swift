import Foundation

/// Hand-written pronunciations that win over every other source (names, brands, tech
/// terms). Read from JSON files shaped like:
///
///     [ { "word": "Kubernetes", "match": "case-insensitive", "us": "kˌubəɹnˈɛTiz", "gb": "kˌuːbənˈɛtiːz" } ]
///
/// `match` is "case-sensitive" (exact casing), "case-insensitive" (any casing), "exact"
/// (exact casing, no suffixes) or "name" (exact casing, possessive endings only: "Payam's",
/// never "Thi" + s for "This"). `gb` is optional; British voices use `us` when
/// it's missing. `unit` and `caps_word` limit where a key applies (below); other fields
/// are ignored here (`LexiconEntry` describes the dictation fields). Phonemes are in the
/// final form Kokoro reads (misaki's symbols, US flaps written T).
///
/// Matching runs on the raw text before tokenization (techlex/lexicon.py is the
/// reference), so keys can hold punctuation and digits ("Next.js", "A/B", "TL;DR",
/// "K8s", "scikit-learn"), and misaki never sees, splits or re-reads a matched term:
///   - longest key first;
///   - no letter or digit right before or after the match, and no match right after
///     ".", "/" or ":" (a following hyphen is fine: "SQL-based");
///   - after a key ending in a letter, a plural or possessive ending (s, es, 's, ’s,
///     s') adds misaki's -s sound; a bare trailing apostrophe adds nothing;
///   - "1:1" is read "one-on-one" only when it's clearly a meeting ("1:1s", "a 1:1
///     meeting"), never as a ratio ("a 1:1 crop");
///   - a `unit` key applies only right after a number, with or without a space ("16 GB",
///     "3mm", "9 AM"), and nowhere else ("mm, that's nice", "the GB team");
///   - a `caps_word` key is skipped in a sentence written all in capitals ("I AM SO
///     HAPPY", see `ShoutedSentences`), where it's an ordinary word.
///
/// These rules used to be one regular expression with an alternative per key, which
/// is fine for a hundred terms and hopeless for ten thousand (seconds per sentence).
/// Keys are now indexed by their first two (lower-cased) characters, and only the
/// keys in the bucket for the text at a word start are compared, longest first, with
/// the same boundary, case and suffix rules the expression had.
///
/// Field packs: the index holds `LexiconSet.entries(for:)` for the packs that are on, so
/// a pack-only entry ("BID" read B-I-D) is there only while its pack is, and then in place
/// of the general entry with its spelling. Two keys of the same length that both match
/// differ only in case rules ("=BID" and "~bid"); then your own entry is tried first, then
/// a pack's, then a general one, so the precedence holds across case rules too. Between
/// two general entries the case-sensitive one is tried first: it reads its own casing and
/// the other reads the rest (the names pack's "Pir" and the tech list's "PIR").
public final class CustomLexicon {
    struct Entry {
        let key: String
        let scalars: [Unicode.Scalar]
        let folded: [UInt32]
        let caseSensitive: Bool
        let allowSuffix: Bool
        /// Only possessive endings ('s, ’s, ', ’): a name's entry.
        let possessiveOnly: Bool
        let unit: Bool
        let capsWord: Bool
        let gate: NSRegularExpression?
        let us: String
        let gb: String?
        /// 2 for your own entries, 1 for a pack's pack-only entries, 0 for the rest.
        let rank: UInt8
    }

    private struct Index {
        var entries: [Entry] = []
        /// (first, second) folded scalar → entries starting with them, longest first.
        /// Single-character keys use 0 as their second scalar.
        var buckets: [UInt64: [Int32]] = [:]
    }

    private var source = LexiconSet()
    private var packs = LexiconPacks()
    private var index: Index?
    private var indexProblems: [String] = []
    private let lock = NSLock()

    public var problems: [String] { source.problems + indexProblems }
    public var count: Int { source.count }
    public var enabledPacks: LexiconPacks {
        lock.lock(); defer { lock.unlock() }
        return packs
    }

    /// Keys that only apply in some contexts: the text right after the key must match.
    static let contextGates: [String: String] = [
        "1:1": #"^(?:s(?![\p{L}\p{N}])|\s+(?:meeting|meetings|call|calls|chat|chats|session|sessions|sync|syncs|catch-?ups?|conversations?|check-?ins?|with)\b)"#,
    ]
    private static let compiledGates: [String: NSRegularExpression] = contextGates.compactMapValues {
        try? NSRegularExpression(pattern: String($0.dropFirst()))
    }

    public init() {}

    public init(_ set: LexiconSet, packs: LexiconPacks = LexiconPacks()) {
        self.source = set
        self.packs = packs
    }

    /// Loads every *.json file in each directory, in order: later files override
    /// earlier ones (so a user folder listed last wins over the app's own lists).
    public convenience init(directories: [URL]) {
        self.init(LexiconSet(directories: directories))
    }

    public func load(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        source.load(url)
        index = nil
    }

    public func add(_ word: String, us: String, gb: String? = nil, match: String = "case-sensitive") {
        lock.lock(); defer { lock.unlock() }
        source.add(LexiconEntry(word: word, match: match, us: us, gb: gb))
        index = nil
    }

    /// Switches field packs on or off. The index is rebuilt on the next `mark` (or
    /// `prepare`), so the change applies from the next sentence read.
    public func setEnabledPacks(_ packs: LexiconPacks) {
        lock.lock(); defer { lock.unlock() }
        guard packs != self.packs else { return }
        self.packs = packs
        index = nil
    }

    /// Builds the index now rather than on the first `mark` (it takes a few milliseconds).
    public func prepare() {
        _ = currentIndex()
    }

    private func currentIndex() -> Index {
        lock.lock(); defer { lock.unlock() }
        if let index { return index }
        indexProblems = []
        let built = Self.build(source.entries(for: packs), problems: &indexProblems)
        index = built
        return built
    }

    private static func build(_ source: [LexiconEntry], problems: inout [String]) -> Index {
        var idx = Index()
        idx.entries.reserveCapacity(source.count)
        for e in source {
            let scalars = Array(e.word.unicodeScalars)
            guard !scalars.isEmpty else { continue }
            var gate: NSRegularExpression?
            if contextGates[e.word] != nil {
                gate = compiledGates[e.word]
                if gate == nil { problems.append("couldn't compile the context rule for \(e.word)") }
            }
            idx.entries.append(Entry(key: e.word, scalars: scalars, folded: Scalars.fold(scalars),
                                     caseSensitive: e.isCaseSensitive,
                                     allowSuffix: !e.isExact && (e.word.last?.isLetter ?? false),
                                     possessiveOnly: e.isName,
                                     unit: e.isUnit, capsWord: e.isCapsWord, gate: gate, us: e.us, gb: e.gb,
                                     rank: e.isUser ? 2 : e.isPackOnly ? 1 : 0))
        }
        // The old expression tried keys longest first (in characters), then alphabetically.
        // Between keys of one length, yours come first, then a pack's (see above); then a
        // case-sensitive key before one that matches any casing, so the narrower key reads
        // its own casing whatever the alphabet says (the names pack's "Pir" before the tech
        // list's "PIR", which still reads "PIR" and "pir").
        let lengths = idx.entries.map { $0.key.count }, ranks = idx.entries.map(\.rank)
        let narrow = idx.entries.map(\.caseSensitive)
        let order = idx.entries.indices.sorted {
            if lengths[$0] != lengths[$1] { return lengths[$0] > lengths[$1] }
            if ranks[$0] != ranks[$1] { return ranks[$0] > ranks[$1] }
            if narrow[$0] != narrow[$1] { return narrow[$0] }
            return idx.entries[$0].key < idx.entries[$1].key
        }
        idx.entries = order.map { idx.entries[$0] }
        for (i, e) in idx.entries.enumerated() {
            idx.buckets[bucket(e.folded[0], e.folded.count > 1 ? e.folded[1] : 0), default: []].append(Int32(i))
        }
        return idx
    }

    @inline(__always) private static func bucket(_ a: UInt32, _ b: UInt32) -> UInt64 {
        UInt64(a) << 32 | UInt64(b)
    }

    /// misaki's -s rule (as in techlex/lexicon.py's add_s): /s/ after p t k f θ,
    /// /ᵻz/ (GB /ɪz/) after s z ʃ ʒ ʧ ʤ, /z/ otherwise.
    static func addS(_ ps: String, british: Bool) -> String {
        let core = ps.trimmingCharacters(in: CharacterSet(charactersIn: "ˈˌ "))
        guard let last = core.last else { return ps + "z" }
        if "ptkfθ".contains(last) { return ps + "s" }
        if "szʃʒʧʤ".contains(last) { return ps + (british ? "ɪ" : "ᵻ") + "z" }
        return ps + "z"
    }

    private static let suffixes: [[Unicode.Scalar]] = ["'s", "’s", "s'", "s’", "es", "s", "'", "’"].map { Array($0.unicodeScalars) }
    private static let possessives: [[Unicode.Scalar]] = ["'s", "’s", "'", "’"].map { Array($0.unicodeScalars) }

    private struct Match {
        let start: Int, end: Int   // scalar offsets, end includes the suffix
        let entry: Int
        let suffix: Int            // length of the suffix
    }

    /// Wraps every match in misaki's [text](/phonemes/) syntax, which fixes its
    /// pronunciation for the rest of the pipeline.
    public func mark(_ text: String, british: Bool) -> String {
        let idx = currentIndex()
        guard !idx.entries.isEmpty else { return text }
        let s = Array(text.unicodeScalars)
        let matches = find(in: s, index: idx)
        guard !matches.isEmpty else { return text }
        var out = String.UnicodeScalarView()
        var last = 0
        for m in matches {
            let e = idx.entries[m.entry]
            var ps = british ? (e.gb ?? e.us) : e.us
            if m.suffix > 0 {
                let suffix = s[(m.end - m.suffix)..<m.end]
                if !(suffix.count == 1 && (suffix.first == "'" || suffix.first == "’")) { ps = Self.addS(ps, british: british) }
            }
            out.append(contentsOf: s[last..<m.start])
            // A unit written against its number ("16GB") is still a word of its own.
            if m.start > 0, Scalars.isDigit(s[m.start - 1]) { out.append(" ") }
            out.append("[")
            out.append(contentsOf: s[m.start..<m.end])
            out.append(contentsOf: "](/\(ps)/)".unicodeScalars)
            last = m.end
        }
        out.append(contentsOf: s[last...])
        return String(out)
    }

    /// Non-overlapping matches, left to right.
    private func find(in s: [Unicode.Scalar], index idx: Index) -> [Match] {
        let n = s.count
        let f = Scalars.fold(s)
        var matches: [Match] = []
        var shouted = ShoutedSentences()
        var i = 0
        while i < n {
            // (?<![\w./:]) — nothing that continues a word, a domain or a path; except that
            // a unit may follow its number directly ("16GB").
            var glued = false
            if i > 0 {
                let p = s[i - 1]
                if Scalars.isDigit(p), Self.isNumber(endingAt: i, s) {
                    glued = true
                } else if Scalars.isWord(p) || p == "." || p == "/" || p == ":" {
                    i += 1
                    continue
                }
            }
            let afterNumber = glued || (i > 1 && Scalars.isSpace(s[i - 1]) && s[i - 1] != "\n" && Scalars.isDigit(s[i - 2])
                                        && Self.isNumber(endingAt: i - 1, s))
            if let m = match(at: i, s, f, idx, afterNumber: afterNumber, unitsOnly: glued, shouted: &shouted) {
                matches.append(m)
                i = m.end
            } else {
                i += 1
            }
        }
        return matches
    }

    private func match(at i: Int, _ s: [Unicode.Scalar], _ f: [UInt32], _ idx: Index,
                       afterNumber: Bool, unitsOnly: Bool, shouted: inout ShoutedSentences) -> Match? {
        let n = s.count
        // Keys of two or more characters, then single-character keys (always shorter).
        for pass in 0..<2 {
            let key = pass == 0 ? (i + 1 < n ? Self.bucket(f[i], f[i + 1]) : nil) : Self.bucket(f[i], 0)
            guard let key, let list = idx.buckets[key] else { continue }
            for k in list {
                let e = idx.entries[Int(k)]
                if e.unit ? !afterNumber : unitsOnly { continue }
                let len = e.scalars.count
                guard i + len <= n else { continue }
                var same = true
                if e.caseSensitive {
                    for j in 0..<len where s[i + j] != e.scalars[j] { same = false; break }
                } else {
                    for j in 0..<len where f[i + j] != e.folded[j] { same = false; break }
                }
                guard same else { continue }
                if e.capsWord, shouted.contains(i, in: s) { continue }
                let end = i + len
                if let gate = e.gate {
                    // The text right after the key must pass the gate; then an optional "s".
                    let rest = String(String.UnicodeScalarView(s[end..<min(n, end + 80)]))
                    guard gate.firstMatch(in: rest, options: [.anchored], range: NSRange(location: 0, length: (rest as NSString).length)) != nil
                    else { continue }
                    if end < n, s[end] == "s", !(end + 1 < n && (Scalars.isLetterOrNumber(s[end + 1]) || s[end + 1] == "_")),
                       Self.endsCleanly(s, at: end + 1) {
                        return Match(start: i, end: end + 1, entry: Int(k), suffix: 1)
                    }
                    if Self.endsCleanly(s, at: end) { return Match(start: i, end: end, entry: Int(k), suffix: 0) }
                    continue
                }
                if e.allowSuffix {
                    for suffix in (e.possessiveOnly ? Self.possessives : Self.suffixes) where end + suffix.count <= n {
                        var ok = true
                        for (j, c) in suffix.enumerated() where s[end + j] != c { ok = false; break }
                        if ok, Self.endsCleanly(s, at: end + suffix.count) {
                            return Match(start: i, end: end + suffix.count, entry: Int(k), suffix: suffix.count)
                        }
                    }
                }
                if Self.endsCleanly(s, at: end) { return Match(start: i, end: end, entry: Int(k), suffix: 0) }
            }
        }
        return nil
    }

    /// The digits before `end` start a number of their own ("16", "1.5", "2,000"), not
    /// the tail of a name or code ("A16", "x86", "v1.2").
    private static func isNumber(endingAt end: Int, _ s: [Unicode.Scalar]) -> Bool {
        var j = end - 1
        while j >= 0, Scalars.isDigit(s[j]) || ((s[j] == "." || s[j] == ",") && j > 0 && Scalars.isDigit(s[j - 1])) { j -= 1 }
        return j < 0 || !Scalars.isWord(s[j])
    }

    /// (?![\w])(?!:\d) — the match doesn't run on into a word or a time.
    @inline(__always) private static func endsCleanly(_ s: [Unicode.Scalar], at p: Int) -> Bool {
        guard p < s.count else { return true }
        if Scalars.isWord(s[p]) { return false }
        if s[p] == ":", p + 1 < s.count, Scalars.isDigit(s[p + 1]) { return false }
        return true
    }
}
