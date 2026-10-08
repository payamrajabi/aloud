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
public enum Tokenizer {
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

    static let prefixChars: Set<Character> = Set("([{<\"'“‘«„‚‹＂`$£€¥₹₩¢#§=—–*&!?,:;¡¿_~|%")
    static let suffixChars: Set<Character> = Set(")]}>\"'”’»“›＂,;:!?—–*&#")
    static let currencySymbols: Set<Character> = ["$", "£", "€", "¥", "₹", "₩", "¢"]

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
            // A single letter ending its sentence ("Plan B.", "x and y.") gives its period back as
            // the full stop, as a title does; kept whole, the sentence lost its final fall. "an
            // A." stays whole (alone, "A" would be the article).
            if s.count == 2, s.last == ".", let c = s.first, c.isASCII, c.isLetter, !"aAI".contains(c), endsSentence(s) {
                return prefixes + [s.prefix(1), s.suffix(1)] + suffixes
            }
            if exceptions.contains(String(s)) {
                let t = String(s)
                if numberSign.contains(t) ? numberFollows(s) && !answersQuestion(s) : titles.contains(t) ? !endsSentence(s) : true { break }
            }
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

    /// "No." is "number" only before one ("No. 5", "no. 12", "Nos. 3–4", "No. #7"). At the
    /// end of a sentence ("The answer was no.") it's the word no and a full stop; kept whole,
    /// the gold lexicon would read it "number".
    static let numberSign: Set<String> = ["No.", "no.", "Nos."]

    /// Whether the next non-space character after `s` in the text is a digit or "#".
    private static func numberFollows(_ s: Substring) -> Bool {
        let text = s.base
        var k = s.endIndex
        while k < text.endIndex, text[k].isWhitespace { k = text.index(after: k) }
        guard k < text.endIndex else { return false }
        return text[k].isNumber || text[k] == "#"
    }

    /// Whether "No." at `s` answers a question just asked ("Did the build pass? No. 2 tests
    /// failed."): it's the word, not "number two".
    private static func answersQuestion(_ s: Substring) -> Bool {
        s == "No." && endsQuestion(s.base[..<s.startIndex]) && answerFollows(s.base[s.endIndex...])
    }

    /// Whether `text` ends in a question mark (closing quotes and brackets aside).
    static func endsQuestion<S: StringProtocol>(_ text: S) -> Bool {
        text.reversed().first { !$0.isWhitespace && !"\"'”’»)]".contains($0) } == "?"
    }

    /// Whether what follows an answer "No." is a new sentence starting with a number ("2 tests
    /// failed."), not "No. 1", which is "number one" ("Who won? No. 1 seed Duke.").
    private static func answerFollows(_ text: Substring) -> Bool {
        guard text.first?.isWhitespace == true else { return false }
        let digits = text.drop(while: \.isWhitespace).prefix { $0.isNumber }
        return !digits.isEmpty && digits != "1"
    }

    /// Where `sentence` ends an answer "No." to the question `previous` before a number, as in
    /// "Did the build pass?" + "No. 2 tests failed.": the offset (UTF-16) just after "No.", so
    /// the answer can be read on its own. nil for "No. 5 is next." after anything else.
    public static func answerNoLength(_ sentence: String, after previous: String) -> Int? {
        guard endsQuestion(previous) else { return nil }
        let lead = sentence.prefix { $0.isWhitespace }
        let rest = sentence.dropFirst(lead.count)
        guard rest.hasPrefix("No."), answerFollows(rest.dropFirst(3)) else { return nil }
        return (String(lead) + "No.").utf16.count
    }

    /// Titles (TextNormalizer spells them out before a name: "Sen. Warren"). One that ends a
    /// sentence ("I met Amartya Sen.", "…a Rep. She was nice.") gives its period back as the
    /// full stop; before anything else it stays whole, with no pause.
    static let titles: Set<String> = ["Sen.", "Gov.", "Prof.", "Gen.", "Rep.", "Rev.", "St."]

