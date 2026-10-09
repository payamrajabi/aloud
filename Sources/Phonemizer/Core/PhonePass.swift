import Foundation

/// Phone numbers (Core readings, FIN-889; area "phone"): North American, international "+" and
/// trunk-0 numbers, extensions, area codes, emergency and short codes, SMS codes, and the "*"
/// key.
///
/// The pass runs after money (its start boundary already excludes "$"), before the address pass
/// (a ZIP or ZIP+4 is a shape it rejects), before the custom lexicon, whose keys "+1", "401" and
/// "404" would split a run of digits, and before the measures pass, so "x 214" after a number
/// is an extension, not a size. It writes words, so no later digit rule touches a number it read.
///
/// A number is read the way people say one aloud: digit by digit with "oh" for 0, a pause (a
/// comma, which Kokoro pauses at) between the written groups. Read as values, the groups were
/// other numbers ("four hundred sixteen, five fifty-five…"), and the lexicon reads a lone 0 as
/// "zero". Shapes that are as often something else (a seven-digit number, digits spaced 3-3-4,
/// Australian 1800 numbers) are phone numbers only straight after a cue ("Call", "Phone:", "my
/// number is"); a miss keeps today's reading, which is better than a date or a count read as
/// digits.
enum PhonePass {
    typealias Rule = TextNormalizer.Rule

    /// The phone pass: in `Phonemizer.phonemize` after the money pass, only when normalizing.
    /// Its words go through `ShoutedCasing` and `SpokenNumbers`. Each reading runs once over
    /// the text, in the order cross.json gives: whole numbers first (with their extensions), then
    /// what only reads as a phone number on its own after a cue word.
    static func apply(_ text: String, british: Bool) -> String {
        // Every reading needs a digit, except the "*" key.
        guard text.utf16.contains(where: { (0x30...0x39).contains($0) || $0 == 0x2A }) else { return text }
        var t = text
        for reading in readings { t = reading.apply(to: t) }
        t = readMeetingIDs(t, british: british)
        return t
    }

    /// A meeting's ID or passcode, digit by digit in its groups: "Meeting ID: 845 1234 5678",
    /// "Passcode: 902114", "Phone conference ID: 812 345 678#" (the "#" is the key: "pound", or
    /// "hash" in the British voice). Read as values they were "eight hundred forty five, twelve
    /// thirty four".
    private static let meetingID = try! NSRegularExpression(pattern:
        #"(?<![\p{L}])((?i:meeting|conference|webinar|participant|access|attendee)[ \t]+(?i:ID|code|number)|Passcode|passcode|PASSCODE)([ \t]*[:#]?[ \t]*)(\d{3,}(?:[ \x{00A0}\-]\d{2,})*)(#?)(?![\d\p{L}])"#)

    private static func readMeetingIDs(_ text: String, british: Bool) -> String {
        guard text.utf16.contains(where: { $0 == 0x49 || $0 == 0x69 || $0 == 0x50 || $0 == 0x70 }) else { return text }
        let ns = text as NSString
        let matches = meetingID.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var casing: ShoutedCasing?
        var out = "", last = 0
        for m in matches {
            let groups = ns.substring(with: m.range(at: 3)).split(whereSeparator: { !$0.isNumber }).map(String.init)
            var words = groups.map(groupWords).joined(separator: ", ")
            if m.range(at: 4).length > 0 { words += british ? " hash" : " pound" }
            if casing == nil { casing = ShoutedCasing(text) }
            out += ns.substring(with: NSRange(location: last, length: m.range(at: 3).location - last)) + casing!.cased(words, at: m.range(at: 3).location)
            last = NSMaxRange(m.range)
        }
        return out + ns.substring(from: last)
    }

    /// fix3/reading's phone rule (a leading 0 or "+") is the pass's trunk-0 and "+" readings now.
    /// It read dates, 24-hour times and lotto lists as phone numbers ("01-02-2024", "0700-1500")
    /// and 0 as "zero"; the pass reads later groups of three digits or more only, and 0 as "oh".
    static func legacyRules(british: Bool) -> [Rule] {
        []
    }

    // MARK: - Readings

    /// One shape of number and what it reads as, run over the whole text at once.
    private struct Reading {
        let regex: NSRegularExpression
        /// The words for a match, or nil to leave it as written.
        let read: (NSTextCheckingResult, NSString) -> String?

        init(_ pattern: String, options: NSRegularExpression.Options = [], _ read: @escaping (NSTextCheckingResult, NSString) -> String?) {
            regex = try! NSRegularExpression(pattern: pattern, options: options)
            self.read = read
        }

        func apply(to text: String) -> String {
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return text }
            var casing: ShoutedCasing?
            var out = "", last = 0
            for m in matches {
                guard let words = read(m, ns) else { continue }
                if casing == nil { casing = ShoutedCasing(text) }
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                out += casing!.cased(words, at: m.range.location)
                last = NSMaxRange(m.range)
            }
            guard casing != nil else { return text }
            return out + ns.substring(from: last)
        }
    }

