import Foundation

/// A small reader for lexicon files: a JSON array of flat objects (or an object holding
/// that array under "entries" or "words"), keeping only string and string-array fields.
///
/// JSONSerialization plus bridging every field into Swift took about 30 ms for a
/// 10,000-entry list, most of the launch budget; this reads the bytes directly and
/// takes a few. Anything it doesn't expect (malformed JSON included) returns nil, and
/// the caller falls back to JSONSerialization, which also explains what's wrong.
enum LexiconJSON {
    /// The fields a lexicon entry uses; everything else is skipped.
    struct Object {
        var word: String?
        var match: String?
        var us: String?
        var gb: String?
        var dictation: String?
        var spoken: [String]?
        var spokenVariants: [String]?
        var spokenContextOnly: [String]?
        /// A known field holding an unexpected kind of value: read the file the slow way.
        var malformed = false
    }

    private enum Field {
        case word, match, us, gb, dictation, spoken, spokenVariants, spokenContextOnly, other

        init(_ key: UnsafeBufferPointer<UInt8>) {
            switch key.count {
            case 2: self = Self.equal(key, "us") ? .us : Self.equal(key, "gb") ? .gb : .other
            case 4: self = Self.equal(key, "word") ? .word : .other
            case 5: self = Self.equal(key, "match") ? .match : .other
            case 6: self = Self.equal(key, "spoken") ? .spoken : .other
            case 9: self = Self.equal(key, "dictation") ? .dictation : .other
            case 15: self = Self.equal(key, "spoken_variants") ? .spokenVariants : .other
            case 19: self = Self.equal(key, "spoken_context_only") ? .spokenContextOnly : .other
            default: self = .other
            }
        }

        private static func equal(_ key: UnsafeBufferPointer<UInt8>, _ s: StaticString) -> Bool {
            guard key.count == s.utf8CodeUnitCount else { return false }
            let b = s.utf8Start
            for j in 0..<key.count where key[j] != b[j] { return false }
            return true
        }
    }

    static func parse(_ data: Data) -> [Object]? {
        data.withUnsafeBytes { raw -> [Object]? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var r = Reader(p: base, n: raw.count)
            return r.document()
        }
    }

    private struct Reader {
        let p: UnsafePointer<UInt8>
        let n: Int
        var i = 0

        init(p: UnsafePointer<UInt8>, n: Int) {
            self.p = p
            self.n = n
            // A UTF-8 byte order mark.
            if n >= 3, p[0] == 0xEF, p[1] == 0xBB, p[2] == 0xBF { i = 3 }
        }

        mutating func document() -> [Object]? {
            skipSpace()
            guard i < n else { return nil }
            var result: [Object]?
            if p[i] == UInt8(ascii: "[") {
                result = objects()
            } else if p[i] == UInt8(ascii: "{") {
                // { "entries": [ ... ] } (or "words")
                i += 1
                skipSpace()
                if i < n, p[i] == UInt8(ascii: "}") { return nil }
                while true {
                    skipSpace()
                    guard let key = string() else { return nil }
                    skipSpace()
                    guard i < n, p[i] == UInt8(ascii: ":") else { return nil }
                    i += 1
                    skipSpace()
                    if result == nil, key == "entries" || key == "words", i < n, p[i] == UInt8(ascii: "[") {
                        guard let list = objects() else { return nil }
                        result = list
                    } else {
                        guard skipValue() else { return nil }
                    }
                    skipSpace()
                    guard i < n else { return nil }
                    if p[i] == UInt8(ascii: ",") { i += 1; continue }
                    guard p[i] == UInt8(ascii: "}") else { return nil }
                    i += 1
                    break
                }
            } else {
                return nil
            }
            skipSpace()
            return i == n ? result : nil
        }

        /// An array of objects; other kinds of items are skipped.
        mutating func objects() -> [Object]? {
            guard i < n, p[i] == UInt8(ascii: "[") else { return nil }
            i += 1
            var out: [Object] = []
            out.reserveCapacity(n / 120)
            skipSpace()
            if i < n, p[i] == UInt8(ascii: "]") { i += 1; return out }
            while true {
                skipSpace()
                guard i < n else { return nil }
                if p[i] == UInt8(ascii: "{") {
                    guard let o = object() else { return nil }
                    out.append(o)
                } else {
                    guard skipValue() else { return nil }
                }
                skipSpace()
                guard i < n else { return nil }
                if p[i] == UInt8(ascii: ",") { i += 1; continue }
                guard p[i] == UInt8(ascii: "]") else { return nil }
                i += 1
                return out
            }
        }

        mutating func object() -> Object? {
            i += 1   // {
            var o = Object()
            skipSpace()
            if i < n, p[i] == UInt8(ascii: "}") { i += 1; return o }
            while true {
                skipSpace()
                guard let field = key() else { return nil }
                skipSpace()
                guard i < n, p[i] == UInt8(ascii: ":") else { return nil }
                i += 1
                skipSpace()
                guard i < n else { return nil }
                switch field {
                case .other:
                    guard skipValue() else { return nil }
                case .spoken, .spokenVariants, .spokenContextOnly:
                    guard p[i] == UInt8(ascii: "["), let list = stringList() else {
                        guard skipValue() else { return nil }
                        o.malformed = true
                        break
                    }
                    switch field {
                    case .spoken: o.spoken = list
                    case .spokenVariants: o.spokenVariants = list
                    default: o.spokenContextOnly = list
                    }
                default:
                    guard p[i] == UInt8(ascii: "\"") else {
                        let start = i
                        guard skipValue() else { return nil }
                        // "gb": null is fine; any other surprise goes the slow way.
                        if !(field == .gb && i - start == 4 && p[start] == UInt8(ascii: "n")) { o.malformed = true }
                        break
                    }
                    guard let s = string() else { return nil }
                    switch field {
                    case .word: o.word = s
                    case .match: o.match = s
                    case .us: o.us = s
                    case .gb: o.gb = s
                    default: o.dictation = s
                    }
                }
                skipSpace()
                guard i < n else { return nil }
                if p[i] == UInt8(ascii: ",") { i += 1; continue }
                guard p[i] == UInt8(ascii: "}") else { return nil }
                i += 1
                return o
            }
        }

