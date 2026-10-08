import AVFoundation
import os

/// Captures the preferred microphone as 16 kHz mono float samples for Parakeet.
///
/// macOS can stop the engine under us. Pointing it at the chosen microphone, or AirPods
/// switching to their headset mode, changes the input's format, and a change that lands just
/// after `start` makes AVAudioEngine stop itself (about a third of starts did). So the engine
/// is made once, ahead of time (`prepare`), which leaves nothing to switch when you start; it's
/// restarted when macOS stops it; and if no audio arrives for a while anyway it's rebuilt.
/// `onFailure` reports a microphone that can't be brought back, so nobody talks into nothing.
final class Recorder {
    /// Called on the main queue with a 0–1 loudness value, about 20 times a second.
    var onLevel: ((Float) -> Void)?
    /// Called on the main queue when the microphone stopped delivering audio and couldn't be restarted.
    var onFailure: (() -> Void)?

    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var watchdog: Timer?
    private var isRecording = false
    private var isBuilding = false
    private var buildStarted: TimeInterval = 0
    /// Restarts since audio last arrived.
    private var restarts = 0
    /// Restarts during this recording.
    private(set) var totalRestarts = 0
    private let lock = NSLock()
    private var samples: [Float] = []       // guarded by lock
    private var lastAudio: TimeInterval = 0  // when a buffer last arrived; guarded by lock
    private var restartedAt: TimeInterval = 0
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(ParakeetEngine.sampleRate),
                                          channels: 1, interleaved: false)!

    /// No buffer for this long means the microphone has stopped (it normally sends one every ~20 ms;
    /// AirPods can take most of a second to switch to their microphone).
    static let silentLimit: TimeInterval = 1.5
    /// Give up after this many restarts in a row without any audio arriving.
    static let maxRestarts = 2
    /// Making an engine normally takes a fraction of a second; it has been seen to hang.
    static let buildLimit: TimeInterval = 6
    private let trace = DebugScript.args.contains("--trace")
    /// `--dead-mic`: drop everything the microphone sends, to test giving up on it.
    private static let deadMic = DebugScript.args.contains("--dead-mic")
    /// Restarts and failures also go to the system log (Console, subsystem co.payamrajabi.readaloud),
    /// so a microphone that misbehaves on someone's Mac can be diagnosed afterwards.
    private static let logger = Logger(subsystem: "co.payamrajabi.readaloud", category: "recorder")

    func start() throws {
        lock.lock()
        samples = []
        samples.reserveCapacity(ParakeetEngine.sampleRate * 60)
        lastAudio = Self.now
        lock.unlock()
        restartedAt = Self.now
        restarts = 0
        totalRestarts = 0
        do {
            try startEngine()
        } catch {
            log("couldn't start the microphone (\(error.localizedDescription)), trying a new engine")
            discardEngine()
            try startEngine()
        }
        isRecording = true
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkAudio() }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    /// Makes the engine in the background, so the first recording doesn't wait for it. Making one
    /// asks the system's audio service for a device of its own, which can take seconds.
    /// Only call it once microphone access is granted: making the engine checks for it.
    func prepare(then completion: (() -> Void)? = nil) {
        if engine != nil { completion?(); return }
        guard !isBuilding else { return }
        isBuilding = true
        buildStarted = Self.now
        let device = AudioDevices.preferredDevice(.input)?.id
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = Self.makeEngine(device: device)
            DispatchQueue.main.async {
                self.isBuilding = false
                if self.engine == nil { self.adopt(engine) }  // a recording that couldn't wait made its own
                completion?()
            }
        }
    }

    /// Starts the engine (made once, then reused) on the preferred microphone.
    private func startEngine() throws {
        let device = AudioDevices.preferredDevice(.input)?.id
        if engine == nil { adopt(Self.makeEngine(device: device)) }
        guard let engine else { return }
        let input = engine.inputNode
        Self.point(input, at: device)
        guard input.outputFormat(forBus: 0).sampleRate > 0 else {
            throw NSError(domain: "ReadAloud", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone is available."])
        }
        let process = makeProcessor()
        input.removeTap(onBus: 0)
        // No tap format: after switching devices the node can report the old one's, which a tap would reject.
        input.installTap(onBus: 0, bufferSize: 1_024, format: nil) { buffer, _ in process(buffer) }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    /// An engine whose input is the given microphone. Safe off the main thread.
    private static func makeEngine(device: AudioDeviceID?) -> AVAudioEngine {
        let engine = AVAudioEngine()
        point(engine.inputNode, at: device)
        return engine
    }

    /// Only switches when it's a different microphone: every switch is a configuration change.
    private static func point(_ input: AVAudioInputNode, at device: AudioDeviceID?) {
        if let device, AudioDevices.device(of: input.audioUnit) != device {
            AudioDevices.use(device, on: input.audioUnit)
        }
    }

    private func adopt(_ engine: AVAudioEngine) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: .main) { [weak self, weak engine] _ in
            // The engine stopped itself (or would have): start it again with the new format.
            guard let self, self.isRecording, let engine, engine === self.engine, !engine.isRunning else { return }
            self.restart(rebuild: false, reason: "the input's configuration changed")
        }
        self.engine = engine
    }

    /// Drops the engine, so the next start makes a new one.
    private func discardEngine() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine = nil
    }

    /// Twice a second while recording: restart a microphone that has stopped sending audio.
    private func checkAudio() {
        guard isRecording else { return }
        if isBuilding {
            if Self.now - buildStarted > Self.buildLimit { giveUp("making a new engine didn't finish") }
            return
        }
        lock.lock()
        let heard = lastAudio
        lock.unlock()
        let now = Self.now, running = engine?.isRunning == true
        let quiet = now - max(heard, restartedAt)  // a restart gets the full wait again
        if heard > restartedAt, now - heard < 0.5, running {
            restarts = 0  // audio is arriving again
        } else if quiet > Self.silentLimit || (!running && quiet > 0.5) {
            // A plain restart first, then a whole new engine.
            restart(rebuild: restarts > 0, reason: String(format: "%@, no audio for %.1fs", running ? "running" : "stopped", quiet))
        }
    }

    private func restart(rebuild: Bool, reason: String) {
        restarts += 1
        totalRestarts += 1
        log("restarting the microphone (\(reason)), attempt \(restarts)")
        guard restarts <= Self.maxRestarts else { return giveUp("it still sent nothing") }
        restartedAt = Self.now
        if rebuild {
            // A new engine, made in the background so the app doesn't freeze while it's made.
            discardEngine()
            prepare { [weak self] in
                guard let self, self.isRecording else { return }
                self.restartedAt = Self.now
                self.startAgain()
            }
            return
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        startAgain()
    }

    private func startAgain() {
        do {
            try startEngine()
        } catch {
            log("restart failed: \(error.localizedDescription)")  // the watchdog tries again
        }
    }

    private func giveUp(_ reason: String) {
        log("the microphone couldn't be restarted: \(reason)")
        stopWatching()
        discardEngine()
        onFailure?()
    }

    private func stopWatching() {
        isRecording = false
        watchdog?.invalidate()
        watchdog = nil
    }

    /// Converts each incoming microphone buffer to 16 kHz mono, stores it and reports loudness.
    func makeProcessor() -> (AVAudioPCMBuffer) -> Void {
        var converter: AVAudioConverter?
        let deadMic = Self.deadMic
        return { [weak self] buffer in
            guard let self, !deadMic else { return }
            if converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: self.outFormat)
            }
            guard let converter else { return }
            let ratio = self.outFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
            guard let out = AVAudioPCMBuffer(pcmFormat: self.outFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let data = out.floatChannelData?[0] else { return }
            let chunk = UnsafeBufferPointer(start: data, count: Int(out.frameLength))
            var sum: Float = 0
            for x in chunk { sum += x * x }
            let rms = (sum / Float(chunk.count)).squareRoot()
            let level = min(1, max(0, (20 * log10(max(rms, 1e-6)) + 55) / 45))  // ~-55 dB … -10 dB → 0…1
            self.lock.lock()
            self.samples.append(contentsOf: chunk)
            self.lastAudio = Self.now
            self.lock.unlock()
            DispatchQueue.main.async { self.onLevel?(level) }
        }
    }

    /// Test hook: feeds buffers through the same conversion path as the microphone.
    func simulate(_ buffers: [AVAudioPCMBuffer]) -> [Float] {
        lock.lock(); samples = []; lock.unlock()
        let process = makeProcessor()
        buffers.forEach(process)
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    /// Test hook: stops the engine without telling anyone, the way macOS sometimes does.
    func debugStopEngine() {
        engine?.stop()
    }

    /// Samples captured so far (safe to call while recording).
    var sampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }

    /// A copy of part of the recording so far (safe to call while recording).
    func read(_ range: Range<Int>) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let upper = min(range.upperBound, samples.count)
        guard range.lowerBound < upper else { return [] }
        return Array(samples[range.lowerBound..<upper])
    }

    /// Stops recording and returns everything captured. The engine stays, ready for next time.
    func stop() -> [Float] {
        stopWatching()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func log(_ s: String) {
        Self.logger.notice("\(s, privacy: .public)")
        guard trace else { return }
        print("   recorder: " + s)
        fflush(stdout)
    }
}
