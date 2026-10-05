import AVFoundation
import AppKit
import CSherpaOnnx

/// Developer-only command-line modes used to test the app without the shortcut.
///   --say "text" [--voice af_heart] [--out file.wav]   synthesize only, print speed
///   --read "text" | --read-file path                    open the player and read
///   --mute                                              silence output
///   --trace                                             print player state twice a second
///   --script "2:seek=30;4:pause;5:play;8:open;9:snapshot=/tmp/p.png;10:quit"
enum DebugScript {
    static let args = CommandLine.arguments

    static func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var isActive: Bool {
        ["--read", "--read-file", "--script", "--say"].contains { args.contains($0) }
    }

    /// Loads any audio file as 16 kHz mono floats.
    static func load16k(_ path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: inBuf)
        return resample(inBuf, to: 16_000)
    }

    static func resample(_ inBuf: AVAudioPCMBuffer, to rate: Double) -> [Float] {
        let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: inBuf.format, to: out)!
        let outBuf = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: AVAudioFrameCount(Double(inBuf.frameLength) * rate / inBuf.format.sampleRate) + 1024)!
        var done = false
        _ = converter.convert(to: outBuf, error: nil) { _, status in
            if done { status.pointee = .endOfStream; return nil }
            done = true; status.pointee = .haveData; return inBuf
        }
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
    }

    /// Synthesis benchmark that runs before the app starts.
    static func runCommandLineIfNeeded() {
        if let path = value("--transcribe") {
            do {
                var t0 = Date()
                let engine = try ParakeetEngine()
                print(String(format: "parakeet load: %.2fs", Date().timeIntervalSince(t0)))
                let samples = try load16k(path)
                t0 = Date()
                let text = engine.transcribe(samples)
                let took = Date().timeIntervalSince(t0)
                let secs = Double(samples.count) / 16_000
                print(String(format: "%.1fs audio in %.2fs (%.0fx real time): %@", secs, took, secs / took, text))
                exit(0)
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
        }
        if let path = value("--mic-sim") {
            // Turn a file into 48 kHz stereo 1,024-frame buffers, like a typical microphone delivers.
            let mono16 = try! load16k(path)
            let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
            let big = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(mono16.count))!
            big.frameLength = AVAudioFrameCount(mono16.count)
            big.floatChannelData![0].update(from: mono16, count: mono16.count)
            let micFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            let up = AVAudioConverter(from: src, to: micFormat)!
            let mic = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: AVAudioFrameCount(mono16.count * 3 + 4096))!
            var given = false
            _ = up.convert(to: mic, error: nil) { _, st in if given { st.pointee = .endOfStream; return nil }; given = true; st.pointee = .haveData; return big }
            var pieces: [AVAudioPCMBuffer] = []
            var offset = 0
            while offset < Int(mic.frameLength) {
                let n = min(1_024, Int(mic.frameLength) - offset)
                let piece = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: 1_024)!
                piece.frameLength = AVAudioFrameCount(n)
                for ch in 0..<2 { piece.floatChannelData![ch].update(from: mic.floatChannelData![ch] + offset, count: n) }
                pieces.append(piece)
                offset += n
            }
            let captured = Recorder().simulate(pieces)
            print(String(format: "mic simulation: %d buffers of 48 kHz stereo → %.2fs at 16 kHz (source %.2fs)", pieces.count, Double(captured.count) / 16_000, Double(mono16.count) / 16_000))
            print("transcript: " + ((try? ParakeetEngine())?.transcribe(captured) ?? "engine failed"))
            exit(0)
        }
        guard let text = value("--say") else { return }
        let voice = Voice.with(key: value("--voice"))
        do {
            print("model: \(KokoroEngine.modelDirectory.path)")
            var t0 = Date()
            let engine = try KokoroEngine(accent: voice.accent)
            print(String(format: "model load: %.2fs", Date().timeIntervalSince(t0)))
            var all: [Float] = []
            for chunk in TextPrep.chunks(for: TextPrep.clean(text)) {
                t0 = Date()
                let samples = engine.generate(chunk.speech, speaker: voice.id)
                let elapsed = Date().timeIntervalSince(t0)
                let secs = Double(samples.count) / Double(KokoroEngine.sampleRate)
                print(String(format: "%.2fs audio in %.2fs (%.1fx real time): %@", secs, elapsed, secs / elapsed, chunk.speech))
                all += samples
            }
            if let out = value("--out") {
                SherpaOnnxWriteWave(all, Int32(all.count), Int32(KokoroEngine.sampleRate), out)
                print("wrote \(out)")
            }
            exit(0)
        } catch {
            print("error: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func run(model: PlayerModel, app: AppDelegate) {
        if args.contains("--mute") { model.isMuted = true }
        if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        var text = value("--read")
        if let path = value("--read-file") { text = try? String(contentsOfFile: path, encoding: .utf8) }
        if let text { model.load(text) }
        if args.contains("--trace") {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                print(String(format: "[%5.1f] ", Date().timeIntervalSince(start)) + model.debugDescription)
                fflush(stdout)
            }
        }
        guard let script = value("--script") else { return }
        for step in script.split(separator: ";") {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let at = Double(parts[0]) else { continue }
            let action = parts[1]
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                print(String(format: "[%5.1f] >> %@", Date().timeIntervalSince(start), action))
                perform(action, model: model, app: app)
                fflush(stdout)
            }
        }
    }

    private static let start = Date()

    private static func perform(_ action: String, model: PlayerModel, app: AppDelegate) {
        let kv = action.split(separator: "=", maxSplits: 1).map(String.init)
        let arg = kv.count > 1 ? kv[1] : ""
        switch kv[0] {
        case "seek": model.seek(to: Double(arg) ?? 0)
        case "skip": model.skip(by: Double(arg) ?? 0)
        case "pause": model.pause()
        case "play": model.play()
        case "next": model.nextSentence()
        case "prev": model.previousSentence()
        case "jump": model.jump(to: Int(arg) ?? 0)
        case "rate": model.setRate(Float(arg) ?? 1)
        case "voice": model.setVoice(Voice.with(key: arg))
        case "open": app.showPlayer()
        case "close": app.player.close()
        case "snapshot":
            if let view = app.player.popover.contentViewController?.view { snapshot(view, to: arg) }
        case "iconshot": if let b = app.statusButton { snapshot(b, to: arg) }
        case "dictate": app.dictationController.toggle()
        case "hud":
            let states: [String: DictationController.State] = [
                "recording": .recording, "transcribing": .transcribing, "downloading": .downloading(0.42),
                "message": .message("Dictation is ready. Press right ⌥ to start."),
            ]
            app.dictationController.debugSet(states[arg] ?? .idle)
        case "hudshot":
            if let view = app.dictationHUD?.panel.contentView { snapshot(view, to: arg) }
        case "quit": NSApp.terminate(nil)
        default: print("unknown action \(action)")
        }
    }

    private static func snapshot(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("snapshot saved to \(path)")
    }
}
