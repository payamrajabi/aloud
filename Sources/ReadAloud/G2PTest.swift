import Foundation
import Phonemizer

/// The pronunciation regression suite (`--g2p-test Tests/g2p/regression.json`).
///
/// Scores the phonemizer against the study's references exactly as its Python
/// evaluation did, and against the Python reference pipeline's own output. Runs twice:
/// "reference" (no text normalization, no custom lexicons: the same pipeline as the
/// Python reference) and "shipped" (what the app uses). Fails if the shipped
/// configuration does worse than the reference on any headline score.
enum G2PTest {
    private struct Item: Decodable {
        let cat: String
        let text: String
        let refs: [String]
        let python: String
        let target: String?
        let oov: Bool?
    }
    private struct Sentence: Decodable {
        let name: String
        let text: String
        let python_us: String
        let python_gb: String
    }
    private struct Doc: Decodable {
        let items: [Item]
        let sentences: [Sentence]
        let reference_scores: [String: Double]
        let lexicon_cases: [LexiconCase]
    }
    private struct LexiconCase: Decodable {
        let text: String
        let us: String
        let gb: String?
        let absent: String?
    }

    static func phonemizers() throws -> (raw: [Bool: Phonemizer], shipped: [Bool: Phonemizer]) {
        let data = try G2PData.load(from: G2PData.defaultDirectory())
        let custom = CustomLexicon(directories: LexiconFiles.directories)
        for p in custom.problems { print("lexicon problem: \(p)") }
        var raw: [Bool: Phonemizer] = [:], shipped: [Bool: Phonemizer] = [:]
        for b in [false, true] {
            raw[b] = Phonemizer(british: b, data: data, custom: nil, normalize: false)
            shipped[b] = Phonemizer(british: b, data: data, custom: custom)
        }
        return (raw, shipped)
    }

    static func phonemizeLines(british: Bool, raw: Bool) -> Int32 {
        do {
            let p = try phonemizers()
            let ph = (raw ? p.raw : p.shipped)[british]!
            while let line = readLine(strippingNewline: true) {
                print("\(line)\t\(ph.phonemize(line, unknown: "❓"))")
            }
            return 0
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }
    }

    // MARK: - Scoring (a port of the study's evaluate.py)

    private static let phones = Set("AIOWYQabdefhijklmnpstuvwxzæçðŋɐɑɒɔəɚɛɜɝɡɪɹɾʃʊʌʒʔʤʧθᵊᵻTβɣχɲɟʎɕʑʐʂɖɳɭɻɽɯɰʋʁɥøœɘɵɤɨʉɞɶ")

