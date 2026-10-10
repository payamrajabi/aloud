import Foundation

/// The messaging & internet shorthand pack's reading rules (FIN-896). Its word list is
/// Lexicons/messaging.json ("lol" as the word, "omg" as letters, "bday" as birthday); these are
/// the readings a list can't hold because they depend on what's around them:
///   - emoji are never read: a run of them is a space (keycap digits keep their digit), and so
///     are text emoticons standing on their own (":)", ";-P", "<3", "^_^", "¯\_(ツ)_/¯");
///   - a hashtag is read "hashtag" and its words: "#ThrowbackThursday" → "hashtag Throwback
///     Thursday", "#100DaysOfCode" → "hashtag 100 Days Of Code". Not a hex colour ("#fff",
///     "#1e90ff"), a C directive at the start of a line ("#include"), an HTML entity ("&#39;"),
///     a URL fragment ("page#top") or C# (the "#" follows a letter); "#1" stays Core's number;
///   - an @mention is read "at" and the handle's words: "@JohnDoe" and "@john_doe" → "at John
///     Doe", so a handle that is a name reads as the name ("@payam" → "at Payam"). Not an email
///     address ("me@example.com");
///   - "u", "ur" and "urs" are "you", "your" and "yours" (the owner's decision: shorthand that
///     can be said as a word is read as the word). Lower case only, so "U", "U.S.", "Part U"
///     and "U-turn" keep the letter; never inside code or maths ("u = 5", "f(u)", "u + v"), a
///     tag ("<u>"), a path or handle ("r/u", "@u"), after a number ("5 u" of insulin, 12 u of
///     mass), or before a hyphen or a point that continues ("u-turn", "u.s.").
///
/// On by default: the pack is always on until packs get a Settings switch (FIN-890's follow-up),
/// so these rules and messaging.json's entries are heard by everyone. It runs first among the
/// passes in `Phonemizer.phonemize`, only when normalizing, so the Core passes and the custom
/// lexicon see "you" and "hashtag Throwback Thursday" rather than the shorthand.
public enum MessagingPass {
    public static func apply(_ text: String) -> String {
        var t = text
        if t.unicodeScalars.contains(where: { $0.value >= 0x2000 }) { t = stripEmoji(t) }
        t = stripEmoticons(t)
        if t.contains("#") { t = readHashtags(t) }
        if t.contains("@") { t = readMentions(t) }
        if t.contains("u") { t = readYou(t) }
        return t
    }

    // MARK: - Emoji

    /// Pictographs whose default presentation is text but which are only ever pictures in prose
    /// (hearts, checks, stars, faces, hands). The rest of the text-default emoji (©, ®, ™, ‼, the
    /// arrows, ♀ and ♂) are signs other rules read, and stay unless an emoji selector follows.
    private static let textPictographs: Set<UInt32> = [
        0x2639, 0x263A, 0x263B, 0x2661, 0x2665, 0x2764, 0x2763, 0x2713, 0x2714, 0x2717, 0x2718, 0x2605, 0x2606,
        0x270C, 0x261D, 0x270D, 0x2600, 0x2601, 0x2602, 0x2603, 0x2708, 0x2709, 0x270F, 0x2744, 0x26A1, 0x2622,
        0x2623, 0x262E, 0x262F, 0x2618, 0x2615, 0x26A0, 0x267B, 0x2716, 0x2734, 0x2733, 0x2747,
    ]

    private static func isRegional(_ v: UInt32) -> Bool { v >= 0x1F1E6 && v <= 0x1F1FF }
    private static func isModifier(_ v: UInt32) -> Bool { v >= 0x1F3FB && v <= 0x1F3FF }
    private static func isTag(_ v: UInt32) -> Bool { v >= 0xE0020 && v <= 0xE007F }
    /// The joiners and selectors that only mean something inside an emoji sequence.
    private static func isGlue(_ v: UInt32) -> Bool { v == 0xFE0F || v == 0xFE0E || v == 0x200D || v == 0x20E3 || isModifier(v) || isTag(v) }

