import Foundation
import Phonemizer

/// Checks for the dictation corrector (the lexicon in reverse).
///   --correct-dictation "text" [--lexicon file.json]    print the corrected text and why each change was (not) made
///   --test-dictation Tests/dictation/regression.json [--lexicon file.json] [--verbose]
/// The regression file names its own fixture lexicon; `--lexicon` swaps in another.
/// Ordinary speech in `must_not_change` is also checked against the app's own lists.
enum DictationTest {
    private struct Doc: Decodable {
        struct Case: Decodable {
            let `in`: String
            let out: String
        }
        let lexicon: String?
        let must_change: [Case]
        let must_not_change: [String]
    }

    static func corrector(lexicon: String?) -> DictationCorrector {
        guard let lexicon else { return DictationCorrector(LexiconFiles.shared) }
        let set = LexiconSet(files: [URL(fileURLWithPath: lexicon)])
        for p in set.problems { print("lexicon problem: \(p)") }
        return DictationCorrector(set)
    }

    static func correct(_ text: String?, lexicon: String?) -> Int32 {
        let c = corrector(lexicon: lexicon)
        let lines = text.map { [$0] } ?? Array(sequence(state: ()) { _ in readLine(strippingNewline: true) })
        for line in lines {
            let r = c.analyze(line)
            print(r.text)
            for change in r.changes {
                print("  \(change.applied ? "✓" : "·") \(change.original) → \(change.replacement)  (\(change.reason))")
            }
            if !r.changes.isEmpty { print("  tech context: \(r.hasTechContext ? "yes" : "no")") }
        }
        return 0
    }

    static func run(path: String, lexicon override: String?, verbose: Bool) -> Int32 {
        let url = URL(fileURLWithPath: path)
        let doc: Doc
        do {
            doc = try JSONDecoder().decode(Doc.self, from: Data(contentsOf: url))
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }
        let fixturePath = override ?? doc.lexicon.map { url.deletingLastPathComponent().appendingPathComponent($0).path }
        let fixture = corrector(lexicon: fixturePath)
        let shipped = corrector(lexicon: nil)
        print("fixture: \(fixturePath ?? "app lexicons"), \(fixture.formCount) forms; app lexicons: \(shipped.formCount) forms")
        var failures = 0

        print("\n== must change (\(doc.must_change.count)) ==")
        for c in doc.must_change {
            let r = fixture.analyze(c.in)
            let again = fixture.correct(r.text)
            let ok = r.text == c.out && again == r.text
            failures += ok ? 0 : 1
            if !ok || verbose {
                print("  \(ok ? "✓" : "✗") \(c.in)\n      → \(r.text)\(r.text == c.out ? "" : "\n      want \(c.out)")\(again == r.text ? "" : "\n      second pass changed it again: \(again)")")
                if !ok { for ch in r.changes { print("      \(ch.applied ? "✓" : "·") \(ch.original) → \(ch.replacement) (\(ch.reason))") } }
            }
        }

        print("\n== must not change (\(doc.must_not_change.count), with the fixture and with the app's lexicons) ==")
        for text in doc.must_not_change {
            for (name, c) in [("fixture", fixture), ("app", shipped)] {
                let r = c.analyze(text)
                let ok = r.text == text
                failures += ok ? 0 : 1
                if !ok || (verbose && name == "fixture") {
                    print("  \(ok ? "✓" : "✗") [\(name)] \(text)\(ok ? "" : "\n      → \(r.text)")")
                    if !ok { for ch in r.changes where ch.applied { print("      \(ch.original) → \(ch.replacement) (\(ch.reason))") } }
                }
            }
        }

        // What's typed vs what "Copy Last Dictation as Heard" keeps (the app's lexicons):
        // heard is always Parakeet's own words, before the clean-up model and the fixer.
        print("\n== typed and as heard ==")
        let heardCases: [(heard: String, tidied: String?, fix: Bool, typed: String)] = [
            ("push the fix to superbase", nil, true, "push the fix to Supabase"),
            ("um so send the jason payload to the API", "So send the jason payload to the API.", true, "So send the JSON payload to the API."),
            ("um so send the jason payload to the API", "So send the jason payload to the API.", false, "So send the jason payload to the API."),
            ("  log in with oh auth ", "", true, "log in with OAuth"),
            ("Jason went to the store", "Jason went to the store.", true, "Jason went to the store."),
        ]
        for c in heardCases {
            let r = DictationController.result(heard: c.heard, tidied: c.tidied, fixTerms: c.fix)
            let wantHeard = c.heard.trimmingCharacters(in: .whitespaces)
            let ok = r?.typed == c.typed && r?.heard == wantHeard
            failures += ok ? 0 : 1
            if !ok || verbose {
                print("  \(ok ? "✓" : "✗") heard \"\(c.heard)\", tidied \(c.tidied.map { "\"\($0)\"" } ?? "none")\(c.fix ? "" : ", fixer off")"
                      + "\n      typed \"\(r?.typed ?? "nil")\", as heard \"\(r?.heard ?? "nil")\"\(ok ? "" : "  (want typed \"\(c.typed)\", as heard \"\(wantHeard)\")")")
            }
        }
        failures += DictationController.result(heard: "  ", tidied: nil, fixTerms: true) == nil ? 0 : 1

        // Speed: a 200-word dictation made of the cases above.
        var words: [String] = []
        for c in doc.must_change + doc.must_not_change.map({ Doc.Case(in: $0, out: $0) }) {
            words += c.in.split(separator: " ").map(String.init)
            if words.count >= 200 { break }
        }
        let text = words.prefix(200).joined(separator: " ")
        var times: [Double] = []
        for _ in 0..<50 {
            let t0 = LexiconBench.now()
            _ = fixture.analyze(text)
            _ = shipped.analyze(text)
            times.append(LexiconBench.now() - t0)
        }
        print(String(format: "\n200-word dictation, fixture + app lexicons: %.3f ms (worst %.3f ms)",
                     1000 * times.reduce(0, +) / Double(times.count), 1000 * times.max()!))

        let total = doc.must_change.count + 2 * doc.must_not_change.count + heardCases.count + 1
        print(failures == 0 ? "\nPASSED (\(total) checks)" : "\nFAILED: \(failures) of \(total) checks")
        return failures == 0 ? 0 : 1
    }
}
