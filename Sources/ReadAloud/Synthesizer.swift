import Foundation

/// Generates audio for a list of text chunks on a background queue.
/// Starts at a priority index and works forward, then fills in anything
/// earlier. Every `begin` starts a new session; results from older sessions
/// are tagged so the player can ignore them.
final class Synthesizer {
    static let trace = CommandLine.arguments.contains("--trace")
    /// Called on the main queue: (session, chunk index, samples).
    var onReady: ((Int, Int, [Float]) -> Void)?
    /// Called on the main queue when the voice model can't be loaded.
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "readaloud.synth", qos: .userInitiated)
    private let lock = NSLock()
    private var session = 0
    private var texts: [String] = []
    private var claimed = Set<Int>()
    private var priority = 0
    private var voice = Voice.default
    private var running = false
    private var engine: KokoroEngine?  // only touched on `queue`

    /// Loads the model ahead of time so the first read starts quickly.
    func preload(accent: Accent) {
        queue.async { _ = self.ensureEngine(accent) }
    }

    @discardableResult
    func begin(texts: [String], voice: Voice, from index: Int) -> Int {
        lock.lock()
        session += 1
        self.texts = texts
        self.voice = voice
        claimed = []
        priority = index
        let s = session
        lock.unlock()
        kick()
        return s
    }

    func prioritize(_ index: Int) {
        lock.lock()
        priority = index
        lock.unlock()
        kick()
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

            guard let engine = ensureEngine(v.accent) else {
                lock.lock()
                running = false
                lock.unlock()
                return
            }
            let t0 = Date()
            let samples = engine.generate(text, speaker: v.id)
            if Synthesizer.trace {
                print(String(format: "   synth #%d: %.2fs audio in %.2fs (%d chars) at %.1f", index, Double(samples.count) / 24000, Date().timeIntervalSince(t0), text.count, Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100))); fflush(stdout)
            }
            DispatchQueue.main.async { self.onReady?(s, index, samples) }
        }
    }

    private func nextIndex() -> Int? {
        guard !texts.isEmpty else { return nil }
        let start = min(priority, texts.count)
        for i in start..<texts.count where !claimed.contains(i) { return i }
        for i in 0..<start where !claimed.contains(i) { return i }
        return nil
    }

    private func ensureEngine(_ accent: Accent) -> KokoroEngine? {
        if let engine, engine.accent == accent { return engine }
        engine = nil
        do {
            engine = try KokoroEngine(accent: accent)
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { self.onError?(message) }
        }
        return engine
    }
}
