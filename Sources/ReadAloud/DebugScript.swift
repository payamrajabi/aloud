import AVFoundation
import AppKit
import CoreAudio
import CSherpaOnnx

/// Developer-only command-line modes used to test the app without the shortcut.
///   --say "text" | --say-file path [--voice af_heart] [--out file.wav] [--show-phonemes]   synthesize only, print speed
///   --read "text" | --read-file path                    open the player and read
///   --mute                                              silence output
///   --trace                                             print player state twice a second
///   --download-voice                                    download the voice model and exit
///   --phonemize [--gb] [--raw] < lines.txt               print each line's phonemes
///   --g2p-test Tests/g2p/regression.json [--verbose]    pronunciation regression suite
///   --render-phonemes "ðə kwˈɪk" [--voice v] [--out f.wav] [--raw]   synthesize exact phonemes
///   --test-gestures                                     check modifier tap / double-tap / hold detection and exit
///   READALOUD_MODELS_DIR=/some/folder                   use a different models folder (test fresh installs)
///   --script "2:seek=30;4:pause;5:play;8:open;9:snapshot=/tmp/p.png;10:quit"
enum DebugScript {
    static let args = CommandLine.arguments

    static func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var isActive: Bool {
        ["--read", "--read-file", "--script", "--say", "--say-file"].contains { args.contains($0) }
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
        if args.contains("--test-gestures") { exit(testGestures() ? 0 : 1) }
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
        if let path = value("--stream-sim") {
            // Simulates a long recording arriving in real time (sped up), with background
            // transcription, then measures the wait after "stop".
            let once = try! load16k(path)
            let repeats = Int(value("--repeat") ?? "1") ?? 1
            let all = Array((0..<repeats).map { _ in once }.joined())
            let speed = Double(value("--speed") ?? "4") ?? 4
            let queue = DispatchQueue(label: "sim.asr", qos: .userInitiated)
            var engine: ParakeetEngine?
            queue.sync { engine = try? ParakeetEngine() }
            let streamer = StreamingTranscriber(queue: queue) { engine }
            streamer.reset()
            var recorded = 0
            let step = Int(0.25 * speed * 16_000)
            var ticks = 0
            print(String(format: "simulating a %.0fs recording at %.0fx speed...", Double(all.count) / 16_000, speed)); fflush(stdout)
            Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
                recorded = min(all.count, recorded + step)
                ticks += 1
                if ticks % max(1, Int(2 / speed / 0.25)) == 0 || ticks % 8 == 0 {
                    streamer.poll(available: recorded) { r in Array(all[r.lowerBound..<min(r.upperBound, recorded)]) }
                }
                if recorded == all.count {
                    timer.invalidate()
                    let stop = Date()
                    streamer.finish(all: all) { text, tail in
                        print(String(format: "STOP → text ready in %.2fs (tail %.1fs).", Date().timeIntervalSince(stop), tail))
                        let t0 = Date()
                        let oneShot = engine?.transcribe(all) ?? ""
                        print(String(format: "Old way (transcribe everything after stop): %.2fs.", Date().timeIntervalSince(t0)))
                        let a = text.split(separator: " "), b = oneShot.split(separator: " ")
                        print("words: streaming \(a.count), one-shot \(b.count)")
                        print("first 300 chars: " + String(text.prefix(300)))
                        exit(0)
                    }
                }
            }
            RunLoop.main.run()
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
        if args.contains("--download-voice") {
            // Downloads the voice the way the app does. Point READALOUD_MODELS_DIR at a scratch folder to test a fresh install.
            let dir = KokoroEngine.downloadedModelDirectory
            if KokoroEngine.isComplete(dir) {
                print("voice already at \(dir.path)")
                exit(0)
            }
            print("downloading \(KokoroEngine.files.map(\.name).joined(separator: ", ")) into \(dir.path)"); fflush(stdout)
            let downloader = ModelDownloader()
            let t0 = Date()
            var shown = -1
            downloader.download(files: KokoroEngine.files, into: dir) { p in
                let step = Int(p * 10)
                if step != shown { shown = step; print("  \(step * 10)%"); fflush(stdout) }
            } completion: { error in
                let ok = KokoroEngine.isComplete(dir)
                print(String(format: "done in %.0fs, error: %@, installed: %@", Date().timeIntervalSince(t0), error?.localizedDescription ?? "none", ok ? "yes" : "no"))
                exit(error == nil && ok ? 0 : 1)
            }
            RunLoop.main.run()
        }
        if args.contains("--tidy-voice") {
            // What launch does to voices from older versions (use READALOUD_MODELS_DIR to try it safely).
            KokoroEngine.removeUnusedFiles()
            exit(0)
        }
        if args.contains("--phonemize") {
            // Reads lines from stdin and prints "line<TAB>phonemes". --gb for British,
            // --raw to skip text normalization and custom lexicons (the reference pipeline).
            exit(G2PTest.phonemizeLines(british: args.contains("--gb"), raw: args.contains("--raw")))
        }
        if let path = value("--g2p-test") {
            exit(G2PTest.run(path: path, verbose: args.contains("--verbose")))
        }
        if let ps = value("--render-phonemes") {
            // Synthesizes a phoneme string as is (for comparing audio with another implementation).
            do {
                let engine = try KokoroEngine()
                let voice = Voice.with(key: value("--voice"))
                let ids = engine.tokenIDs(ps)
                let samples = engine.generate(phonemes: ps, voice: voice, scaleSilence: !args.contains("--raw"))
                print("tokens: \(ids.count), samples: \(samples.count), seconds: \(String(format: "%.3f", Double(samples.count) / 24_000))")
                if let out = value("--out") { SherpaOnnxWriteWave(samples, Int32(samples.count), Int32(KokoroEngine.sampleRate), out) }
                exit(0)
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
        }
        guard let text = value("--say") ?? value("--say-file").flatMap({ try? String(contentsOfFile: $0, encoding: .utf8) }) else { return }
        let voice = Voice.with(key: value("--voice"))
        do {
            print("model: \(KokoroEngine.modelDirectory.path)")
            var t0 = Date()
            let engine = try KokoroEngine()
            engine.prepare(voice.accent)
            print(String(format: "model load: %.2fs", Date().timeIntervalSince(t0)))
            var all: [Float] = []
            for chunk in TextPrep.chunks(for: TextPrep.clean(text)) {
                t0 = Date()
                if args.contains("--show-phonemes") { print("   /\(engine.phonemes(chunk.speech, accent: voice.accent))/") }
                let samples = engine.generate(chunk.speech, voice: voice)
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
    private static var fakeDevice = AudioObjectID(0)

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
        case "menu":
            let menu = NSMenu()
            app.menuNeedsUpdate(menu)
            print(menu.items.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: " | "))
        case "dictate": app.dictationController.toggle()
        case "hud":
            let states: [String: DictationController.State] = [
                "recording": .recording, "transcribing": .transcribing, "downloading": .downloading(0.42),
                "message": .message("Dictation is ready. Press right ⌥ to start."),
            ]
            app.dictationController.debugSet(states[arg] ?? .idle)
        case "hudshot":
            if let view = app.dictationHUD?.panel.contentView { snapshot(view, to: arg) }
        case "settings": app.showSettings()
        case "settingsshot":
            // Forms don't draw into cached bitmaps, so capture the window from the screen.
            if let number = app.settings.contentView?.window?.windowNumber {
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-o", "-x", "-l", String(number), arg]
                try? capture.run()
                capture.waitUntilExit()
                print("snapshot saved to \(arg)")
            }
        case "promptshot":  // the "download again?" question, shown without waiting for an answer
            let alert = DownloadPrompt.alert(model: "dictation", size: "480 MB", feature: "Dictation")
            alert.layout()
            alert.window.center()
            alert.window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-o", "-x", "-l", String(alert.window.windowNumber), arg]
                try? capture.run()
                capture.waitUntilExit()
                alert.window.orderOut(nil)
            }
        case "record": app.settings.recorder.begin(ShortcutAction(rawValue: arg) ?? .read)
        case "tapkey", "doubletapkey":  // a simulated tap (or two) of a modifier, e.g. tapkey=fn
            guard let key = ModifierKey(rawValue: arg) else { break }
            let presses: [Bool] = kv[0] == "tapkey" ? [true, false] : [true, false, true, false]
            for (i, isDown) in presses.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08 * Double(i)) {
                    postKey(.flagsChanged, code: key.code, flags: isDown ? key.family.rawValue | key.bit : 0)
                }
            }
        case "combokey":  // ⌃⌥ plus a key code, e.g. combokey=2 for ⌃⌥D
            postKey(.keyDown, code: UInt16(arg) ?? 0, flags: NSEvent.ModifierFlags([.control, .option]).rawValue)
        case "shortcuts":
            print("   " + ShortcutAction.allCases.map { "\($0.rawValue): \($0.hint)" }.joined(separator: ", "))
            if let problem = app.settings.recorder.problem { print("   problem: \(problem.text)") }
        case "fakeoutput":  // a private copy of the built-in speakers, only visible to this process
            let desc: [String: Any] = [kAudioAggregateDeviceNameKey: "Test Speakers", kAudioAggregateDeviceUIDKey: "aloud-test-speakers",
                                       kAudioAggregateDeviceIsPrivateKey: 1,
                                       kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: "BuiltInSpeakerDevice"]]]
            var id = AudioObjectID(0)
            print("   created test device: \(AudioHardwareCreateAggregateDevice(desc as CFDictionary, &id) == noErr)")
            fakeDevice = id
        case "removefake": AudioHardwareDestroyAggregateDevice(fakeDevice)
        case "rank":  // rank=uid1,uid2 sets the speaker order
            let entries = arg.split(separator: ",").map { AudioDevices.Entry(uid: String($0), name: String($0), transport: 0) }
            AudioDevices.shared.setOrder(entries, for: .output)
        case "route": print("   playing to: \(model.debugOutputDevice), playing: \(model.isPlaying)")
        case "devices":
            for d in AudioDevices.scan() { print("   \(d.hasInput ? "in " : "   ")\(d.hasOutput ? "out" : "   ")  \(d.name)  [\(d.uid)]") }
            print("   preferred output: \(AudioDevices.preferredDevice(.output)?.name ?? "none"), input: \(AudioDevices.preferredDevice(.input)?.name ?? "none")")
        case "quit": NSApp.terminate(nil)
        default: print("unknown action \(action)")
        }
    }

    /// Feeds key sequences through ModifierGestures and checks what fires.
    private static func testGestures() -> Bool {
        typealias G = ModifierGestures
        let lo = ModifierKey.leftOption, ro = ModifierKey.rightOption
        func down(_ k: ModifierKey, _ t: Double, extra: UInt = 0) -> G.Event { .modifier(code: k.code, flags: k.family.rawValue | k.bit | extra, time: t) }
        func up(_ k: ModifierKey, _ t: Double) -> G.Event { .modifier(code: k.code, flags: 0, time: t) }
        func run(_ read: KeyBinding?, _ dictate: KeyBinding?, recording: Bool = false, _ events: [G.Event]) -> [G.Action] {
            var g = G(read: read, dictate: dictate)
            g.interval = 0.4
            g.recording = recording
            return events.compactMap { g.handle($0) }
        }
        let cases: [(String, [G.Action], [G.Action])] = [
            ("double-tap left reads", run(.doubleTap(lo), .doubleTap(ro), [down(lo, 0), up(lo, 0.1), down(lo, 0.25), up(lo, 0.3)]), [.read]),
            ("double-tap right dictates", run(.doubleTap(lo), .doubleTap(ro), [down(ro, 0), up(ro, 0.1), down(ro, 0.25), up(ro, 0.3)]), [.dictate]),
            ("slow taps do nothing", run(.doubleTap(lo), .doubleTap(ro), [down(lo, 0), up(lo, 0.1), down(lo, 0.7), up(lo, 0.8)]), []),
            ("single tap does nothing for a double-tap shortcut", run(.doubleTap(lo), nil, [down(lo, 0), up(lo, 0.1)]), []),
            ("left then right isn't a double-tap", run(.doubleTap(lo), .doubleTap(ro), [down(lo, 0), up(lo, 0.1), down(ro, 0.2), up(ro, 0.3)]), []),
            ("a key between taps cancels", run(.doubleTap(lo), nil, [down(lo, 0), up(lo, 0.1), .keyDown, down(lo, 0.2), up(lo, 0.3)]), []),
            ("chord with ⌘ isn't a tap", run(.doubleTap(lo), nil, [down(lo, 0, extra: NSEvent.ModifierFlags.command.rawValue), up(lo, 0.1),
                                                                    down(lo, 0.2, extra: NSEvent.ModifierFlags.command.rawValue), up(lo, 0.3)]), []),
            ("tap fn dictates", run(nil, .tap(.fn), [down(.fn, 0), up(.fn, 0.1)]), [.dictate]),
            ("tap right ⌘ reads", run(.tap(.rightCommand), nil, [down(.rightCommand, 0), up(.rightCommand, 0.1)]), [.read]),
            ("one press finishes a recording", run(nil, .doubleTap(ro), recording: true, [down(ro, 0), up(ro, 0.1)]), [.dictate]),
            ("a long press finishes a recording too", run(nil, .doubleTap(ro), recording: true, [down(ro, 0), up(ro, 1.2)]), [.dictate]),
            ("double-tap ⇧ on any side", run(.doubleTap(.rightShift), .doubleTap(.leftControl),
                                            [down(.rightShift, 0), up(.rightShift, 0.1), down(.rightShift, 0.2), up(.rightShift, 0.3),
                                             down(.leftControl, 1), up(.leftControl, 1.1), down(.leftControl, 1.2), up(.leftControl, 1.3)]), [.read, .dictate]),
            ("combos are ignored here", run(.combo(keyCode: 15, modifiers: 6144), nil, [down(lo, 0), up(lo, 0.1), down(lo, 0.2), up(lo, 0.3)]), []),
        ]
        var ok = true
        for (name, got, want) in cases {
            let pass = got == want
            ok = ok && pass
            print("\(pass ? "✓" : "✗") \(name)\(pass ? "" : ": got \(got), want \(want)")")
        }
        // Holding the dictation key is push-to-talk.
        var g = G(read: nil, dictate: .doubleTap(ro))
        _ = g.handle(down(ro, 0))
        let hold = [g.holdTimerFired(at: 0.35), g.handle(up(ro, 2))]
        let holdOK = hold == [.holdBegan, .holdEnded]
        ok = ok && holdOK
        print("\(holdOK ? "✓" : "✗") hold right ⌥ to talk\(holdOK ? "" : ": got \(hold)")")
        // Stored shortcuts read back the same.
        let all: [KeyBinding] = [.combo(keyCode: 15, modifiers: 6144), .tap(.fn), .doubleTap(.rightControl)]
        let roundTrip = all.allSatisfy { KeyBinding(storageValue: $0.storageValue) == $0 }
        ok = ok && roundTrip
        print("\(roundTrip ? "✓" : "✗") shortcuts save and load; displays: \(all.map(\.display))")
        return ok
    }

    private static func postKey(_ type: NSEvent.EventType, code: UInt16, flags: UInt) {
        let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
                                     context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)
        if let event { NSApp.postEvent(event, atStart: false) }
    }

    private static func snapshot(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("snapshot saved to \(path)")
    }
}