    /// Between the groups of a number: the hyphen family (with the en dash), a dot, or a space
    /// (with the no-break and thin spaces).
    private static let sep = #"[\-‐‑‒–. \x{00A0}\x{202F}\x{2009}]"#
    /// Between the groups of a trunk-0 number: no dot ("0161.496" is no British number).
    private static let gap = #"[\-‐‑‒– \x{00A0}\x{202F}\x{2009}]"#
    /// Not inside a word, a longer number, a list ("1,", "1.2.", "x/"), an amount ("$555"), a
    /// hashtag or handle, or straight after a colon ("10:30-…"), except a "+" ("Tel:+44 …").
    private static let start = #"(?<![\p{L}\d.,/\-‐‑‒–$£€¥₹₩#@_+:])"#
    private static let startPlus = #"(?<![\p{L}\d.,/\-‐‑‒–$£€¥₹₩#@_+])"#
    /// Not running on into a word, a percentage, or another group ("416-555-0199-22", an IP).
    private static let end = #"(?![\d\p{L}%]|[.,:/\-‐‑‒–]\d)"#
    /// An extension straight after a number: "ext. 23", ", ext 4567", "x23", "x 214",
    /// "extension 7". Group 1 is the marker, group 2 the digits (offset by the caller).
    private static let tail = #"(?:[,;]?[ \x{00A0}]*((?:[Ee]xtn?|EXTN?)[.:]?|[Ee]xtension|EXTENSION|[xX])[ \x{00A0}.]?(\d{1,6})(?![\d\p{L}]))?"#

    private static let readings: [Reading] = [
        northAmerican, international, internationalCompact, trunkZero, australianFreecall, local, tollFreeNamed,
        standaloneExtension, extensionAfterVerb, dialledExtension, areaCodeNamed, areaCodeBefore, serviceNumber,
        textCode, starKey, starKeyNoun,
    ]

    // MARK: Whole numbers

    /// North American ten-digit numbers: "(416) 555-0199", "416-555-0199", "416.555.0199",
    /// "1-800-555-0199", "+1 416 555 0199". The area code and exchange start 2-9, which keeps out
    /// "123-456-7890", SSNs (3-2-4), dates and SI-spaced numbers. Spaced throughout ("416 555
    /// 0199") or spaced then hyphened, it's a phone number only after a cue or a "1"/"+1".
    private static let northAmerican = Reading(
        "(?:" + startPlus + "(?=[+＋])|" + start + ")" + #"(?:([+＋]1|1)("# + sep + #"))?(?:\(([2-9]\d\d)\)[ \x{00A0}\x{202F}\x{2009}]?|([2-9]\d\d)("#
            + sep + #"))([2-9]\d\d)("# + sep + #")(\d{4})"# + tail + end
    ) { m, s in
        let prefix = group(m, 1, s)
        if prefix == nil, m.range(at: 3).location == NSNotFound {
            let a = s.substring(with: m.range(at: 5)), e = s.substring(with: m.range(at: 7))
            let plain = isDash(a) || (a == "." && e == ".")
            guard plain || hasLocalCue(before: m.range, in: s) else { return nil }
        }
        let area = group(m, 3, s) ?? group(m, 4, s)!
        return northAmericanWords(prefix: prefix, area: area, exchange: s.substring(with: m.range(at: 6)),
                                  line: s.substring(with: m.range(at: 8))) + extensionWords(m, 9, s)
    }

