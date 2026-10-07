import Foundation
import NaturalLanguage

/// A word or punctuation mark with a Penn Treebank part-of-speech tag.
struct TaggedToken {
    var text: String
    var whitespace: String
    var tag: String
    var range: Range<String.Index>
}

/// Splits text into tokens the way spaCy's English tokenizer does (which is what
/// misaki was written against), and tags them with Penn Treebank tags.
///
/// MisakiSwift used Apple's NLTagger for both jobs. NLTagger's tokens break misaki's
/// rules: it splits "$4.99" oddly (dropping the amount), tags in-word hyphens as
/// dashes (so "state-of-the-art" got three pauses), and has no verb tenses (so "I
/// read it yesterday" used the present-tense "reed"). Here tokenization follows
/// spaCy's prefix/suffix/exception rules, punctuation and numbers are tagged by
/// rule, and NLTagger only supplies the word class, refined by context.
enum Tokenizer {
    // spaCy keeps these whole (from its English tokenizer exceptions).
    static let exceptions: Set<String> = {
        var s: Set<String> = [
            "a.m.", "p.m.", "A.M.", "P.M.", "Adm.", "Bros.", "co.", "Co.", "Corp.", "D.C.", "Dr.", "e.g.", "E.g.", "E.G.",
            "Gen.", "Gov.", "i.e.", "I.e.", "I.E.", "Inc.", "Jr.", "Ltd.", "Md.", "Messrs.", "Mo.", "Mont.", "Mr.", "Mrs.",
            "Ms.", "Ph.D.", "Prof.", "Rep.", "Rev.", "Sen.", "Sr.", "St.", "vs.", "v.s.", "Mt.", "No.", "no.", "Nos.",
            "Jan.", "Feb.", "Mar.", "Apr.", "Jun.", "Jul.", "Aug.", "Sep.", "Sept.", "Oct.", "Nov.", "Dec.",
            "Ala.", "Ariz.", "Ark.", "Calif.", "Colo.", "Conn.", "Del.", "Fla.", "Ga.", "Ill.", "Ind.", "Kan.", "Kans.",
            "Ky.", "La.", "Mass.", "Mich.", "Minn.", "Miss.", "N.C.", "N.D.", "N.H.", "N.J.", "N.M.", "N.Y.", "Neb.",
            "Nebr.", "Nev.", "Okla.", "Ore.", "Pa.", "S.C.", "Tenn.", "Va.", "Wash.", "Wis.", "U.S.", "U.K.", "U.S.A.",
            "...", "—", "–", "--",
        ]
        for c in "abcdefghijklmnopqrstuvwxyz" { s.insert("\(c)."); s.insert("\(String(c).uppercased()).") }
        return s
    }()

    static let prefixChars: Set<Character> = Set("([{<\"'“‘«`$£€¥₹¢#§=—–*&!?,:;¡¿_~|%")
    static let suffixChars: Set<Character> = Set(")]}>\"'”’»,;:!?—–*&#")
    static let currencySymbols: Set<Character> = ["$", "£", "€", "¥", "₹", "¢"]

