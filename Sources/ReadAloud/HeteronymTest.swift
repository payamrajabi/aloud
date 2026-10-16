import Foundation

/// How well heteronyms are read (`--heteronym-test Tests/heteronyms/heldout.json`): each
/// sentence goes through what the player does (narration chunks, the referee when the
/// clean-up model is downloaded, the phonemizer), with the US voice unless `--gb`, and the
/// reading of each marked word is checked against the answer key. `--rules-only` leaves the
/// referee out. `--out f.json` saves each sentence's phonemes for score.py.
/// `--with-cleanup` loads dictation clean-up first and keeps it tidying text while the
/// referee works, to check the two share one copy of the model's weights.
///
/// Two file formats, both from Vendor/heteronym-test: a list of {text, word, reading, ph1,
/// ph2} (testset.json, heldout.json), or of {text, gold: [[word, reading], …]} (the essay).
enum HeteronymTest {
    private struct Item: Decodable {
        let id: Int?
        let text: String
        let word: String?
        let reading: Int?
        let ph1: String?
        let ph2: String?
        let gold: [[Gold]]?
    }

    private enum Gold: Decodable {
        case word(String), reading(Int)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Int.self) { self = .reading(n) } else { self = .word(try c.decode(String.self)) }
        }
    }

    static func run(path: String, rulesOnly: Bool, british: Bool, withCleanup: Bool, out: String?, verbose: Bool) -> Int32 {
        let items: [Item]
        let engine: KokoroEngine
        do {
            items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            engine = try KokoroEngine()
        } catch {
            print("error: \(error)")
            return 1
        }
        let accent: Accent = british ? .british : .american
        engine.prepare(accent)
        let referee = HeteronymReferee.shared
        let refereeOn = !rulesOnly && HeteronymReferee.isAvailable
        if !rulesOnly && !refereeOn {
            print("the referee is off: the clean-up model isn't at \(TranscriptCleaner.modelPath.path), or the switch is off")
            return 1
        }
        let table = HeteronymReferee.table
        print("\(URL(fileURLWithPath: path).lastPathComponent): \(items.count) sentences, \(british ? "GB" : "US") voice, "
              + (refereeOn ? "rules + referee (overrules at \(HeteronymReferee.threshold))" : "rules only"))
        var cleaner: TranscriptCleaner?
        if withCleanup, refereeOn {
            cleaner = TranscriptCleaner()
            _ = cleaner?.reset()
            cleaner?.waitUntilIdle()
            print(String(format: "clean-up loaded: %.0f MB resident", memory().resident))
        }
        let memoryBefore = memory()
        var memoryLoaded: (footprint: Double, resident: Double)?

        var right = 0, total = 0, neither = 0, pinnedTotal = 0
        var wrong: [String] = []
        var added: [Double] = []
        var saved: [String: String] = [:]
        for (n, item) in items.enumerated() {
            let chunks = NarrationPlanner.plan(NarrationDoc.parse(item.text, format: .plain)).chunks
            let queries = HeteronymReferee.queries(for: chunks.map(\.speech))
            var phonemes: [String] = []
            for (chunk, query) in zip(chunks, queries) {
                var speech = chunk.speech
                if refereeOn, HeteronymReferee.mentions(speech) {
                    let t0 = Date()
                    if let answers = referee.answersNow(for: query) {
                        let r = HeteronymReferee.pin(speech, answers: answers, explained: engine.explain(speech, accent: accent), british: british)
                        speech = r.text
                        pinnedTotal += r.pinned
                    }
                    added.append(Date().timeIntervalSince(t0))
                    if memoryLoaded == nil, referee.loadSeconds != nil { memoryLoaded = memory() }
                }
                phonemes.append(engine.phonemes(speech, accent: accent))
            }
            // Clean-up tidies a piece on its own queue while the referee asks its questions.
            if let cleaner, n % 10 == 0 { cleaner.add("so um I think we should we should ship it on friday if the tests pass") }
            let ps = phonemes.joined(separator: " ")
            saved[String(item.id ?? n)] = ps
            if verbose { print("   \(item.text)\n      /\(ps)/") }

            if let word = item.word, let want = item.reading, let ph1 = item.ph1, let ph2 = item.ph2 {
                // As score.py: either reading anywhere in the sentence's phonemes.
                let got = pickAnywhere(ps, british ? table[word.lowercased()]?.gb ?? [ph1, ph2] : [ph1, ph2])
                total += 1
                if got == want { right += 1 } else { wrong.append("✗ \(word) want \(want) got \(got == 0 ? "?" : String(got)): \(item.text)") }
                if got == 0 { neither += 1 }
            } else if let gold = item.gold {
                // As score_essay.py: each marked word in turn, the next token that is either reading.
                let tokens = ps.split(separator: " ").map { clean(String($0)) }
                var k = 0
                for pair in gold {
                    guard case .word(let w)? = pair.first, case .reading(let want)? = pair.last, let r = table[w.lowercased()] else { continue }
                    var got = 0
                    for j in k..<max(k, tokens.count) {
                        got = HeteronymReferee.pick(tokens[j], among: british ? r.gb : r.us)
                        if got != 0 { k = j + 1; break }
                    }
                    total += 1
                    if got == want { right += 1 } else { wrong.append("✗ \(w) want \(want) got \(got == 0 ? "?" : String(got)): \(item.text.prefix(90))") }
                    if got == 0 { neither += 1 }
                }
            }
        }
        print(String(format: "%d/%d right (%.1f%%)", right, total, 100 * Double(right) / Double(max(total, 1))))
        for w in wrong { print("   " + w) }
        if neither > 0 { print("   (\(neither) read as neither reading)") }
        if refereeOn {
            let qs = referee.questionSeconds
            print(String(format: "referee: %d questions, %d readings pinned; model load %.2fs", qs.count, pinnedTotal, referee.loadSeconds ?? 0))
            if !qs.isEmpty {
                print(String(format: "   per question: average %.0f ms, slowest %.0f ms", 1000 * qs.reduce(0, +) / Double(qs.count), 1000 * (qs.max() ?? 0)))
            }
            // The first chunk also paid for loading the model; it's reported above.
            let perChunk = Array(added.dropFirst())
            if !perChunk.isEmpty {
                print(String(format: "   added per chunk with a heteronym (%d chunks, after the first): average %.0f ms, worst %.0f ms",
                             perChunk.count, 1000 * perChunk.reduce(0, +) / Double(perChunk.count), 1000 * (perChunk.max() ?? 0)))
            }
            let loaded = memoryLoaded ?? memory()
            print(String(format: "   memory (footprint / resident): %.0f / %.0f MB before the model, %.0f / %.0f MB with it loaded",
                         memoryBefore.footprint, memoryBefore.resident, loaded.footprint, loaded.resident))
            if let cleaner {
                cleaner.waitUntilIdle()
                print(String(format: "   with clean-up: %.0f MB resident at the end; weights loaded once: %@", memory().resident,
                             memoryLoaded.map { $0.resident - memoryBefore.resident < 1_000 } == true ? "yes" : "NO"))
                cleaner.shutDown()
            }
            referee.shutDown()
        }
        if let out {
            let data = try? JSONSerialization.data(withJSONObject: saved, options: [.prettyPrinted, .sortedKeys])
            FileManager.default.createFile(atPath: out, contents: data)
            print("wrote \(out)")
        }
        return 0
    }

    /// A phoneme token without punctuation, as score.py strips it.
    private static func clean(_ token: String) -> String {
        token.filter { $0.isLetter || $0.isNumber || $0 == "_" || "ˈˌᵊʤʧθðŋɹɜɑɔəɪʊæɛʌɡʃʒ".contains($0) }
    }

    private static func pickAnywhere(_ phonemes: String, _ readings: [String]) -> Int {
        let tokens = phonemes.split(separator: " ").map { clean(String($0)) }
        for strip in [false, true] {
            func f(_ s: String) -> String { s.filter { $0 != "ˌ" && (!strip || $0 != "ˈ") } }
            let set = Set(tokens.map(f))
            let a = set.contains(f(readings[0])), b = set.contains(f(readings[1]))
            if a != b { return a ? 1 : 2 }
        }
        return 0
    }

    /// This process's memory in MB: its footprint, as Activity Monitor shows it (the model's
    /// weights are mapped from the file, so they barely count), and what's resident.
    static func memory() -> (footprint: Double, resident: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        return (Double(info.phys_footprint) / 1_048_576, Double(info.resident_size) / 1_048_576)
    }
}
