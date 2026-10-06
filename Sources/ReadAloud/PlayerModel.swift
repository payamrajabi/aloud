import AVFoundation
import Combine
import Foundation

/// Owns a reading session: text, generated audio, playback position.
/// Used only from the main thread.
final class PlayerModel: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var chunkRanges: [NSRange] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var outputLevel: Float = 0   // loudness of the speech being played, 0…1
    @Published private(set) var generatedSpans: [ClosedRange<Double>] = []
    @Published private(set) var rate: Float
    @Published private(set) var voice: Voice
    @Published var message: String?

    private(set) var sourceText = ""
    var hasSession: Bool { !chunks.isEmpty }

    /// Called after play, pause, seek, speed and stop, so the system's
    /// Now Playing info (AirPods, media keys, Control Center) stays in sync.
    var onTransportChange: (() -> Void)?
    private var notifiedDuration: Double = 0

    /// A short title for Control Center: the opening words of the text.
    var title: String {
        guard let first = chunks.first?.speech else { return "Aloud" }
        return first.count > 70 ? String(first.prefix(70)).trimmingCharacters(in: .whitespaces) + "…" : first
    }

    private func notify() {
        notifiedDuration = duration
        onTransportChange?()
    }

    private var chunks: [Chunk] = []
    private var buffers: [Int: AVAudioPCMBuffer] = [:]
    private var starts: [Double] = [0]           // start time of each chunk, plus total at the end
    private var secondsPerChar = 0.064           // refined as audio is generated
    private let audio = AudioOut()
    private let synth = Synthesizer()
    private var session = 0
    private var token = 0                        // invalidates callbacks from earlier playback runs
    private var timer: Timer?

    private struct Segment {
        let index: Int
        let fromFrame: Int
        let nodeStart: AVAudioFramePosition
        let frames: AVAudioFramePosition
    }
    private var segments: [Segment] = []
    private var nodeEnd: AVAudioFramePosition = 0
    private var nextToSchedule = 0
    private var resumePoint: (index: Int, fraction: Double) = (0, 0)
    private var lastPoint: (index: Int, fraction: Double) = (0, 0)
    private var outputWasBuiltIn = AudioOut.defaultOutputIsBuiltIn()

    private var sampleRate: Double { audio.format.sampleRate }

    init() {
        let defaults = UserDefaults.standard
        let savedRate = defaults.float(forKey: "rate")
        rate = savedRate > 0 ? savedRate : 1.0
        voice = Voice.with(key: defaults.string(forKey: "voice"))
        audio.rate = rate
        synth.onReady = { [weak self] s, index, samples in self?.chunkReady(session: s, index: index, samples: samples) }
        synth.onError = { [weak self] message in
            self?.message = message
            self?.isBuffering = false
        }
        audio.onConfigurationChange = { [weak self] in self?.audioRouteChanged() }
        audio.onLevel = { [weak self] level in
            guard let self else { return }
            let l = self.isPlaying && !self.isBuffering ? level : 0  // ignore stragglers after a pause
            if l != self.outputLevel { self.outputLevel = l }
        }
    }

    enum Status { case idle, loading, playing, paused }

    var status: Status {
        guard hasSession else { return .idle }
        if !isPlaying { return .paused }
        return isBuffering ? .loading : .playing
    }

    var isMuted: Bool {
        get { audio.volume == 0 }
        set { audio.volume = newValue ? 0 : 1 }
    }

    func preload() {
        synth.preload(accent: voice.accent)
    }

    // MARK: - Session

    func load(_ raw: String) {
        stop()
        let cleaned = TextPrep.clean(raw)
        let newChunks = TextPrep.chunks(for: cleaned)
        guard !newChunks.isEmpty else {
            message = "There's nothing readable in that selection."
            return
        }
        message = KokoroEngine.isModelInstalled ? nil : EngineError.modelMissing(KokoroEngine.modelDirectory.path).localizedDescription
        sourceText = raw
        text = cleaned
        chunks = newChunks
        chunkRanges = newChunks.map(\.range)
        buffers = [:]
        recomputeTimeline()
        session = synth.begin(texts: newChunks.map(\.speech), voice: voice, from: 0)
        isPlaying = true
        startPlayback(at: 0, fraction: 0)
        startTimer()
    }

    /// Ends the session and releases the audio device.
    func stop() {
        token += 1
        synth.cancel()
        audio.shutdown()
        timer?.invalidate()
        timer = nil
        chunks = []
        chunkRanges = []
        buffers = [:]
        segments = []
        text = ""
        sourceText = ""
        isPlaying = false
        isBuffering = false
        outputLevel = 0
        position = 0
        duration = 0
        currentIndex = 0
        generatedSpans = []
        resumePoint = (0, 0)
        notify()
    }

    // MARK: - Transport

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard hasSession, !isPlaying else { return }
        if position >= duration - 0.05 { resumePoint = (0, 0) }  // finished: start over
        isPlaying = true
        startPlayback(at: resumePoint.index, fraction: resumePoint.fraction)
        startTimer()
    }

    func pause() {
        guard isPlaying else { return }
        log("pause()")
        resumePoint = currentPoint()
        isPlaying = false
        isBuffering = false
        outputLevel = 0
        token += 1
        audio.node.stop()
        audio.engine.pause()  // release the output device while paused
        notify()
    }

    func seek(to seconds: Double) {
        guard hasSession else { return }
        let t = min(max(seconds, 0), duration)
        var i = 0
        while i < chunks.count - 1 && starts[i + 1] <= t { i += 1 }
        let fraction = min(max((t - starts[i]) / chunkDuration(i), 0), 0.999)
        if isPlaying {
            startPlayback(at: i, fraction: fraction)
        } else {
            resumePoint = (i, fraction)
            currentIndex = i
            position = t
            updateWindow()
            notify()
        }
    }

    func skip(by seconds: Double) {
        seek(to: position + seconds)
    }

    /// Jumps to the start of a sentence and plays from there.
    func jump(to index: Int) {
        guard hasSession else { return }
        let i = min(max(index, 0), chunks.count - 1)
        isPlaying = true
        startPlayback(at: i, fraction: 0)
        startTimer()
    }

    func previousSentence() {
        let p = currentPoint()
        let into = p.fraction * chunkDuration(p.index)
        jump(to: into > 1.5 ? p.index : p.index - 1)
    }

    func nextSentence() {
        jump(to: currentPoint().index + 1)
    }

    func setRate(_ r: Float) {
        rate = r
        audio.rate = r
        UserDefaults.standard.set(r, forKey: "rate")
        if hasSession {
            updateWindow()
            notify()
        }
    }

    func setVoice(_ v: Voice) {
        guard v != voice else { return }
        voice = v
        UserDefaults.standard.set(v.key, forKey: "voice")
        guard hasSession else {
            synth.preload(accent: v.accent)
            return
        }
        // Regenerate from the current sentence onward in the new voice.
        let p = currentPoint()
        buffers = [:]
        recomputeTimeline()
        session = synth.begin(texts: chunks.map(\.speech), voice: v, from: p.index)
        if isPlaying {
            startPlayback(at: p.index, fraction: 0)
        } else {
            resumePoint = (p.index, 0)
        }
    }

    // MARK: - Playback internals

    private func startPlayback(at index: Int, fraction: Double) {
        defer { notify() }
        outputWasBuiltIn = AudioOut.defaultOutputIsBuiltIn()
        token += 1
        audio.node.stop()
        segments = []
        nodeEnd = 0
        resumePoint = (index, fraction)
        lastPoint = resumePoint
        currentIndex = index
        position = starts[index] + fraction * chunkDuration(index)
        updateWindow()

        guard let buffer = buffers[index] else {
            isBuffering = true
            return
        }
        isBuffering = false
        schedule(index, from: Int(fraction * Double(buffer.frameLength)))
        nextToSchedule = index + 1
        scheduleAhead()
        do {
            try audio.start()
            audio.node.play()
        } catch {
            message = "Couldn't start audio: \(error.localizedDescription)"
            log("audio start failed: \(error)")
            isPlaying = false
        }
    }

    private func schedule(_ index: Int, from frame: Int) {
        guard let full = buffers[index] else { return }
        let from = min(max(frame, 0), Int(full.frameLength) - 1)
        let buffer = from == 0 ? full : audio.slice(full, from: from)
        let myToken = token
        audio.node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.segmentFinished(index, token: myToken) }
        }
        let frames = AVAudioFramePosition(buffer.frameLength)
        segments.append(Segment(index: index, fromFrame: from, nodeStart: nodeEnd, frames: frames))
        nodeEnd += frames
    }

    /// Queues every consecutive chunk that's already generated.
    private func scheduleAhead() {
        while nextToSchedule < chunks.count, buffers[nextToSchedule] != nil {
            schedule(nextToSchedule, from: 0)
            nextToSchedule += 1
        }
    }

    private func segmentFinished(_ index: Int, token t: Int) {
        guard t == token, isPlaying else { return }
        if index >= chunks.count - 1 {
            finished()
            return
        }
        scheduleAhead()
        if segments.last?.index == index {
            // Playback caught up with generation: wait for the next chunk.
            startPlayback(at: index + 1, fraction: 0)
        }
    }

    private func finished() {
        log("finished()")
        token += 1
        audio.node.stop()
        audio.engine.pause()
        isPlaying = false
        isBuffering = false
        outputLevel = 0
        position = duration
        resumePoint = (0, 0)
        notify()
    }

    /// Keeps generation just ahead of the listener: the current sentence plus
    /// enough following sentences to cover `lookahead` seconds (at least two).
    private func updateWindow() {
        guard hasSession else { return }
        let from = currentIndex
        let lookahead = max(25, 12 * Double(rate))
        var end = from
        var ahead = 0.0
        while end < chunks.count - 1 && (ahead < lookahead || end < from + 2) {
            ahead += chunkDuration(end)
            end += 1
        }
        synth.setWindow(from...end)
    }

    private func chunkReady(session s: Int, index: Int, samples: [Float]) {
        guard s == session, index < chunks.count else { return }
        buffers[index] = audio.makeBuffer(samples, pauseAfter: chunks[index].pauseAfter)
        refineEstimate()
        recomputeTimeline()
        if abs(duration - notifiedDuration) > 2 { notify() }
        if !isPlaying || isBuffering {
            position = starts[resumePoint.index] + resumePoint.fraction * chunkDuration(resumePoint.index)
        }
        guard isPlaying else { return }
        if isBuffering {
            if index == resumePoint.index {
                startPlayback(at: index, fraction: resumePoint.fraction)
            }
        } else {
            scheduleAhead()
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard isPlaying, !isBuffering, let point = nodePoint() else { return }
        lastPoint = point
        if point.index != currentIndex {
            currentIndex = point.index
            updateWindow()
        }
        position = starts[point.index] + point.fraction * chunkDuration(point.index)
    }

    /// Where the player node currently is, as (chunk, fraction of chunk).
    private func nodePoint() -> (index: Int, fraction: Double)? {
        guard let sample = audio.sampleTime,
              let seg = segments.last(where: { $0.nodeStart <= sample }),
              let buffer = buffers[seg.index]
        else { return nil }
        let into = min(sample - seg.nodeStart, seg.frames)
        let frame = Double(seg.fromFrame) + Double(into)
        return (seg.index, min(frame / Double(buffer.frameLength), 0.999))
    }

    private func currentPoint() -> (index: Int, fraction: Double) {
        guard isPlaying, !isBuffering else { return resumePoint }
        return nodePoint() ?? lastPoint
    }

    private func audioRouteChanged() {
        log("audio configuration changed")
        let nowBuiltIn = AudioOut.defaultOutputIsBuiltIn()
        defer { outputWasBuiltIn = nowBuiltIn }
        guard hasSession, isPlaying else { return }
        // Like a music player: if headphones disconnect and sound would move to
        // the Mac's speakers, pause instead of carrying on out loud.
        if !outputWasBuiltIn && nowBuiltIn {
            pause()
            return
        }
        // Otherwise (e.g. AirPods just connected) the engine stopped; restart where we were.
        let p = lastPoint
        startPlayback(at: p.index, fraction: p.fraction)
    }

    // MARK: - Timeline

    private func chunkDuration(_ i: Int) -> Double {
        if let b = buffers[i] { return Double(b.frameLength) / sampleRate }
        return Double(chunks[i].speech.count) * secondsPerChar + chunks[i].pauseAfter
    }

    private func refineEstimate() {
        var seconds = 0.0
        var chars = 0
        for (i, b) in buffers {
            seconds += Double(b.frameLength) / sampleRate - chunks[i].pauseAfter
            chars += chunks[i].speech.count
        }
        if chars > 40 { secondsPerChar = seconds / Double(chars) }
    }

    private func recomputeTimeline() {
        var s: [Double] = [0]
        s.reserveCapacity(chunks.count + 1)
        var spans: [ClosedRange<Double>] = []
        for i in chunks.indices {
            let start = s[i]
            let end = start + chunkDuration(i)
            s.append(end)
            if buffers[i] != nil {
                if let last = spans.last, abs(last.upperBound - start) < 0.001 {
                    spans[spans.count - 1] = last.lowerBound...end
                } else {
                    spans.append(start...end)
                }
            }
        }
        starts = s
        duration = s.last ?? 0
        generatedSpans = spans
    }

    // MARK: - Debug

    private func log(_ s: String) {
        guard Synthesizer.trace else { return }
        print("   model: " + s)
        fflush(stdout)
    }

    var debugDescription: String {
        let state = isBuffering ? "buffering" : (isPlaying ? "playing" : "paused")
        return String(format: "%@ sentence %d/%d  %.1fs / %.1fs  generated %d/%d  %@", state, currentIndex + 1, chunks.count, position, duration, buffers.count, chunks.count, message ?? "")
    }
}