    static func tokenize(_ text: String) -> [TaggedToken] {
        var tokens: [TaggedToken] = []
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isWhitespace { i = text.index(after: i); continue }
            var j = i
            while j < text.endIndex, !text[j].isWhitespace { j = text.index(after: j) }
            let ws = j < text.endIndex ? " " : ""
            let pieces = split(text[i..<j])
            for (k, p) in pieces.enumerated() {
                tokens.append(TaggedToken(text: String(p), whitespace: k == pieces.count - 1 ? ws : "", tag: "", range: p.startIndex..<p.endIndex))
            }
            i = j
        }
        tag(&tokens, in: text)
        return tokens
    }

    /// One whitespace-delimited chunk → prefix, core and suffix pieces.
    static func split(_ chunk: Substring) -> [Substring] {
        var prefixes: [Substring] = []
        var suffixes: [Substring] = []
        var s = chunk
        while !s.isEmpty {
            if exceptions.contains(String(s)) { break }
            if let n = prefixLength(s) {
                prefixes.append(s.prefix(n)); s = s.dropFirst(n); continue
            }
            if let n = suffixLength(s) {
                suffixes.insert(s.suffix(n), at: 0); s = s.dropLast(n); continue
            }
            break
        }
        return prefixes + (s.isEmpty ? [] : infixSplit(s)) + suffixes
    }

    private static func prefixLength(_ s: Substring) -> Int? {
        for multi in ["...", "--", "…"] where s.hasPrefix(multi) && s.count > multi.count { return multi.count }
        guard let f = s.first, s.count > 1 else { return nil }
        if f == "+" { return s.dropFirst().first?.isNumber == true ? nil : 1 }
        return prefixChars.contains(f) ? 1 : nil
    }

    private static func suffixLength(_ s: Substring) -> Int? {
        guard s.count > 1 else { return nil }
        for multi in ["...", "--", "…"] where s.hasSuffix(multi) && s.count > multi.count { return multi.count }
        for poss in ["'s", "'S", "’s", "’S"] where s.hasSuffix(poss) && s.count > 2 { return 2 }
        let chars = Array(s)
        let last = chars[chars.count - 1]
        let prev = chars[chars.count - 2]
        if suffixChars.contains(last) { return 1 }
        if last == "%" || currencySymbols.contains(last), prev.isNumber { return 1 }
        if last == "." {
            // spaCy: split a final period after a lower-case letter, digit, punctuation or
            // quote, or after two capitals ("FBI."), but not in "U.S." or "A.".
            if prev.isLowercase || prev.isNumber || prev.isPunctuation && prev != "." || "\"'”’".contains(prev) { return 1 }
            if chars.count >= 3, prev.isUppercase, chars[chars.count - 3].isUppercase { return 1 }
        }
        return nil
    }

    /// Splits at dashes and ellipses inside a chunk ("word—word", "wait...what").
    private static func infixSplit(_ s: Substring) -> [Substring] {
        var out: [Substring] = []
        var start = s.startIndex
        var i = s.startIndex
        while i < s.endIndex {
            var len = 0
            if s[i...].hasPrefix("...") { len = 3 } else if s[i...].hasPrefix("--") { len = 2 } else if "—–…".contains(s[i]) { len = 1 }
            if len > 0, i > s.startIndex {
                let end = s.index(i, offsetBy: len)
                if end < s.endIndex {
                    if start < i { out.append(s[start..<i]) }
                    out.append(s[i..<end])
                    start = end
                    i = end
                    continue
                }
            }
            i = s.index(after: i)
        }
        if start < s.endIndex { out.append(s[start...]) }
        return out
    }

    // MARK: - Tagging

    static let modals: Set<String> = ["will", "would", "can", "could", "shall", "should", "may", "might", "must", "'ll",
                                      "wo", "ca", "cannot", "won't", "can't", "wouldn't", "couldn't", "shouldn't", "mustn't", "mightn't", "shan't"]
    static let infinitiveMarkers: Set<String> = ["to", "do", "does", "did", "don't", "doesn't", "didn't", "let", "let's",
                                                 "please", "lets", "help", "make", "makes", "made"]
    static let haveForms: Set<String> = ["have", "has", "had", "having", "'ve", "haven't", "hasn't", "hadn't", "i've",
                                         "we've", "you've", "they've", "i'd", "we'd", "you'd", "they'd", "he'd", "she'd"]
    static let beForms: Set<String> = ["am", "is", "are", "was", "were", "be", "been", "being", "'m", "'re", "isn't",
                                       "aren't", "wasn't", "weren't", "get", "gets", "got", "gotten", "getting", "i'm",
                                       "you're", "we're", "they're", "he's", "she's", "it's", "that's", "there's"]
    static let skippable: Set<String> = ["not", "n't", "never", "just", "already", "also", "always", "really", "still",
                                         "even", "only", "ever", "often", "usually", "recently", "finally", "once", "all", "both"]
    static let irregularPast: Set<String> = [
        "said", "went", "came", "saw", "took", "made", "got", "gave", "found", "told", "became", "left", "felt", "brought",
        "began", "kept", "held", "wrote", "stood", "heard", "meant", "met", "ran", "paid", "sat", "spoke", "lay", "led",
        "grew", "lost", "fell", "sent", "built", "understood", "drew", "broke", "spent", "rose", "drove", "bought", "wore",
        "chose", "caught", "fought", "sought", "taught", "thought", "threw", "flew", "knew", "won", "sold", "hung", "wound",
        "read", "ate", "drank", "sang", "swam", "rang", "shook", "woke", "froze", "stole", "hid", "bit", "slept", "swept",
        "wept", "fed", "bled", "fled", "sped", "dug", "stuck", "struck", "swung", "spun", "slid", "bent", "lent", "dealt",
        "knelt", "leapt", "crept", "forgot", "forgave", "overcame", "withdrew", "undertook", "was", "were", "did", "had",
    ]
    static let subjects: Set<String> = ["i", "you", "we", "they", "he", "she", "it", "who", "people", "everyone", "nobody"]
    static let determiners: Set<String> = ["a", "an", "the", "this", "that", "these", "those", "my", "your", "his", "her",
                                           "its", "our", "their", "every", "each", "some", "any", "no", "another"]
    static let possessiveDeterminers: Set<String> = ["my", "your", "his", "her", "its", "our", "their"]
    static let whWords: Set<String> = ["who", "whom", "what", "which", "whoever", "whatever", "whichever"]

    private static func ruleTag(_ t: String) -> String? {
        switch t {
        case ",": return ","
        case ".", "!", "?", "!?", "?!": return "."
        case ":", ";", "—", "–", "--", "...", "…", "-": return ":"
        case "(", "[", "{": return "-LRB-"
        case ")", "]", "}": return "-RRB-"
        case "“", "‘", "``", "«": return "``"
        case "”", "’", "''", "»": return "''"
        case "$", "£", "€", "¥", "₹", "¢": return "$"
        case "#": return "$"
        case "%": return "NN"
        case "&", "+": return "CC"
        case "@": return "IN"
        case "/", "\\", "|", "=", "<", ">", "~", "^": return "SYM"
        case "*", "§", "_": return "NFP"
        default: break
        }
        if t.range(of: #"^[-+]?[0-9.,:/]*[0-9][0-9.,:/]*(st|nd|rd|th|s|'s)?$"#, options: .regularExpression) != nil { return "CD" }
        return nil
    }

    static func tag(_ tokens: inout [TaggedToken], in text: String) {
        guard !tokens.isEmpty else { return }
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = text
        var classes: [(Range<String.Index>, NLTag)] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, r in
            if let tag { classes.append((r, tag)) }
            return true
        }
        var names: [Range<String.Index>] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, r in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag) { names.append(r) }
            return true
        }

        // Coarse class for each token from the first NLTagger word it overlaps.
        var coarse: [NLTag?] = []
        var c = 0
        for tk in tokens {
            while c < classes.count, classes[c].0.upperBound <= tk.range.lowerBound { c += 1 }
            coarse.append(c < classes.count && classes[c].0.overlaps(tk.range) ? classes[c].1 : nil)
        }

        let lower = tokens.map { $0.text.lowercased().replacingOccurrences(of: "’", with: "'") }
        func isSentenceStart(_ i: Int) -> Bool {
            var k = i - 1
            while k >= 0 {
                let t = tokens[k].text
                if [".", "!", "?", ":", ";", "—", "–", "\"", "“", "(", "--", "..."].contains(t) { return true }
                if ruleTag(t) == nil || ruleTag(t) == "CD" { return false }
                k -= 1
            }
            return true
        }
        /// The nearest earlier word in the same clause, skipping adverbs like "not".
        func previousWord(_ i: Int) -> String? {
            var k = i - 1
            while k >= 0 {
                if let r = ruleTag(tokens[k].text), r != "CD" { return nil }
                if !skippable.contains(lower[k]) { return lower[k] }
                k -= 1
            }
            return nil
        }
        func nextIsNominal(_ i: Int) -> Bool {
            guard i + 1 < tokens.count, ruleTag(tokens[i + 1].text) == nil else { return false }
            return coarse[i + 1] == .noun || coarse[i + 1] == .adjective || coarse[i + 1] == .number
        }

        for i in tokens.indices {
            let t = tokens[i].text
            if let r = ruleTag(t) {
                // A quote opening a word is `` and one closing it is ''.
                if t == "\"" || t == "'" {
                    let opens = tokens[i].whitespace.isEmpty && i + 1 < tokens.count && (i == 0 || !tokens[i - 1].whitespace.isEmpty)
                    tokens[i].tag = opens ? "``" : (t == "'" && i > 0 && lower[i - 1].hasSuffix("s") && tokens[i - 1].whitespace.isEmpty ? "POS" : "''")
                } else if t == "-" && i > 0 && tokens[i - 1].whitespace.isEmpty {
                    tokens[i].tag = "HYPH"
                } else {
                    tokens[i].tag = r
                }
                continue
            }
            let w = lower[i]
            if w == "'s" { tokens[i].tag = "POS"; continue }
            if w == "a" || w == "an" || w == "the" { tokens[i].tag = "DT"; continue }
            if w == "vs" || w == "vs." || w == "v." { tokens[i].tag = "IN"; continue }
            if (w == "am" || w == "pm" || w == "a.m." || w == "p.m.") && i > 0 && ruleTag(tokens[i - 1].text) == "CD" {
                tokens[i].tag = "NN"; continue
            }
            if modals.contains(w) { tokens[i].tag = "MD"; continue }
            let isName = names.contains { $0.overlaps(tokens[i].range) }
            let capitalized = t.first?.isUppercase == true
            switch coarse[i] {
            case .noun?:
                let plural = w.count > 2 && w.hasSuffix("s") && !w.hasSuffix("ss") && !w.hasSuffix("'s")
                if isName || (capitalized && !isSentenceStart(i)) {
                    tokens[i].tag = plural && !isName ? "NNPS" : "NNP"
                } else {
                    tokens[i].tag = plural ? "NNS" : "NN"
                }
            case .verb?:
                tokens[i].tag = verbTag(w, previous: previousWord(i), sentenceStart: isSentenceStart(i))
            case .adjective?:
                // "a minute." / "a present." — an adjective ending a noun phrase is the noun.
                if i > 0, determiners.contains(lower[i - 1]), !nextIsNominal(i) {
                    tokens[i].tag = "NN"
                } else {
                    tokens[i].tag = w.hasSuffix("est") && w.count > 4 ? "JJS" : w.hasSuffix("er") && w.count > 3 ? "JJR" : "JJ"
                }
            case .adverb?:
                tokens[i].tag = ["when", "where", "why", "how"].contains(w) ? "WRB" : "RB"
            case .pronoun?:
                if w == "that" || w == "this" || w == "these" || w == "those" { tokens[i].tag = "DT" } else if whWords.contains(w) { tokens[i].tag = "WP" } else { tokens[i].tag = possessiveDeterminers.contains(w) && w != "her" && w != "his" ? "PRP$" : "PRP" }
            case .determiner?:
                tokens[i].tag = whWords.contains(w) ? "WDT" : possessiveDeterminers.contains(w) ? "PRP$" : "DT"
            case .preposition?:
                tokens[i].tag = w == "to" ? "TO" : "IN"
            case .particle?:
                tokens[i].tag = w == "to" ? "TO" : "RP"
            case .conjunction?:
                tokens[i].tag = ["and", "or", "but", "nor", "yet", "plus", "&"].contains(w) ? "CC" : "IN"
            case .number?:
                tokens[i].tag = "CD"
            case .interjection?:
                tokens[i].tag = w == "please" ? "UH" : "UH"
            case .personalName?, .placeName?, .organizationName?:
                tokens[i].tag = "NNP"
            default:
                if isName || (capitalized && !isSentenceStart(i)) { tokens[i].tag = "NNP" } else { tokens[i].tag = "NN" }
            }
        }
    }

    /// Penn verb tags from context, which NLTagger doesn't provide.
    static func verbTag(_ w: String, previous: String?, sentenceStart: Bool) -> String {
        switch w {
        case "am", "are", "have", "do": return "VBP"
        case "is", "has", "does": return "VBZ"
        case "was", "were", "had", "did": return "VBD"
        case "be": return "VB"
        case "been": return "VBN"
        case "being": return "VBG"
        default: break
        }
        if let p = previous {
            if modals.contains(p) || infinitiveMarkers.contains(p) { return "VB" }
            if haveForms.contains(p) { return w.hasSuffix("ing") ? "VBG" : "VBN" }
            if beForms.contains(p) { return w.hasSuffix("ing") ? "VBG" : "VBN" }
        } else if sentenceStart {
            if w.hasSuffix("ing") { return "VBG" }
            return w.hasSuffix("ed") ? "VBD" : "VB"  // imperative: "Read the label."
        }
        if w.hasSuffix("ing") { return "VBG" }
        if w.hasSuffix("ed") || irregularPast.contains(w) { return "VBD" }
        if w.hasSuffix("s"), !w.hasSuffix("ss"), let p = previous, ["he", "she", "it", "this", "that"].contains(p) || !subjects.contains(p) {
            return "VBZ"
        }
        return "VBP"
    }
}
