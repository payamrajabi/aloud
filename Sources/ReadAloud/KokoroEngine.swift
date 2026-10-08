import Foundation
import Phonemizer

enum Accent: String {
    case american, british
}

struct Voice: Hashable, Identifiable {
    let id: Int32        // Kokoro speaker ID (row in voices.bin)
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
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing(let path):
            return "A speech model isn't downloaded yet (expected at \(path))."
        case .loadFailed(let why):
            return why
        }
    }
}

/// Kokoro-82M v1.0 on ONNX Runtime: text → misaki phonemes (Phonemizer) → token IDs →
/// the model, with the voice's style vector picked by token count, the same way
/// sherpa-onnx did it. Not thread-safe: call it from a single serial queue.
final class KokoroEngine {
    static let sampleRate = 24_000
    /// Kokoro has a style vector for each input length up to 510 tokens, two of which
    /// are the padding at either end.
    static let maxTokens = 508

    /// The folder name is the one sherpa-onnx's archive unpacked to, so voices that are
    /// already installed keep working.
    static let modelName = "kokoro-multi-lang-v1_0"

    typealias RemoteFile = ModelDownloader.RemoteFile

    /// About 355 MB in all.
    static let downloadSize = "355 MB"

    /// The model, the 54 voice styles and the symbol table, fetched individually from a
    /// pinned revision of sherpa-onnx's Kokoro v1.0 export (Apache-2.0) on Hugging Face.
    /// Byte-identical to the files in sherpa-onnx's tar archive, minus the eSpeak NG
    /// data and lexicons that archive also carries, which Aloud no longer uses.
    static let files: [RemoteFile] = {
        let base = "https://huggingface.co/csukuangfj/kokoro-multi-lang-v1_0/resolve/f7b96bb6bef5c5da4d3aa4f4e0498fbbf62dc78b/"
        return [
            RemoteFile(name: "model.onnx", url: URL(string: base + "model.onnx")!, size: 325_560_556,
                       sha256: "b40f62b166ac8164b0627ef48a0b358eda0985e272fb03ef5252e7206305da11"),
            RemoteFile(name: "voices.bin", url: URL(string: base + "voices.bin")!, size: 28_200_960,
                       sha256: "1c5a5b983d3d50d8586d437a51f3faa2da7919ce76a013c081e65671a3447c29"),
            RemoteFile(name: "tokens.txt", url: URL(string: base + "tokens.txt")!, size: 687, sha256: nil),
            RemoteFile(name: "LICENSE", url: URL(string: base + "LICENSE")!, size: 11_358, sha256: nil),
        ]
    }()

    /// Files left over from the sherpa-onnx archive that this version doesn't read
    /// (eSpeak NG's data, its lexicons, and Chinese text normalization). Aloud 1.5 and
    /// earlier need them, so they stay unless someone tidies up by hand (--tidy-voice).
    static let unusedFiles = ["espeak-ng-data", "dict", "lexicon-us-en.txt", "lexicon-gb-en.txt", "lexicon-zh.txt",
                              "date-zh.fst", "number-zh.fst", "phone-zh.fst"]

