// misaki's Lexicon (en.py), ported to Swift.
//
// Derived from misaki (https://github.com/hexgrad/misaki, Apache-2.0) and MisakiSwift
// (https://github.com/mlalma/MisakiSwift, Apache-2.0; see LICENSE-MisakiSwift.txt).
// Modified for Aloud:
//   - gold lexicon only; the silver lexicon (generated with eSpeak NG) is not used
//   - hand-written pronunciations (CustomLexicon) are applied before this runs
//   - numbers use a num2words-compatible reader (NumberWords), fixing years, ordinals,
//     decimals and currency amounts that MisakiSwift dropped or misread
//   - Penn Treebank tags are plain strings, as in the Python original
import Foundation

final class Lexicon {
    static let currencies: [String: (String, String)] = ["$": ("dollar", "cent"), "£": ("pound", "pence"), "€": ("euro", "cent"),
                                                          "¥": ("yen", "sen"), "₹": ("rupee", "paisa"), "₩": ("won", "jeon")]
    /// Currency words whose plural isn't word + s.
    static let currencyPlurals = ["yen": "yen", "sen": "sen", "paisa": "paise", "won": "won", "jeon": "jeon"]
    static let ordinals: Set<String> = ["st", "nd", "rd", "th"]
    static let addSymbols = [".": "dot", "/": "slash"]
    // Beyond misaki's four: maths symbols, read as eSpeak (Aloud 1.5) did instead of dropped.
    // "<" and ">" are read only between spaces (TextNormalizer), never in "<b>" or "->".
    static let symbols = ["%": "percent", "&": "and", "+": "plus", "@": "at", "=": "equals", "×": "times",
                          "÷": "divided by", "±": "plus or minus", "≠": "not equal to", "≈": "approximately",
                          "≤": "less than or equal to", "≥": "greater than or equal to", "→": "to"]

    let british: Bool
    private let golds: [String: GoldEntry]


    init(british: Bool, data: G2PData) {
        self.british = british
        self.golds = data.golds[british] ?? [:]

    }

    func gold(_ word: String) -> GoldEntry? { golds[word] }

    private func goldString(_ word: String) -> String? {
        switch golds[word] {
        case .plain(let s): return s
        case .tagged(let d): return d["DEFAULT"] ?? nil
        case nil: return nil
        }
    }

    func getNNP(_ word: String) -> (String?, Int?) {
        var parts: [String] = []
        for c in word where c.isLetter {
            guard let p = goldString(String(c).pyUpper) else { return (nil, nil) }
            parts.append(p)
        }
        guard var ps = Ph.applyStress(parts.joined(), 0) else { return (nil, nil) }
        // rsplit(SECONDARY, 1) then join with PRIMARY: the last secondary stress becomes primary.
        if let r = ps.range(of: String(Ph.secondary), options: .backwards) {
            ps.replaceSubrange(r, with: String(Ph.primary))
        }
        return (ps, 3)
    }

    func getSpecialCase(_ word: String, tag: String, stress: Double?, ctx: TokenContext) -> (String?, Int?) {
        if tag == "ADD", let w = Lexicon.addSymbols[word] {
            return lookup(w, tag: nil, stress: -0.5, ctx: ctx)
        } else if let w = Lexicon.symbols[word] {
            // Word by word, each read as it would be on its own ("equals", "divided by", "to").
            let words = w.split(separator: " ").map { getWord(String($0), tag: "", stress: nil, ctx: ctx).0 }
            guard words.allSatisfy({ $0 != nil }) else { return (nil, nil) }
            return (words.compactMap { $0 }.joined(separator: " "), 4)
        } else if word.pyStrip(["."]).contains("."), word.replacingOccurrences(of: ".", with: "").pyIsAlpha,
                  (word.split(separator: ".", omittingEmptySubsequences: false).map(\.count).max() ?? 0) < 3 {
            return getNNP(word)
        } else if word == "a" || word == "A" {
            return (tag == "DT" ? "ɐ" : "ˈA", 4)
        } else if ["am", "Am", "AM"].contains(word) {
            if tag.hasPrefix("NN") {
                return getNNP(word)
            } else if ctx.futureVowel == nil || word != "am" || (stress ?? 0) > 0 {
                return (goldString("am"), 4)
            }
            return ("ɐm", 4)
        } else if ["an", "An", "AN"].contains(word) {
            if word == "AN" && tag.hasPrefix("NN") { return getNNP(word) }
            return ("ɐn", 4)
        } else if word == "I" && tag == "PRP" {
            return ("\(Ph.secondary)I", 4)
        } else if ["by", "By", "BY"].contains(word) && Lexicon.parentTag(tag) == "ADV" {
            return ("bˈI", 4)
        } else if word == "to" || word == "To" || (word == "TO" && (tag == "TO" || tag == "IN")) {
            switch ctx.futureVowel {
            case nil: return (goldString("to"), 4)
            case false?: return ("tə", 4)
            case true?: return ("tʊ", 4)
            }
        } else if word == "in" || word == "In" || (word == "IN" && tag != "NNP") {
            let s = (ctx.futureVowel == nil || tag != "IN") ? String(Ph.primary) : ""
            return (s + "ɪn", 4)
        } else if word == "the" || word == "The" || (word == "THE" && tag == "DT") {
            return (ctx.futureVowel == true ? "ði" : "ðə", 4)
        } else if tag == "IN", word.range(of: #"^(?i)vs\.?$"#, options: .regularExpression) != nil {
            return lookup("versus", tag: nil, stress: nil, ctx: ctx)
        } else if ["used", "Used", "USED"].contains(word) {
            if case .tagged(let d)? = golds["used"] {
                if (tag == "VBD" || tag == "JJ") && ctx.futureTo { return ((d["VBD"] ?? nil), 4) }
                return ((d["DEFAULT"] ?? nil), 4)
            }
        }
        return (nil, nil)
    }

