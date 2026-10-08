import Foundation

/// The lexicon in reverse: fixes how the dictation engine writes tech terms
/// ("super base" → Supabase, "cube control" → kubectl, "github" → GitHub) before the
/// text is typed.
///
/// What it rewrites, from each entry's dictation fields (see `LexiconEntry`):
///   - a `spoken` variant, matched case-insensitively at word boundaries, longest
///     first, with any run of spaces, hyphens or dashes standing for a space;
///   - the term itself in the wrong case ("postgresql" → PostgreSQL), for
///     case-insensitive entries only. Case-sensitive entries (Linear, Notion, Slack)
///     are case-sensitive because their lowercase form is an ordinary word.
/// The replacement is the term exactly as the lexicon spells it ("kubectl", "iOS",
/// even at the start of a sentence). Possessives carry over ("git hub's" → GitHub's);
/// plurals only on the term itself ("apis" → APIs), never on a spoken variant
/// ("super bases" stays as it is).
///
/// What it leaves alone:
///   - entries with `dictation: never`, entries without dictation fields, and units
///     (`unit: true`: "ms" and "GB" are for reading numbers, never written back);
///   - variants of `context` entries, variants listed in `spoken_context_only`, and the
///     spelling of a `context` term itself ("asap" → ASAP), unless an unambiguous tech hit
///     comes within 12 words of it, before or after, in the same dictation: an `always`
///     variant, an `always` term written as itself (GitHub, API, Kubernetes), or a
///     `context` term spelled as no word or abbreviation is (Next.js, K8s). One tech word
///     at the start of a long message doesn't make "the sequel" thirty words on SQL. A hit
///     that itself needed context never supplies it, and neither does an entry marked
///     `evidence: false` (Netflix, iPhone, LOL);
///   - entries marked `caps_word` in a sentence written all in capitals ("I AM SO HAPPY");
///   - ordinary-word variants written with a capital ("Jason" is a person, "jason"
///     may be JSON), very common words ("next", "view") and ordinary phrases that
///     start or end with a little word ("a genetic", "red is"), even with tech context;
///   - a variant that several entries claim, and a term that's already spelled as
///     another entry (Postgres stays Postgres even if PostgreSQL lists "postgres");
///   - anything inside a domain, file name, path or address (github.com, notes.json),
///     and the whole of a URL with a scheme (https://…, postgres://user@db).
///
/// Built once from a `LexiconSet`; thread-safe after that.
public final class DictationCorrector {
    public struct Change {
        public let original: String
        public let replacement: String
        /// False when the change needed tech context the dictation didn't have.
        public let applied: Bool
        public let reason: String
    }

    public struct Result {
        public let text: String
        public let changes: [Change]
        /// An unambiguous tech hit somewhere in the dictation. A gated change also needs one
        /// within `contextReach` words of it.
        public let hasTechContext: Bool
    }

    /// How far tech context reaches, in words either way: a gated rewrite needs an
    /// unambiguous tech hit no more than this many words before or after it.
    public static let contextReach = 12

    /// How one written form relates to one entry.
    struct Target {
        static let rewrite: UInt8 = 1        // may change the text (otherwise it only protects it)
        static let gated: UInt8 = 2          // needs tech context
        static let evidence: UInt8 = 4       // is tech context
        static let lowercaseOnly: UInt8 = 8  // an ordinary word or name: only when written in lowercase
        static let plural: UInt8 = 16        // takes a plural ending
        static let variant: UInt8 = 32       // a spoken variant (not the term's own spelling)
        static let capsWord: UInt8 = 64      // skipped in a sentence written all in capitals

        let entry: Int32
        var flags: UInt8
        func has(_ f: UInt8) -> Bool { flags & f != 0 }
    }

    struct Group {
        var pattern: [UInt32]
        /// Terms from case-sensitive entries: written exactly like this, the text is kept.
        var exact: [Target] = []
        var canonical: Target?
        var variant: Target?
        /// Spoken variant of more than one term: left alone.
        var ambiguous = false
    }

