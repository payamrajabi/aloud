// misaki's English G2P pipeline (en.py, class G2P), ported to Swift.
//
// Derived from misaki (https://github.com/hexgrad/misaki, Apache-2.0) and MisakiSwift
// (https://github.com/mlalma/MisakiSwift, Apache-2.0; see LICENSE-MisakiSwift.txt).
// Modified for Aloud: spaCy-style tokenization (Tokenizer.swift) instead of NLTagger's,
// the subtoken pattern restored to match curly apostrophes as the original does, the
// "2"→"to" rule's operator precedence fixed, and the MLX BART fallback replaced with
// CMUdict + mini-bart (Fallback.swift).
import Foundation

final class MToken {
    var text: String
    var tag: String
    var whitespace: String
    var phonemes: String?
    // misaki's token "underscore" attributes
    var isHead = true
    var alias: String?
    var stress: Double?
    var currency: String?
    var numFlags = ""
    var prespace = false
    var rating: Int?

    init(text: String, tag: String, whitespace: String, phonemes: String? = nil) {
        self.text = text
        self.tag = tag
        self.whitespace = whitespace
        self.phonemes = phonemes
    }
}

struct TokenContext {
    var futureVowel: Bool? = nil
    var futureTo = false
}

final class EnglishG2P {
    let british: Bool
    let lexicon: Lexicon
    var fallback: Fallback?

    init(lexicon: Lexicon, fallback: Fallback?) {
        self.british = lexicon.british
        self.lexicon = lexicon
        self.fallback = fallback
    }

    // ^['‘’]+|\p{Lu}(?=\p{Lu}\p{Ll})|(?:^-)?(?:\d?[,.]?\d)+|[-_]+|['‘’]{2,}|\p{L}*?(?:['‘’]\p{L})*?\p{Ll}(?=\p{Lu})|\p{L}+(?:['‘’]\p{L})*|[^-_\p{L}'‘’\d]|['‘’]+$
    private static let subtokenRegex = try! NSRegularExpression(pattern:
        "^['\u{2018}\u{2019}]+|\\p{Lu}(?=\\p{Lu}\\p{Ll})|(?:^-)?(?:\\d?[,.]?\\d)+|[-_]+|['\u{2018}\u{2019}]{2,}|\\p{L}*?(?:['\u{2018}\u{2019}]\\p{L})*?\\p{Ll}(?=\\p{Lu})|\\p{L}+(?:['\u{2018}\u{2019}]\\p{L})*|[^-_\\p{L}'\u{2018}\u{2019}\\d]|['\u{2018}\u{2019}]+$")