    /// International numbers written in groups: "+44 20 7946 0958", "+44 (0)20 7946 0958", "+81
    /// 3-1234-5678". 8 to 15 digits with the country code, and a group of three digits or more
    /// (or four groups), so "+12", "+5 10 15" and "+20 30 40 50" stay sums and lists. "(0)" is
    /// silent. (A "+1" number is North American, read above.)
    private static let international = Reading(
        startPlus + #"[+＋](\d{1,3})((?:[ \x{00A0}]?\(0\)[ \x{00A0}]?|"# + sep + #")\(?\d{1,6}\)?(?:"# + sep + #"\(?\d{1,6}\)?){0,4})"# + tail + end
    ) { m, s in
        let code = s.substring(with: m.range(at: 1))
        let national = s.substring(with: m.range(at: 2)).replacingOccurrences(of: "(0)", with: " ")
        let groups = national.split(whereSeparator: { !$0.isASCII || !$0.isNumber }).map(String.init)
        let total = code.count + groups.reduce(0) { $0 + $1.count }
        guard (8...15).contains(total), groups.count >= 4 || groups.contains(where: { $0.count >= 3 }) else { return nil }
        return "plus " + SpokenNumbers.digits(code) + ", " + groups.map(groupWords).joined(separator: ", ") + extensionWords(m, 3, s)
    }

    /// International numbers written as one run: "+14165550199", "+447700900123". The country
    /// code comes from the E.164 table; a "+1" number takes the North American groups, any
    /// other is read in one run after the code.
    private static let internationalCompact = Reading(startPlus + #"[+＋](\d{8,15})"# + tail + end) { m, s in
        let run = s.substring(with: m.range(at: 1))
        let code = String(run.prefix(countryCodeLength(run)))
        let national = String(run.dropFirst(code.count))
        if code == "1", national.count == 10 {
            let digits = Array(national)
            return northAmericanWords(prefix: "+1", area: String(digits[0..<3]), exchange: String(digits[3..<6]),
                                      line: String(digits[6...])) + extensionWords(m, 2, s)
        }
        return "plus " + SpokenNumbers.digits(code) + ", " + SpokenNumbers.digits(national) + extensionWords(m, 2, s)
    }

    /// National numbers with a trunk 0 (UK, Australia, Ireland, New Zealand): "020 7946 0958",
    /// "07700 900123", "(02) 7010 1234", "0491 570 156". A first group of 2 to 5 digits, then
    /// groups of 3 to 6: 10 or 11 digits in all, or 9 in three groups or more. Pairs ("04 11 23
    /// 35 42", "01 02 2024") and two short groups ("0700-1500", ZIP+4 "02134-5678") aren't phone
    /// numbers.
    private static let trunkZero = Reading(
        start + #"(?:\((0[1-9]\d{0,3})\)[ \x{00A0}\x{202F}\x{2009}]?|(0[1-9]\d{0,3})"# + gap + #")(\d{3,6})((?:"# + gap + #"\d{3,6}){0,2})"# + tail + end
    ) { m, s in
        let first = group(m, 1, s) ?? group(m, 2, s)!
        let rest = s.substring(with: m.range(at: 4)).split(whereSeparator: { !$0.isASCII || !$0.isNumber }).map(String.init)
        let groups = [s.substring(with: m.range(at: 3))] + rest
        let total = first.count + groups.reduce(0) { $0 + $1.count }
        // Childline's "0800 1111" is the one short freephone number.
        guard (10...11).contains(total) || (total == 9 && groups.count >= 2) || (first == "0800" && total == 8) else { return nil }
        // Freephone "0800" is "oh eight hundred", as Britons say it.
        let head = first == "0800" ? "oh eight hundred" : SpokenNumbers.digits(first)
        return ([head] + groups.map(groupWords)).joined(separator: ", ") + extensionWords(m, 5, s)
    }

    /// Australian freecall and local-rate numbers, "1800 160 401" and "1300 975 707": only after a
    /// cue ("Call", "on", "freecall"), since "By 1800 250 000 people" has the same shape.
    private static let australianFreecall = Reading(
        start + #"(1[38]00)"# + gap + #"(\d{3})"# + gap + #"(\d{3})"# + tail + end
    ) { m, s in
        guard hasLocalCue(before: m.range, in: s) || matches(freecallCue, before: m.range, in: s) else { return nil }
        let prefix = s.substring(with: m.range(at: 1))
        let head = prefix == "1800" ? "one eight hundred" : SpokenNumbers.digits(prefix)
        return [head, SpokenNumbers.digits(s.substring(with: m.range(at: 2))), SpokenNumbers.digits(s.substring(with: m.range(at: 3)))]
            .joined(separator: ", ") + extensionWords(m, 4, s)
    }