    /// Whether `s` (followed by `next`) starts or continues a picture.
    private static func isPicture(_ s: Unicode.Scalar, next: Unicode.Scalar?) -> Bool {
        let v = s.value
        if v < 0x2000 { return false }
        if isRegional(v) || isModifier(v) || textPictographs.contains(v) { return true }
        let p = s.properties
        if p.isEmojiPresentation { return true }
        // A text-default emoji with the emoji selector after it ("❤️", "☀️"), except the signs.
        if p.isEmoji, next?.value == 0xFE0F, !"©®™‼⁉".unicodeScalars.contains(s) { return true }
        return false
    }

    /// Every run of emoji as one space; a keycap keeps its digit ("1️⃣" → "1"; "#️⃣" goes).
    static func stripEmoji(_ text: String) -> String {
        let s = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0, changed = false
        while i < s.count {
            let c = s[i], next = i + 1 < s.count ? s[i + 1] : nil
            // Keycaps: digit, optional FE0F, then U+20E3.
            if c.value < 0x80, "0123456789#*".unicodeScalars.contains(c),
               let n = next, n.value == 0xFE0F || n.value == 0x20E3 {
                var j = i + 1
                while j < s.count, s[j].value == 0xFE0F || s[j].value == 0x20E3 { j += 1 }
                if s[(i + 1)..<j].contains(where: { $0.value == 0x20E3 }) {
                    if Scalars.isDigit(c) { out.append(c) } else { appendSpace(&out) }
                    i = j
                    changed = true
                    continue
                }
            }
            if isPicture(c, next: next) {
                var j = i + 1
                while j < s.count {
                    let v = s[j].value
                    if isGlue(v) { j += 1; continue }
                    if isPicture(s[j], next: j + 1 < s.count ? s[j + 1] : nil) { j += 1; continue }
                    break
                }
                appendSpace(&out)
                i = j
                changed = true
                continue
            }
            // A selector left over after a sign ("©️", "‼️").
            if c.value == 0xFE0F || c.value == 0xFE0E { i += 1; changed = true; continue }
            out.append(c)
            i += 1
        }
        guard changed else { return text }
        return String(out)
    }

    private static func appendSpace(_ out: inout String.UnicodeScalarView) {
        if let last = out.last, last == " " || last == "\n" || last == "\t" { return }
        out.append(" ")
    }

    // MARK: - Emoticons

