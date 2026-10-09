import Foundation
import Phonemizer

/// `--bench-lexicon [lexicon.json] [--article file.txt]`: how long the custom lexicon
/// takes to load, to mark text for reading and to fix dictation at full size. Without a file it makes up a
/// 10,000-entry lexicon in the new schema (spoken variants and all), so the numbers
/// can be checked before the real list exists. Times are this thread's CPU time, so a
/// busy Mac doesn't inflate them.
enum LexiconBench {
    static func run(path: String?, articlePath: String?) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("aloud-lexicon-bench-\(getpid())")
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tech-lexicon.json")
        if let path {
            try? fm.copyItem(at: URL(fileURLWithPath: path), to: file)
        } else {
            let entries = synthetic(count: 10_000)
            let data = try! JSONSerialization.data(withJSONObject: entries)
            try! data.write(to: file)
            print("synthetic lexicon: \(entries.count) entries, \(data.count / 1024) KB")
        }
        // The other lists (Irish names, field packs) ship alongside, as in the app; `--packs`
        // switches packs on as it does elsewhere.
        if let app = LexiconFiles.appDirectories.first, let names = try? fm.contentsOfDirectory(atPath: app.path) {
            for name in names where name.hasSuffix(".json") && name != file.lastPathComponent {
                try? fm.copyItem(at: app.appendingPathComponent(name), to: dir.appendingPathComponent(name))
            }
        }
        let packs = LexiconFiles.packs

        let article = articlePath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? sampleArticle
        let sentences = TextPrep.legacyChunks(for: TextPrep.clean(article)).map(\.speech)
        let words = article.split { $0.isWhitespace }.count

        // Loading: read the files, then index them for reading (best of 5, so the file
        // cache is warm).
        var parse: [Double] = [], index: [Double] = []
        var set = LexiconSet()
        var lexicon = CustomLexicon()
        for _ in 0..<5 {
            var t0 = now()
            set = LexiconSet(directories: [dir])
            parse.append(now() - t0)
            t0 = now()
            lexicon = CustomLexicon(set, packs: packs)
            lexicon.prepare()
            index.append(now() - t0)
        }
        print(String(format: "load: %d entries; reading the files %.1f ms, indexing them %.1f ms: %.1f ms in all (best of 5; worst %.1f ms)",
                     lexicon.count, 1000 * parse.min()!, 1000 * index.min()!, 1000 * (parse.min()! + index.min()!),
                     1000 * zip(parse, index).map(+).max()!))
        if !packs.enabled.isEmpty { print("packs on: \(packs.enabled.sorted().joined(separator: ", "))") }
        for p in lexicon.problems.prefix(5) { print("  problem: \(p)") }

        // Marking: the custom tier on its own, sentence by sentence.
        var markTimes: [Double] = []
        let started = Date()
        rounds: for _ in 0..<5 {
            for s in sentences {
                let t0 = now()
                _ = lexicon.mark(s, british: false)
                markTimes.append(now() - t0)
                if Date().timeIntervalSince(started) > 30 { break rounds }   // a slow lexicon: a sample is enough
            }
        }
        let markMean = markTimes.reduce(0, +) / Double(markTimes.count)
        print(String(format: "custom tier: %d sentences (%d words), mean %.3f ms, worst %.3f ms per sentence (%d timed)",
                     sentences.count, words, 1000 * markMean, 1000 * markTimes.max()!, markTimes.count))
        if Date().timeIntervalSince(started) > 30 { return 0 }

        // Dictation: build the reverse index, then fix about 200 words of the article
        // with some spoken variants mixed in.
        var builds: [Double] = []
        var corrector = DictationCorrector(LexiconSet())
        for _ in 0..<5 {
            let t0 = now()
            corrector = DictationCorrector(set, packs: packs)
            builds.append(now() - t0)
        }
        var rng = SplitMix(state: 3)
        let spoken = set.entries.filter { !$0.spoken.isEmpty }
        var dictation = article.split { $0.isWhitespace }.prefix(190).map(String.init)
        for _ in 0..<10 where !spoken.isEmpty {
            dictation.insert(rng.pick(rng.pick(spoken).spoken), at: rng.int(dictation.count))
        }
        let text = dictation.joined(separator: " ")
        var fixTimes: [Double] = []
        var result = corrector.analyze(text)
        for _ in 0..<50 {
            let t0 = now()
            result = corrector.analyze(text)
            fixTimes.append(now() - t0)
        }
        print(String(format: "dictation: index of %d forms (%d spoken variants) built in %.1f ms; a %d-word dictation fixed in %.3f ms (worst %.3f ms), %d changes",
                     corrector.formCount, corrector.variantCount, 1000 * builds.min()!, text.split(separator: " ").count,
                     1000 * fixTimes.reduce(0, +) / Double(fixTimes.count), 1000 * fixTimes.max()!, result.changes.filter(\.applied).count))

