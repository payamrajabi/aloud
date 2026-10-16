import Foundation

/// Generates audio for a list of text chunks on a background queue, just in
/// time: only chunks inside the current window (the playhead plus a short
/// lookahead) are generated, in order. Every `begin` starts a new session;
/// results from older sessions are tagged so the player can ignore them.
final class Synthesizer {
    static let trace = CommandLine.arguments.contains("--trace")
    /// Called on the main queue: (session, chunk index, samples), with nil samples when the
    /// chunk has nothing the voice can say (letters in another script, say).
    var onReady: ((Int, Int, [Float]?) -> Void)?
    /// Called on the main queue when the voice model can't be loaded.
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "readaloud.synth", qos: .userInteractive)
    private let lock = NSLock()
    private var session = 0
    private var chunks: [Chunk] = []
    private var claimed = Set<Int>()
    private var window = 0...0
    private var voice = Voice.default
    private var running = false
    private var engine: KokoroEngine?  // only touched on `queue`
    private var seconds: [Int: Double] = [:]  // how long each generated chunk of this session lasts
    private let referee = HeteronymReferee.shared
    private var queries: [HeteronymReferee.Query] = []

    /// Loads the model (and the accent's pronunciation rules) ahead of time so the
    /// first read starts quickly.
    func preload(accent: Accent) {
        queue.async { self.ensureEngine()?.prepare(accent) }
    }

    /// Each chunk is said at its own speed (slower for headings and quotes).
    @discardableResult
    func begin(_ chunks: [Chunk], voice: Voice, from index: Int) -> Int {
        lock.lock()
        session += 1
        self.chunks = chunks
        self.voice = voice
        claimed = []
        seconds = [:]
        queries = HeteronymReferee.isAvailable ? HeteronymReferee.queries(for: chunks.map(\.speech)) : []
        window = index...index
        let s = session
        let queries = self.queries
        lock.unlock()
        referee.begin(queries, from: index, session: s)
        kick()
        return s
    }

    /// Sets which chunks should exist: generation runs from the start of the
    /// window to its end, then idles until the window moves.
    func setWindow(_ range: ClosedRange<Int>) {
        lock.lock()
        let changed = range != window
        window = range
        lock.unlock()
        if changed {
            referee.setWindow(range)
            kick()
        }
    }

    func cancel() {
        lock.lock()
        session += 1
        chunks = []
        claimed = []
        queries = []
        lock.unlock()
        referee.cancel()
    }

    private func kick() {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }
        running = true
        queue.async { self.run() }
    }

    private func run() {
        while true {
            lock.lock()
            guard let index = nextIndex() else {
                running = false
                lock.unlock()
                return
            }
            claimed.insert(index)
            let s = session
            let chunk = chunks[index]
            let v = voice
            let slack = slack(before: index)
            let query = index < queries.count ? queries[index] : nil
            lock.unlock()

            guard let engine = ensureEngine() else {
                lock.lock()
                running = false
                lock.unlock()
                return
            }
            let t0 = Date()
            let speech = query.map { refereed($0, session: s, accent: v.accent, slack: slack, engine: engine) } ?? chunk.speech
            let phonemes = engine.phonemes(speech, accent: v.accent)
            let samples = KokoroEngine.isSpeakable(phonemes) ? engine.generate(phonemes: phonemes, voice: v, speed: chunk.speed) : nil
            lock.lock()
            if s == session { seconds[index] = Double(samples?.count ?? 0) / Double(KokoroEngine.sampleRate) }
            lock.unlock()
            if Synthesizer.trace {
                print(String(format: "   synth #%d: %.2fs audio in %.2fs (%d chars, speed %.2f) at %.1f", index, Double(samples?.count ?? 0) / 24000, Date().timeIntervalSince(t0), chunk.speech.count, chunk.speed, Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100))); fflush(stdout)
            }
            DispatchQueue.main.async { self.onReady?(s, index, samples) }
        }
    }

    /// Audio already made that plays before chunk `index`, in seconds: how long the
    /// heteronym referee can be waited for without holding up playback. The chunk playing
    /// now counts for half, since it may be nearly done. Called with `lock` held.
    private func slack(before index: Int) -> Double {
        guard index > window.lowerBound else { return 0 }
        var total = 0.0
        for i in window.lowerBound..<index {
            guard let s = seconds[i] else { return total }
            total += i == window.lowerBound ? s / 2 : s
        }
        return total
    }

    /// `text` with the referee's readings pinned, if its answers are ready in time: it may
    /// wait out half the slack (played at up to twice the speed), less a second for making
    /// this chunk's audio, and never more than three seconds.
    private func refereed(_ query: HeteronymReferee.Query, session s: Int, accent: Accent, slack: Double, engine: KokoroEngine) -> String {
        let text = query.text
        guard HeteronymReferee.isAvailable, HeteronymReferee.mentions(text) else { return text }
        let wait = min(slack / 2 - 1, 3)
        guard let answers = referee.answers(for: query, session: s, waitingUpTo: wait) else {
            if Synthesizer.trace { print("   referee: not ready in time (slack \(String(format: "%.1f", slack))s), read with the rules"); fflush(stdout) }
            return text
        }
        let result = HeteronymReferee.pin(text, answers: answers, explained: engine.explain(text, accent: accent), british: accent == .british)
        if Synthesizer.trace, result.pinned > 0 { print("   referee: \(result.text)"); fflush(stdout) }
        return result.text
    }

    private func nextIndex() -> Int? {
        guard !chunks.isEmpty, window.lowerBound < chunks.count else { return nil }
        let end = min(window.upperBound, chunks.count - 1)
        for i in window.lowerBound...end where !claimed.contains(i) { return i }
        return nil
    }

    /// One engine serves every voice: the accent only changes the phonemizer.
    private func ensureEngine() -> KokoroEngine? {
        if let engine { return engine }
        do {
            engine = try KokoroEngine()
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { self.onError?(message) }
        }
        return engine
    }
}