    static func parentTag(_ tag: String?) -> String? {
        guard let tag else { return nil }
        if tag.hasPrefix("VB") { return "VERB" }
        if tag.hasPrefix("NN") { return "NOUN" }
        if tag.hasPrefix("ADV") || tag.hasPrefix("RB") { return "ADV" }
        if tag.hasPrefix("ADJ") || tag.hasPrefix("JJ") { return "ADJ" }
        return tag
    }

    func isKnown(_ word: String, tag: String?) -> Bool {
        if golds[word] != nil || Lexicon.symbols[word] != nil { return true }
        if !word.pyIsAlpha || !word.isLexiconChars { return false }
        if word.count == 1 { return true }
        if word == word.pyUpper && golds[word.pyLower] != nil { return true }
        return word.tail == word.tail.pyUpper
    }

    func lookup(_ input: String, tag: String?, stress: Double?, ctx: TokenContext?) -> (String?, Int?) {
        var word = input
        var isNNP: Bool? = nil
        if word == word.pyUpper && golds[word] == nil {
            word = word.pyLower
            isNNP = tag == "NNP"
        }
        let rating = 4
        var ps: String?
        switch golds[word] {
        case .plain(let s)?: ps = s
        case .tagged(let d)?:
            var t = tag
            if let ctx, ctx.futureVowel == nil, d["None"] != nil {
                t = "None"
            } else if t == nil || d[t!] == nil {
                t = Lexicon.parentTag(t)
            }
            if let t, let v = d[t] { ps = v } else { ps = d["DEFAULT"] ?? nil }
        case nil: ps = nil
        }
        if ps == nil || (isNNP == true && !(ps!.contains(Ph.primary))) {
            return getNNP(word)  // (nil, nil) if the letters aren't all known
        }
        return (Ph.applyStress(ps, stress), rating)
    }

    func suffixS(_ stem: String?) -> String? {
        guard let stem, let last = stem.last else { return nil }
        if "ptkfθ".contains(last) { return stem + "s" }
        if "szʃʒʧʤ".contains(last) { return stem + (british ? "ɪ" : "ᵻ") + "z" }
        return stem + "z"
    }

    func stemS(_ word: String, tag: String?, stress: Double?, ctx: TokenContext?) -> (String?, Int?) {
        guard word.count >= 3, word.hasSuffix("s") else { return (nil, nil) }
        let stem: String
        if !word.hasSuffix("ss"), isKnown(String(word.dropLast()), tag: tag) {
            stem = String(word.dropLast())
        } else if (word.hasSuffix("'s") || (word.count > 4 && word.hasSuffix("es") && !word.hasSuffix("ies"))),
                  isKnown(String(word.dropLast(2)), tag: tag) {
            stem = String(word.dropLast(2))
        } else if word.count > 4, word.hasSuffix("ies"), isKnown(word.dropLast(3) + "y", tag: tag) {
            stem = word.dropLast(3) + "y"
        } else {
            return (nil, nil)
        }
        let (ps, rating) = lookup(stem, tag: tag, stress: stress, ctx: ctx)
        return (suffixS(ps), rating)
    }

