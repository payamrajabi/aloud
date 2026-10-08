import Foundation
import llama

/// A small language model run by llama.cpp on the GPU, for short, deterministic text
/// jobs. Fixed openings (instructions and examples) are processed once and remembered,
/// so each request only pays for its own text.
/// Not thread-safe: call it from a single serial queue.
final class LlamaEngine {
    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let vocab: OpaquePointer
    private let sampler: UnsafeMutablePointer<llama_sampler>
    private let batchSize: Int32 = 512

    /// Remembered openings and the model's state after each.
    private var prefixes: [String: [UInt8]] = [:]

    init(path: String, contextLength: UInt32 = 8192) throws {
        Self.setUp()
        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 999
        guard let model = llama_model_load_from_file(path, mparams) else { throw EngineError.loadFailed }
        var cparams = llama_context_default_params()
        cparams.n_ctx = contextLength
        cparams.n_batch = UInt32(batchSize)
        cparams.n_ubatch = UInt32(batchSize)
        cparams.n_threads = 4
        cparams.n_threads_batch = 4
        cparams.no_perf = true
        guard let ctx = llama_init_from_model(model, cparams) else {
            llama_model_free(model)
            throw EngineError.loadFailed
        }
        self.model = model
        self.ctx = ctx
        vocab = llama_model_get_vocab(model)
        sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
    }

    deinit {
        llama_sampler_free(sampler)
        llama_free(ctx)
        llama_model_free(model)
    }

    private static let setUpOnce: Void = {
        if ProcessInfo.processInfo.environment["LLAMA_LOG"] == nil {
            llama_log_set({ _, _, _ in }, nil)  // llama.cpp is chatty on stderr
        }
        llama_backend_init()
    }()

    private static func setUp() { _ = setUpOnce }

    /// Continues `prompt` greedily until the model ends its turn, `stop` says so, or
    /// `maxTokens` is reached. A prompt that starts with a remembered opening skips it.
    func complete(prompt: String, maxTokens: Int, stop: ((String) -> Bool)? = nil) -> String? {
        guard prepare(prompt) else { return nil }
        var bytes: [UInt8] = []
        var piece = [CChar](repeating: 0, count: 256)
        for _ in 0..<maxTokens {
            var token = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            let n = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if n > 0 { bytes += piece[0..<Int(n)].map { UInt8(bitPattern: $0) } }
            if let stop, stop(String(decoding: bytes, as: UTF8.self)) { break }
            guard llama_decode(ctx, llama_batch_get_one(&token, 1)) == 0 else { return nil }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Restores the longest remembered opening the prompt starts with, if any, and feeds
    /// the rest of the prompt, leaving the model ready to generate.
    private func prepare(_ prompt: String) -> Bool {
        llama_memory_clear(llama_get_memory(ctx), true)
        llama_sampler_reset(sampler)
        var rest = prompt
        let known = prefixes.filter { prompt.hasPrefix($0.key) }.max { $0.key.count < $1.key.count }
        if let (prefix, state) = known {
            guard llama_state_seq_set_data(ctx, state, state.count, 0) == state.count else { return false }
            rest = String(prompt.dropFirst(prefix.count))
        }
        return feed(tokenize(rest, first: rest == prompt))
    }

    /// Remembers `text`, an opening that many prompts share, so it's only processed once.
    /// It should end at a clean token boundary, such as a special token and a newline.
    /// Building on an opening that's already remembered only costs the extra text.
    func remember(prefix text: String) -> Bool {
        guard prefixes[text] == nil else { return true }
        guard prepare(text) else { return false }
        let size = llama_state_seq_get_size(ctx, 0)
        var state = [UInt8](repeating: 0, count: size)
        guard llama_state_seq_get_data(ctx, &state, size, 0) == size else { return false }
        prefixes[text] = state
        return true
    }

    func forget(prefix text: String) {
        prefixes[text] = nil
    }

    /// Memory held by remembered openings, in bytes.
    var rememberedBytes: Int { prefixes.values.reduce(0) { $0 + $1.count } }

    private func feed(_ tokens: [llama_token]) -> Bool {
        var start = 0
        while start < tokens.count {
            var slice = Array(tokens[start..<min(tokens.count, start + Int(batchSize))])
            guard llama_decode(ctx, llama_batch_get_one(&slice, Int32(slice.count))) == 0 else { return false }
            start += slice.count
        }
        return true
    }

    func tokenize(_ text: String, first: Bool) -> [llama_token] {
        let length = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(length) + 8)
        var n = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), first, true)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), first, true)
        }
        return Array(tokens.prefix(Int(max(n, 0))))
    }
}
