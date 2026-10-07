import AVFoundation

/// Captures the preferred microphone as 16 kHz mono float samples for Parakeet.
final class Recorder {
    /// Called on the main queue with a 0–1 loudness value, about 20 times a second.
    var onLevel: ((Float) -> Void)?

    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var samples: [Float] = []
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(ParakeetEngine.sampleRate),
                                          channels: 1, interleaved: false)!

    func start() throws {
        lock.lock(); samples = []; samples.reserveCapacity(ParakeetEngine.sampleRate * 60); lock.unlock()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let device = AudioDevices.preferredDevice(.input) {
            AudioDevices.use(device.id, on: input.audioUnit)
        }
        guard input.outputFormat(forBus: 0).sampleRate > 0 else {
            throw NSError(domain: "ReadAloud", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone is available."])
        }
        let process = makeProcessor()
        // No tap format: after switching devices the node can report the old one's, which a tap would reject.
        input.installTap(onBus: 0, bufferSize: 1_024, format: nil) { buffer, _ in process(buffer) }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Converts each incoming microphone buffer to 16 kHz mono, stores it and reports loudness.
    func makeProcessor() -> (AVAudioPCMBuffer) -> Void {
        var converter: AVAudioConverter?
        return { [weak self] buffer in
            guard let self else { return }
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
            self.lock.lock(); self.samples.append(contentsOf: chunk); self.lock.unlock()
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

    /// Stops recording and returns everything captured.
    func stop() -> [Float] {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        lock.lock(); defer { lock.unlock() }
        return samples
    }
}
