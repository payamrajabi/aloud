import Foundation

/// A misaki gold-lexicon entry: one pronunciation, or one per part of speech
/// (heteronyms such as "read", "record", "live"), always with a DEFAULT.
enum GoldEntry {
    case plain(String)
    case tagged([String: String?])
}

/// The pronunciation data the phonemizer reads, built by scripts/make-g2p-data.py:
/// misaki gold lexicons (US, GB), CMUdict, and the mini-bart G2P model. Loaded once
/// per process and shared; loading takes a few hundred milliseconds.
public final class G2PData {
    public let directory: URL
    let golds: [Bool: [String: GoldEntry]]   // keyed by `british`
    let cmudict: [String: String]            // lower-cased word → ARPAbet
    let miniBart: MiniBart?

    public struct Missing: LocalizedError {
        public let path: String
        public var errorDescription: String? { "Aloud's pronunciation data is missing (expected at \(path))." }
    }

    private static let lock = NSLock()
    private static var cache: [URL: G2PData] = [:]

    /// Loads (or returns the already loaded) data in `directory`.
    public static func load(from directory: URL) throws -> G2PData {
        lock.lock()
        defer { lock.unlock() }
        if let d = cache[directory] { return d }
        let d = try G2PData(directory: directory)
        cache[directory] = d
        return d
    }

    private init(directory: URL) throws {
        self.directory = directory
        func file(_ name: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { throw Missing(path: url.path) }
            return url
        }
        var golds: [Bool: [String: GoldEntry]] = [:]
        for british in [false, true] {
            let data = try Data(contentsOf: try file(british ? "gb_gold.json" : "us_gold.json"))
            golds[british] = Self.grow(try Self.parseGold(data))
        }
        self.golds = golds
        var cmu: [String: String] = [:]
        let text = try String(contentsOf: try file("cmudict.tsv"), encoding: .utf8)
        cmu.reserveCapacity(130_000)
        for line in text.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            cmu[String(line[..<tab])] = String(line[line.index(after: tab)...])
        }
        self.cmudict = cmu
        miniBart = try? MiniBart(directory: directory)
    }

    private static func parseGold(_ data: Data) throws -> [String: GoldEntry] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: GoldEntry] = [:]
        out.reserveCapacity(json.count)
        for (k, v) in json {
            if let s = v as? String {
                out[k] = .plain(s)
            } else if let d = v as? [String: Any] {
                var tagged: [String: String?] = [:]
                for (tag, p) in d { tagged[tag] = p as? String }
                out[k] = .tagged(tagged)
            }
        }
        return out
    }

    /// misaki's grow_dictionary: adds "Word" for "word" and "word" for "Word".
    private static func grow(_ d: [String: GoldEntry]) -> [String: GoldEntry] {
        var e: [String: GoldEntry] = [:]
        for (k, v) in d where k.count >= 2 {
            if k == k.pyLower {
                let c = k.pyCapitalize
                if k != c { e[c] = v }
            } else if k == k.pyLower.pyCapitalize {
                e[k.pyLower] = v
            }
        }
        return e.merging(d) { _, original in original }
    }

    /// Where the data lives: $READALOUD_G2P_DIR, the app bundle (Resources/g2p), or
    /// Vendor/g2p in a source checkout (for `swift build` runs).
    public static func defaultDirectory(bundle: Bundle = .main) -> URL {
        if let override = ProcessInfo.processInfo.environment["READALOUD_G2P_DIR"] {
            return URL(fileURLWithPath: override)
        }
        let bundled = bundle.resourceURL?.appendingPathComponent("g2p")
        if let r = bundled, FileManager.default.fileExists(atPath: r.appendingPathComponent("us_gold.json").path) {
            return r
        }
        if let root = sourceRoot(bundle: bundle) {
            return root.appendingPathComponent("Vendor/g2p")
        }
        return bundled ?? URL(fileURLWithPath: "g2p")  // missing; loading it reports that
    }

    /// The repository root when running a `swift build` binary from a source checkout:
    /// the nearest folder above the executable (.build/<triple>/<config>/) that holds
    /// Package.swift. Found at run time, not with #filePath, which would put the build
    /// machine's folder (and its user name) into every release binary.
    static func sourceRoot(bundle: Bundle = .main) -> URL? {
        var dir = bundle.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        while let d = dir, d.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: d.appendingPathComponent("Package.swift").path) { return d }
            dir = d.deletingLastPathComponent()
        }
        return nil
    }
}