        /// An object key, identified without making a string when it has no escapes.
        mutating func key() -> Field? {
            guard i < n, p[i] == UInt8(ascii: "\"") else { return nil }
            var j = i + 1
            while j < n, p[j] != UInt8(ascii: "\""), p[j] != UInt8(ascii: "\\") { j += 1 }
            guard j < n else { return nil }
            if p[j] == UInt8(ascii: "\"") {
                let field = Field(UnsafeBufferPointer(start: p + i + 1, count: j - i - 1))
                i = j + 1
                return field
            }
            guard var s = string() else { return nil }
            return s.withUTF8 { Field($0) }
        }

        /// The strings in an array (other items are skipped).
        mutating func stringList() -> [String]? {
            i += 1   // [
            var out: [String] = []
            skipSpace()
            if i < n, p[i] == UInt8(ascii: "]") { i += 1; return out }
            while true {
                skipSpace()
                guard i < n else { return nil }
                if p[i] == UInt8(ascii: "\"") {
                    guard let s = string() else { return nil }
                    out.append(s)
                } else {
                    guard skipValue() else { return nil }
                }
                skipSpace()
                guard i < n else { return nil }
                if p[i] == UInt8(ascii: ",") { i += 1; continue }
                guard p[i] == UInt8(ascii: "]") else { return nil }
                i += 1
                return out
            }
        }

        mutating func string() -> String? {
            guard i < n, p[i] == UInt8(ascii: "\"") else { return nil }
            i += 1
            let start = i
            while i < n, p[i] != UInt8(ascii: "\""), p[i] != UInt8(ascii: "\\") {
                guard p[i] >= 0x20 else { return nil }
                i += 1
            }
            guard i < n else { return nil }
            if p[i] == UInt8(ascii: "\"") {
                let s = String(decoding: UnsafeBufferPointer(start: p + start, count: i - start), as: UTF8.self)
                i += 1
                return s
            }
            // Escapes: copy into a buffer.
            var bytes = Array(UnsafeBufferPointer(start: p + start, count: i - start))
            while i < n {
                let c = p[i]
                if c == UInt8(ascii: "\"") {
                    i += 1
                    return String(decoding: bytes, as: UTF8.self)
                }
                if c != UInt8(ascii: "\\") {
                    guard c >= 0x20 else { return nil }
                    bytes.append(c)
                    i += 1
                    continue
                }
                i += 1
                guard i < n else { return nil }
                let e = p[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): bytes.append(e)
                case UInt8(ascii: "b"): bytes.append(0x08)
                case UInt8(ascii: "f"): bytes.append(0x0C)
                case UInt8(ascii: "n"): bytes.append(0x0A)
                case UInt8(ascii: "r"): bytes.append(0x0D)
                case UInt8(ascii: "t"): bytes.append(0x09)
                case UInt8(ascii: "u"):
                    guard var code = hex4() else { return nil }
                    if code >= 0xD800, code < 0xDC00 {
                        // A surrogate pair.
                        guard i + 1 < n, p[i] == UInt8(ascii: "\\"), p[i + 1] == UInt8(ascii: "u") else { return nil }
                        i += 2
                        guard let low = hex4(), low >= 0xDC00, low < 0xE000 else { return nil }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let scalar = Unicode.Scalar(code) else { return nil }
                    bytes.append(contentsOf: Array(String(scalar).utf8))
                default: return nil
                }
            }
            return nil
        }

        mutating func hex4() -> UInt32? {
            guard i + 4 <= n else { return nil }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let c = p[i]
                let d: UInt32
                switch c {
                case 0x30...0x39: d = UInt32(c - 0x30)
                case 0x41...0x46: d = UInt32(c - 0x41 + 10)
                case 0x61...0x66: d = UInt32(c - 0x61 + 10)
                default: return nil
                }
                v = v << 4 | d
                i += 1
            }
            return v
        }

        /// Skips any JSON value.
        mutating func skipValue() -> Bool {
            skipSpace()
            guard i < n else { return false }
            switch p[i] {
            case UInt8(ascii: "\""):
                return string() != nil
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                let close = p[i] == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: "]")
                let isObject = p[i] == UInt8(ascii: "{")
                i += 1
                skipSpace()
                if i < n, p[i] == close { i += 1; return true }
                while true {
                    skipSpace()
                    if isObject {
                        guard string() != nil else { return false }
                        skipSpace()
                        guard i < n, p[i] == UInt8(ascii: ":") else { return false }
                        i += 1
                    }
                    guard skipValue() else { return false }
                    skipSpace()
                    guard i < n else { return false }
                    if p[i] == UInt8(ascii: ",") { i += 1; continue }
                    guard p[i] == close else { return false }
                    i += 1
                    return true
                }
            default:
                // A number, true, false or null.
                let start = i
                while i < n {
                    let c = p[i]
                    if (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7A) || c == UInt8(ascii: "-") || c == UInt8(ascii: "+")
                        || c == UInt8(ascii: ".") || c == UInt8(ascii: "E") {
                        i += 1
                    } else {
                        break
                    }
                }
                return i > start
            }
        }

        @inline(__always) mutating func skipSpace() {
            while i < n, p[i] == 0x20 || p[i] == 0x0A || p[i] == 0x0D || p[i] == 0x09 { i += 1 }
        }
    }
}
