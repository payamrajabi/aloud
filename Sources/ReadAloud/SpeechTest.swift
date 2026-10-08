import Foundation
import Phonemizer

/// Reading tests written as plain words (`--speech-test Tests/g2p/core-readings.json`).
///
/// A speech case says how a person would read a sentence aloud, in words that need no
/// rule of their own ("It costs $4.99 CAD." → "It costs four ninety-nine Canadian."). It
/// passes when the shipped phonemizer gives the same phonemes for both, compared without
/// stress marks or punctuation, so a test never has to spell out phonemes by hand.
///
/// A frozen case is ordinary text that no rule should touch ("Plan A is fine."). Its
/// phonemes are stored as they were before a change, and it passes while they stay the
/// same. `--freeze` fills in the stored phonemes of frozen cases that have none.
///
/// Field packs: a case's `packs` says which are on for it (otherwise `--packs`, or none).
/// A file can bring its own lists: `lexicon_dirs` stand in for the app's folder and
/// `user_lexicon_dir` for yours (paths relative to the file). `not_says` passes when the
/// text reads anything but that, for a pack-only reading that must stay off.
enum SpeechTest {
    private struct Doc: Codable {
        var about: String?
        var lexicon_dirs: [String]?
        var user_lexicon_dir: String?
        var speech_cases: [SpeechCase]
        var frozen_cases: [FrozenCase]
    }

    private struct SpeechCase: Codable {
        let text: String
        /// What both voices say, unless `says_gb` gives the British reading.
        let says: String?
        let says_gb: String?
        /// What neither voice may say (instead of `says`).
        let not_says: String?
        /// "us" or "gb" to test one voice only; both by default.
        let voice: String?
        let packs: [String]?
        let area: String?
    }

    private struct FrozenCase: Codable {
        let text: String
        var us: String?
        var gb: String?
        let packs: [String]?
        let area: String?
    }

    /// Phonemes without stress, punctuation or extra spaces.
    static func loose(_ ps: String) -> String {
        let dropped = Set("ˈˌ.,;:!?—–…\"“”‘’()[]{}«»¡¿")
        let kept = ps.filter { !dropped.contains($0) }
        return kept.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func run(path: String, verbose: Bool, freeze: Bool) -> Int32 {
        let url = URL(fileURLWithPath: path)
        let data: G2PData
        var doc: Doc
        do {
            doc = try JSONDecoder().decode(Doc.self, from: Data(contentsOf: url))
            data = try G2PData.load(from: G2PData.defaultDirectory())
        } catch {
            print("error: \(error)")
            return 1
        }
        let base = url.deletingLastPathComponent()
        let set: LexiconSet
        if let dirs = doc.lexicon_dirs {
            set = DictationTest.lexiconSet(dirs.map { base.appendingPathComponent($0) },
                                           user: doc.user_lexicon_dir.map { base.appendingPathComponent($0) })
        } else {
            set = LexiconFiles.shared
            for p in set.problems { print("lexicon problem: \(p)") }
        }
        // The shipped phonemizer for each set of packs a case asks for.
        var made: [String: [Bool: Phonemizer]] = [:]
        func phonemizer(_ names: [String]?, british: Bool) -> Phonemizer {
            let packs = names.map { LexiconPacks($0) } ?? LexiconFiles.packs
            let key = packs.enabled.sorted().joined(separator: ",")
            if let p = made[key] { return p[british]! }
            let custom = CustomLexicon(set, packs: packs)
            let p = [false: Phonemizer(british: false, data: data, custom: custom), true: Phonemizer(british: true, data: data, custom: custom)]
            made[key] = p
            return p[british]!
        }
        func packsNote(_ packs: [String]?) -> String {
            packs.map { $0.isEmpty ? " [no packs]" : " [packs: \($0.joined(separator: ", "))]" } ?? ""
        }
        var failures: [String: Int] = [:]
        var total = 0, failed = 0

        for c in doc.speech_cases {
            for british in [false, true] {
                if let v = c.voice, v != (british ? "gb" : "us") { continue }
                let p = phonemizer(c.packs, british: british)
                guard let says = c.not_says ?? (british ? (c.says_gb ?? c.says) : c.says) else {
                    print("  ✗ \(c.text): the case needs says or not_says")
                    total += 1
                    failed += 1
                    continue
                }
                let got = p.phonemize(c.text, unknown: "❓")
                let want = p.phonemize(says, unknown: "❓")
                total += 1
                let ok = (loose(got) == loose(want)) != (c.not_says != nil)
                if !ok {
                    failed += 1
                    failures[c.area ?? "other", default: 0] += 1
                }
                if !ok || verbose {
                    print("  \(ok ? "✓" : "✗") [\(british ? "gb" : "us")] \(c.text)\(packsNote(c.packs))")
                    if !ok {
                        print("      \(c.not_says == nil ? "wanted:" : "not:   ") \(says)\n              \(want)\n      got:    \(got)")
                    }
                }
            }
        }

        var froze = 0
        for i in doc.frozen_cases.indices {
            for british in [false, true] {
                let got = phonemizer(doc.frozen_cases[i].packs, british: british).phonemize(doc.frozen_cases[i].text, unknown: "❓")
                let stored = british ? doc.frozen_cases[i].gb : doc.frozen_cases[i].us
                guard let stored else {
                    if freeze {
                        if british { doc.frozen_cases[i].gb = got } else { doc.frozen_cases[i].us = got }
                        froze += 1
                    }
                    continue
                }
                total += 1
                let ok = stored == got
                if !ok {
                    failed += 1
                    failures["frozen:" + (doc.frozen_cases[i].area ?? "other"), default: 0] += 1
                }
                if !ok || verbose {
                    print("  \(ok ? "✓" : "✗") [\(british ? "gb" : "us")] unchanged: \(doc.frozen_cases[i].text)")
                    if !ok { print("      was: \(stored)\n      now: \(got)") }
                }
            }
        }

        if froze > 0 {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            do {
                try enc.encode(doc).write(to: url)
                print("froze \(froze) readings into \(url.lastPathComponent)")
            } catch {
                print("error: couldn't write \(url.path): \(error)")
                return 1
            }
        }

        print("\n\(total - failed)/\(total) passed")
        for (area, n) in failures.sorted(by: { $0.key < $1.key }) { print("  \(area): \(n) failed") }
        print(failed == 0 ? "\nPASSED" : "\nFAILED")
        return failed == 0 ? 0 : 1
    }
}
