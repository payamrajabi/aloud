import Foundation

/// Transcribes a recording in the background while it's still going, so that
/// stopping only has to process the last few seconds.
///
/// Every couple of seconds `poll` looks at what's been recorded since the last
/// cut. Once there are 20–30 s, it cuts at the quietest moment in that window
/// (ideally a real pause between sentences) and hands that piece to Parakeet.
/// Pieces are transcribed in order on one serial queue; `finish` adds the
/// remainder and returns everything joined.
final class StreamingTranscriber {
    static let minChunk = 20 * ParakeetEngine.sampleRate
    static let maxChunk = 30 * ParakeetEngine.sampleRate
    /// RMS below this counts as a pause, so we can cut early without waiting for 30 s.
    static let pauseLevel: Float = 0.006

    private let queue: DispatchQueue
    private let engine: () -> ParakeetEngine?
    private let trace = DebugScript.args.contains("--trace")

    // Main thread only.
    private var session = 0
    private var committed = 0
    private var inFlight = false

    // Queue only.
    private var pieces: [String] = []
    private var queueSession = 0

    init(queue: DispatchQueue, engine: @escaping () -> ParakeetEngine?) {
        self.queue = queue
        self.engine = engine
    }

    /// Call when a recording starts (or is cancelled) to forget earlier pieces.
    func reset() {
        session += 1
        committed = 0
        inFlight = false
        let s = session
        queue.async {
            self.pieces = []
            self.queueSession = s
        }
    }

    /// Call periodically while recording. `available` is the number of samples
    /// recorded so far; `read` returns a copy of a range of them.
    func poll(available: Int, read: (Range<Int>) -> [Float]) {
        guard !inFlight else { return }
        let pending = available - committed
        guard pending >= Self.minChunk + ParakeetEngine.sampleRate / 2 else { return }

        // Look for the quietest 200 ms between 20 s and 30 s in (keeping half a
        // second of margin from the live edge, where a word may be in progress).
        let lo = committed + Self.minChunk
        let hi = min(committed + Self.maxChunk, available - ParakeetEngine.sampleRate / 2)
        let window = read(lo..<hi)
        let (offset, rms) = Self.quietest(window)
        // Before 30 s, only cut at a real pause; at 30 s, cut at the quietest point regardless.
        guard rms < Self.pauseLevel || pending >= Self.maxChunk + ParakeetEngine.sampleRate / 2 else { return }

        let cut = lo + offset
        let chunk = read(committed..<cut)
        committed = cut
        inFlight = true
        let s = session
        let trace = self.trace
        queue.async {
            guard s == self.queueSession else { return }
            let started = Date()
            let text = self.engine()?.transcribe(chunk) ?? ""
            self.pieces.append(text)
            if trace {
                print(String(format: "   streaming: %.1fs piece (cut at rms %.4f) transcribed in %.2fs: %@",
                             Double(chunk.count) / 16_000, rms, Date().timeIntervalSince(started), String(text.prefix(60))))
                fflush(stdout)
            }
            DispatchQueue.main.async {
                if s == self.session { self.inFlight = false }
            }
        }
    }

    /// Transcribes whatever hasn't been processed yet and returns the full text
    /// (on the main queue). Waits for any piece that's still being transcribed.
    func finish(all samples: [Float], completion: @escaping (_ text: String, _ tailSeconds: Double) -> Void) {
        let rest = committed < samples.count ? Array(samples[committed...]) : []
        let s = session
        queue.async {
            guard s == self.queueSession else { return }
            var parts = self.pieces
            if rest.count > ParakeetEngine.sampleRate / 5 {
                parts.append(self.engine()?.transcribe(rest) ?? "")
            }
            self.pieces = []
            let text = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            DispatchQueue.main.async { completion(text, Double(rest.count) / 16_000) }
        }
        session += 1  // anything still queued for this recording is now covered by `finish`
    }

    /// Offset and RMS of the quietest 200 ms frame, scanning in 100 ms steps.
    static func quietest(_ s: [Float]) -> (Int, Float) {
        let frame = ParakeetEngine.sampleRate / 5
        guard s.count > frame else { return (s.count, 0) }
        var best = 0
        var bestEnergy = Float.greatestFiniteMagnitude
        for i in stride(from: 0, to: s.count - frame, by: frame / 2) {
            var energy: Float = 0
            for j in i..<(i + frame) { energy += s[j] * s[j] }
            if energy < bestEnergy { bestEnergy = energy; best = i }
        }
        return (best + frame / 2, (bestEnergy / Float(frame)).squareRoot())
    }
}