    private var groups: [Group] = []
    private var buckets: [UInt64: [Int32]] = [:]
    /// Each entry's spelling, by entry index (empty for entries that play no part).
    private var words: [[Unicode.Scalar]] = []
    public private(set) var variantCount = 0
    public var formCount: Int { groups.count }

    static let separator: UInt32 = 0x20

    public init(_ set: LexiconSet) {
        build(set.entries)
    }

    public convenience init(directories: [URL]) {
        self.init(LexiconSet(directories: directories))
    }

    // MARK: - Building

    private func build(_ entries: [LexiconEntry]) {
        var positions: [[UInt32]: Int] = [:]
        positions.reserveCapacity(entries.count * 3)
        groups.reserveCapacity(entries.count * 3)
        words = Array(repeating: [], count: entries.count)
        func group(_ p: [UInt32]) -> Int {
            if let g = positions[p] { return g }
            positions[p] = groups.count
            groups.append(Group(pattern: p))
            return groups.count - 1
        }
        for (index, e) in entries.enumerated() where !e.isUnit {
            let id = Int32(index)
            let active = e.dictation == .always || e.dictation == .context
            let canonical = Self.normalize(e.word)
            let common = Self.commonPatterns.contains(canonical)
            // Only developer terms say a dictation is about tech: never everyday brands and
            // words (Netflix, iPhone, LOL), whatever else the entry does.
            let evidence = e.isEvidence
            // A `context` term's own spelling needs context like its variants do, so "asap" or
            // "ASAP" can't vouch for itself; spelled as no word or abbreviation is (Next.js,
            // K8s), it still can.
            let spellingIsEvidence = evidence && active && !common
                && (e.dictation == .always || Self.isUnmistakable(e.word.unicodeScalars))
            let caps = e.isCapsWord ? Target.capsWord : 0
            var used = false
            if Self.usable(canonical) {
                let g = group(canonical)
                used = true
                if e.isCaseSensitive {
                    let flags = (spellingIsEvidence && Self.isDistinctive(e.word) ? Target.evidence : 0) | caps
                    groups[g].exact.append(Target(entry: id, flags: flags))
                } else if groups[g].canonical == nil || (active && groups[g].canonical?.has(Target.rewrite) == false) {
                    var flags: UInt8 = caps
                    if active && !common { flags |= Target.rewrite }
                    if spellingIsEvidence { flags |= Target.evidence }
                    if e.dictation == .context || common { flags |= Target.gated }
                    if !e.isExact, canonical.last.flatMap(Unicode.Scalar.init).map(Scalars.isLetter) == true { flags |= Target.plural }
                    groups[g].canonical = Target(entry: id, flags: flags)
                }
            }
            if active {
                let contextOnly = Set(e.spokenContextOnly.map(Self.normalize))
                for v in e.spoken {
                    let p = Self.normalize(v)
                    guard Self.usable(p), p != canonical || e.isCaseSensitive else { continue }
                    let parts = p.split(separator: Self.separator)
                    if parts.count == 1, Self.commonPatterns.contains(p) { continue }   // "next", "view": never worth the risk
                    let ordinary = contextOnly.contains(p) || parts.allSatisfy { Self.commonPatterns.contains(Array($0)) }
                    // An ordinary phrase that starts or ends with a little word ("a genetic" for
                    // agentic, "red is" for Redis) is how ordinary sentences sound, tech talk
                    // included ("a genetic algorithm"): never rewritten. Spelled-out letters
                    // ("a p i gateway") are exempt.
                    if ordinary, parts.count > 1 {
                        let n = parts.count
                        let first = Self.functionPatterns.contains(Array(parts[0])) && !(parts[0].count == 1 && parts[1].count == 1)
                        let last = Self.functionPatterns.contains(Array(parts[n - 1])) && !(parts[n - 1].count == 1 && parts[n - 2].count == 1)
                        if first || last { continue }
                    }
                    var flags = Target.rewrite | Target.variant | caps
                    if e.dictation == .context || ordinary { flags |= Target.gated }
                    if evidence && e.dictation == .always && !ordinary { flags |= Target.evidence }
                    // A capitalised ordinary word is a name ("Jason"); a capitalised phrase is
                    // more likely the product ("Mac OS", "Super Base"), so only words are held back.
                    if ordinary && parts.count == 1 { flags |= Target.lowercaseOnly }
                    let g = group(p)
                    used = true
                    variantCount += 1
                    if let old = groups[g].variant {
                        if entries[Int(old.entry)].word == e.word {
                            // The same term twice: keep the more careful reading.
                            let careful = (old.flags | flags) & (Target.gated | Target.lowercaseOnly | Target.capsWord)
                            groups[g].variant?.flags = (old.flags & flags) | careful
                        } else {
                            groups[g].ambiguous = true
                        }
                    } else {
                        groups[g].variant = Target(entry: id, flags: flags)
                    }
                }
            }
            if used { words[index] = Array(e.word.unicodeScalars) }
        }
        // Longest patterns first within each bucket.
        let order = groups.indices.sorted { groups[$0].pattern.count > groups[$1].pattern.count }
        for g in order {
            let p = groups[g].pattern
            buckets[Self.bucket(p[0], p[1]), default: []].append(Int32(g))
        }
    }

