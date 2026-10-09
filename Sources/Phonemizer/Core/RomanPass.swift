import Foundation

/// Roman numerals (Core readings, FIN-889; area "roman"): monarchs and popes ("Henry the
/// Eighth"), world wars, document parts, classes and stages, sequels, teams and years.
///
/// The pass runs after the custom lexicon (its keys hold numerals: "SOC 2 Type II", "GTA V",
/// "Mac OS X") and before `unshout`, so a numeral in a shouted sentence is still in capitals.
/// It reads marks as their labels (`LabelView`) and never rewrites inside one, except an "X" or
/// "vi" mark right after a trigger (R0).
///
/// A numeral is read only where its context settles it; everything else stays letters, and a
/// lone "I" stays the pronoun unless a narrow gate passes (R13). Each candidate goes to the
/// rules in order, and the first that takes it decides: years (R11), world wars (R1), Act and
/// Scene (R5), people (R2), keywords with their lists and sub-stage letters (R4, R6, R7),
/// franchises (R8a), teams (R10), sequels (R8b), a subtitle's colon (R9) and heading lines
/// (R12). Numbers are written as words (`SpokenNumbers`), never digits, so the fraction and range
/// rules after it never see "1/2" in "Phase I/II".
enum RomanPass {
    typealias Rule = TextNormalizer.Rule

    /// The Roman pass: in `Phonemizer.phonemize` after `custom.mark` and before `unshout`, only
    /// when normalizing. Both voices read numerals the same way: number words carry no British
    /// "and" (DECISIONS 2).
    static func apply(_ text: String, british: Bool) -> String {
        guard candidate.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
        else { return text }
        var reader = Reader(LabelView(text))
        return reader.read()
    }

    /// The FIN-877 reader ran here, after `unshout`, where "HENRY VIII" had already lost its
    /// capitals. The pass above reads every numeral now (R0).
    static func readAfterUnshout(_ text: String) -> String {
        text
    }

    /// The "WW2" rule ran last in TextNormalizer's list; the pass reads world wars now (R1).
    static func legacyRules(british: Bool) -> [Rule] {
        []
    }

    /// Whether `word` is a numeral of two or more letters in capitals ("XVIII", "MCMLXXXIV"):
    /// `Lexicon.isShoutedWord` keeps one the pass didn't read spelled in a shouted sentence (R14),
    /// as it is in mixed case, rather than reading it as a made-up word.
    static func isNumeral(_ word: String) -> Bool {
        word.utf16.count >= 2 && word.first?.isUppercase == true && value(of: word) != nil
    }

    /// The value of a canonical numeral, in capitals or all in lower case ("XIV" 14, "xii" 12);
    /// nil for anything else ("IIII", "MCMC", "Mix"), so a word made of the same letters stays a
    /// word.
    static func value(of numeral: String) -> Int? {
        var values: [Int] = []
        var upper: Bool?
        for c in numeral.unicodeScalars {
            let v: Int
            switch c {
            case "I", "i": v = 1
            case "V", "v": v = 5
            case "X", "x": v = 10
            case "L", "l": v = 50
            case "C", "c": v = 100
            case "D", "d": v = 500
            case "M", "m": v = 1000
            default: return nil
            }
            let isUpper = c.value < 0x60
            if let upper, upper != isUpper { return nil }
            upper = isUpper
            values.append(v)
            if values.count > 15 { return nil }
        }
        var total = 0
        for (i, v) in values.enumerated() {
            total += i + 1 < values.count && v < values[i + 1] ? -v : v
        }
        guard total > 0, total < 4000, roman(total) == numeral.uppercased() else { return nil }
        return total
    }

