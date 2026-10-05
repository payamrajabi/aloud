import CSherpaOnnx
import Foundation

/// Speech-to-text with NVIDIA Parakeet TDT 0.6B v2 (English) through sherpa-onnx.
/// Not thread-safe: call it from a single serial queue.
final class ParakeetEngine {
    static let sampleRate = 16_000
    static let modelName = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"
    static let downloadURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(modelName).tar.bz2")!

    static var modelsRoot: URL {
        if let override = ProcessInfo.processInfo.environment["READALOUD_MODELS_DIR"] {  // for testing fresh installs
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ReadAloud/models")
    }

    static var modelDirectory: URL { modelsRoot.appendingPathComponent(modelName) }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("tokens.txt").path)
    }

    private let recognizer: OpaquePointer

    init(threads: Int = 4) throws {
        let dir = Self.modelDirectory
        guard Self.isInstalled else { throw EngineError.modelMissing(dir.path) }
        func path(_ name: String) -> String { dir.appendingPathComponent(name).path }

        var owned: [UnsafeMutablePointer<CChar>] = []
        func c(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            owned.append(p)
            return UnsafePointer(p)
        }
        defer { owned.forEach { free($0) } }

        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = Int32(Self.sampleRate)
        config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = c(path("encoder.int8.onnx"))
        config.model_config.transducer.decoder = c(path("decoder.int8.onnx"))
        config.model_config.transducer.joiner = c(path("joiner.int8.onnx"))
        config.model_config.tokens = c(path("tokens.txt"))
        config.model_config.model_type = c("nemo_transducer")
        config.model_config.num_threads = Int32(threads)
        config.model_config.provider = c("cpu")
        config.model_config.debug = ProcessInfo.processInfo.environment["SHERPA_DEBUG"] == nil ? 0 : 1
        config.decoding_method = c("greedy_search")

        guard let recognizer = SherpaOnnxCreateOfflineRecognizer(&config) else { throw EngineError.loadFailed }
        self.recognizer = recognizer
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
    }

    /// Transcribes 16 kHz mono audio. Long recordings are split at quiet moments
    /// so memory and latency stay predictable.
    func transcribe(_ samples: [Float]) -> String {
        let text = Self.split(samples)
            .map { decode($0) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // The tokenizer occasionally glues a currency sign to the previous word ("spend$100").
        return text.replacingOccurrences(of: "([A-Za-z])([$€£])", with: "$1 $2", options: .regularExpression)
    }

    private func decode(_ samples: ArraySlice<Float>) -> String {
        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { return "" }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer { buf in
            SherpaOnnxAcceptWaveformOffline(stream, Int32(Self.sampleRate), buf.baseAddress, Int32(buf.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { return "" }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        guard let text = result.pointee.text else { return "" }
        return String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cuts audio into pieces of roughly 45 s, each cut placed at the quietest
    /// 200 ms within ±10 s of the target so words aren't split.
    static func split(_ s: [Float]) -> [ArraySlice<Float>] {
        let target = 45 * sampleRate
        let window = 10 * sampleRate
        let frame = sampleRate / 5
        var pieces: [ArraySlice<Float>] = []
        var start = 0
        while s.count - start > target + window {
            let lo = start + target - window
            let hi = start + target + window - frame
            var best = lo
            var bestEnergy = Float.greatestFiniteMagnitude
            for i in stride(from: lo, to: hi, by: frame / 2) {
                var energy: Float = 0
                for j in i..<(i + frame) { energy += s[j] * s[j] }
                if energy < bestEnergy { bestEnergy = energy; best = i }
            }
            let cut = best + frame / 2
            pieces.append(s[start..<cut])
            start = cut
        }
        pieces.append(s[start..<s.count])
        return pieces
    }
}
