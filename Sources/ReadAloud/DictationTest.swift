import Foundation
import Phonemizer

/// Checks for the dictation corrector (the lexicon in reverse).
///   --correct-dictation "text" [--lexicon file.json] [--packs finance]   print the corrected text and why each change was (not) made
///   --test-dictation Tests/dictation/regression.json [--lexicon file.json] [--packs finance] [--verbose]
///   --test-tidy Tests/dictation/tidy.json [--verbose]   the clean-up model's rule-based fallback
/// The regression file names its own fixture lexicon; `--lexicon` swaps in another.
/// Ordinary speech in `must_not_change` is also checked against the app's own lists.
///
/// A file can instead name several fixture files or folders (`lexicons`, read in order,
/// each file its own pack) and a folder standing in for your own (`user_lexicon_dir`).
/// The packs that are on come from the case's `packs`, then the file's, then `--packs`.
enum DictationTest {
    private struct Doc: Decodable {
        struct Case: Decodable {
            let `in`: String
            let out: String
            let packs: [String]?
        }
        /// Text that must come out as it went in: a string, or {"in": text, "packs": [...]}.
        struct Unchanged: Decodable {
            let text: String
            let packs: [String]?

            private enum Keys: String, CodingKey { case `in`, packs }

            init(from decoder: Decoder) throws {
                if let text = try? decoder.singleValueContainer().decode(String.self) {
                    self.text = text
                    packs = nil
                    return
                }
                let c = try decoder.container(keyedBy: Keys.self)
                text = try c.decode(String.self, forKey: .in)
                packs = try c.decodeIfPresent([String].self, forKey: .packs)
            }
        }
        let lexicon: String?
        let lexicons: [String]?
        let user_lexicon_dir: String?
        let packs: [String]?
        let must_change: [Case]
        let must_not_change: [Unchanged]
    }