    private static func roman(_ n: Int) -> String {
        var n = n, out = ""
        for (v, s) in [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
                       (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")] {
            while n >= v { out += s; n -= v }
        }
        return out
    }

    /// What could be a numeral: a run of numeral letters in capitals (with a sub-stage letter
    /// glued on: "IIIA", "IIb") or in lower case (i, v and x only: "xii", "ii"), "WW" glued to a
    /// war's number ("WWII", "WW2") and "Mk" glued to a numeral ("MkIV"). No letter or digit on
    /// either side; a hyphen, a possessive or punctuation is fine.
    static let candidate = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])(?:WW(?:III|II|I|[123])|Mk[IVXL]+|[IVXLCDM]+[A-Ca-c]?|[ivx]+)(?![\p{L}\p{N}])"#)

    /// R6: a list or range going on after a numeral the pass read ("Chapters IV and V", "Parts
    /// II–IV", "Phase I/II"): the separator, then the next numeral.
    static let continuation = try! NSRegularExpression(
        pattern: #"(,[ \t](?:(?i:and|or)[ \t])?|[ \t](?:(?i:and|or|to|through)|&)[ \t]|[ \t]?–[ \t]?|-|/)([IVXLCDM]+|[ivx]+)(?![\p{L}\p{N}])"#)

    /// R5: the rest of an Act and Scene citation after the Act's numeral (", Scene ii").
    static let sceneCitation = try! NSRegularExpression(
        pattern: #"([,.]?)\s+(Scene|SCENE|scene|Sc\.|sc\.)\s+([IVXLCDM]+|[ivxlcdm]+)(?![\p{L}\p{N}])"#)
}

/// One pass of `RomanPass` over a text: its candidates in order, each read by the first rule that
/// takes it, and the words written over them.
private struct Reader {
    /// A word before a candidate, and what separates it from the next word (or the numeral).
    struct Word {
        let text: String
        let range: NSRange  // in the reading
        let gap: String
        var lower: String { text.lowercased() }
        var shape: Shape { Shape(text) }
        var capitalised: Bool { shape == .title || shape == .upper }
    }

    /// How a word is written: all lower case, title case ("Chapter", "D"), capitals ("CHAPTER")
    /// or anything else ("WrestleMania", "iPhone").
    enum Shape {
        case lower, title, upper, other
        init(_ word: String) {
            let letters = word.filter(\.isLetter)
            guard let first = letters.first else { self = .other; return }
            if letters.allSatisfy(\.isLowercase) { self = .lower }
            else if first.isUppercase && letters.dropFirst().allSatisfy(\.isLowercase) { self = .title }
            else if letters.allSatisfy(\.isUppercase) { self = .upper }
            else { self = .other }
        }
    }

    let view: LabelView
    let s: NSString
    /// Made on the first rewrite: most texts the pass sees have no numeral it reads.
    var casing: ShoutedCasing?
    /// The rewrites, as reading ranges in order, each plain or exactly one "X" or "vi" mark.
    var edits: [(range: NSRange, words: String)] = []

    init(_ view: LabelView) {
        self.view = view
        s = view.reading
    }

    mutating func read() -> String {
        var next = 0
        for m in RomanPass.candidate.matches(in: s as String, range: NSRange(location: 0, length: s.length))
        where m.range.location >= next {
            if let end = decide(m.range) { next = end }
        }
        guard !edits.isEmpty else { return view.text as String }
        var out = "", last = 0
        for e in edits {
            let r = textRange(e.range)
            out += view.text.substring(with: NSRange(location: last, length: r.location - last)) + e.words
            last = NSMaxRange(r)
        }
        return out + view.text.substring(from: last)
    }

    // MARK: - The rules, in order

    /// Reads the candidate at `r` by the first rule that takes it; returns where reading
    /// continues (past a list or a citation it took with it), or nil to leave it.
    private mutating func decide(_ r: NSRange) -> Int? {
        guard writable(r) else { return nil }
        let token = s.substring(with: r)
        if token.hasPrefix("WW") { return worldWarGlued(token, r) }
        if token.hasPrefix("Mk") { return markGlued(token, r) }
        var numeral = token
        var value = RomanPass.value(of: token)
        var letter: String?
        if value == nil, token.count > 1, let last = token.last, "ABCabc".contains(last) {
            let head = String(token.dropLast())
            if head.first?.isUppercase == true, let v = RomanPass.value(of: head) {
                numeral = head
                value = v
                letter = String(last)
            }
        }
        guard let value else { return nil }
        let prev = words(before: r.location, count: 5)
        if let letter { return subStage(numeral, value, letter, r, prev) }
        let upper = numeral.first!.isUppercase
        if upper, let end = year(numeral, value, r) { return end }
        if upper, let end = worldWar(numeral, value, r, prev) { return end }
        if let end = actScene(value, r, prev) { return end }
        if upper, let end = person(numeral, value, r, prev) { return end }
        if let end = keyword(numeral, value, r, prev) { return end }
        // "St. Thomas VI", "St. Croix VI": the US Virgin Islands' postal code, after any rule's name.
        guard upper, !(numeral == "VI" && prev.count > 1 && ["thomas", "john", "croix"].contains(prev[0].lower)
                       && ["st", "saint"].contains(prev[1].lower)) else { return nil }
        if let end = franchise(numeral, value, r, prev) { return end }
        if let end = team(numeral, value, r, prev) { return end }
        if let end = sequel(numeral, value, r, prev) { return end }
        if let end = subtitle(numeral, value, r, prev) { return end }
        return heading(numeral, value, r)
    }

    /// R11: a year in numerals ("Copyright MCMLXXXIV", "The cornerstone reads MDCCLXXVI"): four
    /// or more letters, 1000 to 2099. No such numeral is a word or a lexicon key. A "©" before it
    /// is written as "copyright", as it reads before a year in digits (DECISIONS 3), unless the
    /// word is already beside it ("Copyright © MCMXC" leaves the sign to the shorthand rules).
    private mutating func year(_ numeral: String, _ value: Int, _ r: NSRange) -> Int? {
        guard numeral.count >= 4, (1000...2099).contains(value) else { return nil }
        var start = r.location
        var words = SpokenNumbers.year(value)
        var p = r.location
        while p > 0, isSpace(s.character(at: p - 1)) { p -= 1 }
        if p > 0, s.character(at: p - 1) == 0xA9, writable(NSRange(location: p - 1, length: r.location - p + 1)) {
            let before = self.words(before: p - 1, count: 1).first
            let saysCopyright = before?.lower == "copyright" && before!.gap.allSatisfy { $0 == " " || $0 == "\u{00A0}" }
            if !saysCopyright {
                start = p - 1
                words = "copyright " + words
            }
        }
        write(words, over: NSRange(location: start, length: NSMaxRange(r) - start))
        return NSMaxRange(r)
    }

    /// R1(a): "WWII", "WW2", "WWIII" (glued, in capitals), with a possessive after it ("WWII's").
    /// A prefix joined to it by a hyphen becomes a word of its own ("post-WWII" → "post World War
    /// Two"): hyphenated, "post-World" was one compound word.
    private mutating func worldWarGlued(_ token: String, _ r: NSRange) -> Int? {
        let number: String
        switch token.dropFirst(2) {
        case "I", "1": number = "One"
        case "II", "2": number = "Two"
        case "III", "3": number = "Three"
        default: return nil
        }
        var range = r
        if r.location >= 2, s.character(at: r.location - 1) == 0x2D, isLetter(s.character(at: r.location - 2)) {
            range = NSRange(location: r.location - 1, length: r.length + 1)
        }
        write((range.location < r.location ? " " : "") + "World War " + number, over: range)
        return NSMaxRange(r)
    }

    /// R1: "World War II", "WORLD WAR III", "WW II" and "WW-II". "World War" in title case or
    /// capitals always takes I, II or III, with no pronoun check ("World War I was a disaster").
    /// But after "the World War", a lone I is the war only before punctuation or a word of its
    /// own ("the World War I centenary"): 1920s prose has "During the World War I served in
    /// France". In lower case ("a third world war I fear") the I must pass the gate. A spaced
    /// "WW" takes only II and III: "WW 2 years ago" is WeightWatchers and "WW I think" the pronoun.
    private mutating func worldWar(_ numeral: String, _ value: Int, _ r: NSRange, _ prev: [Word]) -> Int? {
        guard value <= 3, let w = prev.first else { return nil }
        let names = ["One", "Two", "Three"]
        if w.text == "WW", numeral != "I", w.gap == " " || w.gap == "-" {
            let whole = NSRange(location: w.range.location, length: NSMaxRange(r) - w.range.location)
            guard writable(whole) else { return nil }
            write("World War " + names[value - 1], over: whole)
            return NSMaxRange(r)
        }
        guard w.lower == "war", w.gap == " ", prev.count > 1, prev[1].lower == "world", prev[1].gap == " " else { return nil }
        let titled = w.capitalised && prev[1].capitalised
        if numeral == "I" {
            if !titled {
                guard iGate(after: NSMaxRange(r), followers: nil, bareName: false) else { return nil }
            } else if prev.count > 2, prev[2].lower == "the", prev[2].gap == " " {
                guard endsPhrase(at: NSMaxRange(r)) || RomanNames.worldWarOneNouns.contains(nextWord(after: NSMaxRange(r)).lowercased())
                else { return nil }
            }
        }
        write(titled ? names[value - 1] : names[value - 1].lowercased(), over: r)
        return NSMaxRange(r)
    }

    /// R5: "Act II, Scene ii", "Act I, Scene i", "act iii, sc. ii". The only place a lone lower-case
    /// "i" is one: the whole citation has to be there.
    private mutating func actScene(_ value: Int, _ r: NSRange, _ prev: [Word]) -> Int? {
        guard value <= 39, let act = prev.first, act.lower == "act", act.shape != .other,
              act.gap.allSatisfy(\.isWhitespace) else { return nil }
        let rest = NSRange(location: NSMaxRange(r), length: s.length - NSMaxRange(r))
        guard let m = RomanPass.sceneCitation.firstMatch(in: s as String, options: .anchored, range: rest) else { return nil }
        let scene = m.range(at: 2), second = m.range(at: 3)
        guard let sceneValue = RomanPass.value(of: s.substring(with: second)), sceneValue <= 39,
              writable(scene), writable(second) else { return nil }
        write(SpokenNumbers.cardinal(value), over: r)
        let abbreviated = s.substring(with: scene)
        if abbreviated.hasSuffix(".") { write(abbreviated.first == "S" ? "Scene" : "scene", over: scene) }
        write(SpokenNumbers.cardinal(sceneValue), over: second)
        return NSMaxRange(second)
    }

    /// R2: people, read as ordinals ("Henry the Eighth", "Pope John the Twenty Third", "Thurston
    /// Howell the Third"). A: a title and one to three names ("Queen Elizabeth II", "Pope John
    /// Paul II"; after Prince, Duke or Saint the first name must be a ruler's). B: a ruler's name
    /// alone, or with "the" ("Henry VIII", "Henry the VIII"). C: a given name, one or two more
    /// names or initials, and II, III or IV ("John D. Rockefeller IV"), unless a keyword or a
    /// franchise is what comes before the numeral ("Lincoln Mark VII").
    ///
    /// Numerals of two or more letters run from 2 to 39, never XX or XXX (kisses: "Love, Mary
    /// XX"), never IV before a clinical noun ("give John IV fluids") and never VI after St.
    /// Thomas, St. John or St. Croix (the US Virgin Islands). A single V or X is a numeral only
    /// before a lower-case word, "of", a possessive, a comma, semicolon or colon, or the end of
    /// the sentence; before a capitalised word it's a middle initial ("Henry V. Poor", "Mary V
    /// Jones"), except that after a title ". " ends the sentence ("Queen Elizabeth I. It
    /// hangs…"). X never ends a bare name ("Love, Mary X") and never follows Malcolm. L, C, D and
    /// M alone are initials. A lone I goes through the gate (R13). A list goes on as rulers (R6:
    /// "Louis XIV, XV and XVI").
    private mutating func person(_ numeral: String, _ value: Int, _ r: NSRange, _ prev: [Word]) -> Int? {
        let single = numeral.count == 1
        if single {
            guard numeral == "I" || numeral == "V" || numeral == "X" else { return nil }
        } else {
            guard (2...39).contains(value), numeral != "XX", numeral != "XXX" else { return nil }
        }
        var names = prev[...]
        var hasThe = false
        if let w = names.first, w.lower == "the", w.shape != .other, w.gap == " " {
            hasThe = true
            names = names.dropFirst()
        }
        guard let nearest = names.first, nearest.capitalised, nearest.gap == " " else { return nil }

        // A: a title, then one to three names.
        var title: String?
        for k in 1...3 where k < names.count {
            let run = names.prefix(k)
            guard run.allSatisfy({ $0.capitalised }), run.dropFirst().allSatisfy({ $0.gap == " " }) else { break }
            let t = names[names.startIndex + k]
            let key = t.gap == ". " ? t.lower + "." : t.lower
            guard t.capitalised, t.gap == " " || key == "st.", let restricted = RomanNames.regnalTitles[key] else { continue }
            if restricted && !RomanNames.regnalNames.contains(names[names.startIndex + k - 1].lower) { break }
            title = key
            break
        }
        // B, then C.
        var named = title != nil || RomanNames.regnalNames.contains(nearest.lower)
        if !named, !hasThe, ["II", "III", "IV"].contains(numeral), RomanNames.keywords[nearest.lower] == nil,
           matchedFranchise(prev) == nil {
            named = familyName(Array(names))
        }
        guard named else { return nil }

        let next = nextWord(after: NSMaxRange(r)).lowercased()
        if numeral == "IV", RomanNames.clinicalNouns.contains(next) { return nil }
        if numeral == "VI", title == "st." || title == "saint", ["thomas", "john", "croix"].contains(nearest.lower) { return nil }
        if single {
            if numeral == "I" {
                guard iGate(after: NSMaxRange(r), followers: nil, bareName: title == nil) else { return nil }
            } else {
                if numeral == "X", nearest.lower == "malcolm" { return nil }
                guard letterEndsName(after: NSMaxRange(r), x: numeral == "X", titled: title != nil) else { return nil }
            }
        }
        let ordinal = Self.ordinal(value)
        write(hasThe ? ordinal : "the " + ordinal, over: r)
        return continueList(from: NSMaxRange(r), key: "", kind: .ruler, upper: true)
    }

    /// A ruler's ordinal in title case: "Twenty Third".
    private static func ordinal(_ value: Int) -> String {
        SpokenNumbers.ordinal(value).split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// R2-C: a given name, then one or two capitalised names or initials, before the numeral
    /// (`names`, nearest first).
    private func familyName(_ names: [Word]) -> Bool {
        for k in 1...2 where k < names.count {
            let given = names[k]
            let between = names[0..<k]
            guard between.allSatisfy({ $0.capitalised && ($0.gap == " " || ($0.text.count == 1 && $0.gap == ". ")) })
            else { return false }
            if given.capitalised, given.gap == " ", RomanNames.givenNames.contains(given.lower) { return true }
        }
        return false
    }

    /// Whether a single V or X after a name ends it as a numeral: a lower-case word, "of", a
    /// possessive, a comma, semicolon or colon, or the end of its sentence follows. A capitalised
    /// word next makes it a middle initial, unless a title came first (`titled`), where ". " ends
    /// the sentence. An X that ends the text, its line or a quotation with no full stop signs off
    /// ("Love, Mary X", "“Love, Mary X”") unless titled.
    private func letterEndsName(after end: Int, x: Bool, titled: Bool) -> Bool {
        var p = end
        guard p < s.length else { return !x || titled }
        let c = s.character(at: p)
        if c == 0x2C || c == 0x3B || c == 0x3A { return true }  // , ; :
        if c == 0x29 || c == 0x5D || c == 0x22 || c == 0x201D { return !x || titled }  // ) ] " ”
        if (c == 0x27 || c == 0x2019), p + 1 < s.length, s.character(at: p + 1) == 0x73,
           p + 2 >= s.length || !isLetter(s.character(at: p + 2)) { return true }  // 's
        if c == 0x2E || c == 0x21 || c == 0x3F {  // . ! ?
            p += 1
            while p < s.length, s.character(at: p) == 0x2E || s.character(at: p) == 0x21 || s.character(at: p) == 0x3F { p += 1 }
            guard p < s.length, !isNewline(s.character(at: p)) else { return true }
            guard isSpace(s.character(at: p)) else { return false }
            while p < s.length, isSpace(s.character(at: p)) { p += 1 }
            guard p < s.length, !isNewline(s.character(at: p)) else { return true }
            return titled || !isUppercase(s.character(at: p))
        }
        if isNewline(c) { return !x || titled }
        guard isSpace(c) else { return false }
        let word = nextWord(after: end)
        return word == "of" || word.first?.isLowercase == true
    }

    /// R4 (with R6 and R7): a keyword before the numeral, read as a number ("Chapter four",
    /// "Phase three", "Super Bowl fifty eight", "Mark seven"); "Ch.", "Vol." and "Mk" are written
    /// out. Capitals of two or more letters run from 2 to 89 (one with C, D or M needs four or more
    /// letters: "Chapter CXXXV", not "Appendix CD"). A single V follows a capitalised keyword
    /// other than Mark and Appendix ("Class V", not "class V extends Base"); a single X only a
    /// document part ("Title X"); a single I only a capitalised keyword, through the gate (R13).
    /// C, D, L and M alone are letters ("Section L", "Appendix C"). In lower case, a document
    /// takes i, v and x up to 39 ("page xii", "Chapter v"), a class only ii, iii and iv ("type ii
    /// diabetes"), an event none.
    private mutating func keyword(_ numeral: String, _ value: Int, _ r: NSRange, _ prev: [Word]) -> Int? {
        guard let (key, kind, keywordRange, capitalised) = keyword(before: prev) else { return nil }
        guard accepts(numeral, value, key: key, kind: kind, capitalised: capitalised, end: NSMaxRange(r)) else { return nil }
        if let expansion = RomanNames.expansions[key] {
            let whole = NSRange(location: keywordRange.location, length: keywordRange.length + (key.hasSuffix(".") ? 1 : 0))
            if writable(whole) { write(expansion, over: whole) }
        }
        let words = SpokenNumbers.cardinal(value)
        let end = NSMaxRange(r)
        // R7: a lettered sub-part after a hyphen ("Title IV-E", "Class I-A"), unless a range goes on.
        if kind != .event, let sub = hyphenLetter(at: end), !continues(at: end, key: key, kind: kind, upper: numeral.first!.isUppercase) {
            write(words + subLetter(s.substring(with: sub)), over: NSRange(location: r.location, length: NSMaxRange(sub) - r.location))
            return NSMaxRange(sub)
        }
        return writeNumber(value, over: r, key: key, kind: kind)
    }

    /// Writes a keyword's (or a list's) number over `r`, with "star" for a starred grade (R4 (7):
    /// "Grade II*" is "Grade two star"), and reads the list that goes on after it (R6). In a
    /// ruler's list each number is a ruler of its own ("Louis the Fourteenth, the Fifteenth").
    private mutating func writeNumber(_ value: Int, over r: NSRange, key: String, kind: RomanNames.Kind) -> Int {
        var end = NSMaxRange(r)
        var words = kind == .ruler ? "the " + Self.ordinal(value) : SpokenNumbers.cardinal(value)
        if key.hasPrefix("grade"), end < s.length, s.character(at: end) == 0x2A {
            words += " star"
            end += 1
        }
        write(words, over: NSRange(location: r.location, length: end - r.location))
        return continueList(from: end, key: key, kind: kind, upper: s.character(at: r.location) < 0x60)
    }

    /// The keyword right before a numeral, one space (or no-break space) away: its key ("ch."
    /// for "Ch." and "bowl" for "Super Bowl"), kind, range and whether it's capitalised.
    private func keyword(before prev: [Word]) -> (String, RomanNames.Kind, NSRange, Bool)? {
        guard let w = prev.first else { return nil }
        var key = w.lower
        if w.gap == ". " || w.gap == ".\u{00A0}" {
            key += "."
            guard key == "ch." || key == "vol." || key == "mk." else { return nil }
        } else if w.gap != " " && w.gap != "\u{00A0}" {
            return nil
        }
        guard let kind = RomanNames.keywords[key] else { return nil }
        var capitalised = w.capitalised
        if key == "bowl" {
            guard prev.count > 1, prev[1].lower == "super", prev[1].gap == " " else { return nil }
            capitalised = capitalised && prev[1].capitalised
        }
        return (key, kind, w.range, capitalised)
    }

    /// Whether a keyword takes `numeral` (R4's numerals; `end` is where the numeral ends, for
    /// the gate).
    private func accepts(_ numeral: String, _ value: Int, key: String, kind: RomanNames.Kind, capitalised: Bool, end: Int) -> Bool {
        if kind == .ruler {
            // A ruler's list takes a ruler's numerals (R2); its single letters are decided by R6.
            return numeral.count >= 2 && numeral.first!.isUppercase && (2...39).contains(value) && numeral != "XX" && numeral != "XXX"
        }
        if numeral.first!.isUppercase {
            if numeral.count >= 2 {
                return numeral.contains(where: { "CDM".contains($0) }) ? numeral.count >= 4 : (2...89).contains(value)
            }
            guard capitalised else { return false }
            switch numeral {
            case "V": return !["mark", "mk", "mk.", "appendix"].contains(key)
            case "X": return RomanNames.tenKeywords.contains(key)
            case "I": return key != "appendix" && iGate(after: end, followers: RomanNames.followers[key] ?? [], bareName: false)
            default: return false
            }
        }
        switch kind {
        case .document: return (numeral.count >= 2 && value <= 39) || numeral == "v"
        case .grade: return numeral == "ii" || numeral == "iii" || numeral == "iv"
        case .event, .ruler: return false
        }
    }

    /// R6: the numerals of a list or range that goes on after a keyword's or a ruler's ("Chapters
    /// IV and V", "Parts II–IV", "Phase I/II", "Louis XIV, XV and XVI"), in the same case. A dash
    /// or hyphen reads "to"; a slash joins the two ("Phase one two"); words stay. A single V or X
    /// goes on; a single I never: lists go up, so I only ever starts one, and after "and" it's the
    /// pronoun ("Chapter IV and I loved it", "between King Charles III and I"). C, D, L or M alone
    /// never goes on, and an Arabic digit never ("Form I-9"). Returns where the list ends.
    private mutating func continueList(from start: Int, key: String, kind: RomanNames.Kind, upper: Bool) -> Int {
        guard let (separator, numeral, value) = nextInList(at: start, key: key, kind: kind, upper: upper) else { return start }
        let mark = s.substring(with: separator).trimmingCharacters(in: .whitespaces)
        if mark == "–" || mark == "-" { write(" to ", over: separator) } else if mark == "/" { write(" ", over: separator) }
        return writeNumber(value, over: numeral, key: key, kind: kind)
    }

    /// Whether a list or range goes on at `location` (so a hyphen is a range, not a sub-part).
    private func continues(at location: Int, key: String, kind: RomanNames.Kind, upper: Bool) -> Bool {
        nextInList(at: location, key: key, kind: kind, upper: upper) != nil
    }

    private func nextInList(at location: Int, key: String, kind: RomanNames.Kind, upper: Bool) -> (NSRange, NSRange, Int)? {
        guard location < s.length,
              let m = RomanPass.continuation.firstMatch(in: s as String, options: .anchored,
                                                        range: NSRange(location: location, length: s.length - location))
        else { return nil }
        let numeral = s.substring(with: m.range(at: 2))
        guard numeral.first!.isUppercase == upper, let value = RomanPass.value(of: numeral),
              writable(m.range(at: 1)), writable(m.range(at: 2)) else { return nil }
        if upper && numeral.count == 1 {
            guard numeral == "V" || numeral == "X" else { return nil }
        } else if !accepts(numeral, value, key: key, kind: kind, capitalised: true, end: NSMaxRange(m.range(at: 2))) {
            return nil
        }
        return (m.range(at: 1), m.range(at: 2), value)
    }

    /// R7 glued: "Stage IIIA", "Class IIb": I to IV with a, b or c after Stage, Phase, Type,
    /// Class or Grade. A glued letter is never the pronoun.
    private mutating func subStage(_ numeral: String, _ value: Int, _ letter: String, _ r: NSRange, _ prev: [Word]) -> Int? {
        guard value <= 4, let w = prev.first, w.gap == " ", w.shape != .other,
              RomanNames.subStageKeywords.contains(w.lower) else { return nil }
        write(SpokenNumbers.cardinal(value) + subLetter(letter), over: r)
        return NSMaxRange(r)
    }

    /// A sub-stage letter after its number, in capitals: "four E", "two B". "A" is joined with a
    /// hyphen ("three-A"): after a space the tagger takes it for the article ("three uh").
    private func subLetter(_ letter: String) -> String {
        let capital = letter.uppercased()
        return (capital == "A" ? "-" : " ") + capital
    }

    /// The range of a single letter after a hyphen at `location` ("-E" in "IV-E"), if that's all.
    private func hyphenLetter(at location: Int) -> NSRange? {
        guard location + 1 < s.length, s.character(at: location) == 0x2D, isAsciiLetter(s.character(at: location + 1)),
              location + 2 >= s.length || !isLetterOrDigit(s.character(at: location + 2)) else { return nil }
        return NSRange(location: location + 1, length: 1)
    }

    /// "MkIV", as car forums write it: "Mark four".
    private mutating func markGlued(_ token: String, _ r: NSRange) -> Int? {
        guard let value = RomanPass.value(of: String(token.dropFirst(2))), value <= 89 else { return nil }
        write("Mark " + SpokenNumbers.cardinal(value), over: r)
        return NSMaxRange(r)
    }

    /// R8a: franchises, whose numbers include those the general sequel rule leaves alone ("Rocky
    /// IV", "Final Fantasy X", "WrestleMania XL"), and the lists after them.
    private mutating func franchise(_ numeral: String, _ value: Int, _ r: NSRange, _ prev: [Word]) -> Int? {
        guard let highest = matchedFranchise(prev) else { return nil }
        if numeral.count == 1 {
            guard numeral == "V" || (numeral == "X" && highest > 5) else { return nil }
        } else {
            guard highest > 5, (2...highest).contains(value) else { return nil }
        }
        return writeNumber(value, over: r, key: "", kind: .event)
    }

    /// The highest number of the franchise the words before a numeral name, if they do.
    private func matchedFranchise(_ prev: [Word]) -> Int? {
        guard let first = prev.first, first.gap == " " else { return nil }
        for (words, highest) in RomanNames.franchises where words.count <= prev.count {
            var matches = true
            for (i, word) in words.reversed().enumerated() {
                let w = prev[i]
                // Capitalised as the brand writes it ("WrestleMania", "StarCraft"), or "of".
                let written = w.text.first?.isUppercase == true || (word == "of" && w.shape == .lower)
                if w.lower != word || !written || (i > 0 && w.gap != " ") {
                    matches = false
                    break
                }
            }
            if matches { return highest }
        }
        return nil
    }

    /// R10: a team's XI ("The England XI", "the starting XI") and a rugby side's XV ("The
    /// England XV"; "Subaru XV" is a car).
    private mutating func team(_ numeral: String, _ value: Int, _ r: NSRange, _ prev: [Word]) -> Int? {
        guard numeral == "XI" || numeral == "XV", let w = prev.first, w.gap == " " else { return nil }
        let ok: Bool
        if numeral == "XI" {
            let monarch = RomanNames.regnalNames.contains(w.lower) || RomanNames.regnalTitles[w.lower] != nil
            ok = nextWord(after: NSMaxRange(r)) != "Jinping"
                && ((w.shape == .title && !monarch) || (w.shape == .lower && RomanNames.elevenWords.contains(w.lower)))
        } else {
            ok = (w.shape == .title && RomanNames.rugbySides.contains(w.lower))
                || (w.shape == .lower && RomanNames.fifteenWords.contains(w.lower))
        }
        guard ok else { return nil }
        write(SpokenNumbers.cardinal(value), over: r)
        return NSMaxRange(r)
    }

    /// R8b: a sequel or series after a title-case word ("Frozen II", "Major League II"): II, III,
    /// VI to IX and XII to XXXIX. Never IV (a drip: "Ceftriaxone IV"), XI, XV ("Subaru XV"), XX,
    /// XXX, XL, LI, LV, LX, LIV or a single letter, and never after a sentence opener, a
    /// hyphenated word ("Saudi-backed LIV"), a given name or a keyword.
    private mutating func sequel(_ numeral: String, _ value: Int, _ r: NSRange, _ prev: [Word]) -> Int? {
        guard ["II", "III", "VI", "VII", "VIII", "IX"].contains(numeral)
              || ((12...39).contains(value) && !["XV", "XX", "XXX"].contains(numeral)),
              let w = prev.first, titleWord(w) else { return nil }
        return writeNumber(value, over: r, key: "", kind: .event)
    }

    /// R9: a single V before a subtitle's colon ("Elder Scrolls V: Skyrim"); the other numerals
    /// R8b has read already. Never IV ("Vancomycin IV: 1 g").
    private mutating func subtitle(_ numeral: String, _ value: Int, _ r: NSRange, _ prev: [Word]) -> Int? {
        guard numeral.allSatisfy({ "IVX".contains($0) }), numeral == "V" || (numeral.count >= 2 && numeral != "IV" && (2...39).contains(value)),
              NSMaxRange(r) < s.length, s.character(at: NSMaxRange(r)) == 0x3A, let w = prev.first, titleWord(w) else { return nil }
        write(SpokenNumbers.cardinal(value), over: r)
        return NSMaxRange(r)
    }

    /// A title-case word a sequel number can follow: not a sentence opener, hyphenated, a name,
    /// a title or a keyword.
    private func titleWord(_ w: Word) -> Bool {
        guard w.gap == " ", w.shape == .title, w.text.count >= 2, !Self.sentenceStarters.contains(w.text) else { return false }
        if w.range.location > 0, s.character(at: w.range.location - 1) == 0x2D { return false }
        let lower = w.lower
        return !RomanNames.givenNames.contains(lower) && !RomanNames.regnalNames.contains(lower)
            && RomanNames.regnalTitles[lower] == nil && RomanNames.keywords[lower] == nil
    }

    /// R12: a heading line that is only a numeral ("XIV."): II to XXXIX, but not IV (a route in a
    /// medication table), XI, XX or XXX (kisses on their own line).
    private mutating func heading(_ numeral: String, _ value: Int, _ r: NSRange) -> Int? {
        guard numeral.count >= 2, numeral.allSatisfy({ "IVX".contains($0) }), (2...39).contains(value),
              !["IV", "XI", "XX", "XXX"].contains(numeral) else { return nil }
        var a = r.location
        while a > 0, s.character(at: a - 1) == 0x20 || s.character(at: a - 1) == 0x09 { a -= 1 }
        guard a == 0 || isNewline(s.character(at: a - 1)) else { return nil }
        var b = NSMaxRange(r)
        if b < s.length, s.character(at: b) == 0x2E || s.character(at: b) == 0x3A { b += 1 }
        while b < s.length, s.character(at: b) == 0x20 || s.character(at: b) == 0x09 { b += 1 }
        guard b == s.length || isNewline(s.character(at: b)) else { return nil }
        let words = SpokenNumbers.cardinal(value)
        write(words.prefix(1).uppercased() + words.dropFirst(), over: r)
        return NSMaxRange(r)
    }

    // MARK: - The I-gate

    /// R13: whether a lone "I", right after a trigger, is a numeral: punctuation or structure
    /// follows (the end of the text or line; , ; : ) ] ! ?; a full stop, except that after a bare
    /// name ". " and a capital is a middle initial; a possessive; " of "; " ("; a spaced dash; a
    /// slash, hyphen or en dash and another numeral, never a digit ("Form I-9"); "and", "or",
    /// "&", "to" or "through" and another numeral), a third-person verb the pronoun can't take
    /// ("Table I shows"), or a word the keyword's numbers come before (`followers`: "Schedule I
    /// drug"). A keyword's hyphen and single letter is a sub-part ("Class I-A"). Everything else
    /// keeps the pronoun ("Part I agree", "At the Super Bowl I cried").
    private func iGate(after end: Int, followers: Set<String>?, bareName: Bool) -> Bool {
        guard end < s.length else { return true }
        let c = s.character(at: end)
        if isNewline(c) { return true }
        switch c {
        case 0x2C, 0x3B, 0x3A, 0x29, 0x5D, 0x21, 0x3F: return true  // , ; : ) ] ! ?
        case 0x2E:  // .
            var p = end + 1
            guard p < s.length, !isNewline(s.character(at: p)) else { return true }
            guard isSpace(s.character(at: p)) else { return false }
            while p < s.length, isSpace(s.character(at: p)) { p += 1 }
            guard p < s.length, !isNewline(s.character(at: p)) else { return true }
            return !(bareName && isUppercase(s.character(at: p)))
        case 0x27, 0x2019:  // 's
            return end + 1 < s.length && s.character(at: end + 1) == 0x73
                && (end + 2 >= s.length || !isLetter(s.character(at: end + 2)))
        case 0x2F, 0x2D, 0x2013:  // / - –
            if numeralFollows(at: end + 1) { return true }
            return c == 0x2D && followers != nil && hyphenLetter(at: end) != nil
        default:
            guard isSpace(c) else { return false }
        }
        let rest = s.substring(with: NSRange(location: end + 1, length: min(40, s.length - end - 1)))
        if rest.hasPrefix("(") || rest.hasPrefix("– ") || rest.hasPrefix("— ") { return true }
        if rest.hasPrefix("& ") { return numeralFollows(at: end + 3) }
        let word = String(rest.prefix { $0.isLetter }).lowercased()
        if word == "of" { return true }
        if ["and", "or", "to", "through"].contains(word) {
            let at = end + 1 + (word as NSString).length
            return at < s.length && s.character(at: at) == 0x20 && numeralFollows(at: at + 1)
        }
        return RomanNames.thirdPersonVerbs.contains(word) || followers?.contains(word) == true
    }

    /// Whether a numeral in capitals starts at `location` (not a lone I, which would need a gate
    /// of its own).
    private func numeralFollows(at location: Int) -> Bool {
        var e = location
        while e < s.length, isLetter(s.character(at: e)) { e += 1 }
        guard e > location, e == s.length || !isDigit(s.character(at: e)) else { return false }
        let token = s.substring(with: NSRange(location: location, length: e - location))
        return token != "I" && token.first?.isUppercase == true && RomanPass.value(of: token) != nil
    }

    // MARK: - Reading the text around a numeral

    /// Up to `count` words before `location`, nearest first, on its line: runs of letters (with
    /// an apostrophe inside: "Baldur's") separated by at most four other characters.
    private func words(before location: Int, count: Int) -> [Word] {
        var result: [Word] = []
        var end = location
        while result.count < count {
            var g = end
            while g > 0, !isLetter(s.character(at: g - 1)) {
                if isNewline(s.character(at: g - 1)) || end - g >= 4 { return result }
                g -= 1
            }
            guard g > 0 else { break }
            var w = g
            while w > 0 {
                let c = s.character(at: w - 1)
                if isLetter(c) { w -= 1; continue }
                if c == 0x27 || c == 0x2019, w < g, w >= 2, isLetter(s.character(at: w - 2)) { w -= 1; continue }
                break
            }
            let range = NSRange(location: w, length: g - w)
            result.append(Word(text: s.substring(with: range), range: range,
                               gap: s.substring(with: NSRange(location: g, length: end - g))))
            end = w
        }
        return result
    }

    /// The word after `location`, past spaces ("" at the end of the text or before punctuation).
    private func nextWord(after location: Int) -> String {
        var p = location
        while p < s.length, isSpace(s.character(at: p)) { p += 1 }
        var e = p
        while e < s.length, isLetter(s.character(at: e)) { e += 1 }
        return s.substring(with: NSRange(location: p, length: e - p))
    }

    /// Whether punctuation, a line break or the end follows at `location` (not a word).
    private func endsPhrase(at location: Int) -> Bool {
        guard location < s.length else { return true }
        let c = s.character(at: location)
        return isNewline(c) || (!isSpace(c) && !isLetterOrDigit(c))
    }

    // MARK: - Writing

    /// Writes `words` over `range` (in the reading), in capitals inside a shouted sentence.
    private mutating func write(_ words: String, over range: NSRange) {
        if casing == nil { casing = ShoutedCasing(view) }
        let cased = words.isEmpty ? words : casing!.cased(words, at: view.textLocation(range.location))
        edits.append((range, cased))
    }

    /// Whether `range` of the reading can be rewritten: it's plain text, or exactly the label of
    /// an "X" or "vi" mark (R0: "Charles X", "Title X", "Chapter vi").
    private func writable(_ range: NSRange) -> Bool {
        guard let i = label(overlapping: range) else { return true }
        guard view.labels[i] == range else { return false }
        let label = s.substring(with: range)
        return label == "X" || label == "vi"
    }

    /// Where a rewritten reading range is in the marked text: a mark's whole range for its label.
    private func textRange(_ range: NSRange) -> NSRange {
        if let i = label(overlapping: range), view.labels[i] == range { return view.marks[i] }
        let a = view.textLocation(range.location), b = view.textLocation(NSMaxRange(range))
        return NSRange(location: a, length: b - a)
    }

    /// The index of the first label that overlaps `range` (a binary search: the labels are in
    /// order and don't overlap), or nil for plain text.
    private func label(overlapping range: NSRange) -> Int? {
        let labels = view.labels
        var lo = 0, hi = labels.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(labels[mid]) <= range.location { lo = mid + 1 } else { hi = mid }
        }
        return lo < labels.count && labels[lo].location < NSMaxRange(range) ? lo : nil
    }

    // MARK: - Characters

    private static let sentenceStarters = Set(Tokenizer.sentenceStarters)

    private func isLetter(_ c: unichar) -> Bool { Unicode.Scalar(c).map(Scalars.isLetter) ?? false }
    private func isUppercase(_ c: unichar) -> Bool { Unicode.Scalar(c).map(Scalars.isUppercase) ?? false }
    private func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }
    private func isLetterOrDigit(_ c: unichar) -> Bool { isLetter(c) || isDigit(c) }
    private func isAsciiLetter(_ c: unichar) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
    private func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 || c == 0xA0 }
    private func isNewline(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D }
}