    func suffixEd(_ stem: String?) -> String? {
        guard let stem, let last = stem.last else { return nil }
        if "pkfθʃsʧ".contains(last) { return stem + "t" }
        if last == "d" { return stem + (british ? "ɪ" : "ᵻ") + "d" }
        if last != "t" { return stem + "d" }
        if british || stem.count < 2 { return stem + "ɪd" }
        let chars = Array(stem)
        if Ph.usTaus.contains(chars[chars.count - 2]) { return String(chars.dropLast()) + "ɾᵻd" }
        return stem + "ᵻd"
    }

    func stemEd(_ word: String, tag: String?, stress: Double?, ctx: TokenContext?) -> (String?, Int?) {
        guard word.count >= 4, word.hasSuffix("d") else { return (nil, nil) }
        let stem: String
        if !word.hasSuffix("dd"), isKnown(String(word.dropLast()), tag: tag) {
            stem = String(word.dropLast())
        } else if word.count > 4, word.hasSuffix("ed"), !word.hasSuffix("eed"), isKnown(String(word.dropLast(2)), tag: tag) {
            stem = String(word.dropLast(2))
        } else {
            return (nil, nil)
        }
        let (ps, rating) = lookup(stem, tag: tag, stress: stress, ctx: ctx)
        return (suffixEd(ps), rating)
    }

    func suffixIng(_ stem: String?) -> String? {
        guard let stem, let last = stem.last else { return nil }
        if british {
            if "əː".contains(last) { return nil }
        } else if stem.count > 1, last == "t", Ph.usTaus.contains(Array(stem)[stem.count - 2]) {
            return String(stem.dropLast()) + "ɾɪŋ"
        }
        return stem + "ɪŋ"
    }

