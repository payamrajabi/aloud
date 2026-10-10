import Foundation

/// The academic & research writing pack's reading rules (FIN-895). Its word list is
/// Lexicons/academic.json (ibid., op. cit., loc. cit., n.d., the Greek letters the stack can't
/// say, and the field-only "OR"); these are the readings that depend on what's around them.
/// Core already reads "p. 12", "pp. 14-17", "Fig. 2", "Vol. 3", "Ch. 3" and "c. 1850", and the
/// lists read "et al.", "cf.", "BCE", "CE", "CI", "SD", "R²" and "n = 30" right.
///   - "Eq. 4", "Eqs. 5-7", "Eqn. 2" → Equation(s); "chap. 3", "chs. 4-6", "sect. 2" →
///     chapter(s), section(s); "p. 45 n. 3", "nn. 3-5" → note(s); "pp. 12ff." → "and following";
///   - editors and editions: "(ed.)", "(eds.)" → editor(s); "ed. by" → "edited by"; ", ed. Jane
///     Smith" → "edited by"; "Smith, J., ed. 2020" → editor; "3rd ed.", "2nd edn." → edition;
///     "rev. ed." → "revised edition"; and the same for translators ("(trans.)", "trans. by") and
///     "repr. 2005" (reprinted). A bare "Ed." stays the name, "special ed." the word;
///   - "viz." → "namely"; "fl. 1200" → "flourished 1200"; "c." → "circa" before a year with an
///     era ("c. 300 BCE", "c. AD 50"), a century ("c. 3rd century") or after "fl." (Core does
///     four-digit years);
///   - numbered citations in brackets ("[12]", "[3–5]", "[1, 4; 9]") are read as nothing; not an
///     interval or a list in maths ("x ∈ [0, 1]", "= [1, 2]"), a link ("[1](…)") or "[sic]";
///   - "ibid.", "op. cit." and "loc. cit." ending a sentence keep its full stop (the list's keys
///     hold their abbreviation point, as "etc." does).
///
/// Heard by default: every rule needs a context that only academic writing has, so the pass
/// always runs (when normalizing, after the shorthand pass and before the custom lexicon, which
/// would otherwise read "Eq" as the tech list's EQ). The field-only reading is academic.json's
/// pack_only "OR" (odds ratio, O-R), heard only with the academic pack switched on.
enum AcademicPass {
    static func apply(_ text: String, british: Bool) -> String {
        var t = text
        let lower = t.lowercased()
        if lower.contains("eq") { t = rewrite(t, equations) { m, s in plural(m, s, "equation") + " " } }
        if lower.contains("ch") || lower.contains("sect") {
            t = rewrite(t, chapters) { m, s in
                let found = s.substring(with: m.range(at: 1)), lower = found.lowercased()
                let word = lower.hasPrefix("s") ? "section" : "chapter"
                let out = lower == "chs" || lower == "sects" ? word + "s" : word
                return (found.first!.isUppercase ? out.prefix(1).uppercased() + out.dropFirst() : out) + " "
            }
        }
        if lower.contains("n.") { t = rewrite(t, notes) { m, _ in m.range(at: 1).location != NSNotFound ? "notes " : "note " } }
        if lower.contains("ff.") {
            t = rewrite(t, following) { m, s in
                // The number before it stands on its own: a page ("pp. 12ff."), not the end of a hex
                // colour or a code ("#1e90ff.").
                let head = s.substring(to: m.range.location)
                let number = head.reversed().prefix { $0.isNumber }
                let before = head.dropLast(number.count).last ?? " "
                guard number.count <= 4, before.isWhitespace || "([–—-,;".contains(before) else { return nil }
                return " and following" + FullStop.kept(before: s.substring(from: NSMaxRange(m.range)), next: .capital)
            }
        }
        if lower.contains("ed") || lower.contains("trans") || lower.contains("repr") { t = readEditors(t) }
        if lower.contains("viz.") { t = rewrite(t, viz) { m, s in s.substring(with: m.range(at: 1)) == "V" ? "Namely" : "namely" } }
        if lower.contains("fl.") { t = rewrite(t, flourished) { _, _ in "flourished " } }
        if lower.contains("c.") {
            for rule in circa { t = rewrite(t, rule) { _, _ in "circa " } }
        }
        if lower.contains("cit.") || lower.contains("ibid.") {
            t = rewrite(t, latinEnd, cased: false) { m, s in
                FullStop.ends(before: s.substring(from: NSMaxRange(m.range)), next: .capital) ? s.substring(with: m.range) + "." : nil
            }
        }
        if t.contains("[") { t = dropCitations(t) }
        return t
    }

    // MARK: - Labels before a number