    /// Emoticons standing on their own, as words: before them the start, a space or an opening
    /// quote, after them the end, a space or a closing mark (so "C:\", "http://" and "a[:]" stay).
    private static let emoticon = try! NSRegularExpression(pattern:
        #"(?<![^\s“"])(?:[:;=][-'’^o]?[)(DPpOo3|/\\*$@]+|[xX][DP]|<\/?3+|\^_?\^|\^\.\^|-_-|T_T|>_<|>\.<|[oO]_[oO]|[oO]\.[oO]|\*_\*|[xX]_[xX]|;_;|¯\\_\(ツ\)_\/¯)(?=$|[\s.,!?;)\]”"])"#)

    static func stripEmoticons(_ text: String) -> String {
        let ns = text as NSString
        let matches = emoticon.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = "", last = 0
        for m in matches {
            let found = ns.substring(with: m.range)
            // "XD" and "XP" in capitals are as often names (Adobe XD, Windows XP).
            if found == "XD" || found == "XP" || found == "xP" { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + " "
            last = NSMaxRange(m.range)
        }
        return out + ns.substring(from: last)
    }

    // MARK: - Hashtags

    private static let hashtag = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_&#/\\'’@.:\-])#(\d*\p{L}[\p{L}\p{N}_]*)"#)
    private static let directives: Set<String> = [
        "include", "define", "undef", "if", "ifdef", "ifndef", "elif", "else", "endif", "pragma", "import",
        "error", "warning", "line", "region", "endregion", "using",
    ]

    /// Whether the hashtag body `tag` (after "#") is a word tag rather than a colour or a directive;
    /// `lineStart` says whether only spaces come before the "#" on its line.
    static func isWordTag(_ tag: String, lineStart: Bool) -> Bool {
        if lineStart, directives.contains(tag) { return false }
        // Digits first: a tag only with a word after them ("#2020Vision", "#100DaysOfCode"), not a
        // numbered item ("#4B", "Rule #3a", "#12th"), which stays Core's.
        if let first = tag.first, first.isNumber {
            let letters = tag.drop { $0.isNumber }
            let word = letters.prefix { $0.isLetter }.lowercased()
            if word.count < 3 || ["st", "nd", "rd", "th"].contains(word) { return false }
        }
        let hex = tag.allSatisfy { $0.isHexDigit }
        guard hex, [3, 4, 6, 8].contains(tag.count) else { return true }
        // A colour: digits in it ("#1e90ff"), short ("#fff", "#abc"), one or two letters
        // ("#ffffff", "#ababab") or in pairs ("#aabbcc"). "#decade" and "#facade" are tags.
        if tag.contains(where: \.isNumber) || tag.count <= 4 { return false }
        let lower = Array(tag.lowercased())
        if Set(lower).count <= 2 { return false }
        let paired = stride(from: 0, to: lower.count - 1, by: 2).allSatisfy { lower[$0] == lower[$0 + 1] }
        return !paired
    }

    /// For the player's text clean-up (TextPrep), which drops "#" as markup unless something reads
    /// it: whether the "#" between `before` and `after` starts a hashtag this pass reads.
    public static func startsHashtag(before: String, after: String) -> Bool {
        if let p = before.last, p.isLetter || p.isNumber || "_&#/\\'’@.:-".contains(p) { return false }
        let tag = String(after.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
        guard tag.contains(where: \.isLetter), let first = tag.first, first.isLetter || first.isNumber else { return false }
        if let firstLetter = tag.firstIndex(where: \.isLetter), !tag[..<firstLetter].allSatisfy(\.isNumber) { return false }
        let lineStart = before.reversed().prefix { $0 != "\n" }.allSatisfy { $0 == " " || $0 == "\t" }
            && (before.contains("\n") || before.count < 24)
        return isWordTag(tag, lineStart: lineStart)
    }

    static func readHashtags(_ text: String) -> String {
        let ns = text as NSString
        let matches = hashtag.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var casing: ShoutedCasing?
        var out = "", last = 0
        for m in matches {
            let tag = ns.substring(with: m.range(at: 1))
            let lineStart = ns.substring(to: m.range.location).reversed().prefix { $0 != "\n" }.allSatisfy { $0 == " " || $0 == "\t" }
            guard isWordTag(tag, lineStart: lineStart) else { continue }
            if casing == nil { casing = ShoutedCasing(text) }
            let word = casing!.cased("hashtag", at: m.range.location)
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + word + " " + words(of: tag)
            last = NSMaxRange(m.range)
        }
        return out + ns.substring(from: last)
    }

    /// A tag or handle as words: "_" and "." are spaces, and words split where the case changes
    /// ("ThrowbackThursday", "HTMLParser" → "HTML Parser") and between letters and digits
    /// ("100DaysOfCode", "COVID19"), but not before an ordinal's letters ("1st").
    static func words(of tag: String, titleCase: Bool = false) -> String {
        let chars = Array(tag)
        var out = ""
        for (i, c) in chars.enumerated() {
            if c == "_" || c == "." {
                if !out.isEmpty, out.last != " " { out.append(" ") }
                continue
            }
            if i > 0, out.last != " ", !out.isEmpty {
                let p = chars[i - 1]
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                var split = false
                if p.isLowercase && c.isUppercase { split = true }
                if p.isUppercase && c.isUppercase, let n = next, n.isLowercase { split = true }
                if p.isLetter && c.isNumber { split = true }
                if p.isNumber && c.isLetter {
                    let rest = String(chars[i...].prefix { $0.isLetter }).lowercased()
                    split = !["st", "nd", "rd", "th", "s"].contains(rest)
                }
                if split { out.append(" ") }
            }
            out.append(c)
        }
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        guard titleCase else { return trimmed }
        // An all-lower-case part of a handle reads like a name ("@payam" → "Payam").
        return trimmed.split(separator: " ").map { part -> String in
            guard part.allSatisfy({ !$0.isLetter || $0.isLowercase }), let first = part.first, first.isLetter else { return String(part) }
            return first.uppercased() + part.dropFirst()
        }.joined(separator: " ")
    }

    // MARK: - Mentions

    private static let mention = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_.@/\\+\-])@([\p{L}_][\p{L}\p{N}_]*(?:\.[\p{L}\p{N}_]+)*)"#)

    static func readMentions(_ text: String) -> String {
        let ns = text as NSString
        let matches = mention.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var casing: ShoutedCasing?
        var out = "", last = 0
        for m in matches {
            let handle = ns.substring(with: m.range(at: 1))
            guard handle.contains(where: \.isLetter) else { continue }
            if casing == nil { casing = ShoutedCasing(text) }
            let at = casing!.cased("at", at: m.range.location)
            let shouted = casing!.isShouted(at: m.range.location)
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + at + " "
                + words(of: handle, titleCase: !shouted)
            last = NSMaxRange(m.range)
        }
        return out + ns.substring(from: last)
    }

    // MARK: - u, ur, urs

    private static let youWords = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])(urs|ur|u)(?![\p{L}\p{N}_])"#)
    private static let youReadings = ["u": "you", "ur": "your", "urs": "yours"]
    /// What may not stand right before the word: it would be part of a token, a path, a tag or code.
    private static let blockedBefore = Set(".'’/\\<>@#&$%^*=+-~|`")
    private static let mathAfter = Set("=+*/^<>≤≥≠×÷|")

    static func readYou(_ text: String) -> String {
        let ns = text as NSString
        let matches = youWords.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        let chars = Array(text.utf16)
        func char(_ i: Int) -> Character? {
            guard i >= 0, i < chars.count, let u = Unicode.Scalar(chars[i]) else { return nil }
            return Character(u)
        }
        var out = "", last = 0
        for m in matches {
            let found = ns.substring(with: m.range)
            let start = m.range.location, end = NSMaxRange(m.range)
            // Before: nothing that joins it to a token; not "f(u)"; not right after a number ("5 u").
            if let p = char(start - 1) {
                if blockedBefore.contains(p) { continue }
                if p == "(", let q = char(start - 2), q.isLetter { continue }
            }
            var k = start - 1
            while let c = char(k), c == " " || c == "\t" { k -= 1 }
            if k < start - 1, let c = char(k), c.isNumber { continue }
            if let c = char(k), mathAfter.contains(c) || c == "=" { continue }
            // After: a contraction for "u" ("u'll" → "you'll"); otherwise nothing that continues a
            // token ("u-turn", "u.s.", "u/", "<u>", "u(t)"), and no maths ("u = 5", "u + v").
            if let n = char(end) {
                if n == "'" || n == "’" {
                    let rest = ns.substring(from: end + 1).prefix { $0.isLetter }.lowercased()
                    guard found == "u", ["ll", "re", "ve", "d"].contains(rest) else { continue }
                } else if n == "-" || n == "/" || n == ">" || n == "@" || n == "(" || n == "_" {
                    continue
                } else if n == ".", let nn = char(end + 1), nn.isLetter || nn.isNumber {
                    continue
                }
            }
            var j = end
            while let c = char(j), c == " " || c == "\t" { j += 1 }
            if let c = char(j), mathAfter.contains(c) {
                // "<3" after "u" is a heart, already gone by now; any other "<" is maths.
                continue
            }
            out += ns.substring(with: NSRange(location: last, length: start - last)) + youReadings[found]!
            last = end
        }
        return out + ns.substring(from: last)
    }
}