    /// Builds made with BUNDLE_MODEL=1 carry the model inside the app. Otherwise it
    /// lives in Application Support: the app downloads it on first launch, and
    /// scripts/setup.sh puts it there for developers.
    static var modelDirectory: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(modelName), isComplete(bundled) {
            return bundled
        }
        return downloadedModelDirectory
    }

    static var downloadedModelDirectory: URL { ModelStore.root.appendingPathComponent(modelName) }

    static var isModelInstalled: Bool { isComplete(modelDirectory) }

    static func isComplete(_ dir: URL) -> Bool {
        ["model.onnx", "voices.bin", "tokens.txt"].allSatisfy {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    /// Removes the eSpeak NG data and other leftovers of the old archive from a
    /// downloaded voice. Never touches a voice bundled inside an app. Only run by hand
    /// (--tidy-voice): at launch they stay, so going back to Aloud 1.5 keeps working.
    static func removeUnusedFiles() {
        let dir = downloadedModelDirectory
        guard isComplete(dir) else { return }
        for name in unusedFiles {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    private let model: OnnxModel
    private let vocab: [Character: Int64]
    private let styles: [Float]          // speakers × 510 × 256
    private let styleCount: Int
    private let styleDim = 256
    private let g2pData: G2PData
    private let lexicon: CustomLexicon
    private var phonemizers: [Accent: Phonemizer] = [:]

    init(threads: Int = Int(ProcessInfo.processInfo.environment["KOKORO_THREADS"] ?? "") ?? 4) throws {
        let dir = Self.modelDirectory
        guard Self.isModelInstalled else { throw EngineError.modelMissing(dir.path) }
        do {
            model = try OnnxModel(path: dir.appendingPathComponent("model.onnx").path, threads: threads)
        } catch {
            throw EngineError.loadFailed("The voice model failed to load (\(error.localizedDescription)).")
        }

        var vocab: [Character: Int64] = [:]
        let tokens = (try? String(contentsOf: dir.appendingPathComponent("tokens.txt"), encoding: .utf8)) ?? ""
        for line in tokens.split(separator: "\n", omittingEmptySubsequences: true) {
            // "<symbol> <id>"; the space symbol's line is " 16".
            guard let space = line.lastIndex(of: " "), let id = Int64(line[line.index(after: space)...]) else { continue }
            let symbol = line[..<space]
            vocab[symbol.isEmpty ? " " : symbol.first!] = id
        }
        guard !vocab.isEmpty else { throw EngineError.loadFailed("The voice model is incomplete (tokens.txt is empty).") }
        self.vocab = vocab

        let voices = try Data(contentsOf: dir.appendingPathComponent("voices.bin"), options: .mappedIfSafe)
        styles = voices.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        styleCount = styles.count / styleDim

        do {
            g2pData = try G2PData.load(from: G2PData.defaultDirectory())
        } catch {
            throw EngineError.loadFailed("The voice model failed to load (\(error.localizedDescription)).")
        }
        lexicon = CustomLexicon(LexiconFiles.shared)
        lexicon.prepare()
    }

    /// Warms up the phonemizer for an accent (loads nothing new; builds lookup state).
    func prepare(_ accent: Accent) {
        _ = phonemizer(accent)
    }

    private func phonemizer(_ accent: Accent) -> Phonemizer {
        if let p = phonemizers[accent] { return p }
        let p = Phonemizer(british: accent == .british, data: g2pData, custom: lexicon)
        phonemizers[accent] = p
        return p
    }

    func phonemes(_ text: String, accent: Accent) -> String {
        phonemizer(accent).phonemize(text)
    }

    /// Synthesizes `text` and returns mono float samples at `sampleRate`.
    /// Long pauses are shortened to a fifth, as sherpa-onnx did with silence_scale 0.2.
    func generate(_ text: String, voice: Voice, speed: Float = 1, scaleSilence: Bool = true) -> [Float] {
        let ps = phonemes(text, accent: voice.accent)
        return generate(phonemes: ps, voice: voice, speed: speed, scaleSilence: scaleSilence)
    }

    func generate(phonemes ps: String, voice: Voice, speed: Float = 1, scaleSilence: Bool = true) -> [Float] {
        let ids = ps.compactMap { vocab[$0] }
        var audio: [Float] = []
        for piece in Self.split(ids, symbols: Array(ps.filter { vocab[$0] != nil })) where !piece.isEmpty {
            let samples = run(piece, speaker: Int(voice.id), speed: speed)
            audio += scaleSilence ? Self.scaleSilence(samples, scale: 0.2) : samples
        }
        return audio
    }

    func tokenIDs(_ ps: String) -> [Int64] { ps.compactMap { vocab[$0] } }

    private func run(_ ids: [Int64], speaker: Int, speed: Float) -> [Float] {
        let row = (speaker * 510 + ids.count) * styleDim
        guard row + styleDim <= styles.count else { return [] }
        let style = Array(styles[row..<(row + styleDim)])
        let tokens = [0] + ids + [0]
        do {
            let out = try model.run([
                .int64("tokens", tokens, shape: [1, Int64(tokens.count)]),
                .float("style", style, shape: [1, Int64(styleDim)]),
                .float("speed", [speed], shape: [1]),
            ], output: "audio")
            return out.values
        } catch {
            NSLog("Kokoro failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Splits token sequences longer than the model accepts, preferably after
    /// punctuation, otherwise at a space.
    static func split(_ ids: [Int64], symbols: [Character]) -> [[Int64]] {
        guard ids.count > maxTokens else { return [ids] }
        var pieces: [[Int64]] = []
        var start = 0
        while ids.count - start > maxTokens {
            let window = (start + maxTokens / 2)..<(start + maxTokens)
            let cut = window.reversed().first { ".!?;:,—…".contains(symbols[$0]) }.map { $0 + 1 }
                ?? window.reversed().first { symbols[$0] == " " }.map { $0 + 1 }
                ?? start + maxTokens
            pieces.append(Array(ids[start..<cut]))
            start = cut
        }
        pieces.append(Array(ids[start...]))
        return pieces
    }

    /// sherpa-onnx's GeneratedAudio::ScaleSilence: stretches of near-silence (|x| ≤ 0.01)
    /// longer than 0.2 s are cut to `scale` of their length.
    static func scaleSilence(_ samples: [Float], scale: Float) -> [Float] {
        let threshold = Int(Float(sampleRate) * 0.2)
        var intervals: [(Int, Int)] = []
        var last = -1
        for i in 0..<samples.count {
            if abs(samples[i]) <= 0.01 {
                if last == -1 { last = i }
                continue
            }
            if last != -1 && i - last < threshold { last = -1; continue }
            if last != -1 { intervals.append((last, i)); last = -1 }
        }
        if last != -1 && samples.count - last > threshold { intervals.append((last, samples.count)) }
        guard !intervals.isEmpty else { return samples }
        var out: [Float] = []
        out.reserveCapacity(samples.count)
        var i = 0
        for (start, end) in intervals {
            out += samples[i..<start]
            let n = Int(Float(end - start) * scale)
            out += samples[start..<(start + min(n, end - start))]
            i = end
        }
        if i < samples.count { out += samples[i...] }
        return out
    }
}

/// Where custom pronunciations come from: the lists shipped in the app, then the
/// user's own folder (~/Library/Application Support/ReadAloud/lexicons), which wins.
enum LexiconFiles {
    static var userDirectory: URL {
        ModelStore.root.deletingLastPathComponent().appendingPathComponent("lexicons")
    }

    /// Every list, read once per launch and shared by reading and dictation.
    static let shared = LexiconSet(directories: directories)

    static var directories: [URL] {
        var dirs: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("lexicons"),
           FileManager.default.fileExists(atPath: bundled.path) {
            dirs.append(bundled)
        } else {
            // Running from a source checkout (swift build).
            dirs.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Lexicons"))
        }
        dirs.append(userDirectory)
        return dirs
    }
}
