import COrt
import Foundation

/// An ONNX model loaded into ONNX Runtime. Running it is thread-safe.
public final class OnnxModel {
    public enum Input {
        case int64(String, [Int64], shape: [Int64])
        case float(String, [Float], shape: [Int64])
    }

    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    private let session: OpaquePointer

    /// - Parameter threads: ONNX Runtime intra-op threads; 0 lets it decide.
    public init(path: String, threads: Int = 0) throws {
        var err = [CChar](repeating: 0, count: 512)
        guard let s = ortshim_open(path, Int32(threads), &err, err.count) else {
            throw Failure(message: "Couldn't load \((path as NSString).lastPathComponent): \(String(cString: err))")
        }
        session = s
    }

    deinit { ortshim_close(session) }

    /// Runs the model and returns the named float output with its shape.
    public func run(_ inputs: [Input], output: String) throws -> (values: [Float], shape: [Int64]) {
        // Keep every buffer alive (and pinned) for the duration of the C call.
        var names: [UnsafeMutablePointer<CChar>] = []
        var buffers: [UnsafeMutableRawPointer] = []
        var shapes: [UnsafeMutablePointer<Int64>] = []
        defer {
            names.forEach { free($0) }
            buffers.forEach { $0.deallocate() }
            shapes.forEach { $0.deallocate() }
        }
        var cInputs: [OrtShimInput] = []
        for input in inputs {
            let name: String, shape: [Int64], type: OrtShimType, raw: UnsafeMutableRawPointer
            switch input {
            case let .int64(n, values, s):
                name = n; shape = s; type = ORTSHIM_INT64
                let p = UnsafeMutablePointer<Int64>.allocate(capacity: max(values.count, 1))
                p.initialize(from: values, count: values.count)
                raw = UnsafeMutableRawPointer(p)
            case let .float(n, values, s):
                name = n; shape = s; type = ORTSHIM_FLOAT
                let p = UnsafeMutablePointer<Float>.allocate(capacity: max(values.count, 1))
                p.initialize(from: values, count: values.count)
                raw = UnsafeMutableRawPointer(p)
            }
            let cName = strdup(name)!
            let cShape = UnsafeMutablePointer<Int64>.allocate(capacity: max(shape.count, 1))
            cShape.initialize(from: shape, count: shape.count)
            names.append(cName); buffers.append(raw); shapes.append(cShape)
            cInputs.append(OrtShimInput(name: cName, type: type, data: raw, shape: cShape, rank: shape.count))
        }

        var out: UnsafeMutablePointer<Float>?
        var outShape = [Int64](repeating: 0, count: 8)
        var rank = 0
        var err = [CChar](repeating: 0, count: 512)
        let rc = ortshim_run(session, cInputs, cInputs.count, output, &out, &outShape, &rank, &err, err.count)
        guard rc == 0, let out else { throw Failure(message: String(cString: err)) }
        defer { ortshim_free(out) }
        let shape = Array(outShape.prefix(rank))
        let count = shape.reduce(1) { $0 * Int($1) }
        return (Array(UnsafeBufferPointer(start: out, count: count)), shape)
    }
}