    /// Seven-digit local numbers, "555-0199" and "555 0199", only straight after a cue ("Call me
    /// at", "My number is"): order and part numbers share the shape. Two round numbers are a
    /// range ("Call between 250-1000").
    private static let local = Reading(start + #"([2-9]\d\d)([\-‐‑‒–.]|[ \x{00A0}])(\d{4})"# + tail + end) { m, s in
        let a = s.substring(with: m.range(at: 1)), b = s.substring(with: m.range(at: 3))
        guard !(a.hasSuffix("0") && b.hasSuffix("0")) else { return nil }
        // Not the end of a longer number that wasn't read ("1234 5678", "21 555 0199").
        let before = text(before: m.range, in: s, limit: 2)
        if before.count == 2, before.last!.isWhitespace || isDash(String(before.last!)), before.first!.isNumber { return nil }
        // 555 is the numbers' fiction prefix (and "555.0134" its dotted form), and an extension
        // after the number settles it too ("Front desk 555-0123, ext. 4").
        let dotted = s.substring(with: m.range(at: 2)) == "."
        let settled = a == "555" || (!dotted && m.range(at: 5).location != NSNotFound)
        guard settled || (!dotted && hasLocalCue(before: m.range, in: s)) else { return nil }
        return SpokenNumbers.digits(a) + ", " + SpokenNumbers.digits(b) + extensionWords(m, 4, s)
    }

    /// A toll-free prefix named as a kind of number: "a 1-800 number", "an 888 number". "We
    /// handle 1-800 calls an hour" and "We received 866 calls" are counts and ranges: plural
    /// nouns need a determiner and "1-" ("your 1-800 numbers").
    private static let tollFreeNamed = Reading(
        start + #"(?:(1)[\-‐‑‒–])?(800|833|844|855|866|877|888|900)(\s+)(numbers|number|lines|line|hotlines|hotline|calls|call)(?![\p{L}\d])"#
    ) { m, s in
        let noun = s.substring(with: m.range(at: 4))
        let determined = matches(determinerEnd, before: m.range, in: s)
        if m.range(at: 1).location != NSNotFound {
            guard ["number", "line", "hotline", "call"].contains(noun) || (noun == "numbers" && determined) else { return nil }
        } else {
            guard determined, ["number", "line", "hotline"].contains(noun) else { return nil }
        }
        let prefix = s.substring(with: m.range(at: 2))
        return (m.range(at: 1).location != NSNotFound ? "one " : "") + areaWords(prefix) + s.substring(with: m.range(at: 3)) + noun
    }

    // MARK: Extensions on their own

    /// "Ext. 23", "ext. 105", "Ext: 4": an extension with no number before it. Not "EXT." (a
    /// screenplay's exterior: "EXT. 10 DOWNING STREET - DAY"), not "next." or "text.", not an
    /// exterior after "int." ("Doors: int. 6, ext. 2."), and not before a capitalised word.
    private static let standaloneExtension = Reading(
        #"(?<![\p{L}\d.])(ext|Ext|extn|Extn)[.:][ \x{00A0}]?(\d{1,6})"# + end
    ) { m, s in
        guard !matches(interiorBefore, before: m.range, in: s) else { return nil }
        let next = s.substring(from: NSMaxRange(m.range)).drop { $0 == " " || $0 == "\t" }.first
        guard next.map(\.isUppercase) != true else { return nil }
        let word = s.substring(with: m.range(at: 1)).first!.isUppercase ? "Extension " : "extension "
        return word + extensionNumber(s.substring(with: m.range(at: 2)))
    }

    /// A bare "ext" before digits, only after a verb that reaches one or "ask for": "runs on ext
    /// 4" is the file system.
    private static let extensionAfterVerb = Reading(
        #"\b((?i:call|calls|called|calling|dial|dials|dialed|dialled|dialing|dialling|ring|rings|rang|ringing|reach|reaches|reached|reaching|(?:ask|asks|asked|asking)\s+for)\s+)(?:ext|Ext)[ \x{00A0}](\d{1,6})"# + end
    ) { m, s in
        s.substring(with: m.range(at: 1)) + "extension " + extensionNumber(s.substring(with: m.range(at: 2)))
    }