    private static let equations = try! NSRegularExpression(pattern:
        #"(?<![\p{L}\p{N}_.&])(?:(Eqs|eqs|Eq|eq)\.|(Eqns|eqns|Eqn|eqn)\.?)[ \t]?(?=\(?\d)"#)
    private static let chapters = try! NSRegularExpression(pattern:
        #"(?<![\p{L}\p{N}_.&])(?<!\d[ \t])(Chap|chap|Chs|chs|Sects|sects|Sect|sect)\.[ \t]?(?=\d)"#)
    /// A note: "nn. 3-5" anywhere before a number, "n. 3" only after a page ("p. 45 n. 3", "45, n. 3").
    private static let notes = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_.])(nn)\.[ \t]?(?=\d)|(?<=\d[ \t]|\d,[ \t])(n)\.[ \t]?(?=\d)"#)
    private static let following = try! NSRegularExpression(pattern: #"(?<=\d)[ \t]?ff\.(?![\p{L}\p{N}])"#)

    /// "Equation" or "Equations", capitalised as written.
    private static func plural(_ m: NSTextCheckingResult, _ s: NSString, _ word: String) -> String {
        let group = m.range(at: 1).location != NSNotFound ? 1 : 2
        let found = s.substring(with: m.range(at: group))
        let out = found.hasSuffix("s") ? word + "s" : word
        return found.first!.isUppercase ? out.prefix(1).uppercased() + out.dropFirst() : out
    }

    // MARK: - Editors, editions, translators

    private static let ordinals = #"(?:\d{1,3}(?:st|nd|rd|th)|[Ff]irst|[Ss]econd|[Tt]hird|[Ff]ourth|[Ff]ifth|[Ss]ixth|[Ss]eventh|[Ee]ighth|[Nn]inth|[Tt]enth|[Nn]ew|[Rr]evised|[Ee]xpanded|[Ee]nlarged|[Ii]nternational|[Ss]tudent|[Cc]ritical|[Aa]nniversary)"#
    private static let editorInBrackets = try! NSRegularExpression(pattern: #"\((Eds|eds|Ed|ed|Trans|trans|Tr|tr)\.\)"#)
    private static let edition = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])("# + ordinals + #"[ \t])(?:Edn|edn|Ed|ed)(\.)?(?![\p{L}\p{N}])"#)
    private static let revisedEdition = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_.])([Rr])ev\.[ \t]?(?:edn|ed)(\.)?(?![\p{L}\p{N}])"#)
    private static let editedBy = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_.])(Eds|eds|Ed|ed|Trans|trans)\.[ \t]+by(?![\p{L}])"#)
    /// After a name or title and a comma, in lower case as citation styles write it (", Ed." is
    /// more often the name): before another name it's "edited by" (", ed. Jane Smith"); before a
    /// year, a bracket, a comma or the end it's the editor ("Smith, J., ed. 2020").
    private static let editorAfterComma = try! NSRegularExpression(pattern: #"(?<=[\p{L}.],[ \t])(eds|ed|trans)\.(?=[ \t]*(?:([,;:(]|\d{4}|$)|\p{Lu}[\p{Ll}.]))"#)
    private static let reprinted = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_.])([Rr])epr\.[ \t]?(?=\d{4})"#)

    static func readEditors(_ text: String) -> String {
        var t = text
        t = rewrite(t, editorInBrackets) { m, s in
            switch s.substring(with: m.range(at: 1)).lowercased() {
            case "eds": return "(editors)"
            case "ed": return "(editor)"
            default: return "(translator)"
            }
        }
        t = rewrite(t, revisedEdition) { m, s in
            (s.substring(with: m.range(at: 1)) == "R" ? "Revised edition" : "revised edition")
                + (m.range(at: 2).location != NSNotFound ? FullStop.kept(before: s.substring(from: NSMaxRange(m.range)), next: .capital) : "")
        }
        t = rewrite(t, edition) { m, s in
            s.substring(with: m.range(at: 1)) + "edition"
                + (m.range(at: 2).location != NSNotFound ? FullStop.kept(before: s.substring(from: NSMaxRange(m.range)), next: .capital) : "")
        }
        t = rewrite(t, editedBy) { m, s in
            let found = s.substring(with: m.range(at: 1))
            let word = found.lowercased() == "trans" ? "translated by" : "edited by"
            return found.first!.isUppercase ? word.prefix(1).uppercased() + word.dropFirst() : word
        }
        t = rewrite(t, editorAfterComma) { m, s in
            let found = s.substring(with: m.range(at: 1)).lowercased()
            let beforeName = m.range(at: 2).location == NSNotFound
            if found.hasPrefix("trans") { return beforeName ? "translated by" : "translator" }
            if beforeName { return "edited by" }
            let word = found == "eds" ? "editors" : "editor"
            return word + FullStop.kept(before: s.substring(from: NSMaxRange(m.range)), next: .capital)
        }
        t = rewrite(t, reprinted) { m, s in s.substring(with: m.range(at: 1)) == "R" ? "Reprinted " : "reprinted " }
        return t
    }

    // MARK: - viz., fl., c.

    private static let viz = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_.])([Vv])iz\.(?=[ \t,:;]|$)"#)
    private static let flourished = try! NSRegularExpression(pattern:
        #"(?<![\p{L}\p{N}_.])fl\.[ \t]?(?=(?:c\.|ca\.|circa)?[ \t]?\d{1,4}(?![\d,.]\d))"#)
    private static let circa: [NSRegularExpression] = [
        // Before a year with its era: "c. 300 BCE", "c.700 BC", "c. 50 CE".
        #"(?<![\p{L}\p{N}_.&])c\.[ \t]?(?=\d{1,4}[ \t]?(?:BCE|CE|BC|AD|B\.C\.E\.|B\.C\.|A\.D\.|C\.E\.)(?![\p{L}]))"#,
        // Before the era: "c. AD 50".
        #"(?<![\p{L}\p{N}_.&])c\.[ \t]?(?=(?:AD|A\.D\.)[ \t]?\d)"#,
        // Before a century: "c. 3rd century", "c. the 12th century".
        #"(?<![\p{L}\p{N}_.&])c\.[ \t]?(?=(?:the[ \t])?\d{1,2}(?:st|nd|rd|th)[ \t]+centur(?:y|ies))"#,
        // After "flourished" (fl.): "fl. c. 700".
        #"(?<=flourished )c\.[ \t]?(?=\d)"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// "ibid.", "op. cit." and "loc. cit." (the list's keys, with their point).
    private static let latinEnd = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_.])(?:[Ii]bid|[Oo]p\. cit|[Ll]oc\. cit)\."#)

    // MARK: - Citations

    private static let citation = try! NSRegularExpression(pattern:
        #"\[(\d{1,3}(?:[ \t]*[–—-][ \t]*\d{1,3})?(?:[ \t]*[,;][ \t]*\d{1,3}(?:[ \t]*[–—-][ \t]*\d{1,3})?)*)\](?![(:\[])"#)
    private static let mathBefore = Set("=∈∉⊂⊆⊃⊇<>≤≥×÷+*^|")

    static func dropCitations(_ text: String) -> String {
        let ns = text as NSString
        let matches = citation.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = "", last = 0
        for m in matches {
            let inside = ns.substring(with: m.range(at: 1))
            // Citations count from 1: an interval or vector has a 0 ("[0, 1]").
            let numbers = inside.split { !$0.isNumber }
            if numbers.contains(where: { Int($0) == 0 }) { continue }
            let before = ns.substring(to: m.range.location)
            if let p = before.last(where: { $0 != " " && $0 != "\t" }), mathBefore.contains(p) { continue }
            // "in [1, 2]" / "x in [3, 4]" in maths: a lone letter before "in".
            if before.hasSuffix(" in ") || before.hasSuffix(" in\t") {
                let words = before.split(separator: " ")
                if words.count >= 2, words[words.count - 2].count == 1 { continue }
            }
            let prev = before.last, next = NSMaxRange(m.range) < ns.length ? ns.substring(with: NSRange(location: NSMaxRange(m.range), length: 1)).first : nil
            var gap = ""
            // Between two words with no space ("shown[12]that") a space keeps them apart.
            if let p = prev, let n = next, !p.isWhitespace, n.isLetter || n.isNumber { gap = " " }
            var head = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            // "results [12]." / "results [12], and": the space before the citation goes with it.
            if let n = next, ".,;:!?)".contains(n), head.hasSuffix(" ") { head.removeLast() }
            out += head + gap
            last = NSMaxRange(m.range)
        }
        return out + ns.substring(from: last)
    }

    // MARK: -

    /// Rewrites every match `read` returns words for, in capitals inside a shouted sentence.
    private static func rewrite(_ text: String, _ regex: NSRegularExpression, cased: Bool = true,
                                _ read: (NSTextCheckingResult, NSString) -> String?) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var casing: ShoutedCasing?
        var out = "", last = 0, changed = false
        for m in matches {
            guard var words = read(m, ns) else { continue }
            if cased {
                if casing == nil { casing = ShoutedCasing(text) }
                words = casing!.cased(words, at: m.range.location)
            }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + words
            last = NSMaxRange(m.range)
            changed = true
        }
        return changed ? out + ns.substring(from: last) : text
    }
}