    /// Capitalised words that usually start a sentence rather than name someone, so
    /// "…Amartya Sen. He was kind." isn't "Senator He" and "…the Gov. Yesterday he resigned."
    /// isn't "Governor Yesterday": pronouns, determiners, conjunctions, prepositions, common
    /// adverbs, auxiliaries and imperatives. Words that are also common surnames or first
    /// names ("May", "Will", "Mark", "Grant", "Young", "Long", "King", "Love", "Early") aren't
    /// here: "Gov. Young", "Sen. King" and "Gen. Grant" are names.
    static let sentenceStarters: [String] = [
        "A", "About", "Above", "Accordingly", "Actually", "Additionally", "After", "Afterward", "Afterwards", "Again",
        "Against", "All", "Almost", "Along", "Already", "Also", "Although", "Always", "Am", "Among", "An", "And", "Another",
        "Any", "Anybody", "Anyone", "Anything", "Anyway", "Apparently", "Are", "Aren't", "Around", "As", "Ask", "At",
        "Basically", "Be", "Because", "Before", "Behind", "Below", "Besides", "Between", "Beyond", "Both", "But", "By",
        "Can", "Can't", "Certainly", "Check", "Click", "Clearly", "Consequently", "Consider", "Could", "Couldn't",
        "Currently", "Customers", "Despite", "Did", "Didn't", "Do", "Does", "Doesn't", "Don't", "During", "Each", "Earlier",
        "Eight", "Either", "Else", "Elsewhere", "Even", "Eventually", "Ever", "Every", "Everybody", "Everyone", "Everything",
        "Everywhere", "Experts", "Few", "Finally", "First", "Five", "For", "Fortunately", "Four", "From", "Furthermore",
        "Generally", "Get", "Give", "Go", "Had", "Hadn't", "Has", "Hasn't", "Have", "Haven't", "He", "He'd", "He'll",
        "He's", "Hello", "Hence", "Her", "Here", "Here's", "Hers", "Hey", "Hi", "Him", "His", "Honestly", "Hopefully",
        "How", "How's", "However", "I", "I'd", "I'll", "I'm", "I've", "If", "Imagine", "Immediately", "Importantly", "In",
        "Indeed", "Initially", "Instead", "Interestingly", "Into", "Is", "Isn't", "It", "It's", "Its", "Just", "Last",
        "Lastly", "Later", "Let", "Let's", "Like", "Likewise", "Look", "Luckily", "Many", "Maybe", "Me", "Meanwhile",
        "Might", "Mine", "More", "Moreover", "Most", "Much", "Must", "My", "Naturally", "Neither", "Never", "Nevertheless",
        "Next", "Nine", "No", "Nobody", "None", "Nonetheless", "Nor", "Normally", "Not", "Note", "Nothing", "Now",
        "Nowadays", "Nowhere", "Obviously", "Of", "Oh", "Often", "Okay", "On", "Once", "One", "Only", "Or", "Originally",
        "Other", "Others", "Otherwise", "Our", "Ours", "Over", "Overall", "People", "Perhaps", "Please", "Press",
        "Previously", "Probably", "Rarely", "Recently", "Regardless", "Remember", "Researchers", "Sadly",
        "Second", "See", "Seven", "Several", "She", "She'd", "She'll", "She's", "Should", "Shouldn't", "Similarly",
        "Since", "Six", "So", "Some", "Somebody", "Someone", "Something", "Sometimes", "Somewhere", "Soon", "Sorry",
        "Specifically", "Still", "Students", "Such", "Suddenly", "Sure", "Ten", "Thank", "Thanks", "That", "That's", "The",
        "Their", "Theirs", "Them", "Then", "There", "There's", "Therefore", "These", "They", "They'd", "They'll",
        "They're", "They've", "Third", "This", "Those", "Though", "Three", "Through", "Throughout", "Thus", "To", "Today",
        "Together", "Tomorrow", "Tonight", "Too", "Toward", "Towards", "Try", "Twice", "Two", "Typically", "Ultimately",
        "Under", "Unfortunately", "Unless", "Unlike", "Until", "Upon", "Us", "Use", "Users", "Usually", "Very", "Was",
        "Wasn't", "We", "We'd", "We'll", "We're", "We've", "Well", "Were", "Weren't", "What", "What's", "Whatever",
        "When", "Whenever", "Where", "Where's", "Whereas", "Wherever", "Whether", "Which", "While", "Who", "Who's", "Whom",
        "Whose", "Why", "With", "Within", "Without", "Won't", "Would", "Wouldn't", "Wow", "Yes", "Yesterday", "Yet",
        "You", "You'd", "You'll", "You're", "You've", "Your", "Yours",
    ]
    private static let sentenceStarterSet = Set(sentenceStarters)

    /// Whether `s` ends its sentence: nothing follows, or the next word is a usual sentence
    /// opener ("He", "The"). A capitalised word that isn't one is taken as a name.
    private static func endsSentence(_ s: Substring) -> Bool {
        let text = s.base
        var k = s.endIndex
        while k < text.endIndex, text[k].isWhitespace { k = text.index(after: k) }
        guard k < text.endIndex else { return true }
        guard k > s.endIndex, text[k].isUppercase else { return false }
        var e = k
        while e < text.endIndex, text[e].isLetter || text[e] == "'" || text[e] == "’" { e = text.index(after: e) }
        return sentenceStarterSet.contains(String(text[k..<e]).replacingOccurrences(of: "’", with: "'"))
    }

