import Foundation

/// Pronunciations for words the gold lexicon doesn't have: CMUdict first, then the
/// mini-bart G2P model. Both give American ARPAbet, mapped to misaki's symbols (and
/// converted for British voices). Tokens without letters ("3:45") are re-read by the
/// lexicon on their own, dropping anything it can't say.
final class Fallback {
    private let data: G2PData
    private let british: Bool
    private let inner: () -> EnglishG2P   // the same pipeline without a fallback
    private var cache: [String: String?] = [:]
    private let lock = NSLock()

    init(data: G2PData, british: Bool, inner: @escaping () -> EnglishG2P) {
        self.data = data
        self.british = british
        self.inner = inner
    }

    func callAsFunction(_ tk: MToken) -> (String?, Int?) {
        let text = tk.text
        if text.range(of: "[A-Za-z]", options: .regularExpression) == nil {
            let ps = inner().phonemize(text, unk: "❓").replacingOccurrences(of: "❓", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (ps.isEmpty ? nil : ps, 1)
        }
        // The guessers only know letters, apostrophes, hyphens and dots: a quote, symbol or
        // invisible character left in the group ("＂hello＂") made mini-bart garble the word.
        let word = String(text.replacingOccurrences(of: "’", with: "'").filter { $0.isLetter || $0.isNumber || "'-.".contains($0) })
        lock.lock()
        if let hit = cache[word] { lock.unlock(); return (hit, hit == nil ? nil : 1) }
        lock.unlock()
        // CMUdict and mini-bart only know unaccented spellings ("Zoe", "fiancee").
        let plain = word.folding(options: .diacriticInsensitive, locale: nil)
        var ps = Self.cmuWord(word, data: data) ?? Self.cmuWord(plain, data: data) ?? miniBartWord(plain)
        if let p = ps, british { ps = Self.usToGB(p) }
        ps = ps?.trimmingCharacters(in: .whitespaces)
        if ps?.isEmpty == true { ps = nil }
        lock.lock(); cache[word] = ps; lock.unlock()
        return (ps, ps == nil ? nil : 1)
    }

    /// `--phonemize --explain`: which guesser `callAsFunction` used for `text`.
    func source(of text: String) -> String {
        guard text.range(of: "[A-Za-z]", options: .regularExpression) != nil else { return "rule" }
        let word = String(text.replacingOccurrences(of: "’", with: "'").filter { $0.isLetter || $0.isNumber || "'-.".contains($0) })
        let plain = word.folding(options: .diacriticInsensitive, locale: nil)
        return (Self.cmuWord(word, data: data) ?? Self.cmuWord(plain, data: data)) != nil ? "cmudict" : "guesser"
    }

    static func cmuWord(_ word: String, data: G2PData) -> String? {
        guard let arpa = data.cmudict[word.lowercased()] else { return nil }
        return demoteExtraPrimaries(arpaToMisaki(arpa.split(separator: " ").map(String.init)))
    }

    private func miniBartWord(_ word: String) -> String? {
        guard let model = data.miniBart, let out = model.predict(word) else { return nil }
        return Self.demoteExtraPrimaries(Self.arpaToMisaki(Self.splitArpa(out)))
    }

    // MARK: - ARPAbet → misaki

    static let arpa: [String: String] = [
        "AA": "ɑ", "AE": "æ", "AH": "ʌ", "AO": "ɔ", "AW": "W", "AY": "I", "EH": "ɛ", "ER": "ɜɹ", "EY": "A", "IH": "ɪ",
        "IY": "i", "OW": "O", "OY": "Y", "UH": "ʊ", "UW": "u", "B": "b", "CH": "ʧ", "D": "d", "DH": "ð", "F": "f",
        "G": "\u{0261}", "HH": "h", "JH": "ʤ", "K": "k", "L": "l", "M": "m", "N": "n", "NG": "ŋ", "P": "p", "R": "ɹ",
        "S": "s", "SH": "ʃ", "T": "t", "TH": "θ", "V": "v", "W": "w", "Y": "j", "Z": "z", "ZH": "ʒ",
    ]
    private static let arpaSymbols = arpa.keys.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }

    static func arpaToMisaki(_ tokens: [String]) -> String {
        var out = ""
        for raw in tokens {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { out += " "; continue }
            // ([A-Z]+)([012]?)
            var base = t, st = ""
            if let last = t.last, "012".contains(last) { base = String(t.dropLast()); st = String(last) }
            guard !base.isEmpty, base.unicodeScalars.allSatisfy({ (65...90).contains($0.value) }) else {
                if t.count == 1, ",.!?;:".contains(t) { out += t }
                continue
            }
            let ph: String
            if base == "AH" && st == "0" { ph = "ə" } else if base == "ER" && st == "0" { ph = "əɹ" } else { ph = arpa[base] ?? "" }
            out += (st == "1" ? "ˈ" : st == "2" ? "ˌ" : "") + ph
        }
        return out
    }

