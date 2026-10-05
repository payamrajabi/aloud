import AVFoundation
import CoreAudio

/// Audio output: player node -> time-stretch (speed without pitch change) -> speakers.
final class AudioOut {
    let engine = AVAudioEngine()
    let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    let format: AVAudioFormat
    var onConfigurationChange: (() -> Void)?

    init(sampleRate: Double = Double(KokoroEngine.sampleRate)) {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.attach(node)
        engine.attach(timePitch)
        engine.connect(node, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    var rate: Float {
        get { timePitch.rate }
        set { timePitch.rate = newValue }
    }

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    func start() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // The output device can be briefly unavailable (e.g. switching to AirPods); retry once.
            engine.reset()
            usleep(150_000)
            engine.prepare()
            try engine.start()
        }
    }

    func shutdown() {
        node.stop()
        engine.stop()
    }

    /// Frames played since the node last started, or nil when not playing.
    var sampleTime: AVAudioFramePosition? {
        guard node.isPlaying,
              let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime)
        else { return nil }
        return max(0, playerTime.sampleTime)
    }

    /// True when sound is going to the Mac's own speakers or headphone jack
    /// (as opposed to AirPods, Bluetooth, USB or AirPlay).
    static func defaultOutputIsBuiltIn() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return false }
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBuiltIn
    }

    func makeBuffer(_ samples: [Float], pauseAfter: Double) -> AVAudioPCMBuffer {
        let speech = Self.trimSilence(samples)
        let pad = Int(pauseAfter * format.sampleRate)
        let total = max(speech.count + pad, 1)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        let out = buffer.floatChannelData![0]
        speech.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { out.update(from: base, count: src.count) }
        }
        (out + speech.count).update(repeating: 0, count: total - speech.count)
        return buffer
    }

    /// A copy of `buffer` starting at `frame`.
    func slice(_ buffer: AVAudioPCMBuffer, from frame: Int) -> AVAudioPCMBuffer {
        let count = max(Int(buffer.frameLength) - frame, 1)
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        out.frameLength = AVAudioFrameCount(count)
        let src = buffer.floatChannelData![0] + min(frame, Int(buffer.frameLength) - 1)
        out.floatChannelData![0].update(from: src, count: count)
        return out
    }

    private static func trimSilence(_ s: [Float]) -> [Float] {
        let threshold: Float = 0.004
        guard let first = s.firstIndex(where: { abs($0) > threshold }),
              let last = s.lastIndex(where: { abs($0) > threshold })
        else { return [] }
        let lead = max(0, first - 240)            // keep 10 ms before speech
        let tail = min(s.count, last + 1 + 1_200) // keep 50 ms after speech
        return Array(s[lead..<tail])
    }
}
