import Foundation
import NaturalLanguage

/// Picks how heteronyms are said ("read" as REED or RED, "bass" the fish or the guitar)
/// with the clean-up model (Qwen 3.5 4B), on top of Aloud's own grammar rules.
///
/// For each sentence holding a word from Lexicons/heteronyms.json, the model gets a
/// two-choice question ("1: BAYS, low sound. 2: BAS, the fish") and Aloud keeps its own
/// reading unless the model is at least `threshold` sure it's the other one, or Aloud's
/// reading is neither. The rules are good at grammar (record vs record), the model at
/// meaning (bass vs bass), so together they beat either one (FIN-940).
///
/// It runs ahead of the voice on its own queue. When an answer isn't ready by the time a
/// sentence has to be spoken, the sentence is read with the rules: it never holds up
/// playback. It shares the model's weights with dictation clean-up (`LlamaModel`) and lets
/// go of them after the same idle time.
final class HeteronymReferee {
    static let shared = HeteronymReferee()

    /// How sure the model must be to overrule Aloud's reading. Chosen on
    /// Vendor/heteronym-test/testset.json; heldout.json checks it.
    static let threshold = 0.7

    struct Readings {
        let us: [String]
        let gb: [String]
        let say: [String]
        let means: [String]
    }

    /// The model's answer for one occurrence of a word in a text.
    struct Answer {
        let range: NSRange   // UTF-16, in the text that was asked about
        let word: String     // as written ("Close")
        let choice: Int      // 1 or 2
        let confidence: Double
    }

    /// One chunk to ask about, with the whole sentence around it: the player splits long
    /// sentences ("…he joked about tying" / "a bow around his neck…"), and the model needs
    /// all of it. `context` holds `text` at `offset` (UTF-16).
    struct Query: Hashable {
        let text: String
        let context: String
        let offset: Int
    }

    /// A query for each chunk: a chunk that doesn't end its sentence is joined to the next
    /// when that one carries on in lower case (up to four chunks each way).
    static func queries(for texts: [String]) -> [Query] {
        func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        func carriesOn(_ i: Int) -> Bool {
            guard i + 1 < texts.count else { return false }
            let a = trimmed(texts[i]).trimmingCharacters(in: CharacterSet(charactersIn: "\"”’')]"))
            guard let last = a.last, !".!?…:;".contains(last), let first = trimmed(texts[i + 1]).first else { return false }
            return first.isLowercase || first.isNumber
        }
        return texts.indices.map { i in
            var a = i, b = i
            while a > 0, i - a < 4, carriesOn(a - 1) { a -= 1 }
            while b < texts.count - 1, b - i < 4, carriesOn(b) { b += 1 }
            let before = texts[a..<i].map(trimmed).joined(separator: " ")
            let after = texts[(i + 1)..<(b + 1)].map(trimmed).joined(separator: " ")
            let context = [before, texts[i], after].filter { !$0.isEmpty }.joined(separator: " ")
            return Query(text: texts[i], context: context, offset: before.isEmpty ? 0 : (before as NSString).length + 1)
        }
    }

    /// Settings → "Use it to pick how words like read, lead and bass are said".
    static let enabledKey = "pickHeteronymsWithModel"

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// On, the model downloaded, and enough memory to hold it while reading.
    static var isAvailable: Bool {
        isEnabled && TranscriptCleaner.isInstalled && TranscriptCleaner.hasRecommendedMemory
    }

    // MARK: - The table

    static let table: [String: Readings] = {
        for dir in LexiconFiles.appDirectories {
            let url = dir.appendingPathComponent("heteronyms.json")
            guard let data = try? Data(contentsOf: url),
                  let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let words = doc["words"] as? [String: [String: [String]]] else { continue }
            var table: [String: Readings] = [:]
            for (word, r) in words {
                guard let us = r["us"], let gb = r["gb"], let say = r["say"], let means = r["means"],
                      [us, gb, say, means].allSatisfy({ $0.count == 2 }) else { continue }
                table[word] = Readings(us: us, gb: gb, say: say, means: means)
            }
            return table
        }
        return [:]
    }()

