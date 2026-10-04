import AppKit
import CSherpaOnnx

/// Developer-only command-line modes used to test the app without the shortcut.
///   --say "text" [--voice af_heart] [--out file.wav]   synthesize only, print speed
///   --read "text" | --read-file path                    open the player and read
///   --mute                                              silence output
///   --trace                                             print player state twice a second
///   --script "2:seek=30;4:pause;5:play;9:snapshot=/tmp/p.png;10:quit"
enum DebugScript {
    static let args = CommandLine.arguments

    static func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var isActive: Bool {
        ["--read", "--read-file", "--script", "--say"].contains { args.contains($0) }
    }

    /// Synthesis benchmark that runs before the app starts.
    static func runCommandLineIfNeeded() {
        guard let text = value("--say") else { return }
        let voice = Voice.with(key: value("--voice"))
        do {
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

    static func run(model: PlayerModel, player: PlayerWindowController) {
        if args.contains("--mute") { model.isMuted = true }
        var text = value("--read")
        if let path = value("--read-file") { text = try? String(contentsOfFile: path, encoding: .utf8) }
        if let text {
            model.load(text)
            player.show()
        }
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
                perform(action, model: model, player: player)
                fflush(stdout)
            }
        }
    }

    private static let start = Date()

    private static func perform(_ action: String, model: PlayerModel, player: PlayerWindowController) {
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
        case "snapshot": snapshot(player.panel, to: arg)
        case "quit": NSApp.terminate(nil)
        default: print("unknown action \(action)")
        }
    }

    private static func snapshot(_ window: NSWindow, to path: String) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("snapshot saved to \(path)")
    }
}