    /// "Dial x4567": "x" and digits are an extension only after "dial" ("call x86 code", "call
    /// x264" are an architecture and a codec), and never a term the tech lexicon has.
    private static let dialledExtension = Reading(
        #"\b((?i:dial|dials|dialed|dialled|dialing|dialling)\s+)[xX](\d{2,6})"# + end
    ) { m, s in
        let digits = s.substring(with: m.range(at: 2))
        guard !lexiconXTerms.contains(digits) else { return nil }
        return s.substring(with: m.range(at: 1)) + "extension " + extensionNumber(digits)
    }

    /// The digits of the tech lexicon's "x" terms (x86, x64, x264, x265, x509, X11, x8664).
    private static let lexiconXTerms: Set<String> = ["86", "64", "264", "265", "509", "11", "8664"]

    // MARK: Area codes

    /// "Area code 416", "dialling code: 0161", "STD code (02)": the code digit by digit.
    private static let areaCodeNamed = Reading(
        #"\b((?i:area\s+codes?|diall?ing\s+code)|STD\s+code)(\s?:?\s?\(?)(\d{2,5})"# + end
    ) { m, s in
        s.substring(with: m.range(at: 1)) + s.substring(with: m.range(at: 2)) + SpokenNumbers.digits(s.substring(with: m.range(at: 3)))
    }

    /// "the 212 area code": a determiner, three digits and the singular "area code" ("over 300
    /// area codes" is a count).
    private static let areaCodeBefore = Reading(
        #"\b((?i:the|a|an|that|this|my|your|our|their|his|her|its)\s+)([2-9]\d\d)(\s+(?i:area\s+code))(?![\p{L}\d])"#
    ) { m, s in
        s.substring(with: m.range(at: 1)) + SpokenNumbers.digits(s.substring(with: m.range(at: 2))) + s.substring(with: m.range(at: 3))
    }

    // MARK: Emergency and service numbers

    /// Emergency and service numbers, digit by digit ("nine one one", "one oh one"; Australia's
    /// "000" is "triple zero"), when they're dialled: straight after "call", "dial", "ring",
    /// "phone" or "text" ("call police on 101"), and only before what can follow a number you
    /// call ("now", "if", "for", the end of the sentence). The less a number is an emergency
    /// number, the fewer words may follow it: "called 112 in the first hour" and "called 211 on
    /// Monday" are counts. 911, 999 and 000 (and 112 more strictly) are also read before a phone
    /// noun ("The 911 dispatcher", "a 999 call", "911 calls doubled").
    private static let serviceNumber = Reading(
        start + #"(911|999|112|000|111|101|988|211|311|411|511|611|711|811)"# + end
    ) { m, s in
        let number = s.substring(with: m.range(at: 1))
        let tier = number == "911" || number == "999" ? 1 : number == "112" || number == "000" ? 2 : 3
        let after = s.substring(from: NSMaxRange(m.range))
        let dialled = matches(serviceCue, before: m.range, in: s) && followsServiceNumber(after, tier: tier)
        // A service named before it ("NHS 111", "TTY 711", "the emergency number is 112"), or a
        // second number in a list after one ("dial 111, not 999").
        let named = matches(serviceName, before: m.range, in: s)
            || matches(numberIsCue, before: m.range, in: s) && followsServiceNumber(after, tier: 1)
            || matches(serviceListCue, before: m.range, in: s)
        guard dialled || named || isNamedService(number, before: m.range, after: after, in: s) else { return nil }
        return number == "000" ? "triple zero" : SpokenNumbers.digits(number)
    }

