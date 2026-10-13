// Phoneme constants and helpers shared by the lexicon and the G2P pipeline.
//
// Derived from misaki (https://github.com/hexgrad/misaki, en.py, Apache-2.0) and its
// Swift port MisakiSwift (https://github.com/mlalma/MisakiSwift, Apache-2.0; see
// LICENSE-MisakiSwift.txt). Modified for Aloud: Python string semantics are
// reproduced exactly (capitalize, isalpha, code-point iteration), which the original
// Swift port didn't always do.
import Foundation

enum Ph {
    static let primary: Character = "ˈ"
    static let secondary: Character = "ˌ"
    static let stresses: Set<Character> = ["ˈ", "ˌ"]
    static let vowels: Set<Character> = Set("AIOQWYaiuæɑɒɔəɛɜɪʊʌᵻ")
    static let consonants: Set<Character> = Set("bdfhjklmnpstvwzðŋɡɹɾʃʒʤʧθ")
    static let diphthongs: Set<Character> = Set("AIOQWYʤʧ")
    static let usTaus: Set<Character> = Set("AIOWYiuæɑəɛɪɹʊʌ")
    static let puncts: Set<Character> = Set(";:,.!?—…\"“”")
    static let nonQuotePuncts: Set<Character> = Set(";:,.!?—…")
    static let subtokenJunks: Set<Character> = Set("',-._‘’/")

    /// misaki's apply_stress: -2 removes stress, -1/-0.5/0 demote, 0.5/1/2 promote.
    static func applyStress(_ ps: String?, _ stress: Double?) -> String? {
        guard let ps else { return nil }
        guard let stress else { return ps }
        let hasPrimary = ps.contains(primary)
        let hasAnyStress = ps.contains { stresses.contains($0) }
        let hasVowel = ps.contains { vowels.contains($0) }
        if stress < -1 {
            return ps.replacingOccurrences(of: String(primary), with: "").replacingOccurrences(of: String(secondary), with: "")
        } else if stress == -1 || ((stress == 0 || stress == -0.5) && hasPrimary) {
            return ps.replacingOccurrences(of: String(secondary), with: "").replacingOccurrences(of: String(primary), with: String(secondary))
        } else if (stress == 0 || stress == 0.5 || stress == 1) && !hasAnyStress {
            return hasVowel ? restress(String(secondary) + ps) : ps
        } else if stress >= 1 && !hasPrimary && ps.contains(secondary) {
            return ps.replacingOccurrences(of: String(secondary), with: String(primary))
        } else if stress > 1 && !hasAnyStress {
            return hasVowel ? restress(String(primary) + ps) : ps
        }
        return ps
    }

    /// Moves each stress mark to just before the vowel that follows it.
    private static func restress(_ ps: String) -> String {
        let chars = Array(ps)
        var keyed: [(Double, Character)] = chars.enumerated().map { (Double($0.offset), $0.element) }
        for (i, c) in chars.enumerated() where stresses.contains(c) {
            if let j = chars[i...].firstIndex(where: { vowels.contains($0) }) {
                keyed[i] = (Double(j) - 0.5, c)
            }
        }
        return String(keyed.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map { $0.element.1 })
    }

    static func stressWeight(_ ps: String?) -> Int {
        guard let ps else { return 0 }
        return ps.reduce(0) { $0 + (diphthongs.contains($1) ? 2 : 1) }
    }
}

/// Python str semantics used by misaki.
extension String {
    var pyLower: String { lowercased() }
    var pyUpper: String { uppercased() }
    /// str.capitalize(): first character upper-cased, the rest lower-cased.
    var pyCapitalize: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst().lowercased()
    }
    var pyIsAlpha: Bool { !isEmpty && allSatisfy { $0.isLetter } }
    /// misaki's is_digit: ASCII digits only, at least one.
    var isAsciiDigits: Bool { !isEmpty && unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 } }
    /// Every character is an apostrophe, hyphen or ASCII letter (misaki's LEXICON_ORDS).
    var isLexiconChars: Bool {
        unicodeScalars.allSatisfy { s in
            let v = s.value
            return v == 39 || v == 45 || (65...90).contains(v) || (97...122).contains(v)
        }
    }
    /// Python s[1:]
    var tail: String { String(dropFirst()) }
    func pyStrip(_ chars: Set<Character>) -> String {
        var s = Substring(self)
        while let f = s.first, chars.contains(f) { s = s.dropFirst() }
        while let l = s.last, chars.contains(l) { s = s.dropLast() }
        return String(s)
    }
}