    static func corrector(lexicon: String?) -> DictationCorrector {
        let set = lexicon.map { lexiconSet([URL(fileURLWithPath: $0)]) } ?? LexiconFiles.shared
        return DictationCorrector(set, packs: LexiconFiles.packs)
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
            if !r.changes.isEmpty { print("  context: \(r.contextPacks.isEmpty ? "none" : r.contextPacks.joined(separator: ", "))") }
        }
        return 0
    }

    /// Lexicon files and folders, read in order (a folder's files sorted by name), then
    /// `user` as your own folder.
    static func lexiconSet(_ urls: [URL], user: URL? = nil) -> LexiconSet {
        var set = LexiconSet()
        for url in urls {
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
                set.load(directory: url)
            } else {
                set.load(url)
            }
        }
        if let user { set.load(directory: user, pack: LexiconPacks.user) }
        for p in set.problems { print("lexicon problem: \(p)") }
        return set
    }

    static func run(path: String, lexicon override: String?, verbose: Bool) -> Int32 {
        let url = URL(fileURLWithPath: path)
        let doc: Doc
        do {
            doc = try JSONDecoder().decode(Doc.self, from: Data(contentsOf: url))
        } catch {
            print("error: \(error)")
            return 1
        }
        let base = url.deletingLastPathComponent()
        let fixturePaths = override.map { [URL(fileURLWithPath: $0)] }
            ?? (doc.lexicons ?? doc.lexicon.map { [$0] })?.map { base.appendingPathComponent($0) }
        let fixtureSet = fixturePaths.map {
            lexiconSet($0, user: override == nil ? doc.user_lexicon_dir.map { base.appendingPathComponent($0) } : nil)
        }
        let defaultPacks = doc.packs.map { LexiconPacks($0) } ?? LexiconFiles.packs
        // One corrector per list and set of packs.
        var built: [String: DictationCorrector] = [:]
        func corrector(app: Bool, packs names: [String]?) -> DictationCorrector {
            let packs = names.map { LexiconPacks($0) } ?? defaultPacks
            let key = "\(app ? "app" : "fixture"):\(packs.enabled.sorted().joined(separator: ","))"
            if let c = built[key] { return c }
            let c = DictationCorrector(app ? LexiconFiles.shared : (fixtureSet ?? LexiconFiles.shared), packs: packs)
            built[key] = c
            return c
        }
        let fixture = corrector(app: false, packs: nil)
        let shipped = corrector(app: true, packs: nil)
        print("fixture: \(fixturePaths?.map(\.path).joined(separator: ", ") ?? "app lexicons"), \(fixture.formCount) forms; app lexicons: \(shipped.formCount) forms"
              + (defaultPacks.enabled.isEmpty ? "" : "; packs on: \(defaultPacks.enabled.sorted().joined(separator: ", "))"))
        var failures = 0
        func packsNote(_ packs: [String]?) -> String {
            packs.map { $0.isEmpty ? "  [no packs]" : "  [packs: \($0.joined(separator: ", "))]" } ?? ""
        }

        print("\n== must change (\(doc.must_change.count)) ==")
        for c in doc.must_change {
            let fixture = corrector(app: false, packs: c.packs)
            let r = fixture.analyze(c.in)
            let again = fixture.correct(r.text)
            let ok = r.text == c.out && again == r.text
            failures += ok ? 0 : 1
            if !ok || verbose {
                print("  \(ok ? "✓" : "✗") \(c.in)\(packsNote(c.packs))\n      → \(r.text)\(r.text == c.out ? "" : "\n      want \(c.out)")\(again == r.text ? "" : "\n      second pass changed it again: \(again)")")
                if !ok { for ch in r.changes { print("      \(ch.applied ? "✓" : "·") \(ch.original) → \(ch.replacement) (\(ch.reason))") } }
            }
        }

        print("\n== must not change (\(doc.must_not_change.count), with the fixture and with the app's lexicons) ==")
        for u in doc.must_not_change {
            for (name, app) in [("fixture", false), ("app", true)] {
                let r = corrector(app: app, packs: u.packs).analyze(u.text)
                let ok = r.text == u.text
                failures += ok ? 0 : 1
                if !ok || (verbose && name == "fixture") {
                    print("  \(ok ? "✓" : "✗") [\(name)] \(u.text)\(packsNote(u.packs))\(ok ? "" : "\n      → \(r.text)")")
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
        for text in doc.must_change.map(\.in) + doc.must_not_change.map(\.text) {
            words += text.split(separator: " ").map(String.init)
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

    // MARK: - Clean-up fallback

    private struct TidyDoc: Decodable {
        struct Case: Decodable {
            let `in`: String
            let out: String
        }
        let must_change: [Case]
        let must_not_change: [String]
        let faithful: [Case]?
        let unfaithful: [Case]?
    }

    /// The cleanup fallback and the lexical faithfulness guard for model output.
    ///   --test-tidy Tests/dictation/tidy.json [--verbose]
    /// Each output must also come out unchanged from a second pass.
    static func runTidy(path: String, verbose: Bool) -> Int32 {
        let doc: TidyDoc
        do {
            doc = try JSONDecoder().decode(TidyDoc.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            print("error: \(error)")
            return 1
        }
        var failures = 0
        func check(_ input: String, want: String) {
            let got = TranscriptCleaner.basicTidy(input)
            let again = TranscriptCleaner.basicTidy(got)
            let ok = got == want && again == got
            failures += ok ? 0 : 1
            if !ok || verbose {
                print("  \(ok ? "✓" : "✗") \(input.debugDescription)"
                      + (got == input ? "" : "\n      → \(got.debugDescription)")
                      + (got == want ? "" : "\n      want \(want.debugDescription)")
                      + (again == got ? "" : "\n      second pass changed it again: \(again.debugDescription)"))
            }
        }
        print("== must change (\(doc.must_change.count)) ==")
        for c in doc.must_change { check(c.in, want: c.out) }
        print("\n== must not change (\(doc.must_not_change.count)) ==")
        for text in doc.must_not_change { check(text, want: text) }

        func checkFaithfulness(_ cases: [TidyDoc.Case], wantFaithful: Bool) {
            for c in cases {
                let got = TranscriptCleaner.isFaithful(c.out, to: c.in)
                let ok = got == wantFaithful
                failures += ok ? 0 : 1
                if !ok || verbose {
                    print("  \(ok ? "✓" : "✗") \(c.in.debugDescription) → \(c.out.debugDescription)"
                          + "\n      expected \(wantFaithful ? "faithful" : "unfaithful"), got \(got ? "faithful" : "unfaithful")")
                }
            }
        }
        let faithful = doc.faithful ?? []
        let unfaithful = doc.unfaithful ?? []
        print("\n== faithfulness guard: accept (\(faithful.count)) ==")
        checkFaithfulness(faithful, wantFaithful: true)
        print("\n== faithfulness guard: reject (\(unfaithful.count)) ==")
        checkFaithfulness(unfaithful, wantFaithful: false)

        let stressInput = Array(repeating: "alpha beta", count: 5_000).joined(separator: " ")
        let stressStart = Date()
        let stressAccepted = TranscriptCleaner.isFaithful("Alpha beta", to: stressInput)
        let stressDuration = Date().timeIntervalSince(stressStart)
        let stressPassed = stressAccepted && stressDuration < 2
        failures += stressPassed ? 0 : 1
        print("\n== repeated-phrase stress (10,000 words) ==")
        print("  \(stressPassed ? "✓" : "✗") \(String(format: "%.3f", stressDuration))s, \(stressAccepted ? "accepted" : "rejected")")

        let total = doc.must_change.count + doc.must_not_change.count + faithful.count + unfaithful.count + 1
        print(failures == 0 ? "\nPASSED (\(total) checks)" : "\nFAILED: \(failures) of \(total) checks")
        return failures == 0 ? 0 : 1
    }
}