    /// What may follow a dialled service number, by tier (1: 911 and 999; 2: 112 and 000; 3: the
    /// others): the end of the sentence, or one of these words.
    private static let serviceNext: [Int: Set<String>] = [
        1: ["now", "immediately", "right", "straight", "first", "again", "instead", "if", "for", "to", "or", "and", "in", "on",
            "from", "when", "about", "with", "at", "as", "any", "anytime", "today", "tonight"],
        2: ["now", "immediately", "right", "straight", "first", "again", "instead", "if", "for", "to", "or", "and", "from",
            "when", "any", "anytime", "today", "tonight"],
        3: ["now", "immediately", "first", "again", "instead", "if", "for", "to", "or", "and", "when", "anytime", "today",
            "tonight"],
    ]
    /// Two-word phrases that may follow, by tier: "in an emergency", "right away", "any time".
    private static let servicePhrases: [Int: [String]] = [
        2: ["in an emergency", "in emergencies", "in case"],
        3: ["right away", "any time"],
    ]

    private static func followsServiceNumber(_ after: String, tier: Int) -> Bool {
        let rest = after.drop { $0 == " " || $0 == "\t" }
        guard let c = rest.first else { return true }
        if ".!?,;:)]…\"”’—–*_\n\r".contains(c) { return true }
        let words = rest.prefix(40).lowercased().split(whereSeparator: { !$0.isLetter }).prefix(3).map(String.init)
        guard let word = words.first else { return false }
        if serviceNext[tier]!.contains(word) { return true }
        let phrase = words.joined(separator: " ")
        return servicePhrases[tier]?.contains { phrase.hasPrefix($0) && (phrase.count == $0.count || phrase.dropFirst($0.count).first == " ") } == true
    }

    /// Nouns that make 911, 999 and 000 the emergency number ("911 calls", "the 999 operator"),
    /// and the singular ones for 112 after an article. Not "service" or "system" ("Porsche 911
    /// service"), and not "line" for 112 (a bus or tram line).
    private static let emergencyNouns: Set<String> = [
        "call", "calls", "caller", "callers", "dispatcher", "dispatchers", "dispatch", "operator", "operators", "centre",
        "centres", "center", "centers", "line", "hotline", "emergency",
    ]
    private static let euroEmergencyNouns: Set<String> = ["call", "caller", "dispatcher", "operator", "centre", "center"]

    private static func isNamedService(_ number: String, before range: NSRange, after: String, in s: NSString) -> Bool {
        guard number == "911" || number == "999" || number == "000" || number == "112" else { return false }
        let words = after.prefix(40).split(whereSeparator: { !$0.isLetter }).prefix(2).map { $0.lowercased() }
        guard let noun = words.first, after.first == " " else { return false }
        if number == "112" {
            let named = euroEmergencyNouns.contains(noun) || (noun == "emergency" && words.dropFirst().first == "number")
            return named && matches(articleEnd, before: range, in: s)
        }
        guard emergencyNouns.contains(noun) else { return false }
        return matches(determinerEnd, before: range, in: s) || startsSentence(before: range, in: s)
    }

    // MARK: SMS short codes

    /// "Text HOME to 741741": a keyword in capitals or quotes, "to", and a short code of 4 to 6
    /// digits, read digit by digit. "Text" opens the sentence or follows "please", "just", "or",
    /// "and", "then" or a comma, so "Text messages fell to 1200 a day" is a count.
    private static let textCode = Reading(
        #"(?<![\p{L}\d])((?:Text|text|TEXT|txt|TXT|SMS)\s+(?:\p{Lu}{2,}[\p{Lu}\d]*|"[^"\n]{1,30}"|“[^”\n]{1,30}”)(?:\s+(?:\p{Lu}{2,}[\p{Lu}\d]*|"[^"\n]{1,30}"|“[^”\n]{1,30}”))?\s+(?:to|TO|To)\s+)(\d{4,6})"# + end
    ) { m, s in
        guard startsSentence(before: m.range, in: s) || matches(textOpener, before: m.range, in: s) else { return nil }
        let next = s.substring(from: NSMaxRange(m.range)).drop { $0 == " " }.prefix { $0.isLetter }.lowercased()
        guard !rateWords.contains(next) else { return nil }
        return s.substring(with: m.range(at: 1)) + SpokenNumbers.digits(s.substring(with: m.range(at: 2)))
    }

    /// Words after a number that make it an amount, not a short code ("to 25000 per day").
    private static let rateWords: Set<String> = ["per", "percent", "a", "an", "each", "times"]

    // MARK: The "*" key