    static func norm(_ input: String, stress: Bool) -> String {
        var ps = input
        for (a, b) in [("ɚ", "əɹ"), ("ɝ", "ɜɹ"), ("ɾ", "T"), ("ʔ", "t"), ("ᵻ", "ɪ"), ("ᵊ", "ə"), ("ɐ", "ə"), ("ː", ""), ("T", "t"), ("ɒ", "ɑ")] {
            ps = ps.replacingOccurrences(of: a, with: b)
        }
        ps = ps.filter { phones.contains($0) || (stress && ($0 == "ˈ" || $0 == "ˌ")) }
        if !stress { ps = ps.replacingOccurrences(of: "ʌ", with: "ə").replacingOccurrences(of: "ɜ", with: "ə") }
        return ps
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        var prev = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var cur = [i + 1]
            for (j, cb) in b.enumerated() {
                cur.append(min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (ca == cb ? 0 : 1)))
            }
            prev = cur
        }
        return prev[b.count]
    }

    static func per(_ h: String, _ r: String) -> Double {
        let hn = Array(norm(h, stress: false)), rn = Array(norm(r, stress: false))
        return Double(levenshtein(hn, rn)) / Double(max(1, rn.count))
    }

    private struct Score {
        var n = 0, exact = 0, exactNS = 0, samePython = 0, samePythonNorm = 0, unknown = 0
        var perSum = 0.0
        var exactRate: Double { n == 0 ? 0 : Double(exact) / Double(n) }
        var perMean: Double { n == 0 ? 0 : perSum / Double(n) }
        var line: String {
            String(format: "%3d items  exact %5.1f%%  (no stress %5.1f%%)  PER %5.1f%%  unknown %d  same as Python %5.1f%% (normalized %5.1f%%)",
                   n, 100 * exactRate, 100 * Double(exactNS) / Double(max(n, 1)), 100 * perMean, unknown,
                   100 * Double(samePython) / Double(max(n, 1)), 100 * Double(samePythonNorm) / Double(max(n, 1)))
        }
    }

    static func run(path: String, verbose: Bool) -> Int32 {
        let doc: Doc
        let p: (raw: [Bool: Phonemizer], shipped: [Bool: Phonemizer])
        do {
            doc = try JSONDecoder().decode(Doc.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            p = try phonemizers()
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }
        var failed = false
        for (mode, ph) in [("reference pipeline (no normalizer, no custom lexicon)", p.raw[false]!), ("shipped configuration", p.shipped[false]!)] {
            print("\n== \(mode), US ==")
            var scores: [String: Score] = [:]
            var heteronyms = (ok: 0, n: 0, samePython: 0)
            let t0 = Date()
            for item in doc.items {
                let out = ph.phonemize(item.text, unknown: "❓")
                let same = out == item.python
                let sameNorm = norm(out, stress: true) == norm(item.python, stress: true)
                if item.cat == "heteronym" {
                    let ok = norm(out, stress: false).contains(norm(item.refs[0], stress: false))
                    heteronyms.n += 1
                    heteronyms.ok += ok ? 1 : 0
                    heteronyms.samePython += same ? 1 : 0
                    if verbose && !ok { print("  ✗ heteronym \(item.text) → /\(out)/ (want \(item.target ?? "") = /\(item.refs[0])/)") }
                    continue
                }
                let exact = item.refs.contains { norm(out, stress: true) == norm($0, stress: true) }
                let exactNS = item.refs.contains { norm(out, stress: false) == norm($0, stress: false) }
                let e = item.refs.map { per(out, $0) }.min() ?? 1
                let unknown = out.contains("❓") || norm(out, stress: false).isEmpty
                var groups = [item.cat]
                if ["common", "heldout"].contains(item.cat) { groups.append("IN-LEXICON") }
                if item.oov == true { groups.append("UNKNOWN WORDS") }
                if ["number", "abbrev", "hyphen", "contraction"].contains(item.cat) { groups.append("NORMALISATION") }
                for g in groups {
                    var s = scores[g, default: Score()]
                    s.n += 1
                    s.exact += exact ? 1 : 0
                    s.exactNS += exactNS ? 1 : 0
                    s.perSum += e
                    s.unknown += unknown ? 1 : 0
                    s.samePython += same ? 1 : 0
                    s.samePythonNorm += sameNorm ? 1 : 0
                    scores[g] = s
                }
                if verbose && (!sameNorm || e > 0.25) && item.cat != "silveronly" {
                    print(String(format: "  %@ %-12@ %@ → /%@/  python /%@/  ref /%@/  PER %.0f%%", exact ? "✓" : "✗", item.cat, item.text, out, item.python, item.refs[0], 100 * e))
                }
            }
            let elapsed = Date().timeIntervalSince(t0)
            for g in ["common", "heldout", "freqoov", "name", "tech", "madeup", "contraction", "number", "abbrev", "hyphen", "silveronly",
                      "IN-LEXICON", "UNKNOWN WORDS", "NORMALISATION"] {
                if let s = scores[g] { print(String(format: "  %-14@ %@", g, s.line)) }
            }
            let hRate = Double(heteronyms.ok) / Double(max(1, heteronyms.n))
            print(String(format: "  %-14@ %d/%d read correctly (%.1f%%), same as Python %d/%d", "heteronyms",
                         heteronyms.ok, heteronyms.n, 100 * hRate, heteronyms.samePython, heteronyms.n))
            print(String(format: "  %.1f ms per item", 1000 * elapsed / Double(doc.items.count)))

            if mode.hasPrefix("shipped") {
                let ref = doc.reference_scores
                var checks: [(String, Bool)] = []
                checks.append(("in-lexicon exact ≥ \(ref["in_lexicon_exact"]!)", scores["IN-LEXICON"]!.exactRate >= ref["in_lexicon_exact"]! - 0.0001))
                checks.append(("unknown words exact ≥ \(ref["unknown_exact"]!)", scores["UNKNOWN WORDS"]!.exactRate >= ref["unknown_exact"]! - 0.0001))
                checks.append(("unknown words PER ≤ \(ref["unknown_per"]!)", scores["UNKNOWN WORDS"]!.perMean <= ref["unknown_per"]! + 0.0001))
                checks.append(("heteronyms ≥ \(ref["heteronyms"]!)", hRate >= ref["heteronyms"]! - 0.0001))
                checks.append(("normalisation exact ≥ \(ref["normalisation_exact"]!)", scores["NORMALISATION"]!.exactRate >= ref["normalisation_exact"]! - 0.0001))
                checks.append(("normalisation PER ≤ \(ref["normalisation_per"]!)", scores["NORMALISATION"]!.perMean <= ref["normalisation_per"]! + 0.0001))
                print("  against the Python reference's scores:")
                for (name, ok) in checks {
                    print("    \(ok ? "✓" : "✗") \(name)")
                    failed = failed || !ok
                }
            }
        }

        print("\n== comparison sentences (reference pipeline vs Python) ==")
        for s in doc.sentences {
            for british in [false, true] {
                let out = p.raw[british]!.phonemize(s.text, unknown: "❓")
                let py = british ? s.python_gb : s.python_us
                let ok = out == py
                print("  \(ok ? "=" : "≠") \(british ? "GB" : "US") \(s.name)")
                if !ok {
                    print("      swift:  \(out)")
                    print("      python: \(py)")
                }
                if verbose {
                    print("      shipped: \(p.shipped[british]!.phonemize(s.text, unknown: "❓"))")
                }
            }
        }
        print("\n== custom lexicon cases (shipped configuration) ==")
        for c in doc.lexicon_cases {
            for (british, want) in [(false, c.us), (true, c.gb)] {
                guard let want else { continue }
                let out = p.shipped[british]!.phonemize(c.text, unknown: "❓")
                let ok = out.contains(want) && !(c.absent.map { out.contains($0) } ?? false)
                failed = failed || !ok
                print("  \(ok ? "✓" : "✗") \(british ? "GB" : "US") \(c.text) → /\(out)/\(ok ? "" : "  (want \(want)\(c.absent.map { ", not \($0)" } ?? ""))")")
            }
        }
        print(failed ? "\nFAILED" : "\nPASSED")
        return failed ? 1 : 0
    }
}