    private static let wordPattern = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}'’])\p{L}+(?![\p{L}\p{N}])"#)
    /// Links and pins ("[read](+1)", "[Kokoro](/kˈOkəɹO/)"): their words are left alone.
    private static let linkPattern = try! NSRegularExpression(pattern: #"!?\[[^\]]*\]\([^)]*\)"#)

    /// The table's words in `text`, in order, outside links and pins.
    static func occurrences(in text: String) -> [(range: NSRange, word: String)] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let links = linkPattern.matches(in: text, range: all).map(\.range)
        return wordPattern.matches(in: text, range: all).compactMap { m in
            let word = ns.substring(with: m.range)
            guard table[word.lowercased()] != nil, !links.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) else { return nil }
            return (m.range, word)
        }
    }

    static func mentions(_ text: String) -> Bool { !occurrences(in: text).isEmpty }

    // MARK: - Pinning

    /// `text` with the model's readings pinned ("[read](/ɹˈɛd/)") where it overrules Aloud.
    /// `explained` is the phonemizer's word-by-word reading of `text` (`Phonemizer.explain`),
    /// which says what Aloud would say for each occurrence.
    static func pin(_ text: String, answers: [Answer], explained: [(word: String, phonemes: String, source: String)],
                    british: Bool) -> (text: String, pinned: Int) {
        guard !answers.isEmpty else { return (text, 0) }
        // Aloud's reading of each occurrence: the phonemizer's words of that spelling, in
        // order. A word whose count doesn't match the text's (a rule rewrote it) is left alone.
        var aloud: [Int: Int] = [:]  // answer index → 1, 2 or 0 (neither)
        let byWord = Dictionary(grouping: answers.indices, by: { answers[$0].word.lowercased() })
        for (word, indices) in byWord {
            let said = explained.filter { $0.word.lowercased() == word }.map(\.phonemes)
            guard said.count == indices.count, let r = table[word] else { continue }
            for (i, ps) in zip(indices, said) { aloud[i] = pick(ps, among: british ? r.gb : r.us) }
        }
        var out = text as NSString
        var pinned = 0
        for i in answers.indices.reversed() {
            let a = answers[i]
            guard let mine = aloud[i], let r = table[a.word.lowercased()] else { continue }
            let overrule = mine == 0 || (a.choice != mine && a.confidence >= threshold)
            guard overrule, mine != a.choice else { continue }
            let ps = (british ? r.gb : r.us)[a.choice - 1]
            out = out.replacingCharacters(in: a.range, with: "[\(a.word)](/\(ps)/)") as NSString
            pinned += 1
        }
        return (out as String, pinned)
    }

    /// Which of two readings `phonemes` is: compared without secondary stress, then without
    /// any stress. 0 when it's neither (or both).
    static func pick(_ phonemes: String, among readings: [String]) -> Int {
        for strip in [false, true] {
            func f(_ s: String) -> String {
                s.filter { $0 != "ˌ" && (!strip || $0 != "ˈ") }
            }
            let p = f(phonemes)
            let a = p == f(readings[0]), b = p == f(readings[1])
            if a != b { return a ? 1 : 2 }
        }
        return 0
    }

    // MARK: - Asking

    static let system = "You help a text-to-speech voice read English aloud. For the word marked with ** **, "
        + "decide which pronunciation a careful native speaker would use in this exact sentence."
    /// The opening every question shares, remembered by the engine. It ends on a special
    /// token and a newline, so the question's own text is split into tokens as it would be whole.
    static let promptPrefix = "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n"

    /// The question for one occurrence, as in Vendor/heteronym-test/llm_pick_v3.py: the
    /// sentence alone (no context), and which occurrence is meant when the word repeats.
    static func prompt(sentence: String, range: NSRange) -> String {
        let ns = sentence as NSString
        let word = ns.substring(with: range)
        let r = table[word.lowercased()]!
        let marked = ns.substring(to: range.location) + "**" + word + "**" + ns.substring(from: NSMaxRange(range))
        let same = occurrences(in: sentence).filter { $0.word.lowercased() == word.lowercased() }
        var which = ""
        if same.count > 1, let n = same.firstIndex(where: { $0.range.location == range.location }) {
            which = " (\"\(word)\" appears \(same.count) times in this sentence, possibly with different meanings; "
                + "answer only for occurrence number \(n + 1), the one marked ** **)"
        }
        return promptPrefix + "Sentence: \(marked)\n\nHow is **\(word)** pronounced here\(which)?\n"
            + "1: \(r.say[0]) (\(r.means[0]))\n2: \(r.say[1]) (\(r.means[1]))\n\nAnswer 1 or 2."
            + "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    /// The sentences of `text`, each with where it starts (UTF-16).
    static func sentences(_ text: String) -> [(range: NSRange, text: String)] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).map { r in
            let sentence = String(text[r])
            let trimmed = String(sentence.reversed().drop(while: \.isWhitespace).reversed())
            return (NSRange(location: NSRange(r, in: text).location, length: (trimmed as NSString).length), trimmed)
        }
    }

    private let queue = DispatchQueue(label: "readaloud.referee", qos: .userInitiated)
    private let trace = DebugScript.args.contains("--trace")

    // Queue only.
    private var engine: LlamaEngine?
    private var failed = false
    private var unloadTimer: DispatchWorkItem?
    /// Time spent on the last load, for the test report.
    private(set) var loadSeconds: Double?
    private(set) var questionSeconds: [Double] = []

    // Guarded by `lock`.
    private let lock = NSCondition()
    private var session = 0
    private var queries: [Query] = []
    private var window = 0...0
    private var answers: [Query: [Answer]] = [:]  // a voice change asks nothing again
    private var running = false

    /// Answers for a chunk now, on the calling thread's behalf (blocks while the model loads
    /// and answers). Nil if the model can't run.
    func answersNow(for query: Query) -> [Answer]? {
        queue.sync { ask(query) }
    }

    /// A new list of chunks to read, starting at `index`: answers are worked out ahead.
    func begin(_ queries: [Query], from index: Int, session s: Int) {
        guard Self.isAvailable else { return }
        lock.lock()
        session = s
        self.queries = queries
        window = index...index
        if answers.count > 2_000 { answers = [:] }
        lock.unlock()
        kick()
    }

    /// The chunks to have answers for, from the one playing on.
    func setWindow(_ range: ClosedRange<Int>) {
        lock.lock()
        window = range
        lock.unlock()
        kick()
    }

    func cancel() {
        lock.lock()
        session += 1
        queries = []
        lock.unlock()
    }

    /// The answers for a chunk if they're ready, waiting up to `wait` seconds for them.
    func answers(for query: Query, session s: Int, waitingUpTo wait: TimeInterval) -> [Answer]? {
        let deadline = Date().addingTimeInterval(max(0, wait))
        lock.lock()
        defer { lock.unlock() }
        while answers[query] == nil, s == session, running, lock.wait(until: deadline) {}
        return answers[query]
    }

    private func kick() {
        lock.lock()
        defer { lock.unlock() }
        guard !running, nextQuery() != nil else { return }
        running = true
        queue.async { self.run() }
    }

    /// The first chunk in the window, plus a few after it, that has no answers yet.
    private func nextQuery() -> Query? {
        guard !queries.isEmpty, window.lowerBound < queries.count else { return nil }
        let end = min(window.upperBound + 3, queries.count - 1)
        for i in window.lowerBound...end where answers[queries[i]] == nil { return queries[i] }
        return nil
    }

    private func run() {
        while true {
            lock.lock()
            guard let query = nextQuery() else {
                running = false
                lock.broadcast()
                lock.unlock()
                scheduleUnload()
                return
            }
            lock.unlock()
            let result = Self.mentions(query.text) ? ask(query) : []
            lock.lock()
            answers[query] = result ?? []  // the model failed: the rules read it
            lock.broadcast()
            lock.unlock()
            if result == nil {
                lock.lock()
                running = false
                lock.unlock()
                return
            }
        }
    }

    /// The answer for every occurrence in the chunk, each asked with its whole sentence.
    /// Ranges are in `query.text`. On the queue.
    private func ask(_ query: Query) -> [Answer]? {
        let span = NSRange(location: query.offset, length: (query.text as NSString).length)
        let found = Self.occurrences(in: query.context).filter { NSLocationInRange($0.range.location, span) }
        guard !found.isEmpty else { return [] }
        guard let engine = loadEngine() else { return nil }
        unloadTimer?.cancel()
        var out: [Answer] = []
        for sentence in Self.sentences(query.context) {
            for (range, word) in found where NSLocationInRange(range.location, sentence.range) {
                let local = NSRange(location: range.location - sentence.range.location, length: range.length)
                let prompt = Self.prompt(sentence: sentence.text, range: local)
                let t0 = Date()
                guard let p = engine.choose(prompt: prompt, among: ["1", "2"]) else { return nil }
                questionSeconds.append(Date().timeIntervalSince(t0))
                let choice = p[0] >= p[1] ? 1 : 2
                out.append(Answer(range: NSRange(location: range.location - query.offset, length: range.length),
                                  word: word, choice: choice, confidence: max(p[0], p[1])))
                if trace {
                    print(String(format: "   referee: %@ → %d (%.2f) in %.2fs", word, choice, max(p[0], p[1]), Date().timeIntervalSince(t0)))
                    fflush(stdout)
                }
            }
        }
        return out
    }

    private func loadEngine() -> LlamaEngine? {
        if let engine { return engine }
        guard !failed, TranscriptCleaner.isInstalled else { return nil }
        let t0 = Date()
        do {
            // Questions are short: a small context beside clean-up's, on the same weights.
            let engine = try LlamaEngine(path: TranscriptCleaner.modelPath.path, contextLength: 1024)
            guard engine.remember(prefix: Self.promptPrefix) else { throw LlamaEngine.LoadError() }
            self.engine = engine
            loadSeconds = Date().timeIntervalSince(t0)
            if trace { print(String(format: "   referee: model ready in %.2fs", loadSeconds!)); fflush(stdout) }
        } catch {
            failed = true  // read with the rules until the model changes (Settings) or the app restarts
            if trace { print("   referee: model failed to load: \(error.localizedDescription)"); fflush(stdout) }
        }
        return engine
    }

    /// Called on the queue.
    private func scheduleUnload() {
        unloadTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.engine = nil }
        unloadTimer = item
        queue.asyncAfter(deadline: .now() + TranscriptCleaner.idleUnload, execute: item)
    }

    /// Frees the model now (Settings → Remove, or the switch turned off).
    func unload() {
        cancel()
        queue.async {
            self.unloadTimer?.cancel()
            self.engine = nil
            self.failed = false
        }
    }

    /// Frees the model and waits until it's gone. Call before the app quits: Metal aborts at
    /// exit if the model's buffers are still alive.
    func shutDown() {
        cancel()
        queue.sync {
            unloadTimer?.cancel()
            engine = nil
        }
    }
}