    /// Splits run-together ARPAbet ("GIH1THHAH0B") back into symbols, with backtracking,
    /// exactly as the reference pipeline does with the model's output.
    static func splitArpa(_ input: String) -> [String] {
        let s = Array(input.filter { !$0.isWhitespace })
        var memo: [Int: [String]?] = [:]
        func go(_ i: Int) -> [String]? {
            if i == s.count { return [] }
            if let m = memo[i] { return m }
            var result: [String]? = nil
            for sym in arpaSymbols {
                let chars = Array(sym)
                guard i + chars.count <= s.count, Array(s[i..<(i + chars.count)]) == chars else { continue }
                let j = i + chars.count
                let st = j < s.count && "012".contains(s[j]) ? String(s[j]) : ""
                if let rest = go(j + st.count) { result = [sym + st] + rest; break }
            }
            memo[i] = result
            return result
        }
        return go(0) ?? []
    }

    static func demoteExtraPrimaries(_ ps: String) -> String {
        guard let first = ps.firstIndex(of: "ˈ") else { return ps }
        let after = ps.index(after: first)
        return String(ps[..<after]) + ps[after...].replacingOccurrences(of: "ˈ", with: "ˌ")
    }

    // MARK: - US → GB

    private static let gbVowels: Set<Character> = Set("AIOQWYaiuæɑɒɔəɛɜɪʊʌᵻ")

    /// A rough conversion of American phonemes for British voices: non-rhotic r,
    /// lengthened vowels, ɒ for ɑ, Q for O, a for æ, no flapped t.
    static func usToGB(_ input: String) -> String {
        let chars = Array(input.replacingOccurrences(of: "T", with: "t").replacingOccurrences(of: "O", with: "Q")
            .replacingOccurrences(of: "æ", with: "a"))
        var out: [Character] = []
        for (i, ch) in chars.enumerated() {
            var c = ch
            if c == "ɹ" {
                var j = i + 1
                while j < chars.count, "ˈˌ".contains(chars[j]) { j += 1 }
                if j >= chars.count || !gbVowels.contains(chars[j]) {
                    let prev = out.last
                    if prev == "ɑ" || prev == "ɔ" || prev == "ɜ" || prev == "ɛ" { out.append("ː") } else if prev == "ɪ" || prev == "ʊ" || prev == "I" { out.append("ə") }
                    continue
                }
            }
            if c == "ɑ" {
                let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                if next != "ɹ" { c = "ɒ" }
            }
            out.append(c)
        }
        var s = String(out)
        s = s.replacingOccurrences(of: "([ˈˌ])i(?!ː)", with: "$1iː", options: .regularExpression)
        s = s.replacingOccurrences(of: "([ˈˌ])u(?!ː)", with: "$1uː", options: .regularExpression)
        s = s.replacingOccurrences(of: "([ˈˌ])ɔ(?!ː)", with: "$1ɔː", options: .regularExpression)
        return s.replacingOccurrences(of: "əː", with: "ə")
    }
}

/// cisco-ai/mini-bart-g2p: a small BART that spells unknown words in ARPAbet.
/// Greedy decoding, as transformers' generate() does with this model's settings.
final class MiniBart {
    private let encoder: OnnxModel
    private let decoder: OnnxModel
    private let vocab: [String: Int64]
    private let tokens: [Int64: String]

    init(directory: URL) throws {
        encoder = try OnnxModel(path: directory.appendingPathComponent("minibart-encoder.onnx").path, threads: 1)
        decoder = try OnnxModel(path: directory.appendingPathComponent("minibart-decoder.onnx").path, threads: 1)
        let data = try Data(contentsOf: directory.appendingPathComponent("minibart-vocab.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Int] ?? [:]
        vocab = json.mapValues(Int64.init)
        tokens = Dictionary(json.map { (Int64($0.value), $0.key) }, uniquingKeysWith: { a, _ in a })
    }

    /// ARPAbet tokens run together, e.g. "PAO1L", or nil if the model fails.
    func predict(_ word: String) -> String? {
        let ids: [Int64] = [0] + word.lowercased().map { vocab[String($0)] ?? 3 } + [2]
        let n = Int64(ids.count)
        let mask = [Int64](repeating: 1, count: ids.count)
        guard let hidden = try? encoder.run([.int64("input_ids", ids, shape: [1, n]),
                                             .int64("attention_mask", mask, shape: [1, n])],
                                            output: "last_hidden_state") else { return nil }
        var out: [Int64] = [2]
        for _ in 0..<63 {
            guard let logits = try? decoder.run([.int64("encoder_attention_mask", mask, shape: [1, n]),
                                                 .int64("input_ids", out, shape: [1, Int64(out.count)]),
                                                 .float("encoder_hidden_states", hidden.values, shape: hidden.shape)],
                                                output: "logits") else { return nil }
            let vocabSize = Int(logits.shape.last ?? 0)
            guard vocabSize > 0 else { return nil }
            let last = logits.values[(logits.values.count - vocabSize)...]
            var best = 0
            var bestValue = -Float.infinity
            for (k, v) in last.enumerated() where v > bestValue { bestValue = v; best = k }
            if best == 2 { break }
            out.append(Int64(best))
        }
        return out.dropFirst().filter { $0 > 4 }.compactMap { tokens[$0] }.joined()
    }
}
