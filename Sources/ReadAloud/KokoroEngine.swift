import CSherpaOnnx
import Foundation

enum Accent: String {
    case american, british
}

struct Voice: Hashable, Identifiable {
    let id: Int32        // Kokoro speaker ID
    let key: String      // Kokoro voice name, e.g. "af_heart"
    let name: String     // Friendly name for menus
    let accent: Accent

    static let all: [Voice] = [
        Voice(id: 3, key: "af_heart", name: "Heart", accent: .american),
        Voice(id: 2, key: "af_bella", name: "Bella", accent: .american),
        Voice(id: 6, key: "af_nicole", name: "Nicole (soft)", accent: .american),
        Voice(id: 9, key: "af_sarah", name: "Sarah", accent: .american),
        Voice(id: 1, key: "af_aoede", name: "Aoede", accent: .american),
        Voice(id: 5, key: "af_kore", name: "Kore", accent: .american),
        Voice(id: 16, key: "am_michael", name: "Michael", accent: .american),
        Voice(id: 14, key: "am_fenrir", name: "Fenrir", accent: .american),
        Voice(id: 18, key: "am_puck", name: "Puck", accent: .american),
        Voice(id: 21, key: "bf_emma", name: "Emma", accent: .british),
        Voice(id: 22, key: "bf_isabella", name: "Isabella", accent: .british),
        Voice(id: 26, key: "bm_george", name: "George", accent: .british),
        Voice(id: 25, key: "bm_fable", name: "Fable", accent: .british),
        Voice(id: 27, key: "bm_lewis", name: "Lewis", accent: .british),
    ]

    static let `default` = all[0]

    static func with(key: String?) -> Voice {
        all.first { $0.key == key } ?? .default
    }
}

enum EngineError: LocalizedError {
    case modelMissing(String)
    case loadFailed

    var errorDescription: String? {
        switch self {
        case .modelMissing(let path):
            return "The Kokoro voice model isn't installed (expected at \(path)). Run scripts/setup.sh."
        case .loadFailed:
            return "The Kokoro voice model failed to load."
        }
    }
}

/// Thin wrapper around sherpa-onnx's offline Kokoro text-to-speech.
/// Not thread-safe: call it from a single serial queue.
final class KokoroEngine {
    static let sampleRate = 24_000

    static let modelName = "kokoro-multi-lang-v1_0"

    /// The model ships inside the app for downloaded builds; developer builds
    /// use the copy that scripts/setup.sh puts in Application Support.
    static var modelDirectory: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(modelName),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("model.onnx").path) {
            return bundled
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ReadAloud/models/\(modelName)")
    }

    static var isModelInstalled: Bool {
        FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("model.onnx").path)
    }

    let accent: Accent
    private let tts: OpaquePointer

    init(accent: Accent, threads: Int = Int(ProcessInfo.processInfo.environment["KOKORO_THREADS"] ?? "") ?? 4) throws {
        let dir = Self.modelDirectory
        func path(_ name: String) -> String { dir.appendingPathComponent(name).path }
        guard Self.isModelInstalled else { throw EngineError.modelMissing(dir.path) }

        var owned: [UnsafeMutablePointer<CChar>] = []
        func c(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            owned.append(p)
            return UnsafePointer(p)
        }
        defer { owned.forEach { free($0) } }

        let lexicon = accent == .british ? "lexicon-gb-en.txt" : "lexicon-us-en.txt"

        var config = SherpaOnnxOfflineTtsConfig()
        config.model.kokoro.model = c(path("model.onnx"))
        config.model.kokoro.voices = c(path("voices.bin"))
        config.model.kokoro.tokens = c(path("tokens.txt"))
        config.model.kokoro.data_dir = c(path("espeak-ng-data"))
        config.model.kokoro.lexicon = c([path(lexicon), path("lexicon-zh.txt")].joined(separator: ","))
        config.model.kokoro.lang = c(accent == .british ? "en" : "en-us")
        config.model.kokoro.length_scale = 1.0
        config.model.num_threads = Int32(threads)
        config.model.provider = c(ProcessInfo.processInfo.environment["KOKORO_PROVIDER"] ?? "cpu")
        config.model.debug = ProcessInfo.processInfo.environment["SHERPA_DEBUG"] == nil ? 0 : 1
        config.max_num_sentences = 1
        config.silence_scale = 0.2

        guard let tts = SherpaOnnxCreateOfflineTts(&config) else { throw EngineError.loadFailed }
        self.tts = tts
        self.accent = accent
    }

    deinit {
        SherpaOnnxDestroyOfflineTts(tts)
    }

    /// Synthesizes `text` and returns mono float samples at `sampleRate`.
    func generate(_ text: String, speaker: Int32) -> [Float] {
        var cfg = SherpaOnnxGenerationConfig()
        cfg.sid = speaker
        cfg.speed = 1.0
        cfg.silence_scale = 0.2
        let audio = text.withCString { SherpaOnnxOfflineTtsGenerateWithConfig(tts, $0, &cfg, nil, nil) }
        guard let audio else { return [] }
        defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
        let n = Int(audio.pointee.n)
        guard n > 0, let samples = audio.pointee.samples else { return [] }
        return Array(UnsafeBufferPointer(start: samples, count: n))
    }
}