    /// "Press * then 2", "the * key": a standalone "*" after a key verb or before "key" or
    /// "button" is the star key. Markdown's "*Enter*" is joined to its word. ("#" is the
    /// shorthand area's: "pound" or "hash" by voice.)
    private static let starKey = Reading(
        #"\b((?i:press|presses|pressed|pressing|hit|hits|tap|taps|tapped|tapping|enter|dial|dials)\s+)\*(?=[\s.,;:!?)]|$)"#
    ) { m, s in
        s.substring(with: m.range(at: 1)) + "star"
    }

    private static let starKeyNoun = Reading(#"(?<![^\s(])\*(?=\s+(?i:keys?|buttons?)(?![\p{L}]))"#) { _, _ in "star" }

    // MARK: - Cues

    /// Verbs that put a number to be dialled after them, in any tense.
    private static let dialVerbs = "call|calls|called|calling|text|texts|texted|texting|ring|rings|rang|ringing|phone|phones|phoned|phoning|dial|dials|dialed|dialled|dialing|dialling|reach|reaches|reached|reaching"

    /// What makes a spaced, seven-digit or Australian 1800 number a phone number when it comes
    /// straight before it: a label ("Phone:", "Tel:"), "number (is)", "No.", a verb ("Call",
    /// "Ring me on"), or "at"/"on" up to three words after one ("Call the office at").
    private static let localCue = try! NSRegularExpression(
        pattern: #"(?:\b(?:phone|tel|telephone|cell|mobile|fax|home|work|office|direct|main|line|desk)\s?:|\bnumber(?:\s+(?:is|was)|\s?[:,])?|\bno\.|\b(?:"#
            + dialVerbs + #")(?:\s+(?:me|us|him|her|them|you))?|\b(?:"# + dialVerbs + #")(?:\s+[\p{L}'’]+){0,3}\s+(?:at|on))\s*$"#,
        options: .caseInsensitive)
    /// More cues for Australian 1800 numbers: "Freecall 1800…", "free on 1800…".
    private static let freecallCue = try! NSRegularExpression(pattern: #"(?:\bfree\s?call|\bon)\s*$"#, options: .caseInsensitive)
    /// A dialled service number: straight after the verb ("Call or text 988"), or after up to two
    /// words and "on" ("call police on 101").
    private static let serviceCue = try! NSRegularExpression(
        pattern: #"\b(?:call|calls|called|calling|dial|dials|dialed|dialled|dialing|dialling|ring|rings|rang|ringing|phone|phoned|phoning|text|texted|texting)(?:\s+or\s+(?:call|text|dial))?(?:(?:\s+[\p{L}'’]+){1,2}\s+on)?\s+$"#,
        options: .caseInsensitive)
    /// A service before its number: "NHS 111", "TTY 711", "TDD 711".
    private static let serviceName = try! NSRegularExpression(pattern: #"\b(?:NHS|TTY|TDD|TTD|Textphone|textphone)\s+$"#)
    /// "The emergency number is 112", "the number to call is 999".
    private static let numberIsCue = try! NSRegularExpression(pattern: #"\b(?:emergency|police|ambulance|fire|crisis|helpline)\s+(?:number|line)\s+(?:is|was)\s+$"#, options: .caseInsensitive)
    /// A second service number after a dialled one: "dial 111, not 999", "call 999 or 112".
    private static let serviceListCue = try! NSRegularExpression(
        pattern: #"\b(?:call|dial|ring|phone|text)\s+(?:911|999|112|000|111|101|988|211|311|411|511|611|711|811),?\s+(?:not|or|and)\s+$"#,
        options: .caseInsensitive)
    private static let determinerEnd = try! NSRegularExpression(
        pattern: #"\b(?:a|an|the|this|that|these|those|my|your|our|their|his|her|its)\s+$"#, options: .caseInsensitive)
    private static let articleEnd = try! NSRegularExpression(pattern: #"\b(?:a|an|the)\s+$"#, options: .caseInsensitive)
    /// An exterior in a spec list: "int." up to three words back ("Doors: int. 6, ext. 2").
    private static let interiorBefore = try! NSRegularExpression(pattern: #"\b[Ii]nt\.(?:\s+\S+){0,3}\s*$"#)
    /// What may come before "Text KEYWORD to …" besides the start of a sentence.
    private static let textOpener = try! NSRegularExpression(pattern: #"(?:\b(?:please|just|or|and|then)|[,:])\s*$"#, options: .caseInsensitive)

    /// Up to `limit` UTF-16 units of `s` just before `range`.
    private static func text(before range: NSRange, in s: NSString, limit: Int = 80) -> String {
        let start = max(0, range.location - limit)
        return s.substring(with: NSRange(location: start, length: range.location - start))
    }

    private static func matches(_ cue: NSRegularExpression, before range: NSRange, in s: NSString) -> Bool {
        let before = text(before: range, in: s)
        return cue.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) != nil
    }

    private static func hasLocalCue(before range: NSRange, in s: NSString) -> Bool {
        matches(localCue, before: range, in: s)
    }

    /// Whether `range` opens its sentence: nothing before it but spaces after the start, a line
    /// break, a sentence's end mark, or an opening quote or bracket.
    private static func startsSentence(before range: NSRange, in s: NSString) -> Bool {
        let before = text(before: range, in: s, limit: 8).reversed().drop { $0 == " " || $0 == "\t" }
        guard let c = before.first else { return true }
        return c.isNewline || ".!?…\"“(".contains(c)
    }

    // MARK: - Words

    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ s: NSString) -> String? {
        m.range(at: i).location == NSNotFound ? nil : s.substring(with: m.range(at: i))
    }

    private static func isDash(_ s: String) -> Bool { s.count == 1 && "-‐‑‒–".contains(s) }

    /// "four one six, five five five, oh one nine nine". A "1" before the area code joins it with
    /// no pause ("one eight hundred"); "+1" is "plus one" and a pause.
    private static func northAmericanWords(prefix: String?, area: String, exchange: String, line: String) -> String {
        let head: String
        switch prefix {
        case "+1", "＋1": head = "plus one, "
        case "1": head = "one "
        default: head = ""
        }
        return head + areaWords(area) + ", " + SpokenNumbers.digits(exchange) + ", " + SpokenNumbers.digits(line)
    }

    /// An area code digit by digit, except the N00 codes, which people say as hundreds ("eight
    /// hundred", "nine hundred"). Toll-free 888, 877 and 866 are digit by digit too.
    private static func areaWords(_ area: String) -> String {
        if area.hasSuffix("00"), let d = area.first?.wholeNumberValue, (5...9).contains(d) {
            return SpokenNumbers.cardinal(d) + " hundred"
        }
        return SpokenNumbers.digits(area)
    }

    /// A written group digit by digit; a six-digit block is said as two threes ("nine oh oh, one
    /// two three").
    private static func groupWords(_ digits: String) -> String {
        guard digits.count == 6 else { return SpokenNumbers.digits(digits) }
        return SpokenNumbers.digits(digits.prefix(3)) + ", " + SpokenNumbers.digits(digits.suffix(3))
    }

    /// ", extension twenty three" for an extension tail whose marker is group `i` and digits
    /// group `i + 1`; nothing when the number has none.
    private static func extensionWords(_ m: NSTextCheckingResult, _ i: Int, _ s: NSString) -> String {
        guard m.range(at: i + 1).location != NSNotFound else { return "" }
        return ", extension " + extensionNumber(s.substring(with: m.range(at: i + 1)))
    }

    /// One or two digits as a number ("seven", "twenty three"), as people say a short extension;
    /// longer ones (and a leading 0) digit by digit ("four five six seven").
    private static func extensionNumber(_ digits: String) -> String {
        if digits.count <= 2, !digits.hasPrefix("0") || digits.count == 1, let n = Int(digits) {
            return SpokenNumbers.cardinal(n)
        }
        return SpokenNumbers.digits(digits)
    }

    /// The length of a compact number's country code (E.164): 1 and 7 have one digit, these
    /// two, and every other code three.
    private static func countryCodeLength(_ run: String) -> Int {
        guard let first = run.first else { return 0 }
        if first == "1" || first == "7" { return 1 }
        guard let two = Int(run.prefix(2)) else { return 3 }
        return twoDigitCodes.contains(two) ? 2 : 3
    }

    private static let twoDigitCodes: Set<Int> = Set([20, 27, 36, 39, 40, 41, 81, 82, 84, 86, 98] + Array(30...34) + Array(43...49)
                                                        + Array(51...58) + Array(60...66) + Array(90...95))
}