    @inline(__always) private static func bucket(_ a: UInt32, _ b: UInt32) -> UInt64 { UInt64(a) << 32 | UInt64(b) }

    /// Lower-cased scalars, curly apostrophes made straight, and every run of spaces,
    /// hyphens and dashes turned into one separator.
    static func normalize(_ s: String) -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity(s.utf8.count)
        var pendingSeparator = false
        let text = s.utf8.allSatisfy { $0 < 0x80 } ? s : s.precomposedStringWithCanonicalMapping
        for c in text.unicodeScalars {
            if isSeparator(c) {
                pendingSeparator = !out.isEmpty
                continue
            }
            if pendingSeparator { out.append(separator); pendingSeparator = false }
            out.append(foldApostrophe(Scalars.fold(c)))
        }
        return out
    }

    /// At least two characters, with a letter or digit somewhere: a lone "r" or "c"
    /// is never safe to touch.
    static func usable(_ p: [UInt32]) -> Bool {
        p.count >= 2 && p.contains { Unicode.Scalar($0).map(Scalars.isLetterOrNumber) ?? false }
    }

    @inline(__always) static func isSeparator(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x20, 0x09, 0x0A, 0x0D, 0xA0, 0x2D, 0x2010, 0x2011, 0x2013: return true
        case 0..<0x80: return false
        default: return c.properties.isWhitespace
        }
    }

    static let commonPatterns: Set<[UInt32]> = Set(commonWords.map(normalize))

    /// Articles, pronouns, auxiliaries and the like: words that belong to the sentence
    /// around a phrase, not to a product name.
    static let functionPatterns: Set<[UInt32]> = Set([
        "a", "an", "the", "my", "your", "our", "his", "her", "their", "its", "this", "that", "these", "those", "some", "any",
        "no", "is", "are", "was", "were", "be", "been", "am", "do", "does", "did", "and", "or", "but", "of", "to", "in", "on",
        "at", "by", "for", "with", "as", "if", "it", "i", "you", "we", "they", "he", "she", "me", "us", "them", "so", "not",
    ].map(normalize))

    @inline(__always) static func foldApostrophe(_ v: UInt32) -> UInt32 { v == 0x2019 ? 0x27 : v }

    /// Written in a way no ordinary word is: a digit or symbol, or a capital after the
    /// first letter (GitHub, JSON, iOS, Next.js). "Notion" and "Linear" aren't.
    static func isDistinctive(_ word: String) -> Bool {
        isDistinctive(word.unicodeScalars)
    }

    /// Distinctive, and not just by being in capitals: a digit or symbol, or a capital
    /// inside a word that also has lowercase letters (Next.js, K8s, GraphQL, iOS). An
    /// all-capitals term may be an everyday abbreviation ("ASAP", "FYI").
    static func isUnmistakable<C: Collection>(_ word: C) -> Bool where C.Element == Unicode.Scalar {
        isDistinctive(word) && word.contains { Scalars.isLowercase($0) || (!Scalars.isLetter($0) && !isSeparator($0)) }
    }

    static func isDistinctive<C: Collection>(_ word: C) -> Bool where C.Element == Unicode.Scalar {
        for (i, c) in word.enumerated() {
            if Scalars.isDigit(c) { return true }
            if !Scalars.isLetter(c), !isSeparator(c) { return true }
            if i > 0, Scalars.isUppercase(c) { return true }
        }
        return false
    }

    // MARK: - Correcting

    public func correct(_ text: String) -> String {
        analyze(text).text
    }

    private struct Hit {
        let start: Int, end: Int
        let replacement: [Unicode.Scalar]?
        let gated: Bool
        let evidence: Bool
        let target: Target?

        /// Unless told otherwise, only a hit that needs no context can be context: an
        /// ungated target of an evidence entry.
        init(start: Int, end: Int, replacement: [Unicode.Scalar]? = nil, target: Target? = nil, evidence: Bool? = nil) {
            self.start = start
            self.end = end
            self.replacement = replacement
            self.target = target
            self.gated = target?.has(Target.gated) ?? false
            self.evidence = evidence ?? target.map { $0.has(Target.evidence) && !$0.has(Target.gated) } ?? false
        }
    }

    private func reason(_ t: Target?) -> String {
        guard let t else { return "" }
        let word = String(String.UnicodeScalarView(words[Int(t.entry)]))
        if !t.has(Target.variant) { return "spelling of \(word)" }
        return t.has(Target.lowercaseOnly) ? "ordinary-word variant of \(word)" : "variant of \(word)"
    }

    public func analyze(_ text: String) -> Result {
        let s = Array(text.unicodeScalars)
        let n = s.count
        guard n > 1, !groups.isEmpty else { return Result(text: text, changes: [], hasTechContext: false) }
        let f = s.map { Self.foldApostrophe(Scalars.fold($0)) }
        var hits: [Hit] = []
        var found: [(end: Int, group: Int32)] = []
        var shouted = ShoutedSentences()
        let urls = Self.urls(in: s)
        var nextURL = 0
        var i = 0
        while i < n - 1 {
            // A URL with a scheme is left whole, scheme included ("https://", "postgres://").
            while nextURL < urls.count, urls[nextURL].upperBound <= i { nextURL += 1 }
            if nextURL < urls.count, urls[nextURL].contains(i) { i = urls[nextURL].upperBound; continue }
            if i > 0, !Self.canStart(after: s[i - 1]) { i += 1; continue }
            let second = Self.isSeparator(s[i + 1]) ? Self.separator : f[i + 1]
            guard let list = buckets[Self.bucket(f[i], second)] else { i += 1; continue }
            found.removeAll(keepingCapacity: true)
            for g in list {
                if let end = matchPattern(groups[Int(g)].pattern, at: i, s, f) { found.append((end, g)) }
            }
            var hit: Hit?
            if !found.isEmpty {
                found.sort { $0.end > $1.end }
                for (end, g) in found {
                    if let h = decide(groups[Int(g)], start: i, end: end, s, &shouted) { hit = h; break }
                }
            }
            if let hit {
                hits.append(hit)
                i = hit.end
            } else {
                i += 1
            }
        }
        guard !hits.isEmpty else { return Result(text: text, changes: [], hasTechContext: false) }
        let context = hits.contains { $0.evidence }
        let near = context ? Self.nearEvidence(hits, s) : []
        var out = String.UnicodeScalarView()
        var changes: [Change] = []
        var last = 0
        for (k, h) in hits.enumerated() {
            guard let r = h.replacement, !s[h.start..<h.end].elementsEqual(r) else { continue }
            let applied = !h.gated || (context && near[k])
            let missing = applied ? "" : context ? ", but no tech context within \(Self.contextReach) words" : ", but no tech context"
            changes.append(Change(original: String(String.UnicodeScalarView(s[h.start..<h.end])), replacement: String(String.UnicodeScalarView(r)),
                                  applied: applied, reason: reason(h.target) + missing))
            guard applied else { continue }
            out.append(contentsOf: s[last..<h.start])
            out.append(contentsOf: r)
            last = h.end
        }
        guard last > 0 else { return Result(text: text, changes: changes, hasTechContext: context) }
        out.append(contentsOf: s[last...])
        return Result(text: String(out), changes: changes, hasTechContext: context)
    }

    /// For each hit, whether an evidence hit lies within `contextReach` words of it, before
    /// or after (an evidence hit is near itself). Words are counted the way patterns match
    /// them: any run of spaces, hyphens or dashes is a break ("16-year-old" is three).
    private static func nearEvidence(_ hits: [Hit], _ s: [Unicode.Scalar]) -> [Bool] {
        // The word each hit starts and ends in. Hits are in order and don't overlap, so
        // one pass over the text numbers them all.
        var firstWord = [Int](repeating: 0, count: hits.count), lastWord = firstWord
        var words = 0, p = 0
        func word(at q: Int) -> Int {
            while p <= q {
                if !isSeparator(s[p]), p == 0 || isSeparator(s[p - 1]) { words += 1 }
                p += 1
            }
            return words
        }
        for (k, h) in hits.enumerated() {
            firstWord[k] = word(at: h.start)
            lastWord[k] = word(at: h.end - 1)
        }
        var near = hits.map(\.evidence)
        var previous: Int?   // last word of the closest evidence hit before
        for k in hits.indices {
            if hits[k].evidence { previous = lastWord[k] } else if let w = previous, firstWord[k] - w <= contextReach { near[k] = true }
        }
        var following: Int?  // first word of the closest evidence hit after
        for k in hits.indices.reversed() {
            if hits[k].evidence { following = firstWord[k] } else if let w = following, w - lastWord[k] <= contextReach { near[k] = true }
        }
        return near
    }

    /// Where the pattern ends in the text, if it matches at `i`.
    @inline(__always) private func matchPattern(_ p: [UInt32], at i: Int, _ s: [Unicode.Scalar], _ f: [UInt32]) -> Int? {
        let n = s.count
        var j = i
        for c in p {
            if c == Self.separator {
                guard j < n, Self.isSeparator(s[j]) else { return nil }
                while j < n, Self.isSeparator(s[j]) { j += 1 }
            } else {
                guard j < n, f[j] == c else { return nil }
                j += 1
            }
        }
        return j
    }

    private func decide(_ g: Group, start: Int, end: Int, _ s: [Unicode.Scalar], _ shouted: inout ShoutedSentences) -> Hit? {
        let written = s[start..<end]
        // In a sentence written all in capitals an all-caps word is just a word ("I AM SO HAPPY").
        func skipped(_ t: Target) -> Bool { t.has(Target.capsWord) && shouted.contains(start, in: s) }
        // Already spelled exactly as a case-sensitive term: keep it.
        for e in g.exact where written.elementsEqual(words[Int(e.entry)]) && Self.endsCleanly(s, at: end) && !skipped(e) {
            return Hit(start: start, end: end, evidence: e.has(Target.evidence))
        }
        if let c = g.canonical, !skipped(c) {
            var stop = end
            let word0 = words[Int(c.entry)]
            if c.has(Target.plural) {
                // "-es" only after s, x, z, ch or sh ("regexes"); otherwise "cranes" would be CRAN + es.
                let suffixes = Self.takesEs(word0) ? ["es", "s"] : ["s"]
                for suffix in suffixes where Self.has(suffix, in: s, at: end) && Self.endsCleanly(s, at: end + suffix.count) {
                    stop = end + suffix.count
                    break
                }
            }
            if Self.endsCleanly(s, at: stop) {
                guard c.has(Target.rewrite) else { return Hit(start: start, end: stop) }
                // A gated term is context only when written as no ordinary word is ("Next.js",
                // not "asap").
                let evidence = c.has(Target.evidence) && (!c.has(Target.gated) || Self.isUnmistakable(written))
                // A Titlecase word for an all-caps term is a name or a place ("Maui" isn't MAUI,
                // "Aria" isn't ARIA). Mixed-case terms still get fixed ("Github" → GitHub).
                if Self.isTitlecase(written), Self.isAllCaps(word0) { return Hit(start: start, end: stop) }
                var word = word0
                if !word.contains(where: Scalars.isUppercase) {
                    // An all-lowercase term ("kubectl", "grep"): keep a capital the sentence gave it.
                    if written.map(Scalars.fold).elementsEqual(word.map(Scalars.fold)) {
                        return Hit(start: start, end: stop, evidence: evidence)
                    }
                    if let first = written.first, Scalars.isUppercase(first),
                       let up = word.first.map({ String($0).uppercased().unicodeScalars }), up.count == 1 {
                        word[0] = up.first!
                    }
                }
                return Hit(start: start, end: stop, replacement: word + s[end..<stop], target: c, evidence: evidence)
            }
        }
        if let v = g.variant, !g.ambiguous, !skipped(v) {
            if v.has(Target.lowercaseOnly), written.contains(where: Scalars.isUppercase) { return nil }
            guard Self.endsCleanly(s, at: end) else { return nil }
            return Hit(start: start, end: end, replacement: words[Int(v.entry)], target: v)
        }
        return nil
    }

    /// Ends in s, x, z, ch or sh, so a plural adds "es".
    static func takesEs(_ word: [Unicode.Scalar]) -> Bool {
        let f = word.map(Scalars.fold)
        guard let last = f.last else { return false }
        if last == 0x73 || last == 0x78 || last == 0x7A { return true }   // s x z
        return f.count >= 2 && last == 0x68 && (f[f.count - 2] == 0x63 || f[f.count - 2] == 0x73)   // ch sh
    }

    /// "Maui": a capital, then lowercase letters only (at least two letters in all).
    static func isTitlecase<C: Collection>(_ written: C) -> Bool where C.Element == Unicode.Scalar {
        guard let first = written.first, Scalars.isUppercase(first) else { return false }
        var letters = 0
        for c in written where Scalars.isLetter(c) {
            letters += 1
            if letters > 1, Scalars.isUppercase(c) { return false }
        }
        return letters >= 2
    }

    /// "MAUI", "LEED", "EC2": every letter a capital (at least two letters).
    static func isAllCaps(_ word: [Unicode.Scalar]) -> Bool {
        var letters = 0
        for c in word where Scalars.isLetter(c) {
            guard Scalars.isUppercase(c) else { return false }
            letters += 1
        }
        return letters >= 2
    }

    @inline(__always) private static func has(_ suffix: String, in s: [Unicode.Scalar], at p: Int) -> Bool {
        var j = p
        for c in suffix.unicodeScalars {
            guard j < s.count, s[j] == c else { return false }
            j += 1
        }
        return true
    }

    /// Every URL with a scheme ("https://supabase.com/docs", "redis://localhost"), from the
    /// start of the scheme to the next space, in order.
    static func urls(in s: [Unicode.Scalar]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var i = 1
        while i + 2 < s.count {
            guard s[i] == ":", s[i + 1] == "/", s[i + 2] == "/", Scalars.isLetterOrNumber(s[i - 1]) else { i += 1; continue }
            var start = i - 1
            // RFC 3986 schemes: letters, digits, "+", "-" and "." ("git+ssh", "coap+tcp").
            while start > 0, Scalars.isLetterOrNumber(s[start - 1]) || s[start - 1] == "+" || s[start - 1] == "-" || s[start - 1] == "." {
                start -= 1
            }
            var end = i + 3
            while end < s.count, !Scalars.isSpace(s[end]) { end += 1 }
            out.append(start..<end)
            i = end
        }
        return out
    }

    /// Not in the middle of a word, a domain, a path, an address or a hashtag.
    @inline(__always) private static func canStart(after p: Unicode.Scalar) -> Bool {
        if Scalars.isWord(p) { return false }
        switch p {
        case ".", "/", ":", "@", "#", "\\", "$", "~", "_": return false
        default: return true
        }
    }

    /// Nothing after the match that continues the word, a file name, a domain or a path.
    @inline(__always) private static func endsCleanly(_ s: [Unicode.Scalar], at p: Int) -> Bool {
        guard p < s.count else { return true }
        let c = s[p]
        if Scalars.isWord(c) { return false }
        if c == "." || c == "/" || c == ":" || c == "@" || c == "\\" {
            return !(p + 1 < s.count && Scalars.isWord(s[p + 1]))
        }
        return true
    }

    // MARK: - Words never worth rewriting

    /// Very common English words. As a spoken variant on their own they're never
    /// rewritten ("next" isn't Next.js, "view" isn't Vue, even in a dictation about
    /// code); a variant made only of them counts as ordinary speech; and a term that is
    /// one of them is never case-corrected on its own.
    static let commonWords: Set<String> = [
        "a", "about", "above", "after", "again", "against", "all", "almost", "also", "always", "am", "an", "and", "another",
        "any", "are", "around", "as", "ask", "at", "away", "back", "bad", "base", "be", "because", "been", "before", "being",
        "best", "better", "between", "big", "both", "but", "by", "call", "came", "can", "case", "change", "check", "close",
        "come", "could", "course", "day", "did", "different", "do", "does", "done", "down", "during", "each", "early", "end",
        "even", "ever", "every", "fact", "far", "feel", "few", "find", "fine", "first", "for", "found", "from", "full", "gave",
        "get", "give", "go", "going", "gone", "good", "got", "great", "group", "had", "hand", "has", "have", "he", "head",
        "help", "her", "here", "high", "him", "his", "home", "how", "i", "if", "in", "into", "is", "it", "its", "it's", "just",
        "keep", "kind", "know", "last", "late", "later", "leave", "left", "less", "let", "life", "light", "like", "line",
        "little", "long", "look", "lot", "made", "make", "man", "many", "may", "me", "mean", "might", "more", "most", "move",
        "much", "must", "my", "name", "need", "never", "new", "next", "nice", "no", "not", "now", "number", "of", "off", "old",
        "on", "once", "one", "only", "open", "or", "order", "other", "our", "out", "over", "own", "page", "part", "people",
        "place", "plan", "play", "point", "put", "quite", "rather", "read", "real", "really", "right", "run", "said", "same",
        "saw", "say", "see", "seem", "set", "she", "should", "show", "side", "since", "small", "so", "some", "something",
        "soon", "start", "state", "still", "stop", "such", "sure", "take", "talk", "team", "tell", "than", "thank", "that",
        "the", "their", "them", "then", "there", "these", "they", "thing", "think", "this", "those", "though", "through",
        "time", "to", "today", "together", "too", "took", "try", "turn", "two", "under", "until", "up", "us", "use", "used",
        "very", "view", "want", "was", "way", "we", "week", "well", "went", "were", "what", "when", "where", "which", "while",
        "who", "why", "will", "with", "without", "word", "work", "world", "would", "year", "yes", "yet", "you", "your",
    ]
}