    func stemIng(_ word: String, tag: String?, stress: Double?, ctx: TokenContext?) -> (String?, Int?) {
        guard word.count >= 5, word.hasSuffix("ing") else { return (nil, nil) }
        let base = String(word.dropLast(3))
        let stem: String
        if word.count > 5, isKnown(base, tag: tag) {
            stem = base
        } else if isKnown(base + "e", tag: tag) {
            stem = base + "e"
        } else if word.count > 5,
                  word.range(of: #"([bcdgklmnprstvxz])\1ing$|cking$"#, options: .regularExpression) != nil,
                  isKnown(String(word.dropLast(4)), tag: tag) {
            stem = String(word.dropLast(4))
        } else {
            return (nil, nil)
        }
        let (ps, rating) = lookup(stem, tag: tag, stress: stress, ctx: ctx)
        return (suffixIng(ps), rating)
    }

    func getWord(_ input: String, tag: String, stress: Double?, ctx: TokenContext) -> (String?, Int?) {
        let special = getSpecialCase(input, tag: tag, stress: stress, ctx: ctx)
        if special.0 != nil { return special }
        var word = input
        let wl = word.pyLower
        if word.count > 1, word.replacingOccurrences(of: "'", with: "").pyIsAlpha, word != wl,
           tag != "NNP" || word.count > 7, golds[word] == nil,
           word == word.pyUpper || word.tail == word.tail.pyLower,
           golds[wl] != nil
            || stemS(wl, tag: tag, stress: stress, ctx: ctx).0 != nil
            || stemEd(wl, tag: tag, stress: stress, ctx: ctx).0 != nil
            || stemIng(wl, tag: tag, stress: stress, ctx: ctx).0 != nil {
            word = wl
        }
        if isKnown(word, tag: tag) {
            return lookup(word, tag: tag, stress: stress, ctx: ctx)
        } else if word.hasSuffix("s'"), isKnown(word.dropLast(2) + "'s", tag: tag) {
            return lookup(word.dropLast(2) + "'s", tag: tag, stress: stress, ctx: ctx)
        } else if word.hasSuffix("'"), isKnown(String(word.dropLast()), tag: tag) {
            return lookup(String(word.dropLast()), tag: tag, stress: stress, ctx: ctx)
        }
        let s = stemS(word, tag: tag, stress: stress, ctx: ctx)
        if s.0 != nil { return s }
        let ed = stemEd(word, tag: tag, stress: stress, ctx: ctx)
        if ed.0 != nil { return ed }
        let ing = stemIng(word, tag: tag, stress: stress ?? 0.5, ctx: ctx)
        if ing.0 != nil { return ing }
        return (nil, nil)
    }

    static func isCurrency(_ word: String) -> Bool {
        guard word.contains(".") else { return true }
        let parts = word.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count > 2 { return false }
        return parts[1].count < 3
    }

    func getNumber(_ input: String, currency: String?, isHead: Bool, numFlags: String) -> (String?, Int?) {
        var word = input
        var suffix: String? = nil
        if let r = word.range(of: "[a-z']+$", options: .regularExpression) {
            suffix = String(word[r])
            word = String(word[..<r.lowerBound])
        }
        var result: [(String?, Int?)] = []
        if word.hasPrefix("-") {
            result.append(lookup("minus", tag: nil, stress: nil, ctx: nil))
            word = String(word.dropFirst())
        }
        func extend(_ num: String, first: Bool = true, escape: Bool = false) {
            let text: String
            if escape {
                text = num
            } else {
                guard let n = Int(num) else {
                    // Too big for the number reader: digit by digit, never dropped.
                    if num.isAsciiDigits { num.forEach { extend(String($0), first: false) } }
                    return
                }
                text = NumberWords.cardinal(n)
            }
            let words = Self.splitNonLetters(text)
            for (i, w) in words.enumerated() {
                if w != "and" || numFlags.contains("&") {
                    if first && i == 0 && words.count > 1 && w == "one" && numFlags.contains("a") {
                        result.append(("ə", 4))
                    } else {
                        result.append(lookup(w, tag: nil, stress: w == "point" ? -2 : nil, ctx: nil))
                    }
                } else if w == "and", numFlags.contains("n"), let last = result.last {
                    result[result.count - 1] = ((last.0 ?? "") + "ən", last.1)
                }
            }
        }
        let digitsOnly = word.isAsciiDigits
        if digitsOnly, let suffix, Lexicon.ordinals.contains(suffix), let n = Int(word) {
            extend(NumberWords.ordinal(n), escape: true)
        } else if result.isEmpty, word.count == 4, currency.flatMap({ Lexicon.currencies[$0] }) == nil, digitsOnly, let n = Int(word) {
            extend(NumberWords.year(n), escape: true)
        } else if !isHead, !word.contains(".") {
            let num = word.replacingOccurrences(of: ",", with: "")
            let chars = Array(num)
            if chars.first == "0" || chars.count > 3 {
                chars.forEach { extend(String($0), first: false) }
            } else if chars.count == 3, !num.hasSuffix("00") {
                extend(String(chars[0]))
                if chars[1] == "0" {
                    result.append(lookup("O", tag: nil, stress: -2, ctx: nil))
                    extend(String(chars[2]), first: false)
                } else {
                    extend(String(chars[1...]), first: false)
                }
            } else {
                extend(num)
            }
        } else if word.filter({ $0 == "." }).count > 1 || !isHead {
            var first = true
            for num in word.replacingOccurrences(of: ",", with: "").split(separator: ".", omittingEmptySubsequences: false).map(String.init) {
                if num.isEmpty {
                } else if num.first == "0" || (num.count != 2 && num.dropFirst().contains { $0 != "0" }) {
                    num.forEach { extend(String($0), first: false) }
                } else {
                    extend(num, first: first)
                }
                first = false
            }
        } else if let currency, let units = Lexicon.currencies[currency], Lexicon.isCurrency(word) {
            let pieces = word.replacingOccurrences(of: ",", with: "").split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            // nil: too big for an Int, so not 0 or 1 (it was read as "zero dollars").
            func value(_ s: String) -> Int? { s.isEmpty ? 0 : Int(s) }
            var pairs: [(String, String)] = Array(zip(pieces, [units.0, units.1]))
            if pairs.count > 1 {
                if value(pairs[1].0) == 0 { pairs = Array(pairs.prefix(1)) } else if value(pairs[0].0) == 0 { pairs = Array(pairs.dropFirst()) }
            }
            for (i, (digits, unit)) in pairs.enumerated() {
                if i > 0 { result.append(lookup("and", tag: nil, stress: nil, ctx: nil)) }
                extend(value(digits).map(String.init) ?? digits, first: i == 0)
                result.append(currencyWord(unit, plural: value(digits).map { abs($0) != 1 } ?? true))
            }
        } else {
            var text: String?
            if digitsOnly {
                text = Int(word).map(NumberWords.cardinal) ?? NumberWords.digits(word)
            } else if !word.contains(".") {
                let w = word.replacingOccurrences(of: ",", with: "")
                if let n = Int(w) {
                    text = suffix.map { Lexicon.ordinals.contains($0) } == true ? NumberWords.ordinal(n) : NumberWords.cardinal(n)
                } else {
                    text = NumberWords.digits(w)
                }
            } else {
                let w = word.replacingOccurrences(of: ",", with: "")
                if w.hasPrefix(".") {
                    text = "point " + w.dropFirst().compactMap { $0.wholeNumberValue }.map(NumberWords.cardinal).joined(separator: " ")
                } else {
                    text = NumberWords.decimal(w)
                }
            }
            if let text { extend(text, escape: true) }
        }
        guard !result.isEmpty else { return (nil, nil) }
        let joined = result.map { $0.0 ?? "" }.joined(separator: " ")
        let rating = result.compactMap(\.1).min()
        if suffix == "s" || suffix == "'s" { return (suffixS(joined), rating) }
        if suffix == "ed" || suffix == "'d" { return (suffixEd(joined), rating) }
        if suffix == "ing" { return (suffixIng(joined), rating) }
        return (joined, rating)
    }

    /// re.split(r'[^a-z]+', text)
    static func splitNonLetters(_ text: String) -> [String] {
        var out: [String] = [""]
        var inSep = false
        for c in text.unicodeScalars {
            if (97...122).contains(c.value) {
                if inSep { out.append(""); inSep = false }
                out[out.count - 1].unicodeScalars.append(c)
            } else {
                inSep = true
            }
        }
        if inSep { out.append("") }
        return out
    }

    func appendCurrency(_ ps: String, _ currency: String?) -> String {
        guard let currency, let units = Lexicon.currencies[currency],
              let c = currencyWord(units.0, plural: true).0 else { return ps }
        return "\(ps) \(c)"
    }

    /// "dollar"/"dollars", "pence", "yen", "paise".
    func currencyWord(_ unit: String, plural: Bool) -> (String?, Int?) {
        if unit == "pence" || !plural { return lookup(unit, tag: nil, stress: nil, ctx: nil) }
        if let p = Lexicon.currencyPlurals[unit] { return lookup(p, tag: nil, stress: nil, ctx: nil) }
        return stemS(unit + "s", tag: nil, stress: nil, ctx: nil)
    }

    static func numericIfNeeded(_ c: Character) -> String {
        guard c.isNumber, let v = c.wholeNumberValue else { return String(c) }
        return String(v)
    }

    static func isNumber(_ input: String, isHead: Bool) -> Bool {
        guard input.contains(where: { $0.isASCII && $0.isNumber }) else { return false }
        var word = input
        for s in ["ing", "'d", "ed", "'s", "st", "nd", "rd", "th", "s"] where word.hasSuffix(s) {
            word = String(word.dropLast(s.count))
            break
        }
        return word.enumerated().allSatisfy { i, c in
            (c.isASCII && c.isNumber) || c == "," || c == "." || (isHead && i == 0 && c == "-")
        }
    }

    /// The pronunciation of one token (or several merged ones), or nil if unknown.
    func callAsFunction(_ tk: MToken, ctx: TokenContext) -> (String?, Int?) {
        var word = (tk.alias ?? tk.text).replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
        word = word.precomposedStringWithCompatibilityMapping
        word = word.map(Lexicon.numericIfNeeded).joined()
        let stress: Double? = word == word.pyLower ? nil : (word == word.pyUpper ? 2 : 0.5)
        var (ps, rating) = getWord(word, tag: tk.tag, stress: stress, ctx: ctx)
        if ps == nil, !word.isLexiconChars, word.contains(where: \.isLetter) {
            // misaki has no entry for "café" or "naïve" ("TODO: café" in the original);
            // the unaccented spelling is a far better guess than the G2P model's.
            let folded = word.folding(options: .diacriticInsensitive, locale: nil)
            if folded != word, folded.isLexiconChars {
                (ps, rating) = getWord(folded, tag: tk.tag, stress: stress, ctx: ctx)
            }
        }
        if let ps {
            return (Ph.applyStress(appendCurrency(ps, tk.currency), tk.stress), rating)
        } else if Lexicon.isNumber(word, isHead: tk.isHead) {
            let (nps, nr) = getNumber(word, currency: tk.currency, isHead: tk.isHead, numFlags: tk.numFlags)
            return (Ph.applyStress(nps, tk.stress), nr)
        }
        return (nil, nil)
    }
}