    static func subtokenize(_ word: String) -> [String] {
        let ns = word as NSString
        return subtokenRegex.matches(in: word, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    static let punctTags: Set<String> = [".", ",", "-LRB-", "-RRB-", "``", "\"\"", "''", ":", "$", "#", "NFP"]
    static let punctTagPhonemes = ["-LRB-": "(", "-RRB-": ")", "``": "\u{201C}", "\"\"": "\u{201D}", "''": "\u{201D}"]

    // MARK: - Pipeline

    enum Word {
        case one(MToken)
        case many([MToken])
    }

    func phonemize(_ input: String, unk: String = "") -> String {
        let (text, features) = Self.preprocess(input)
        var tokens = Self.tokenize(text, features: features)
        tokens = foldLeft(tokens)
        var words = Self.retokenize(tokens)
        var ctx = TokenContext()
        for i in words.indices.reversed() {
            switch words[i] {
            case .one(let w):
                if w.phonemes == nil {
                    let r = lexicon(w, ctx: ctx)
                    w.phonemes = r.0; w.rating = r.1
                }
                if w.phonemes == nil, let fallback {
                    let r = fallback(w)
                    w.phonemes = r.0; w.rating = r.1
                }
                ctx = Self.tokenContext(ctx, ps: w.phonemes, token: w)
            case .many(let w):
                var left = 0, right = w.count
                var shouldFallback = false
                while left < right {
                    let fixed = w[left..<right].contains { $0.alias != nil || $0.phonemes != nil }
                    let tk: MToken? = fixed ? nil : Self.merge(Array(w[left..<right]))
                    let (ps, rating) = tk.map { lexicon($0, ctx: ctx) } ?? (nil, nil)
                    if let ps, let tk {
                        w[left].phonemes = ps
                        w[left].rating = rating
                        for x in w[(left + 1)..<right] { x.phonemes = ""; x.rating = rating }
                        ctx = Self.tokenContext(ctx, ps: ps, token: tk)
                        right = left
                        left = 0
                    } else if left + 1 < right {
                        left += 1
                    } else {
                        right -= 1
                        let tk = w[right]
                        if tk.phonemes == nil {
                            if tk.text.allSatisfy({ Ph.subtokenJunks.contains($0) }) {
                                tk.phonemes = ""
                                tk.rating = 3
                            } else if !tk.text.contains(where: { $0.isLetter || $0.isNumber }),
                                      w.contains(where: { $0.text.contains { $0.isASCII && $0.isLetter } }) {
                                // A quote or symbol stuck to a word ("„Hallo", a byte-order mark):
                                // keep any pause it makes, but never hand the word to the guessers
                                // for it, which garbled it ("\"hello\"" → "chellon"). (Groups
                                // without letters, like "3:45", are re-read by the lexicon.)
                                tk.phonemes = tk.text.filter { Ph.puncts.contains($0) }
                                tk.rating = 3
                            } else if fallback != nil {
                                shouldFallback = true
                                break
                            }
                        }
                        left = 0
                    }
                }
                if shouldFallback, let fallback {
                    let tk = Self.merge(w)
                    let r = fallback(tk)
                    w[0].phonemes = r.0; w[0].rating = r.1
                    for x in w.dropFirst() { x.phonemes = ""; x.rating = r.1 }
                } else {
                    Self.resolveTokens(w)
                }
                words[i] = .many(w)
            }
        }
        let final: [MToken] = words.map {
            switch $0 {
            case .one(let t): return t
            case .many(let ts): return Self.merge(ts, unk: unk)
            }
        }
        var out = ""
        for tk in final {
            var ps = tk.phonemes ?? unk
            if !ps.isEmpty { ps = ps.replacingOccurrences(of: "ɾ", with: "T").replacingOccurrences(of: "ʔ", with: "t") }
            out += ps + tk.whitespace
        }
        return out
    }

    // MARK: - Steps

    struct Feature {
        let range: Range<String.Index>   // in the preprocessed text
        let phonemes: String?
        let stress: Double?
    }

    /// misaki's link syntax: "[Kokoro](/kˈOkəɹO/)" fixes a pronunciation, "[word](-1)"
    /// sets its stress, and any other [text](target) is read as just its text.
    static func preprocess(_ input: String) -> (String, [Feature]) {
        let text = String(input.drop { $0.isWhitespace })
        let re = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^\)]*)\)"#)
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (text, []) }
        var result = ""
        var marks: [(Int, Int, String?, Double?)] = []   // utf16 offsets into result
        var last = 0
        for m in matches {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let word = ns.substring(with: m.range(at: 1))
            let f = ns.substring(with: m.range(at: 2))
            let start = (result as NSString).length
            result += word
            let end = (result as NSString).length
            let body = f.hasPrefix("-") || f.hasPrefix("+") ? String(f.dropFirst()) : f
            if body.isAsciiDigits, let n = Int(f) {
                marks.append((start, end, nil, Double(n)))
            } else if f == "0.5" || f == "+0.5" {
                marks.append((start, end, nil, 0.5))
            } else if f == "-0.5" {
                marks.append((start, end, nil, -0.5))
            } else if f.count > 1, f.hasPrefix("/"), f.hasSuffix("/"), isPronunciation(f.dropFirst().dropLast()) {
                marks.append((start, end, f.trimmingCharacters(in: CharacterSet(charactersIn: "/")), nil))
            }
            last = NSMaxRange(m.range)
        }
        result += ns.substring(from: last)
        let features: [Feature] = marks.compactMap { s, e, ps, st in
            guard let r = Range(NSRange(location: s, length: e - s), in: result) else { return nil }
            return Feature(range: r, phonemes: ps, stress: st)
        }
        return (result, features)
    }

    /// Whether a "/…/" link target is a pronunciation: one always holds a stress mark or an
    /// IPA symbol, and no slash. A path ("[Getting started](/guide/start/)", "[docs](/docs/)")
    /// is read as its label; its letters used to go to the voice as phonemes.
    private static func isPronunciation(_ s: Substring) -> Bool {
        !s.contains("/") && s.contains { !$0.isASCII }
    }

    static func tokenize(_ text: String, features: [Feature]) -> [MToken] {
        var tagged = Tokenizer.tokenize(text)
        // A fixed pronunciation covers exactly its span: split tokens that run past it
        // ("SQL-based" → "SQL" + "-based"), as spaCy's finer tokens would be.
        for f in features {
            var split: [TaggedToken] = []
            for t in tagged {
                guard t.range.overlaps(f.range), t.range != f.range else { split.append(t); continue }
                var cuts = [t.range.lowerBound]
                if f.range.lowerBound > t.range.lowerBound { cuts.append(f.range.lowerBound) }
                if f.range.upperBound < t.range.upperBound { cuts.append(f.range.upperBound) }
                cuts.append(t.range.upperBound)
                for k in 0..<(cuts.count - 1) where cuts[k] < cuts[k + 1] {
                    let r = cuts[k]..<cuts[k + 1]
                    split.append(TaggedToken(text: String(text[r]), whitespace: r.upperBound == t.range.upperBound ? t.whitespace : "",
                                             tag: t.tag, range: r))
                }
            }
            tagged = split
        }
        let tokens = tagged.map { MToken(text: $0.text, tag: $0.tag, whitespace: $0.whitespace) }
        for f in features {
            var first = true
            for (tk, t) in zip(tokens, tagged) where t.range.overlaps(f.range) {
                if let s = f.stress { tk.stress = s }
                if let ps = f.phonemes {
                    tk.isHead = first
                    tk.phonemes = first ? ps : ""
                    tk.rating = 5
                }
                first = false
            }
        }
        return tokens
    }

    func foldLeft(_ tokens: [MToken]) -> [MToken] {
        var result: [MToken] = []
        for tk in tokens {
            if let last = result.last, !tk.isHead {
                result[result.count - 1] = Self.merge([last, tk], unk: "")
            } else {
                result.append(tk)
            }
        }
        return result
    }

    static func retokenize(_ tokens: [MToken]) -> [Word] {
        var words: [Word] = []
        var currency: String? = nil
        for (i, token) in tokens.enumerated() {
            var tks: [MToken]
            if token.alias == nil && token.phonemes == nil {
                tks = subtokenize(token.text).map { t in
                    let x = MToken(text: t, tag: token.tag, whitespace: "")
                    x.numFlags = token.numFlags
                    x.stress = token.stress
                    return x
                }
                if tks.isEmpty { tks = [MToken(text: token.text, tag: token.tag, whitespace: "")] }
            } else {
                tks = [token]
            }
            tks[tks.count - 1].whitespace = token.whitespace
            for (j, tk) in tks.enumerated() {
                if tk.alias != nil || tk.phonemes != nil {
                } else if tk.tag == "$", Lexicon.currencies[tk.text] != nil {
                    currency = tk.text
                    tk.phonemes = ""
                    tk.rating = 4
                } else if tk.tag == ":", tk.text == "-" || tk.text == "–" {
                    tk.phonemes = "—"
                    tk.rating = 3
                } else if punctTags.contains(tk.tag), !tk.text.lowercased().unicodeScalars.allSatisfy({ (97...122).contains($0.value) }) {
                    tk.phonemes = punctTagPhonemes[tk.tag] ?? tk.text.filter { Ph.puncts.contains($0) }
                    tk.rating = 4
                } else if currency != nil {
                    if tk.tag != "CD" {
                        currency = nil
                    } else if j + 1 == tks.count && (i + 1 == tokens.count || tokens[i + 1].tag != "CD") {
                        tk.currency = currency
                    }
                } else if j > 0, j < tks.count - 1, tk.text == "2",
                          let a = tks[j - 1].text.last, let b = tks[j + 1].text.first, a.isLetter, b.isLetter {
                    tk.alias = "to"
                }
                if tk.alias != nil || tk.phonemes != nil {
                    words.append(.one(tk))
                } else if case .many(var group)? = words.last, group.last?.whitespace.isEmpty == true {
                    tk.isHead = false
                    group.append(tk)
                    words[words.count - 1] = .many(group)
                } else {
                    words.append(tk.whitespace.isEmpty ? .many([tk]) : .one(tk))
                }
            }
        }
        return words.map { if case .many(let g) = $0, g.count == 1 { return .one(g[0]) } else { return $0 } }
    }

    static func tokenContext(_ ctx: TokenContext, ps: String?, token: MToken) -> TokenContext {
        var vowel = ctx.futureVowel
        if let ps {
            for c in ps {
                if Ph.nonQuotePuncts.contains(c) { vowel = nil; break }
                if Ph.vowels.contains(c) { vowel = true; break }
                if Ph.consonants.contains(c) { vowel = false; break }
            }
        }
        let futureTo = token.text == "to" || token.text == "To" || (token.text == "TO" && (token.tag == "TO" || token.tag == "IN"))
        return TokenContext(futureVowel: vowel, futureTo: futureTo)
    }

    static func resolveTokens(_ tokens: [MToken]) {
        let text = tokens.dropLast().map { $0.text + $0.whitespace }.joined() + (tokens.last?.text ?? "")
        let classes = Set(text.filter { !Ph.subtokenJunks.contains($0) }.map { c -> Int in
            c.isLetter ? 0 : (c.isASCII && c.isNumber ? 1 : 2)
        })
        let prespace = text.contains(" ") || text.contains("/") || classes.count > 1
        for (i, tk) in tokens.enumerated() {
            if tk.phonemes == nil {
                if i == tokens.count - 1, tk.text.count == 1, let c = tk.text.first, Ph.nonQuotePuncts.contains(c) {
                    tk.phonemes = tk.text
                    tk.rating = 3
                } else if tk.text.allSatisfy({ Ph.subtokenJunks.contains($0) }) {
                    tk.phonemes = ""
                    tk.rating = 3
                }
            } else if i > 0 {
                tk.prespace = prespace
            }
        }
        if prespace { return }
        var indices: [(Bool, Int, Int)] = []
        for (i, tk) in tokens.enumerated() {
            if let ps = tk.phonemes, !ps.isEmpty { indices.append((ps.contains(Ph.primary), Ph.stressWeight(ps), i)) }
        }
        if indices.count == 2, tokens[indices[0].2].text.count == 1 {
            let i = indices[1].2
            tokens[i].phonemes = Ph.applyStress(tokens[i].phonemes, -0.5)
            return
        } else if indices.count < 2 || indices.filter(\.0).count <= (indices.count + 1) / 2 {
            return
        }
        indices.sort { ($0.0 ? 1 : 0, $0.1, $0.2) < ($1.0 ? 1 : 0, $1.1, $1.2) }
        for x in indices.prefix(indices.count / 2) {
            tokens[x.2].phonemes = Ph.applyStress(tokens[x.2].phonemes, -0.5)
        }
    }

    static func merge(_ tokens: [MToken], unk: String? = nil) -> MToken {
        let stresses = Set(tokens.compactMap(\.stress))
        let currencies = tokens.compactMap(\.currency)
        var phonemes: String? = nil
        if let unk {
            var p = ""
            for tk in tokens {
                if tk.prespace, !p.isEmpty, !(p.last!.isWhitespace), tk.phonemes != nil, !(tk.phonemes!.isEmpty) { p += " " }
                p += tk.phonemes ?? unk
            }
            phonemes = p
        }
        func score(_ t: MToken) -> Int { t.text.reduce(0) { $0 + (String($1) == String($1).lowercased() ? 1 : 2) } }
        var best = tokens[0]
        for t in tokens.dropFirst() where score(t) > score(best) { best = t }
        let m = MToken(text: tokens.dropLast().map { $0.text + $0.whitespace }.joined() + tokens[tokens.count - 1].text,
                       tag: best.tag, whitespace: tokens[tokens.count - 1].whitespace, phonemes: phonemes)
        m.isHead = tokens[0].isHead
        m.stress = stresses.count == 1 ? stresses.first : nil
        m.currency = currencies.max()
        m.numFlags = String(Set(tokens.flatMap { Array($0.numFlags) }).sorted())
        m.prespace = tokens[0].prespace
        m.rating = tokens.contains { $0.rating == nil } ? nil : tokens.compactMap(\.rating).min()
        return m
    }
}
