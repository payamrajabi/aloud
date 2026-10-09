import Foundation

/// Titles and name suffixes (Core readings, FIN-889; area "titles"): ranks and offices before a
/// name ("Lt. Col. Smith"), "Gen." as a generation, Jr. and Sr., Esq., "Lt." as light, and the
/// period of a title that is also the full stop.
///
/// The pass runs on the raw text before the custom lexicon (T0), so a name the lexicon would mark
/// is still in view ("Sen. Niamh Smyth") and the tech entries CPL, ENS, SNR and LTS don't take a
/// title first. It runs after the address pass, so "Ocean Dr. Suite 3" is already Drive. It owns
/// Jr and Sr (the Roman area's R3 is deleted in favour of T5). The word lists are in
/// TitleWords.swift.
enum TitlePass {
    typealias Rule = TextNormalizer.Rule

    /// The titles pass: in `Phonemizer.phonemize` after the address pass, only when normalizing.
    /// Each abbreviation is read where it stands, from the words around it in the raw text, in
    /// titles.json's order: the pairs (T8, T4b), "Gen." as a generation (T3), Jr. and Sr. (T5),
    /// Assoc. and Asst. (T7), Esq. (T6), "(Ret.)" (T10), the readings that need no name (T14),
    /// "Lt." as light (T9), a title before a name (T2, T4), a rank with no name (T11), and last
    /// a bare "Lt." as its letters (DECISIONS 6). Its words go through `ShoutedCasing`.
    static func apply(_ text: String, british: Bool) -> String {
        // "Navy/Lt. Gray": a second colour after a slash, which the candidates skip ("2-Br.").
        let text = text.contains("/Lt.") ? colourAfterSlash.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: " light") : text
        let ns = text as NSString
        let matches = candidates.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var casing: ShoutedCasing?
        var out = "", last = 0
        // A pair reads its second word too ("Lt. Gov."); a match inside it is already read.
        for m in matches where m.range.location >= last {
            guard let (end, words) = reading(Site(m, in: ns), british: british) else { continue }
            if casing == nil { casing = ShoutedCasing(text) }
            // "Ex-Gov." is "Ex Governor": hyphenated, the reader made one word of them.
            let ex = m.range.location > last && ns.character(at: m.range.location - 1) == 0x2D  // "-"
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last - (ex ? 1 : 0))) + (ex ? " " : "")
            out += casing!.cased(words, at: m.range.location)
            last = end
        }
        return last == 0 ? text : out + ns.substring(from: last)
    }

    /// Whether `head`, a sentence as Apple's splitter cut it (trimmed), ends in a title of this
    /// area that runs on into `next` ("Det." + "Benson called.", "Rt. Rev." + "Hollis"), so the
    /// two are read as one (T12). Apple's splitter breaks after "Det.", "Fr.", "Sr.", "Mx.",
    /// "Hon.", "Brig.", "Msgr.", "Rt.", "Lts.", "Sgts." and "Drs." even before a name. A
    /// capitalised word that isn't a usual sentence opener runs on, as it does for the titles
    /// `Tokenizer.titleContinues` knows; those ("Sen.", "Gov.", "Prof.", "Gen.", "Rep.", "Rev.")
    /// and anything else give nil and are left to it. Each one needs a chunk case in
    /// Tests/g2p/regression.json: the speech tests phonemize whole lines and never see the split.
    static func sentenceContinues(_ head: String, into next: String) -> Bool? {
        guard head.hasSuffix(".") else { return nil }
        let body = head.dropLast()
        var start = body.endIndex
        while start > body.startIndex, body[body.index(before: start)].isLetter { start = body.index(before: start) }
        guard start < body.endIndex, start == body.startIndex || body[body.index(before: start)] != "." else { return nil }
        let title = String(body[start...])
        // "Fmr." + "Rep. Liz Cheney" (never the end of a sentence before a capital), "Dem." +
        // "Rep. Jasmine Crockett", "Asst." + "Mgr: Ana".
        let following = next.drop { $0.isWhitespace }
        if title == "Fmr" { return following.first?.isUppercase == true ? true : nil }
        if title == "Dem" {
            let word = following.prefix { $0.isLetter }
            return partyTitles.contains(String(word)) && following.dropFirst(word.count).first == "." ? true : nil
        }
        if ["Asst", "Assoc"].contains(title) {
            return assistedJobs.contains(String(following.prefix { $0.isLetter })) ? true : nil
        }
        guard runOnTitles.contains(title) else { return nil }
        let word = next.drop { $0.isWhitespace }.prefix { $0.isLetter || $0 == "'" || $0 == "’" }
        guard word.first?.isUppercase == true else { return false }
        return !starters.contains(String(word).replacingOccurrences(of: "’", with: "'"))
    }

    /// The titles `sentenceContinues` decides: every title of this area with a period, but not the
    /// ones `Tokenizer.titles` already runs on.
    private static let runOnTitles = Set(titles.keys).union(["Rt", "Treas", "Sr", "Snr"])
        .subtracting(["Sen", "Gov", "Prof", "Gen", "Rep", "Rev"])

    /// The title rule that ran near the end of TextNormalizer's list. The titles pass reads every
    /// title before the custom lexicon (T0), so this is empty.
    static func legacyRules(british: Bool) -> [Rule] {
        []
    }

    // MARK: - Finding them

    /// Every abbreviation the pass reads, as a whole word, with its period if it has one. Matched
    /// case-sensitively: "JR Pass", "CPT codes" and "The SEC" stay letters (T15). Not after a
    /// hyphen or slash ("Semi-Det.", "2-Br."), and not before an apostrophe ("Sgt's").
    private static let candidates: NSRegularExpression = {
        let forms = Set(titles.keys).union(bareTitles.keys).union(pairOpeners)
            .union(["Jr", "Jnr", "Sr", "Snr", "sr", "Esq", "Ret", "ret", "Assoc", "Asst", "atty", "ATTY", "pvt", "PVT", "lt", "Fmr", "Dem"])
        let alternation = forms.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }.joined(separator: "|")
        return try! NSRegularExpression(pattern: #"(?:(?<![\p{L}\p{N}_.'’/\\-])|(?<=(?<![\p{L}\p{N}])[Ee]x-))("# + alternation + #")(\.)?(?![\p{L}\p{N}_'’])"#)
    }()

    private static let starters = Set(Tokenizer.sentenceStarters)
    /// "Navy/Lt. Gray", "Black/Lt. Blue": a colour, a slash and "Lt." before another colour.
    private static let colourAfterSlash = try! NSRegularExpression(pattern: #"(?<=\p{L})/Lt\.(?=[ \t]+(?i:gray|grey|green|brown|blue|pink|purple|yellow|teal|aqua|beige|khaki|tan|olive|coral|rose)(?![\p{L}]))"#)

    /// An abbreviation in the text and the words around it.
    private struct Site {
        let ns: NSString
        let range: NSRange
        /// Its letters, without the period.
        let abbr: String
        let dot: Bool
        /// The words after it, when a space (not a line break) follows it.
        let next: [Token]
        /// The word before it.
        let before: Before?

        init(_ m: NSTextCheckingResult, in ns: NSString) {
            self.ns = ns
            range = m.range
            abbr = ns.substring(with: m.range(at: 1))
            dot = m.range(at: 2).location != NSNotFound
            next = TitlePass.tokens(after: NSMaxRange(m.range), in: ns)
            before = Before(m.range.location, in: ns)
        }

        var end: Int { NSMaxRange(range) }

        /// T1's number guard: a digit and a space before it ("Spacious 2 Br. Condo", "30 Sec.
        /// Timer"). "1st Lt." isn't caught.
        var afterNumber: Bool {
            guard range.location >= 2, isSpace(ns.character(at: range.location - 1)) else { return false }
            let c = ns.character(at: range.location - 2)
            return c >= 0x30 && c <= 0x39
        }

        /// "." when its period is also the full stop: the end of the text or a line, or a usual
        /// sentence opener next (`FullStop`), as for "Jr." and "Sr.". Nothing without a period.
        var keptStop: String { dot ? TitlePass.keptStop(after: end, in: ns) : "" }
    }

    /// A word after the abbreviation: the text up to the next space.
    private struct Token {
        let location: Int
        let chunk: String
        /// Its leading letters, with apostrophes and inner hyphens ("O'Brien", "Pepper's").
        let word: String
        /// A period right after `word` ("Col.", "Smith.").
        let dot: Bool

        init(location: Int, chunk: String) {
            self.location = location
            self.chunk = chunk
            var word = ""
            for c in chunk {
                if c.isLetter || (!word.isEmpty && (c == "'" || c == "’" || c == "-")) { word.append(c) } else { break }
            }
            while let l = word.last, !l.isLetter { word.removeLast() }
            self.word = word
            dot = chunk.dropFirst(word.count).first == "."
        }

        /// Where `word` and its period end (UTF-16).
        var wordEnd: Int { location + word.utf16.count + (dot ? 1 : 0) }

        /// One or more initials and nothing else: "J.", "J.T.".
        var isInitials: Bool {
            guard chunk.count >= 2, chunk.count % 2 == 0 else { return false }
            return chunk.enumerated().allSatisfy { $0.offset % 2 == 0 ? $0.element.isUppercase : $0.element == "." }
        }
    }

    /// The word before the abbreviation.
    private struct Before {
        /// The text from the space before it up to the abbreviation ("Smith,", "(by", "3rd").
        let chunk: String
        /// `chunk` without punctuation at either end ("Smith", "by", "3rd").
        let word: String
        let start: Int
        /// A space between it and the abbreviation, and how many characters of it.
        let gap: Int

        init?(_ location: Int, in ns: NSString) {
            var j = location
            while j > 0, isSpace(ns.character(at: j - 1)) {
                if isLineBreak(ns.character(at: j - 1)) { return nil }
                j -= 1
            }
            var k = j
            while k > 0, !isSpace(ns.character(at: k - 1)) {
                k -= 1
                if j - k > longestWord { return nil }
            }
            guard k < j else { return nil }
            chunk = ns.substring(with: NSRange(location: k, length: j - k))
            word = chunk.trimmingCharacters(in: Self.wordCharacters.inverted)
            start = k
            gap = location - j
        }

        private static let wordCharacters = CharacterSet.letters.union(.decimalDigits)
    }

    /// Up to five words after `start`, each after a space; none when no space follows `start`.
    /// A line break ends them: a title at the end of a line isn't read with the next one.
    private static func tokens(after start: Int, in ns: NSString) -> [Token] {
        var out: [Token] = []
        var i = start
        while out.count < 5 {
            var j = i
            while j < ns.length, isSpace(ns.character(at: j)) {
                if isLineBreak(ns.character(at: j)) { return out }
                j += 1
            }
            guard j > i, j < ns.length else { return out }
            var k = j
            while k < ns.length, !isSpace(ns.character(at: k)) {
                k += 1
                if k - j > longestWord { return out }
            }
            out.append(Token(location: j, chunk: ns.substring(with: NSRange(location: j, length: k - j))))
            i = k
        }
        return out
    }

    /// The longest run without a space read as a word next to an abbreviation (UTF-16). A longer
    /// one (a link, a blob of code) is no name, and stopping there keeps a long run holding many
    /// abbreviations from being scanned again for each one.
    private static let longestWord = 64

    private static func isSpace(_ u: unichar) -> Bool {
        Unicode.Scalar(u).map(Scalars.isSpace) ?? false
    }

    private static func isLineBreak(_ u: unichar) -> Bool {
        u == 0x0A || u == 0x0D || u == 0x2028 || u == 0x2029
    }

    /// "." when the period ending at `end` is also the full stop (`FullStop.sentenceStarter`).
    private static func keptStop(after end: Int, in ns: NSString) -> String {
        FullStop.kept(before: ns.substring(with: NSRange(location: end, length: min(48, ns.length - end))), next: .sentenceStarter)
    }

    // MARK: - Reading them

    /// What the abbreviation at `s` reads as, and where in the text that reading ends (past the
    /// second word of a pair); nil leaves it as written.
    private static func reading(_ s: Site, british: Bool) -> (Int, String)? {
        if let r = pair(s) { return r }
        let a = s.abbr
        switch a {
        case "Gen" where s.dot: if let r = generation(s) { return r }
        case "Jr", "Jnr": return (s.end, "Junior" + s.keptStop)
        case "Sr", "Snr", "sr": return senior(s).map { (s.end, $0) }
        case "Assoc", "Asst": return assisted(s).map { (s.end, $0) }
        case "Esq": return esquire(s) ? (s.end, "Esquire" + s.keptStop) : nil
        // "Fmr. Rep. Liz Cheney", "Fmr. Pres. Barack Obama", "Fmr. Address": former, whatever
        // follows (it's never a word).
        case "Fmr" where s.dot: return (s.end, "Former" + s.keptStop)
        // "Dem. Rep. Jasmine Crockett", "Dem. Sen. Chris Murphy": a party before a title and a
        // name. "Dem. Rep. Congo" is the republic, and stays.
        case "Dem" where s.dot:
            guard let t = s.next.first, t.dot, partyTitles.contains(t.word), s.next.count > 1, !republics.contains(s.next[1].word),
                  name(s.next.dropFirst(), for: t.word, in: s.ns) else { return nil }
            return (s.end, "Democratic")
        // "the Foreign Sec.", "the 79th Treasury Sec.": an office after its department.
        case "Sec" where s.dot:
            if let b = s.before, b.gap > 0, b.chunk == b.word, departments.contains(b.word) { return (s.end, "Secretary" + s.keptStop) }
        // "Col Gaddafi": a UK paper's colonel before a surname alone, then a lower-case word.
        case "Col" where !s.dot:
            if s.next.count > 1, s.next[0].chunk == s.next[0].word, isName(s.next[0].word), !starters.contains(s.next[0].word),
               !(skips[a]?.contains(s.next[0].word) ?? false), s.next[1].word.first?.isLowercase == true {
                return (s.end, "Colonel")
            }
        case "Ret", "ret": return retired(s)
        // T14: one meaning in any case, with or without a name ("atty. fees", "Pvt. Parking Only").
        case "Atty", "atty", "ATTY": return (s.end, sameCase("attorney", as: a) + s.keptStop)
        case "Pvt", "pvt", "PVT": return (s.end, sameCase("private", as: a) + s.keptStop)
        default: break
        }
        if s.dot, let t = s.next.first {
            let w = t.word.lowercased()
            if a == "Hon", mentions.contains(w) { return (s.end, british ? "Honourable" : "Honorable") }
            if let plain = plainReadings[a], plain.words.contains(w) { return (s.end, plain.reads) }
            // "Sec. of State", "the Dir. of National Intelligence".
            if let office = officesOf[a], t.chunk == "of", s.next.count > 1, s.next[1].word.first?.isUppercase == true {
                return (s.end, office)
            }
            // "Prof. X": a single capital after "Prof." is still a name.
            if a == "Prof", t.chunk.count == 1, t.chunk.first?.isUppercase == true { return (s.end, "Professor") }
        }
        if a == "Lt" || a == "lt", isLight(s) { return (s.end, a == "lt" ? "light" : "Light") }
        if let title = beforeName(s) { return (s.end, title == "Honorable" && british ? "Honourable" : title) }
        if s.dot, let rank = rankAlone(s) { return (s.end, rank + s.keptStop) }
        // DECISIONS 6: a bare "Lt." is said as its letters ("the L T"), never "limit".
        if a == "Lt", s.dot { return (s.end, "L T" + s.keptStop) }
        return nil
    }

    /// T8 and T4b: two (or three) abbreviations that make one title ("Lt. Gov.", "Det Ch Supt",
    /// "Pvt. Ltd."), and the fixed phrases "Gov.-elect", "Sgt. at Arms", "Maj. Leader", "Lt.
    /// (j.g.)" and "Sr. Sec. School".
    private static func pair(_ s: Site) -> (Int, String)? {
        let a = s.abbr
        if s.dot {
            let after = s.ns.substring(with: NSRange(location: s.end, length: min(9, s.ns.length - s.end)))
            if electTitles.contains(a), after.hasPrefix("-elect"), !(after.dropFirst(6).first?.isLetter ?? false) {
                // Two words: hyphenated, "Governor-elect" is one compound with the stress moved.
                return (s.end + 6, titles[a]! + " elect")
            }
            if a == "Sgt", after.hasPrefix("-at-Arms") || after.hasPrefix("-at-arms") { return (s.end + 8, "Sergeant at Arms") }
            if a == "Sec", after.hasPrefix("-Gen.") {
                return (s.end + 5, "Secretary General" + keptStop(after: s.end + 5, in: s.ns))
            }
        }
        guard let t = s.next.first else { return nil }
        if s.dot {
            if a == "Lt", let jg = ["(j.g.)", "j.g."].first(where: t.chunk.hasPrefix) {
                return (t.location + jg.utf16.count, "Lieutenant junior grade")
            }
            if a == "Maj", ["leader", "leaders", "whip"].contains(t.word.lowercased()) { return (s.end, "Majority") }
            if a == "Sgt", t.chunk == "at", s.next.count > 1, s.next[1].word == "Arms" { return (s.end, "Sergeant") }
        }
        if a == "Sr", t.word == "Sec", s.next.count > 1, ["School", "Schools", "Education"].contains(s.next[1].word) {
            return (t.wordEnd, "Senior Secondary")
        }
        if s.next.count > 1, let three = triples[a + " " + t.word + " " + s.next[1].word] {
            let u = s.next[1]
            if s.dot || t.dot || u.dot || name(s.next.dropFirst(2), for: "", in: s.ns) {
                return (u.wordEnd, three + (u.dot ? keptStop(after: u.wordEnd, in: s.ns) : ""))
            }
        }
        let key = a + " " + t.word
        guard let both = pairs[key] else { return nil }
        if !(s.dot || t.dot), !namelessPairs.contains(key), !name(s.next.dropFirst(), for: "", in: s.ns) { return nil }
        return (t.wordEnd, both + (t.dot ? keptStop(after: t.wordEnd, in: s.ns) : ""))
    }

    /// T3: "Gen." as a generation, read "Gen" ("jen"): before X, Y, Z, Alpha or Beta, or after an
    /// ordinal, "Next", "Latest" and the like ("3rd Gen. Echo Dot", "Our Next Gen. Platform").
    private static func generation(_ s: Site) -> (Int, String)? {
        if let t = s.next.first, generations.contains(t.word),
           !(t.chunk.dropFirst(t.word.count).first.map { $0.isLetter || $0.isNumber } ?? false) {
            return (s.end, "Gen")
        }
        guard let b = s.before, b.gap > 0, isOrdinal(b.word) || generationAfter.contains(b.word.lowercased()) else { return nil }
        return (s.end, "Gen" + s.keptStop)
    }

    /// T5: "Sr.", "Sr" and "Snr". Senior after a name ("John Smith Sr.", "Downey Sr., a
    /// director") or before a job or "senior" noun ("Sr. Vice President", "Our Sr. Living
    /// community"); Sister before a given name from `sisterNames` ("Sr. Mary Joseph"); otherwise
    /// left alone ("Sr. No.", Spanish "Sr. García"). Lowercase "sr." is senior before a lowercase
    /// word.
    private static func senior(_ s: Site) -> String? {
        let a = s.abbr
        let first = s.next.first
        if a == "sr" {
            guard s.dot, let w = first?.word, w.first?.isLowercase == true else { return nil }
            return "senior"
        }
        // (a) After a name: a capitalised word that isn't a usual opener, written right before it
        // ("Sr." and "Snr" may follow a comma). Bare "Sr" needs one space, no comma and a word of
        // three letters or more, so element lists ("Ca, Sr, Ba", "Rb Sr") stay. A name that opens
        // the sentence counts only when no capitalised word follows ("Dear Sr. Helen" isn't one).
        if let b = s.before, b.gap > 0, b.chunk == b.word || b.chunk == b.word + ",",
           isName(b.word), !starters.contains(b.word) {
            let comma = b.chunk.hasSuffix(",")
            let bare = a == "Sr" && !s.dot
            let fits = bare ? !comma && b.gap == 1 && b.word.count >= 3 : true
            let opens = startsSentence(b.start, in: s.ns) && first?.word.first?.isUppercase == true
            if fits && !opens { return "Senior" + s.keptStop }
        }
        guard let first else { return nil }
        // (b) A job or "senior" noun among the next three capitalised words, or the lower-case
        // word right after them ("A Sr. White House adviser"); or an article before it ("a Sr.
        // something" is never Sister or Señor).
        if first.word.first?.isLowercase == true, seniorWords.contains(first.word) { return "Senior" }
        if s.dot, let b = s.before, b.chunk == b.word, ["a", "an", "A", "An", "our", "Our", "their", "his", "her"].contains(b.word) { return "Senior" }
        for t in s.next.prefix(4) {
            if t.word.first?.isLowercase == true { if seniorWords.contains(t.word) { return "Senior" }; break }
            if seniorWords.contains(t.word.lowercased()) { return "Senior" }
            if t.chunk != t.word { break }
        }
        // (c) Sister, before a listed given name or the initial "M." ("Sr. M. Agnes").
        if a == "Sr", sisterNames.contains(first.word) || first.chunk == "M." {
            return "Sister"
        }
        return nil
    }

    /// T7: "Assoc." and "Asst." before a job ("Assoc. Prof. Chen"), unless a capitalised word that
    /// isn't a usual opener comes before it: "Dental Assoc. Director Kim" is the association's.
    private static func assisted(_ s: Site) -> String? {
        guard let t = s.next.first, assistedJobs.contains(t.word) else { return nil }
        // Not after a list's comma ("Mgr: Tom, Asst. Mgr: Ana").
        if let b = s.before, b.chunk == b.word, b.word.first?.isUppercase == true, !starters.contains(b.word) { return nil }
        return s.abbr == "Assoc" ? "Associate" : "Assistant"
    }

    /// T6: "Esq." after a name ("Jane Doe, Esq.", "John Roe Esq").
    private static func esquire(_ s: Site) -> Bool {
        guard let b = s.before, b.gap > 0, let last = b.chunk.last else { return false }
        return last.isLetter || (last == "," && b.chunk.dropLast().last?.isLetter == true)
    }

    /// T10: "(Ret.)" is "(retired)"; ", Ret." after a name and before a comma, a closing bracket or
    /// the end of the sentence is ", retired".
    private static func retired(_ s: Site) -> (Int, String)? {
        let ns = s.ns
        let opened = s.range.location > 0 && ns.character(at: s.range.location - 1) == 0x28  // "("
        let next = s.end < ns.length ? ns.character(at: s.end) : nil
        if opened, next == 0x29 { return (s.end, "retired") }  // ")"
        guard let b = s.before, b.gap > 0, b.chunk.hasSuffix(","), b.word.first?.isUppercase == true else { return nil }
        if let next, [0x2C, 0x29, 0x3B].contains(next) { return (s.end, "retired") }  // , ) ;
        guard s.dot, s.keptStop == "." else { return nil }
        return (s.end, "retired.")
    }

    /// T9: "Lt." as light, before a colour or "Duty", "Wash", "Roast" ("Color: Lt. Blue", "Lt.
    /// Duty Casters"). A colour that is also a first name only when no capitalised word follows
    /// it ("Lt. Olive Harper" is a lieutenant); one that is also a surname only after "Color:"
    /// or "Colour:" (DECISIONS 6), so "Lt. Gray" in the news stays Lieutenant.
    private static func isLight(_ s: Site) -> Bool {
        guard let t = s.next.first else { return false }
        let colour = t.word.lowercased()
        if lightWords.contains(colour) { return true }
        let labelled = s.before.map { colourLabels.contains($0.chunk) } ?? false
        if nameColours.contains(colour) {
            return labelled || !(s.next.count > 1 && t.chunk == t.word && s.next[1].word.first?.isUppercase == true)
        }
        guard surnameColours.contains(colour) else { return false }
        // A colour in lower case is no surname ("Lt. gray is the new background"), and nor is one
        // before a garment or a finish ("Lt. Gray sweater, $39").
        if labelled || t.word.first?.isLowercase == true { return true }
        return t.chunk == t.word && s.next.count > 1 && colourNouns.contains(s.next[1].word.lowercased())
    }

    /// T2 and T4: a title before a name (T1), with or without a period, as `titles` and
    /// `bareTitles` read it.
    private static func beforeName(_ s: Site) -> String? {
        let a = s.abbr
        guard !s.afterNumber, !s.next.isEmpty else { return nil }
        let b = s.before
        // The calendar header "Mo Tu We Th Fr Sa Su"; Czech or Dominican "Rep." (Republic); "2nd
        // Brig." (a brigade).
        if a == "Fr", let w = b?.word, w == "Th" || w == "Thu" { return nil }
        if a == "Rep", let c = b?.chunk, ["Czech", "Dominican", "Slovak"].contains(c) { return nil }
        if a == "Rep", b?.chunk == "Dem.", s.next.first.map({ republics.contains($0.word) || $0.chunk == "of" }) ?? true { return nil }
        if a == "Brig", let w = b?.word, isOrdinal(w) { return nil }
        if s.dot {
            guard let title = titles[a], name(s.next[...], for: a, in: s.ns) else { return nil }
            return title
        }
        switch a {
        case "Col", "Maj":
            // Only before a first name and a surname ("Col Tim Collins", not "Maj Sjöwall wrote").
            guard s.next.count > 1, s.next[0].chunk == s.next[0].word, isName(s.next[0].word), isName(s.next[1].word),
                  !starters.contains(s.next[0].word), !(skips[a]?.contains(s.next[0].word) ?? false) else { return nil }
            return titles[a]
        case "Rev":
            // "The Rev Richard Coles", not "the Rev Up Tour".
            guard b?.chunk == "the" || b?.chunk == "The", name(s.next[...], for: a, in: s.ns) else { return nil }
            return titles[a]
        default:
            guard let title = bareTitles[a], name(s.next[...], for: a, in: s.ns) else { return nil }
            return title
        }
    }

    /// T11: a rank with no name after it, after "the", "to", "as" and the like ("promoted to Sgt.
    /// last year", "Ask the Capt."); "Lt." only after "to" or "as".
    private static func rankAlone(_ s: Site) -> String? {
        guard let b = s.before, b.gap > 0, b.chunk == b.word else { return nil }
        let w = b.word.lowercased()
        if s.abbr == "Lt" { return w == "to" || w == "as" ? titles["Lt"] : nil }
        guard ranksAlone.contains(s.abbr), rankWords.contains(w) else { return nil }
        return titles[s.abbr]
    }

    /// T1: whether `tokens` open a name for the title `abbr`: a capitalised word with a
    /// lower-case second letter or an apostrophe (Smith, O'Brien, McKay, Pepper's) that isn't a
    /// usual sentence opener or on the title's skip list; initials before one ("J. T. Kirk");
    /// another title ("Lt. Col. Ramirez", "Rev. Dr. King"); or, for "Sgt.", an ordinal and
    /// "Class". A single capital ("Col. B", "Gen. Z"), a number and a word in capitals ("Gen.
    /// AI") are no names. A word ending in "." must be a title itself ("Phys. Rev. Lett.",
    /// "Ofc. Mgr.", "Br. J. Surg." stay), unless that period is the full stop ("…to Lt. Smith.").
    private static func name(_ tokens: ArraySlice<Token>, for abbr: String, in ns: NSString) -> Bool {
        guard var i = tokens.indices.first else { return false }
        let first = tokens[i]
        if first.dot, chainTitles.contains(first.word) { return true }
        if abbr == "Sgt", isOrdinal(first.chunk) { return i + 1 < tokens.endIndex && tokens[i + 1].word == "Class" }
        while i < tokens.endIndex, tokens[i].isInitials { i += 1 }
        guard i < tokens.endIndex else { return false }
        let t = tokens[i]
        guard isName(t.word), !starters.contains(t.word.replacingOccurrences(of: "’", with: "'")),
              !(skips[abbr]?.contains(t.word) ?? false) else { return false }
        return !t.dot || keptStop(after: t.wordEnd, in: ns) == "."
    }

    /// Whether the word starting at `start` opens its sentence: nothing before it but spaces, or a
    /// line break, "!", "?" or a full stop. The period of a title or an initial isn't one ("Dr.
    /// Smith Sr.", "J. Smith Sr.").
    private static func startsSentence(_ start: Int, in ns: NSString) -> Bool {
        var j = start
        while j > 0, isSpace(ns.character(at: j - 1)) {
            if isLineBreak(ns.character(at: j - 1)) { return true }
            j -= 1
        }
        guard j > 0 else { return true }
        let c = ns.character(at: j - 1)
        if c == 0x21 || c == 0x3F { return true }  // ! ?
        guard c == 0x2E, let b = Before(j, in: ns) else { return false }
        let initial = b.word.count == 1 && b.word.first?.isUppercase == true
        return !initial && titles[b.word] == nil && !["Dr", "Mr", "Mrs", "Ms", "St", "Mt"].contains(b.word)
    }

    /// Whether `word` looks like a name: a capital, then a lower-case letter or an apostrophe.
    private static func isName(_ word: String) -> Bool {
        var it = word.makeIterator()
        guard let a = it.next(), a.isUppercase, let b = it.next() else { return false }
        return b.isLowercase || b == "'" || b == "’"
    }

    /// "1st", "2nd", "23rd", "4th".
    private static func isOrdinal(_ word: String) -> Bool {
        let digits = word.prefix { $0.isASCII && $0.isNumber }
        return !digits.isEmpty && ["st", "nd", "rd", "th"].contains(String(word.dropFirst(digits.count)))
    }

    /// "Attorney" for "Atty", "attorney" for "atty", "ATTORNEY" for "ATTY".
    private static func sameCase(_ word: String, as abbr: String) -> String {
        if abbr == abbr.uppercased() { return word.uppercased() }
        return abbr.first?.isUppercase == true ? word.prefix(1).uppercased() + word.dropFirst() : word
    }
}
