import Foundation

/// Hand-written pronunciations that win over every other source (names, brands, tech
/// terms). Read from JSON files shaped like:
///
///     [ { "word": "Kubernetes", "match": "case-insensitive", "us": "kˌubəɹnˈɛTiz", "gb": "kˌuːbənˈɛtiːz" } ]
///
/// `match` is "case-sensitive" (exact casing), "case-insensitive" (any casing) or
/// "exact" (exact casing, no suffixes). `gb` is optional; British voices use `us` when
/// it's missing. Other fields are ignored. Phonemes are in the final form Kokoro reads
/// (misaki's symbols, US flaps written T).
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
///     meeting"), never as a ratio ("a 1:1 crop").
public final class CustomLexicon {
    struct Entry {
        let key: String
        let caseSensitive: Bool
        let allowSuffix: Bool
        let us: String
        let gb: String?
    }

    private var entries: [String: Entry] = [:]   // keyed by key (+ case flag)
    private var compiled: (NSRegularExpression, [Entry])?
    public private(set) var problems: [String] = []
    public var count: Int { entries.count }

    /// Keys that only apply in some contexts: the text right after the key must match.
    static let contextGates: [String: String] = [
        "1:1": #"^(?:s(?![\p{L}\p{N}])|\s+(?:meeting|meetings|call|calls|chat|chats|session|sessions|sync|syncs|catch-?ups?|conversations?|check-?ins?|with)\b)"#,
    ]

    public init() {}

    /// Loads every *.json file in each directory, in order: later files override
    /// earlier ones (so a user folder listed last wins over the app's own lists).
    public convenience init(directories: [URL]) {
        self.init()
        let fm = FileManager.default
        for dir in directories {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names.sorted() where name.hasSuffix(".json") {
                load(dir.appendingPathComponent(name))
            }
        }
    }

    public func load(_ url: URL) {
        do {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            let items: [Any]
            if let a = json as? [Any] {
                items = a
            } else if let d = json as? [String: Any], let a = (d["entries"] ?? d["words"]) as? [Any] {
                items = a
            } else {
                problems.append("\(url.lastPathComponent): expected a JSON array of entries")
                return
            }
            for case let item as [String: Any] in items {
                guard let word = (item["word"] as? String)?.trimmingCharacters(in: .whitespaces), !word.isEmpty,
                      let us = (item["us"] as? String)?.trimmingCharacters(in: .whitespaces), !us.isEmpty else {
                    problems.append("\(url.lastPathComponent): entry without word/us: \(item["word"] ?? "?")")
                    continue
                }
                let gb = (item["gb"] as? String)?.trimmingCharacters(in: .whitespaces)
                add(word, us: us, gb: gb?.isEmpty == false ? gb : nil, match: item["match"] as? String ?? "case-sensitive")
            }
        } catch {
            problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    public func add(_ word: String, us: String, gb: String? = nil, match: String = "case-sensitive") {
        let key = word.precomposedStringWithCanonicalMapping
        let m = match.lowercased()
        let caseSensitive = m == "case-sensitive" || m == "exact"
        let allowSuffix = m != "exact" && (key.last?.isLetter ?? false)
        entries[(caseSensitive ? "=" : "~") + (caseSensitive ? key : key.lowercased())] =
            Entry(key: key, caseSensitive: caseSensitive, allowSuffix: allowSuffix, us: us, gb: gb)
        compiled = nil
    }

    private func regex() -> (NSRegularExpression, [Entry])? {
        if let compiled { return compiled }
        guard !entries.isEmpty else { return nil }
        let alts = entries.values.sorted { $0.key.count != $1.key.count ? $0.key.count > $1.key.count : $0.key < $1.key }
        // Every alternative has two groups, the key and its (possibly empty) ending.
        let parts = alts.map { e -> String in
            var key = NSRegularExpression.escapedPattern(for: e.key)
            if !e.caseSensitive { key = "(?i:" + key + ")" }
            if let gate = Self.contextGates[e.key] {
                key += "(?=" + String(gate.dropFirst()) + ")"
                return "(" + key + ")(s(?![\\p{L}\\p{N}_]))?"
            }
            return "(" + key + ")" + (e.allowSuffix ? "('s|’s|s'|s’|es|s|'|’)?" : "()")
        }
        let pattern = #"(?<![\w.\/:])(?:"# + parts.joined(separator: "|") + #")(?![\w])(?!:\d)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            problems.append("couldn't compile the lexicon's pattern")
            return nil
        }
        compiled = (re, alts)
        return compiled
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

    /// Wraps every match in misaki's [text](/phonemes/) syntax, which fixes its
    /// pronunciation for the rest of the pipeline.
    public func mark(_ text: String, british: Bool) -> String {
        guard let (re, alts) = regex() else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        var last = 0
        for m in matches {
            guard let i = (0..<alts.count).first(where: { m.range(at: 2 * $0 + 1).location != NSNotFound }) else { continue }
            let e = alts[i]
            var ps = british ? (e.gb ?? e.us) : e.us
            let suffix = m.range(at: 2 * i + 2)
            if suffix.location != NSNotFound, suffix.length > 0 {
                let s = ns.substring(with: suffix)
                if s != "'" && s != "’" { ps = Self.addS(ps, british: british) }
            }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += "[\(ns.substring(with: m.range))](/\(ps)/)"
            last = NSMaxRange(m.range)
        }
        out += ns.substring(from: last)
        return out
    }
}