        // The whole phonemizer, with and without the custom tier.
        guard let data = try? G2PData.load(from: G2PData.defaultDirectory()) else {
            print("pronunciation data missing; skipped the full phonemizer timing")
            return 0
        }
        let with = Phonemizer(british: false, data: data, custom: lexicon)
        let without = Phonemizer(british: false, data: data, custom: nil)
        for s in sentences { _ = with.phonemize(s); _ = without.phonemize(s) }   // warm caches
        func total(_ p: Phonemizer) -> Double {
            let t0 = now()
            for _ in 0..<3 { for s in sentences { _ = p.phonemize(s) } }
            return (now() - t0) / 3
        }
        let a = total(with), b = total(without)
        print(String(format: "phonemize the article: %.1f ms with the lexicon, %.1f ms without (%.2f ms extra per sentence)",
                     1000 * a, 1000 * b, 1000 * (a - b) / Double(max(1, sentences.count))))
        return 0
    }

    /// CPU seconds used by this thread.
    static func now() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    // MARK: - A made-up lexicon

    /// Deterministic pseudo-random numbers, so every run benchmarks the same list.
    struct SplitMix {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
        mutating func chance(_ p: Double) -> Bool { Double(next() % 10_000) / 10_000 < p }
    }

    static func synthetic(count: Int) -> [[String: Any]] {
        var rng = SplitMix(state: 42)
        let onsets = ["b", "br", "c", "ch", "cl", "d", "dr", "f", "fl", "g", "gr", "h", "j", "k", "kr", "l", "m", "n", "p", "pl",
                      "pr", "qu", "r", "s", "sc", "sh", "sk", "sl", "sp", "st", "t", "th", "tr", "v", "w", "z", ""]
        let vowels = ["a", "e", "i", "o", "u", "ai", "ea", "oo", "y", "io"]
        let codas = ["", "", "n", "r", "s", "x", "t", "l", "m", "ck", "nd", "st"]
        // Ordinary words the real list marks as context-only variants ("view" → Vue).
        let ordinary = ["view", "next", "notion", "linear", "slack", "rust", "swift", "go", "jason", "ruby", "stripe", "spark",
                        "flow", "base", "cloud", "bolt", "mint", "pulse", "beam", "forge", "pilot", "atlas", "nova", "echo"]
        func syllable() -> String { rng.pick(onsets) + rng.pick(vowels) + rng.pick(codas) }
        func stem() -> [String] { (0..<(2 + rng.int(3))).map { _ in syllable() } }
        var seen = Set<String>()
        var out: [[String: Any]] = []
        while out.count < count {
            let parts = stem()
            let joined = parts.joined()
            var word: String
            switch rng.int(20) {
            case 0..<9: word = joined.prefix(1).uppercased() + joined.dropFirst()
            case 9..<12: word = String(joined.prefix(2 + rng.int(3))).uppercased()
            case 12..<14: word = parts[0].prefix(1).uppercased() + parts[0].dropFirst() + parts[1...].joined().prefix(1).uppercased() + parts[1...].joined().dropFirst()
            case 14..<16: word = joined.prefix(1).uppercased() + joined.dropFirst() + rng.pick([".js", ".io", "DB", "-cli", " Cloud"])
            case 16..<18: word = (joined.prefix(1).uppercased() + joined.dropFirst()) + " " + (syllable() + syllable()).capitalized
            default: word = joined
            }
            guard seen.insert(word.lowercased()).inserted else { continue }
            let roll = rng.int(100)
            let match = roll < 70 ? "case-insensitive" : roll < 95 ? "case-sensitive" : "exact"
            var e: [String: Any] = ["word": word, "match": match, "us": parts.map { _ in rng.pick(["kˈæ", "bəɹ", "nˈɛ", "Tiz", "ɡˈɪt", "hˌʌb", "sˈu", "pə"]) }.joined()]
            if rng.chance(0.5) { e["gb"] = (e["us"] as! String).replacingOccurrences(of: "æ", with: "a") }
            let mode = rng.int(100)
            e["dictation"] = mode < 50 ? "always" : mode < 85 ? "context" : "never"
            if mode < 85 {
                var spoken = [parts.joined(separator: " ")]
                if parts.count > 2 { spoken.append(parts[0] + " " + parts[1...].joined()) }
                if rng.chance(0.4) { spoken.append(parts.map { String($0.reversed()) }.joined(separator: " ")) }
                if mode >= 50, rng.chance(0.1) {
                    let w = rng.pick(ordinary)
                    spoken.append(w)
                    e["spoken_context_only"] = [w]
                }
                e["spoken"] = spoken
            }
            out.append(e)
        }
        return out
    }

    /// About 300 words of the kind of article Aloud reads.
    static let sampleArticle = """
    Last quarter we moved our whole platform onto Kubernetes, and the migration taught us more than we expected. \
    The old setup was a handful of virtual machines behind nginx, deployed by a shell script that only two people \
    understood. Every release meant a 1:1 call between them and a long checklist in Notion. Our database, PostgreSQL 14, \
    lived on its own server, and the front end was a Next.js app that we built on a laptop and copied up by hand.

    We started small. First we wrote Dockerfiles for each service and pushed the images to GitHub's container registry. \
    Then we described every deployment in YAML and checked it into the same repository as the code, so a pull request \
    could change both at once. Running kubectl apply against a staging cluster became the new release process, and \
    within a week nobody missed the checklist.

    The database was the hard part. We tried running PostgreSQL inside the cluster, but backups and failover were \
    harder to get right than we wanted, so we moved it to a managed service instead. Connection pooling with PgBouncer \
    fixed the spikes we saw whenever the API scaled up during a busy afternoon. Our Grafana dashboards now show \
    request latency, error rates and queue depth on one screen, and the on-call engineer gets a page only when \
    something users would notice goes wrong.

    Costs went down by about a fifth. Most of the savings came from packing small services onto fewer nodes and \
    turning off the staging cluster at night. The bigger win was confidence: a new engineer shipped a change to \
    production on her second day, reviewed it on GitHub, watched it roll out, and rolled it back in under a minute \
    when a test caught a typo. That would have taken an afternoon before. Next year we want to move the remaining \
    cron jobs into the cluster and finally retire the last of the old machines.
    """
}
