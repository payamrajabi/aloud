import Foundation

/// Generates audio for a list of text chunks on a background queue, just in
/// time: only chunks inside the current window (the playhead plus a short
/// lookahead) are generated, in order. Every `begin` starts a new session;
/// results from older sessions are tagged so the player can ignore them.
final class Synthesizer {
    static let trace = CommandLine.arguments.contains("--trace")
    /// Called on the main queue: (session, chunk index, samples).
    var onReady: ((Int, Int, [Float]) -> Void)?
    /// Called on the main queue when the voice model can't be loaded.
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "readaloud.synth", qos: .userInteractive)
    private let lock = NSLock()
    private var session = 0
    private var texts: [String] = []
    private var claimed = Set<Int>()
    private var window = 0...0
    private var voice = Voice.default
    private var running = false
    private var engine: KokoroEngine?  // only touched on `queue`

    /// Loads the model (and the accent's pronunciation rules) ahead of time so the
    /// first read starts quickly.
    func preload(accent: Accent) {
        queue.async { self.ensureEngine()?.prepare(accent) }
    }

    @discardableResult
    func begin(texts: [String], voice: Voice, from index: Int) -> Int {
        lock.lock()
        session += 1
        self.texts = texts
        self.voice = voice
        claimed = []
        window = index...index
        let s = session
        lock.unlock()
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
        if changed { kick() }
    }

    func cancel() {
        lock.lock()
        session += 1
        texts = []
        claimed = []
        lock.unlock()
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
            let text = texts[index]
            let v = voice
            lock.unlock()

            guard let engine = ensureEngine() else {
                lock.lock()
                running = false
                lock.unlock()
                return
            }
            let t0 = Date()
            let samples = engine.generate(text, voice: v)
            if Synthesizer.trace {
                print(String(format: "   synth #%d: %.2fs audio in %.2fs (%d chars) at %.1f", index, Double(samples.count) / 24000, Date().timeIntervalSince(t0), text.count, Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100))); fflush(stdout)
            }
            DispatchQueue.main.async { self.onReady?(s, index, samples) }
        }
    }

    private func nextIndex() -> Int? {
        guard !texts.isEmpty, window.lowerBound < texts.count else { return nil }
        let end = min(window.upperBound, texts.count - 1)
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