    /// Whether "St." right after `before` (the text up to it), and before a name, is a street
    /// rather than Saint: in a numbered address, where the word before it holds a digit ("5th
    /// St.") or follows a house number ("221B Baker St."), and after a street preposition and a
    /// name ("Park on Elm St.", "Walk down High St.", "We met on Baker St."), where the next
    /// capital starts a new sentence ("Bring cash."). Before a name, "St." is otherwise Saint:
    /// "Mount St. Helens", "Port St. Lucie", "Yves St. Laurent", "to St. Louis", "near Mount
    /// St. Helens". (Before a lower-case word, punctuation, the end or a usual opener it's a
    /// street: "Main St. Then…"; TextNormalizer reads that.)
    static func isStreet(before text: String) -> Bool {
        let head = text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        guard head.count < text.count, let r = head.range(of: #"[\p{L}\p{N}'’]+$"#, options: .regularExpression) else { return false }
        if head[r].contains(where: \.isNumber) { return true }
        let rest = head[..<r.lowerBound]
        guard let space = rest.last, space.isWhitespace, let n = rest.dropLast().range(of: #"[\p{L}\p{N}]+$"#, options: .regularExpression)
        else { return false }
        if rest[n].first?.isNumber == true { return true }
        let name = String(head[r])
        return streetPrepositions.contains(rest[n].lowercased()) && name.first?.isUppercase == true
            && !placePrefixes.contains(name)
    }
    private static let streetPrepositions: Set<String> = ["on", "down", "along", "onto", "off", "up", "at", "near",
                                                          "via", "across", "past", "into"]
    /// Names that "St." (Saint) follows in a place: "near Mount St. Helens", "at Port St. Lucie".
    private static let placePrefixes: Set<String> = ["Mount", "Mt", "Port", "Fort", "Ft", "Lake", "Cape", "Point", "Pointe",
                                                     "Isle", "Bay", "Grand", "Sault", "Little", "Great", "East", "West",
                                                     "North", "South", "New", "Old", "Upper", "Lower", "Rue", "Ste"]

    /// Titles a sentence splitter can take for a full stop.
    private static let runOnTitles = titles.union(["Dr.", "Mr.", "Mrs.", "Ms.", "Mt."])

    /// Whether `sentence` ends in a title that runs on into `next`, so the two are one
    /// sentence: "We flew to St." + "Louis on Friday.", "Gov." + "Newsom signed it.", "See
    /// No." + "5 on the list.". Apple's sentence splitter breaks after "St.", "Gov." and
    /// "Sen." even before a name, and the halves were read apart ("…to Street", a pause,
    /// "Louis…"). A title before a usual sentence opener ("…Amartya Sen. Nobody read it.",
    /// "…the Gov. Yesterday he resigned."), a street ("Main St. Then…") or "No." before
    /// anything but a number, or answering a question ("Pass? No." + "2 failed."), does end
    /// the sentence.
    public static func titleContinues(_ sentence: String, into next: String) -> Bool {
        let head = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = head.range(of: #"(?<![\p{L}.])\p{L}+\.$"#, options: .regularExpression) else { return false }
        let title = String(head[r])
        let following = next.drop { $0.isWhitespace }
        guard let first = following.first else { return false }
        if numberSign.contains(title) {
            return (first.isNumber || first == "#")
                && !(title == "No." && endsQuestion(head[..<r.lowerBound]) && answerFollows(" " + following))
        }
        guard runOnTitles.contains(title) else { return false }
        if title == "St.", isStreet(before: String(head[..<r.lowerBound])) { return false }
        if first.isNumber { return true }
        guard first.isUppercase else { return false }
        let word = following.prefix { $0.isLetter || $0 == "'" || $0 == "’" }
        return !sentenceStarterSet.contains(String(word).replacingOccurrences(of: "’", with: "'"))
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
            // After a sign read as a word ("is ∞.", "Acme™."), it's the full stop too.
            if prev.isLowercase || prev.isNumber || prev.isPunctuation && prev != "." || "\"'”’".contains(prev)
                || Lexicon.symbols[String(prev)] != nil { return 1 }
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
        case ".", "!", "?", "!?", "?!", "¿", "¡": return "."
        case ":", ";", "—", "–", "--", "...", "…", "-": return ":"
        case "(", "[", "{": return "-LRB-"
        case ")", "]", "}": return "-RRB-"
        case "“", "‘", "``", "«", "„", "‚", "‹": return "``"
        // A straight double quote opens or closes (decided in `tag`). Untagged, it stayed in
        // the word's group and sent the whole thing ("\"hello\"") to the G2P model.
        case "”", "’", "''", "»", "›", "\"", "＂": return "''"
        case "$", "£", "€", "¥", "₹", "₩", "¢": return "$"
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
                if t == "\"" || t == "＂" || t == "'" {
                    let opens = tokens[i].whitespace.isEmpty && i + 1 < tokens.count
                        && (i == 0 || !tokens[i - 1].whitespace.isEmpty || ruleTag(tokens[i - 1].text) == "-LRB-")
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
