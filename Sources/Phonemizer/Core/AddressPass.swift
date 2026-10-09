import Foundation

/// Addresses (Core readings, FIN-889; area "addresses"): house numbers, street types and
/// directions, units and boxes, route numbers, states and provinces, ZIP and postal codes, and
/// "St." as Saint, Street or Suite.
///
/// The pass runs after the phone pass (a ZIP or ZIP+4 is a shape phones reject) and before the
/// titles pass, so "Ocean Dr. Suite 3" is Drive before any title rule sees "Dr.". It runs before
/// the custom lexicon, whose marks include CA, GA, IL, MD, DR, Room, Box and SE. In a British
/// postcode it writes "zed" for the British voice (cross.json: addresses and titles).
///
/// It writes words, never digits: a house number left as "1005" would be read "one thousand
/// five", and a ZIP "90210" "ninety thousand two hundred ten". Number words come from
/// `SpokenNumbers` (no hyphens), and every inserted word goes through `ShoutedCasing`, so an
/// address on a shouted receipt ("4545 S 1ST ST, AUSTIN TX 78745") stays shouted for unshout.
enum AddressPass {
    typealias Rule = TextNormalizer.Rule

    /// The address pass: in `Phonemizer.phonemize` after the phone pass, only when normalizing.
    /// Codes after a place come first (their ZIP and postal codes are digits the street rules
    /// must not take), then route and box numbers, numbered streets, unit numbers, street types
    /// after a name, and "St"/"Ste" as Saint. Each step is one scan of the text.
    static func apply(_ text: String, british: Bool) -> String {
        var hasDigit = false, hasCapital = false, hasComma = false, hasCapitalPair = false
        var previous: Unicode.Scalar = " "
        for c in text.unicodeScalars {
            if c.value >= 0x30 && c.value <= 0x39 {
                hasDigit = true
            } else if Scalars.isUppercase(c) {
                hasCapital = true
                if c.value >= 0x41 && c.value <= 0x5A && previous.value >= 0x41 && previous.value <= 0x5A { hasCapitalPair = true }
            } else if c == "," {
                hasComma = true
            }
            previous = c
        }
        guard hasCapital else { return text }
        // A state, province or territory code reads only after a comma (in capitals: "Austin,
        // TX") or before a ZIP or postal code (digits, "٧٨٧٠١" too). Each of those scans tries
        // every space, so they're skipped in the plain sentences that are most of what's read.
        let codes = hasComma && hasCapitalPair || hasDigit || TextNormalizer.containsDigit(text)
        var t = text
        if hasDigit {
            t = rewrite(t, ukPostcode) { m, s, casing in readUKPostcode(m, s, &casing, british: british) }
        }
        if codes { t = rewrite(t, usState, readUSState) }
        if t.utf8.contains(UInt8(ascii: ",")) { t = rewrite(t, apState, readAPState) }
        if codes { t = rewrite(t, province, readProvince) }
        if hasDigit {
            t = rewrite(t, stateNameZip, readZip)
            t = rewrite(t, canadianPostcode, readCanadianPostcode)
        }
        if codes { t = rewrite(t, australianState, readAustralianState) }
        if hasDigit {
            t = rewrite(t, zipCue, readZip)
            t = rewrite(t, route, readRoute)
            t = rewrite(t, box, readBox)
            t = rewrite(t, streetAddress, readStreetAddress)
            t = rewrite(t, streetAddressCaps, readStreetAddress)
            t = rewrite(t, broadway, readBroadway)
            t = rewrite(t, unit, readUnit)
            t = rewrite(t, floorOrdinal, readFloorOrdinal)
        }
        t = rewrite(t, building, readBuilding)
        t = rewrite(t, streetType, readStreetType)
        t = rewrite(t, typeDirection, readTypeDirection)
        t = rewrite(t, saintNoStop, readSaintNoStop)
        t = rewrite(t, sainte, readSainte)
        t = rewrite(t, letteredAvenue, readLetteredAvenue)
        return t
    }

    // MARK: - Running a step

    /// What one match becomes: the range it replaces (the match, or a little more after it, as
    /// the hyphen of "OR-based") and the words in its place.
    private typealias Rewrite = (range: NSRange, words: String)

    /// Shouted-sentence casing for a step, made only once the step has a match.
    private struct Casing {
        private let text: String
        private var shouted: ShoutedCasing?
        init(_ text: String) { self.text = text }

        mutating func cased(_ words: String, at location: Int) -> String {
            if shouted == nil { shouted = ShoutedCasing(text) }
            return shouted!.cased(words, at: location)
        }

        mutating func isShouted(at location: Int) -> Bool {
            if shouted == nil { shouted = ShoutedCasing(text) }
            return shouted!.isShouted(at: location)
        }
    }

    /// `text` with each match of `regex` that `read` rewrites replaced, in one scan.
    private static func rewrite(_ text: String, _ regex: NSRegularExpression,
                                _ read: (NSTextCheckingResult, NSString, inout Casing) -> Rewrite?) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var casing = Casing(text)
        var out = "", last = 0, changed = false
        for m in matches where m.range.location >= last {
            guard let r = read(m, ns, &casing), r.range.location >= last else { continue }
            out += ns.substring(with: NSRange(location: last, length: r.range.location - last)) + r.words
            last = NSMaxRange(r.range)
            changed = true
        }
        return changed ? out + ns.substring(from: last) : text
    }

    // MARK: - Numbers and letters (rule B)

    /// A number in an address slot (a house, suite, room, box or route number) as people say
    /// it: 42 "forty two", 123 "one twenty three", 903 "nine oh three", 1600 "sixteen hundred",
    /// 1005 "ten oh five", 2041 "twenty forty one", 2000 "two thousand"; five digits or more one
    /// at a time ("one oh five four eight"). Only here: a bare number keeps its cardinal ("I
    /// bought 1005 shares").
    static func addressNumber<S: StringProtocol>(_ digits: S) -> String {
        guard let n = Int(digits) else { return SpokenNumbers.digits(digits) }
        if digits.count > 1 && digits.first == "0" { return SpokenNumbers.digits(digits) }
        switch digits.count {
        case 1, 2:
            return SpokenNumbers.cardinal(n)
        case 3:
            if n % 100 == 0 { return SpokenNumbers.cardinal(n) }
            if n % 100 < 10 { return SpokenNumbers.cardinal(n / 100) + " oh " + SpokenNumbers.cardinal(n % 10) }
            return SpokenNumbers.cardinal(n / 100) + " " + SpokenNumbers.cardinal(n % 100)
        case 4:
            if n % 1000 == 0 { return SpokenNumbers.cardinal(n) }
            let high = SpokenNumbers.cardinal(n / 100), low = n % 100
            if low == 0 { return high + " hundred" }
            return high + (low < 10 ? " oh " : " ") + SpokenNumbers.cardinal(low)
        default:
            return n % 1000 == 0 ? SpokenNumbers.cardinal(n) : SpokenNumbers.digits(digits)
        }
    }

    /// A letter read as its name: "A" written alone is the article ("Apartment four A" was
    /// "four uh"), so it's "ay"; Z is "zed" in a British postcode.
    private static func letterName(_ c: Character, british: Bool = false) -> String {
        if c == "A" { return "ay" }
        if c == "Z" && british { return "zed" }
        return String(c)
    }

    /// A code read one character at a time: "M5V" → "M five V", "1YZ" → "one Y zed".
    private static func spelled<S: StringProtocol>(_ code: S, british: Bool = false) -> String {
        code.map { c in c.wholeNumberValue.map { $0 == 0 ? "oh" : SpokenNumbers.cardinal($0) } ?? letterName(c, british: british) }
            .joined(separator: " ")
    }

    /// A ZIP code, digit by digit with "oh" for 0; ZIP+4 after a pause.
    private static func zipWords(_ zip: String, _ plus4: String?) -> String {
        SpokenNumbers.digits(zip) + (plus4.map { ", " + SpokenNumbers.digits($0) } ?? "")
    }

    // MARK: - Looking around a match

    private static func scalar(_ c: unichar) -> Unicode.Scalar? { Unicode.Scalar(c) }
    private static func isBlank(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }
    private static func isWordUnit(_ c: unichar) -> Bool {
        guard let u = scalar(c) else { return false }
        return Scalars.isLetterOrNumber(u) || c == 0x27 || c == 0x2019 || c == 0x2D || c == 0x2E || c == 0x3A
    }

    /// The word just before `location` (past spaces, on the same line), with its full stops
    /// and colons ("No.", "address:"), and where it starts.
    private static func word(before location: Int, in s: NSString) -> (word: String, start: Int)? {
        var i = location
        while i > 0, isBlank(s.character(at: i - 1)) { i -= 1 }
        let end = i
        while i > 0, end - i < 40, isWordUnit(s.character(at: i - 1)) { i -= 1 }
        guard i < end else { return nil }
        return (s.substring(with: NSRange(location: i, length: end - i)), i)
    }

    /// Up to `limit` UTF-16 units of `s` from `location`.
    private static func text(after location: Int, in s: NSString, limit: Int = 60) -> String {
        s.substring(with: NSRange(location: location, length: max(0, min(limit, s.length - location))))
    }

    /// Up to `limit` UTF-16 units of `s` before `location`.
    private static func text(before location: Int, in s: NSString, limit: Int = 100) -> String {
        let start = max(0, location - limit)
        return s.substring(with: NSRange(location: start, length: location - start))
    }

    /// The first word of `rest` past spaces and tabs (letters, digits, apostrophes), or nil
    /// when something else comes first.
    private static func firstWord<S: StringProtocol>(_ rest: S) -> String? {
        let start = rest.drop { $0 == " " || $0 == "\t" }
        let word = start.prefix { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }
        return word.isEmpty ? nil : String(word)
    }

    private static let starters = Set(Tokenizer.sentenceStarters)

    /// "Street." at the end of its sentence: the type's period is also the full stop before a
    /// capitalised word, unless that word carries the address on ("Ocean Dr. Suite 3",
    /// "King St. W", "Washington Sq. Park").
    private static func keptStop(before rest: String) -> String {
        guard FullStop.ends(before: rest, next: .capital) else { return "" }
        if let next = firstWord(rest), unitWords[next] != nil || directions[next] != nil || landmarks.contains(next) { return "" }
        return "."
    }

    // MARK: - Places before a code ("Austin, TX", "Salem, Ore.")

    /// The run of capitalised words before a code's comma, with any usual sentence openers in
    /// front of it dropped ("In Boise" is Boise), and the word before it.
    private struct Place {
        let name: String
        /// The word before the run, lower case ("in", "to"), or "(" for an opening bracket.
        let previous: String?
        /// A run starting St., Ste., Ft., Mt. or Port: the shape of a place name.
        let prefixed: Bool
    }

    private static let placeRun = try! NSRegularExpression(pattern:
        #"(?<![\p{L}\d'’.\-])((?:(?:\p{Lu}[\p{L}'’\-]*|St\.|Ste\.|Ft\.|Mt\.|Pt\.|de|del|la|du)[ \t]+){0,3}\p{Lu}[\p{L}'’\-]*)$"#)

    /// Greetings, sign-offs and interjections: "Morning, Miss.", "Love, Mo.", "Hey, OK".
    private static let notPlaces: Set<String> = [
        "Morning", "Evening", "Night", "Goodnight", "Love", "Cheers", "Regards", "Best", "Thanks", "Yours", "Hi",
        "Hey", "Hello", "Yes", "No", "Oh", "Well", "Okay", "OK", "Sorry", "Please", "Fine", "Sure", "Dear", "Bye",
        "Goodbye", "Congrats", "Congratulations", "Welcome", "Ah", "Wow", "Mom", "Mum", "Dad", "Ma", "Pa",
    ]
    private static let titlesBefore: Set<String> = ["Mr.", "Mrs.", "Ms.", "Mx.", "Dr.", "Prof.", "Mr", "Mrs", "Ms", "Dr", "Sir", "Dame"]

    private static func place(before location: Int, in s: NSString) -> Place? {
        let before = text(before: location, in: s, limit: 80)
        let b = before as NSString
        guard let m = placeRun.firstMatch(in: before, range: NSRange(location: 0, length: b.length)) else { return nil }
        // A window cut mid-word isn't a run.
        if m.range.location == 0, location > b.length,
           let u = scalar(s.character(at: location - b.length - 1)), !Scalars.isSpace(u) { return nil }
        var tokens = b.substring(with: m.range(at: 1)).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var dropped: String?
        while let first = tokens.first, starters.contains(first) {
            dropped = first.lowercased()
            tokens.removeFirst()
        }
        guard let first = tokens.first, first.first?.isUppercase == true else { return nil }
        if tokens.count == 1, notPlaces.contains(first) { return nil }
        let start = m.range.location
        var previous = dropped
        if previous == nil {
            let head = b.substring(to: start)
            if head.reversed().first(where: { $0 != " " && $0 != "\t" }) == "(" {
                previous = "("
            } else if let w = word(before: start, in: b) {
                if titlesBefore.contains(w.word) { return nil }
                previous = w.word.lowercased()
            }
        }
        let prefixed = tokens.count > 1 && ["St.", "Ste.", "Ft.", "Mt.", "Pt.", "Saint", "Sainte", "Fort", "Mount", "Port"].contains(first)
        return Place(name: tokens.joined(separator: " "), previous: previous, prefixed: prefixed)
    }

    /// Words before a place that make it one: "in Boise, ID", "than Portland, OR", "(Fresno, CA)".
    private static let placeWords: Set<String> = [
        "in", "to", "from", "near", "at", "of", "outside", "around", "via", "through", "than", "and", "toward", "towards",
        "into", "across", "(", "based", "between", "visit", "visited", "visiting",
    ]
    /// Verbs right after a code that make the place a subject: "Pittsburgh, PA is hilly".
    private static let verbsAfter: Set<String> = [
        "is", "was", "has", "had", "have", "will", "would", "are", "were", "can", "could", "may", "might", "remains",
        "became", "becomes", "hosts", "hosted", "sits", "lies", "gets", "got", "saw", "sees", "said", "says", "voted",
        "does", "did",
    ]

    /// What may follow a state or province code read with no postal code after it: the end, a
    /// punctuation mark, "-based", or a lower-case word. A capital starts a name or another word
    /// ("Was it Portland, OR Seattle?").
    private static func codeMayEnd(_ rest: String) -> Bool {
        guard let c = rest.first else { return true }
        if ".,;:!?)".contains(c) || c.isNewline || rest.hasPrefix("-based") { return true }
        guard c == " " || c == "\t" else { return false }
        guard let n = rest.first(where: { $0 != " " && $0 != "\t" }) else { return true }
        return n.isLowercase || n.isNewline
    }

    /// "OK" as a word after a name: before "?" or "!" (a tag question, "Say hi to Norman, OK?")
    /// or before a comma and a pronoun ("Fine, Norman, OK, you win", "Enid, OK, let's go").
    private static func okIsWord(_ rest: String) -> Bool {
        let r = rest.drop { $0 == " " || $0 == "\t" }
        if r.first == "?" || r.first == "!" { return true }
        guard r.first == "," else { return false }
        let next = firstWord(r.dropFirst())?.lowercased() ?? ""
        return ["i", "you", "we", "they", "he", "she", "it", "let's", "lets", "then", "so", "but", "sure", "fine",
                "thanks", "see", "bye"].contains(next)
    }

    /// A credential after the code ("Amy Jackson, MS, RD"): it's a degree, not a state.
    private static func credentialFollows(_ rest: String) -> Bool {
        guard rest.hasPrefix(", ") else { return false }
        let next = firstWord(rest.dropFirst(2)) ?? ""
        return next.count >= 2 && next.count <= 5 && next.first?.isUppercase == true && next.dropFirst().contains(where: \.isUppercase)
    }

    // MARK: - US states and ZIP codes (rules I and K)

    /// "City, ST", "City, ST 12345", "CITY ST 12345-6789".
    private static let usState = try! NSRegularExpression(pattern:
        #"(?<=[\p{L}.'’])(,?)[ \t]+(\p{Lu}[\p{Lu}\p{Ll}])(?![\p{L}\d'’])(?:[ \t]+(\d{5})(?:-(\d{4}))?(?![\d\p{L}]))?"#)

    private static func readUSState(_ m: NSTextCheckingResult, _ s: NSString, _ casing: inout Casing) -> Rewrite? {
        let comma = m.range(at: 1).length > 0
        var code = s.substring(with: m.range(at: 2))
        let zip = m.range(at: 3).location == NSNotFound ? nil : s.substring(with: m.range(at: 3))
        if code != code.uppercased() {
            // A title-case code ("Miami, Fl 33101") only before a ZIP.
            guard zip != nil else { return nil }
            code = code.uppercased()
        }
        guard let name = AddressPlaces.states[code], comma || zip != nil else { return nil }
        guard let place = place(before: m.range.location, in: s) else { return nil }
        let end = NSMaxRange(m.range)
        var range = m.range
        var written = name
        if zip == nil {
            // With no ZIP the place must settle it, and a shouted sentence never does.
            guard code != "DC", !casing.isShouted(at: m.range.location) else { return nil }
            guard AddressPlaces.isUSPlace(place.name, code) || place.prefixed else { return nil }
            let rest = text(after: end, in: s)
            guard codeMayEnd(rest), !credentialFollows(rest), !(code == "OK" && okIsWord(rest)) else { return nil }
            let placeWord = place.previous.map(placeWords.contains) ?? false
            let after = firstWord(rest).map { verbsAfter.contains($0) } ?? false
            let based = rest.hasPrefix("-based"), closed = rest.first == ")"
            if AddressPlaces.territories.contains(code) {
                guard placeWord else { return nil }
            } else if AddressPlaces.wordLikeStates.contains(code) {
                guard placeWord || after || based || closed else { return nil }
            }
            if based {
                // "a Portland, OR-based startup": "Oregon based", two words as the says reads them.
                range.length += 1
                written += " "
            }
        }
        var words = (comma ? "," : "") + " " + casing.cased(written, at: m.range(at: 2).location)
        if let zip {
            let plus4 = m.range(at: 4).location == NSNotFound ? nil : s.substring(with: m.range(at: 4))
            words += " " + casing.cased(zipWords(zip, plus4), at: m.range(at: 3).location)
        }
        return (range, words)
    }

    /// A ZIP after a state written out: "Austin, Texas 78701".
    private static let stateNameZip = try! NSRegularExpression(pattern:
        ",[ \\t]+(?:" + Set(AddressPlaces.states.values).filter { $0.count > 3 }.sorted { $0.count > $1.count }.joined(separator: "|")
            + #")[ \t]+(\d{5})(?:-(\d{4}))?(?![\d\p{L}])"#)

    /// "ZIP 90210", "zip code: 02139", "My ZIP code is 90210". A bare "zip" is the verb ("zip
    /// 25000 files").
    private static let zipCue = try! NSRegularExpression(pattern:
        #"(?<![\p{L}])(?:ZIP(?:[ \t]+[Cc]ode)?|[Zz]ip[ \t]+code|ZIP[ \t]+CODE)(?:[ \t]*[:,]|[ \t]+is)?[ \t]*(\d{5})(?:-(\d{4}))?(?![\d\p{L}])"#)

    /// The ZIP (group 1) and any +4 (group 2) after a state's name or a ZIP cue; the words before
    /// it stay as written.
    private static func readZip(_ m: NSTextCheckingResult, _ s: NSString, _ casing: inout Casing) -> Rewrite? {
        let digits = NSRange(location: m.range(at: 1).location, length: NSMaxRange(m.range) - m.range(at: 1).location)
        let plus4 = m.range(at: 2).location == NSNotFound ? nil : s.substring(with: m.range(at: 2))
        return (digits, casing.cased(zipWords(s.substring(with: m.range(at: 1)), plus4), at: digits.location))
    }

    // MARK: - AP-style states (rule J)

    private static let apState = try! NSRegularExpression(pattern:
        #"(?<=[\p{L}'’]),[ \t]+("# + AddressPlaces.apStates.keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern).joined(separator: "|")
            + #")(?![\p{L}\d])"#)

    private static let stateCodes: [String: String] = Dictionary(AddressPlaces.states.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })

    private static func readAPState(_ m: NSTextCheckingResult, _ s: NSString, _ casing: inout Casing) -> Rewrite? {
        let abbr = s.substring(with: m.range(at: 1))
        guard let name = AddressPlaces.apStates[abbr], let place = place(before: m.range.location, in: s) else { return nil }
        let rest = text(after: NSMaxRange(m.range), in: s)
        let next = rest.drop { $0 == " " || $0 == "\t" }
        let zip = next.prefix(while: \.isNumber).count == 5 && next.dropFirst(5).first?.isNumber != true
        if AddressPlaces.wordLikeAPStates.contains(abbr) {
            guard zip || AddressPlaces.isUSPlace(place.name, stateCodes[name] ?? "") else { return nil }
        }
        // Its period: dropped before a comma, a ZIP, "(AP)" or a lower-case word; the full stop at
        // the end, and before a capital.
        var stop = ""
        if rest.first == "," || zip || next.hasPrefix("(AP)") || next.first?.isLowercase == true {
            stop = ""
        } else if next.isEmpty || next.first?.isNewline == true || (next.count < rest.count && next.first?.isUppercase == true) {
            if next.first?.isUppercase == true, AddressPlaces.wordLikeAPStates.contains(abbr) { return nil }
            stop = "."
        } else {
            return nil
        }
        return (m.range, ", " + casing.cased(name, at: m.range(at: 1).location) + stop)
    }

    // MARK: - Canada (rule L)

    private static let postalCode = #"([ABCEGHJ-NPRSTVXY]\d[ABCEGHJ-NPRSTV-Z])[ \t]?(\d[ABCEGHJ-NPRSTV-Z]\d)(?![\p{L}\d])"#

    private static let province = try! NSRegularExpression(pattern:
        #"(?<=[\p{L}.'’])(,?)[ \t]+(ON|QC|AB|MB|SK|NS|NB|PE|NL|YT|NU|NT|BC)(?![\p{L}\d'’])(?:[ \t]+"# + postalCode + ")?")

    /// "T2P 1J9" → "T two P, one J nine".
    private static func postalWords(_ s: NSString, _ m: NSTextCheckingResult, _ a: Int, _ b: Int) -> String {
        spelled(s.substring(with: m.range(at: a))) + ", " + spelled(s.substring(with: m.range(at: b)))
    }

    private static func readProvince(_ m: NSTextCheckingResult, _ s: NSString, _ casing: inout Casing) -> Rewrite? {
        let comma = m.range(at: 1).length > 0
        let code = s.substring(with: m.range(at: 2))
        let postal = m.range(at: 3).location != NSNotFound
        guard let name = AddressPlaces.provinces[code], comma || postal, let place = place(before: m.range.location, in: s) else { return nil }
        if !postal {
            // "Vancouver, BC" keeps its letters; any other code needs a listed city.
            guard code != "BC", AddressPlaces.isCanadianPlace(place.name), !casing.isShouted(at: m.range.location) else { return nil }
            let rest = text(after: NSMaxRange(m.range), in: s)
            guard codeMayEnd(rest), !credentialFollows(rest) else { return nil }
            if code == "ON" {
                guard place.previous.map(placeWords.contains) == true || firstWord(rest).map(verbsAfter.contains) == true else { return nil }
            }
        }
        var words = (comma ? "," : "") + " " + casing.cased(name, at: m.range(at: 2).location)
        if postal { words += " " + casing.cased(postalWords(s, m, 3, 4), at: m.range(at: 3).location) }
        return (m.range, words)
    }

    /// A postal code after a province's name, "Canada" or "postal code".
    private static let canadianPostcode = try! NSRegularExpression(pattern: #"(?<![\p{L}\d])"# + postalCode)
    private static let postalCues = Set(AddressPlaces.provinces.values.map { $0.lowercased() } + ["canada", "code", "code:"])

    private static func readCanadianPostcode(_ m: NSTextCheckingResult, _ s: NSString, _ casing: inout Casing) -> Rewrite? {
        let before = text(before: m.range.location, in: s, limit: 40).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " \t,"))
        guard postalCues.contains(where: { before.hasSuffix($0) }) else { return nil }
        if before.hasSuffix("code") || before.hasSuffix("code:"), !before.contains("postal") { return nil }
        return (m.range, casing.cased(postalWords(s, m, 1, 2), at: m.range.location))
    }

    // MARK: - Australia (rule N)

    private static let australianState = try! NSRegularExpression(pattern:
        #"(?<=[\p{L}.'’])(,?)[ \t]+(NSW|VIC|QLD|TAS|ACT|NT|SA|WA|Vic\.?|Tas\.?|Qld\.?)(?![\p{L}\d'’])(?:[ \t]+(\d{4})(?![\d\p{L}]))?"#)

    private static func readAustralianState(_ m: NSTextCheckingResult, _ s: NSString, _ casing: inout Casing) -> Rewrite? {
        let comma = m.range(at: 1).length > 0
        var code = s.substring(with: m.range(at: 2))
        let postcode = m.range(at: 3).location == NSNotFound ? nil : s.substring(with: m.range(at: 3))
        if code != code.uppercased() {
            // "Vic", "Tas" and "Qld" are also names ("Cheers, Vic."): only before a postcode.
            guard postcode != nil else { return nil }
            code = code.replacingOccurrences(of: ".", with: "").uppercased()
        }
        guard AddressPlaces.australianStates[code] != nil || AddressPlaces.australianLetterStates.contains(code),
              let place = place(before: m.range.location, in: s) else { return nil }
        // ACT, NT, SA and WA are said as letters, as written.
        let name = AddressPlaces.australianStates[code].map { casing.cased($0, at: m.range(at: 2).location) }
        var words = (comma ? "," : "") + " "
        if let postcode {
            let n = Int(postcode) ?? 0
            words += (name ?? s.substring(with: m.range(at: 2))) + " "
                + casing.cased(n % 1000 == 0 ? SpokenNumbers.cardinal(n) : SpokenNumbers.digits(postcode), at: m.range(at: 3).location)
        } else {
            // With no postcode: "Melbourne, VIC." at the end of a sentence or before punctuation.
            guard comma, let name, AddressPlaces.isAustralianPlace(place.name) || place.previous.map(placeWords.contains) == true
            else { return nil }
            let rest = text(after: NSMaxRange(m.range), in: s)
            guard rest.isEmpty || ".,;:!?)".contains(rest.first!) || rest.first!.isNewline else { return nil }
            words += name
        }
        return (m.range, words)
    }

    // MARK: - UK postcodes (rule M)

    /// "SW1A 2AA", "B33 8TH", "EH1 1YZ": the outward code, a space, the inward code. The inward
    /// letters never include C, I, K, M, O or V, so "1PM" and "2AM" can't be one.
    private static let ukPostcode = try! NSRegularExpression(pattern:
        #"(?<![\p{L}\d])(?:(GIR)[ ](0AA)|([A-PR-UWYZ][A-HK-Y]?)(\d[A-Z\d]?)[ ](\d)([ABD-HJLNP-UW-Z]{2}))(?![\p{L}\d])"#)

    private static func readUKPostcode(_ m: NSTextCheckingResult, _ s: NSString, _ casing: inout Casing, british: Bool) -> Rewrite? {
        // A place cue before it: a place's name, "postcode", a comma or the start of a line.
        let before = text(before: m.range.location, in: s, limit: 40)
        if let last = before.reversed().first(where: { $0 != " " && $0 != "\t" }), last != ",", !last.isNewline {
            guard let w = word(before: m.range.location, in: s)?.word else { return nil }
            let bare = w.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard bare.lowercased() == "postcode" || (bare.first?.isUppercase == true && bare.contains(where: \.isLowercase)) else { return nil }
        }
        let words: String
        if m.range(at: 1).location != NSNotFound {
            words = "G I R, " + spelled("0AA", british: british)
        } else {
            let inwardLetters = s.substring(with: m.range(at: 6))
            // "8GB", "1TB": a storage size after a model name, not an inward code.
            guard !["GB", "TB", "PB", "EB"].contains(inwardLetters) else { return nil }
            let area = s.substring(with: m.range(at: 3)), district = s.substring(with: m.range(at: 4))
            let districtWords: String
            if district.allSatisfy(\.isNumber) {
                districtWords = SpokenNumbers.cardinal(Int(district) ?? 0)
            } else {
                districtWords = spelled(district, british: british)
            }
            words = spelled(area, british: british) + " " + districtWords + ", "
                + spelled(s.substring(with: m.range(at: 5)) + inwardLetters, british: british)
        }
        return (m.range, casing.cased(words, at: m.range.location))
    }

    // MARK: - Routes and boxes (rules H and G)

    private static let route = try! NSRegularExpression(pattern:
        #"(?<![\p{L}\d])(US|U\.S\.|Hwy\.?|HWY|Highway|HIGHWAY|Route|ROUTE|Rte\.?|RTE|SR|State Route|Interstate)[ \t]+(\d{1,3})(?![\d\p{L}%]|[.,]\d)"#)
    private static let routeFollowers: Set<String> = ["exit", "freeway", "highway", "bridge", "north", "south", "east", "west",
                                                      "northbound", "southbound", "eastbound", "westbound", "N", "S", "E", "W",
                                                      "North", "South", "East", "West", "NB", "SB", "EB", "WB"]
    private static let notRouteFollowers: Set<String> = ["million", "billion", "trillion", "thousand", "hundred", "percent",
                                                         "miles", "mile", "km", "kilometers", "kilometres", "people", "dollars"]

    /// "US 101 north" → "U S one oh one north", "Hwy 401" → "Highway four oh one". Only three
    /// digits are read as a route number; "Route 66" keeps its cardinal.
    private static func readRoute(_ m: NSTextCheckingResult, _ s: NSString, _ casing: inout Casing) -> Rewrite? {
        let keyword = s.substring(with: m.range(at: 1)), digits = s.substring(with: m.range(at: 2))
        let rest = text(after: NSMaxRange(m.range), in: s)
        var plainNoun = false
        if let c = rest.first, c == " " || c == "\t" {
            guard let next = firstWord(rest) else { return nil }
            if !routeFollowers.contains(next) {
                guard next.first?.isLowercase == true, !notRouteFollowers.contains(next) else { return nil }
                plainNoun = true
            }
        } else if let c = rest.first, !".,;:!?)".contains(c), !c.isNewline {
            return nil
        }
        let names = ["Hwy": "Highway", "Hwy.": "Highway", "HWY": "Highway", "Rte": "Route", "Rte.": "Route", "RTE": "Route",
                     "US": "U S", "U.S.": "U S"]
        if keyword == "US" || keyword == "U.S." {
            // "US" is also the country, and a count can follow it: "Our US 150 employees", "the
            // US 500 index". Before a plain noun it's a route only with no determiner in front;
            // a round hundred reads the same either way, so it's left as written.
            if keyword == "US", casing.isShouted(at: m.range.location) { return nil }
            if digits.hasSuffix("00") { return nil }
            if plainNoun, let previous = word(before: m.range.location, in: s)?.word.lowercased(), countWords.contains(previous) {
                return nil
            }
        }
        guard digits.count == 3 || ["Hwy", "Hwy.", "HWY", "Rte", "Rte.", "RTE"].contains(keyword) else { return nil }
        let number = digits.count == 3 ? addressNumber(digits) : digits
        let word = names[keyword].map { casing.cased($0, at: m.range.location) } ?? keyword
        return (m.range, word + " " + casing.cased(number, at: m.range(at: 2).location))
    }

    /// "P.O. Box 1234", "PO Box 70": "P O Box twelve thirty four" (written "P.O." it was one
    /// word to the voice).
    private static let box = try! NSRegularExpression(pattern:
        #"(?<![\p{L}\d])(P\.[ ]?O\.|PO|P O|Post Office|POST OFFICE)[ \t]+(Box|BOX)[ \t]+#?[ \t]*(\d{1,6})(?![\d\p{L}])"#)

    private static func readBox(_ m: NSTextCheckingResult, _ s: NSString, _ casing: inout Casing) -> Rewrite? {
        let office = s.substring(with: m.range(at: 1))
        let lead = office.lowercased().hasPrefix("post") ? office : casing.cased("P O", at: m.range.location)
        return (m.range, lead + " " + s.substring(with: m.range(at: 2)) + " "
            + casing.cased(addressNumber(s.substring(with: m.range(at: 3))), at: m.range(at: 3).location))
    }

    // MARK: - Numbered streets (rules C and E)

    static let directions = ["N": "North", "S": "South", "E": "East", "W": "West", "NE": "Northeast", "NW": "Northwest",
                             "SE": "Southeast", "SW": "Southwest"]
    private static let abbreviatedTypes = [
        "St": "Street", "Ave": "Avenue", "Av": "Avenue", "Rd": "Road", "Dr": "Drive", "Blvd": "Boulevard", "Ln": "Lane",
        "Ct": "Court", "Pl": "Place", "Pkwy": "Parkway", "Hwy": "Highway", "Terr": "Terrace", "Ter": "Terrace",
        "Cres": "Crescent", "Sq": "Square", "Cir": "Circle", "Trl": "Trail", "Plz": "Plaza", "Gdns": "Gardens",
        "Tpke": "Turnpike", "Expy": "Expressway", "Fwy": "Freeway",
    ]
    private static let fullTypes = [
        "Street", "Avenue", "Road", "Drive", "Boulevard", "Lane", "Way", "Court", "Place", "Parkway", "Highway", "Terrace",
        "Crescent", "Square", "Circle", "Trail", "Plaza", "Close", "Grove", "Gardens", "Mews", "Alley", "Pike", "Turnpike",
        "Expressway", "Freeway",
    ]
    private static let fullTypeSet = Set(fullTypes + fullTypes.map { $0.uppercased() })

    /// Words that carry an address on after a street type: units, and the landmark words a
    /// street's name runs into ("Washington Sq. Park", "Liverpool St. Station").
    static let unitWords = ["Suite": "Suite", "Ste": "Suite", "Apt": "Apartment", "Apartment": "Apartment", "Unit": "Unit",
                            "Fl": "Floor", "Floor": "Floor", "Rm": "Room", "Room": "Room", "Bldg": "Building",
                            "Building": "Building"]
    static let landmarks: Set<String> = [
        "Park", "Square", "Station", "Stn", "Journal", "Bridge", "Market", "Mall", "Pier", "Tunnel", "Garage", "Line",
        "Subway", "Bus", "Exit", "Gate", "Festival", "Fair", "Parade",
    ]

    private static func streetPattern(caps: Bool) -> String {
        let token = caps
            ? #"(?:(?:ST|MT|FT)\.?[ \t]+)?(?:\d{1,3}(?:ST|ND|RD|TH)|\p{Lu}[\p{Lu}'’\-]*)(?![\p{L}\d])"#
            : #"(?:(?:St|Mt|Ft)\.?[ \t]+)?(?:\d{1,3}(?:st|nd|rd|th)|\p{Lu}(?=[\p{L}'’\-]*\p{Ll})[\p{L}'’\-]*|\p{Lu})(?![\p{L}\d])"#
        let abbreviations = abbreviatedTypes.keys.sorted { $0.count > $1.count }
        let types = caps ? (abbreviations + fullTypes).map { $0.uppercased() } : fullTypes + abbreviations
        let direction = caps ? "N|S|E|W|NE|NW|SE|SW|NORTH|SOUTH|EAST|WEST" : "N|S|E|W|NE|NW|SE|SW|North|South|East|West"
        return #"(?<![\p{L}\d$#£€¥.,:/\-])(\d{1,5})([A-Z])?(?:-(\d{1,5})([A-Z])?)?[ \t]+"#
            + "(?:(" + direction + #")\.?[ \t]+)?"#
            + "(" + token + #"(?:[ \t]+"# + token + "){0,3})" + #"[ \t]+"#
            + "(" + types.joined(separator: "|") + #")(?![\p{L}\d'’\-])(\.)?"#
            + #"(?:[ \t]+(NE|NW|SE|SW|N|S|E|W)(?![\p{L}\d'’]))?"#
    }

    /// "123 W 42nd St.", "1300 E St NW", "221B Baker St.", "123-125 Main St.", "742 Evergreen
    /// Terrace": a number, an optional direction, 1 to 4 words of name, a street type.
    private static let streetAddress = try! NSRegularExpression(pattern: streetPattern(caps: false))
    /// The same in USPS capitals: "123 MAIN ST APT 4B", "4545 S 1ST ST".
    private static let streetAddressCaps = try! NSRegularExpression(pattern: streetPattern(caps: true))

    /// A determiner or quantity before the number makes it a count ("over 350 Main Street
    /// businesses", "the 150 Federal Court judges").
    private static let countWords: Set<String> = [
        "over", "under", "about", "around", "nearly", "almost", "roughly", "approximately", "some", "than", "only", "just",
        "all", "the", "its", "their", "our", "these", "those", "no.", "nos.", "#", "my", "his", "her", "your",
    ]
    /// Before a year: "In 2015 Ocean Drive was repaved."
    private static let yearWords: Set<String> = ["in", "since", "by", "until", "before", "after", "during", "of", "from", "till"]
    /// Words before a number that make it an address when the street type is spelled out.
    private static let addressCues: Set<String> = ["at", "on", "to", "from", "near", "off", "opposite", "address", "address:", "via"]
    /// Lower-case words a spelled-out street type can run into ("at 742 Evergreen Terrace now");
    /// any other is a noun ("350 Main Street businesses").
    private static let afterStreet: Set<String> = [
        "in", "on", "at", "to", "is", "was", "and", "or", "now", "for", "near", "by", "with", "from", "until", "which",
        "where", "that", "but", "so", "then", "today", "since", "has", "had", "will", "instead", "across", "off",
    ]

    private static func readStreetAddress(_ m: NSTextCheckingResult, _ s: NSString, _ casing: inout Casing) -> Rewrite? {
        func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : s.substring(with: m.range(at: i)) }
        let number = group(1)!, type = group(7)!
        let previous = word(before: m.range.location, in: s)?.word.lowercased()
        if let previous, countWords.contains(previous) { return nil }
        if group(2) == nil, group(3) == nil, number.count == 4, let n = Int(number), (1000...2099).contains(n),
           let previous, yearWords.contains(previous) { return nil }
        let full = fullTypeSet.contains(type)
        let rest = text(after: NSMaxRange(m.range), in: s)
        if full {
            // Spelled out, a street type needs an address cue, and runs only into what an
            // address can: punctuation, a unit, or a word like "now".
            let line = text(before: m.range.location, in: s, limit: 60)
            let lineHead = line.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
            let cue = lineHead.allSatisfy { $0 == " " || $0 == "\t" } || lineHead.trimmingCharacters(in: .whitespaces).hasSuffix(":")
                || previous.map(addressCues.contains) == true
                || lineHead.lowercased().range(of: #"address[: ]+(is[ \t]+)?$"#, options: .regularExpression) != nil
            guard cue else { return nil }
            if let next = firstWord(rest), rest.first == " " || rest.first == "\t" {
                if next.first?.isLowercase == true, !afterStreet.contains(next) { return nil }
                if next.first?.isUppercase == true, unitWords[next] == nil, !starters.contains(next) { return nil }
            }
        }
        let at = m.range.location
        var words = addressNumber(number) + (group(2).map { " " + letterName(Character($0)) } ?? "")
        if let second = group(3) {
            words += " to " + addressNumber(second) + (group(4).map { " " + letterName(Character($0)) } ?? "")
        }
        words = casing.cased(words, at: at)
        if let d = group(5) {
            words += " " + casing.cased(directions[d] ?? d, at: m.range(at: 5).location)
        }
        // The name: an ordinal in capitals is read as a word ("1ST" was "one S T"), a lone "A"
        // is the letter, and St./Mt./Ft. in a name are Saint, Mount and Fort.
        let names = group(6)!.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { token -> String in
            switch token.replacingOccurrences(of: ".", with: "").uppercased() {
            case "ST": return casing.cased("Saint", at: at)
            case "MT": return casing.cased("Mount", at: at)
            case "FT": return casing.cased("Fort", at: at)
            case "A": return casing.cased("ay", at: at)
            default: break
            }
            if token.first?.isNumber == true, token.last?.isUppercase == true, let n = Int(token.prefix(while: \.isNumber)) {
                return casing.cased(SpokenNumbers.ordinal(n), at: at)
            }
            return String(token)
        }
        words += " " + names.joined(separator: " ")
        let typeWord = abbreviatedTypes.first { $0.key.uppercased() == type.uppercased() }?.value ?? type
        words += " " + (full ? type : casing.cased(typeWord, at: m.range(at: 7).location))
        if group(8) != nil {
            words += full ? "." : (group(9) != nil ? "" : keptStop(before: rest))
        }
        if let d = group(9) {
            words += " " + casing.cased(directions[d] ?? d, at: m.range(at: 9).location)
        }
        return (m.range, words)
    }

    /// "1585 Broadway": a number straight before Broadway is a house number.
    private static let broadway = try! NSRegularExpression(pattern: #"(?<![\p{L}\d$#£€¥.,:/\-])(\d{1,5})[ \t]+(?=(?:Broadway|BROADWAY)(?![\p{L}\d]))"#)

    private static func readBroadway(_ m: NSTextCheckingResult, _ s: NSString, _ casing: inout Casing) -> Rewrite? {
        if let previous = word(before: m.range.location, in: s)?.word.lowercased(), countWords.contains(previous) || yearWords.contains(previous) {
            return nil
        }
        return (m.range(at: 1), casing.cased(addressNumber(s.substring(with: m.range(at: 1))), at: m.range.location))
    }

    // MARK: - Units (rule G)

    /// "Suite 1500", "Ste. 200", "Apt 4B", "Rm. 214", "Unit 302", "Fl. 3", "APT 4B". Capitalised
    /// or in capitals only: "apt", "fl." and "rm" stay words; "RM 500" (ringgit) and "FL" (a
    /// state) aren't here.
    private static let unit = try! NSRegularExpression(pattern:
        #"(?<![\p{L}\d])(Suite|Ste|Apartment|Apt|Unit|Floor|Fl|Room|Rm|Building|Bldg|SUITE|STE|APARTMENT|APT|UNIT|FLOOR|ROOM|BLDG)(\.)?(?:[ \t]+#?|[ \t]*#)[ \t]*(?:(\d{1,4})([A-Z])?|([A-Z])(\d{1,3})?)(?![\p{L}\d'’])"#)

    private static func readUnit(_ m: NSTextCheckingResult, _ s: NSString, _ casing: inout Casing) -> Rewrite? {
        let keyword = s.substring(with: m.range(at: 1))
        let title = keyword.prefix(1) + keyword.dropFirst().lowercased()
        guard let name = unitWords[String(title)] else { return nil }
        if title == "Fl" {
            // "Miami, Fl 33101" is Florida: a code after "City, ", never a floor.
            let before = text(before: m.range.location, in: s, limit: 3)
            if before.hasSuffix(", ") { return nil }
        }
        var words = casing.cased(name, at: m.range.location)
        if m.range(at: 3).location != NSNotFound {
            words += " " + casing.cased(addressNumber(s.substring(with: m.range(at: 3))), at: m.range(at: 3).location)
            if m.range(at: 4).location != NSNotFound {
                words += " " + casing.cased(letterName(Character(s.substring(with: m.range(at: 4)))), at: m.range(at: 4).location)
            }
        } else {
            let letter = s.substring(with: m.range(at: 5))
            // "Suite B" is already read right; only the keyword or the letter A changes.
            guard letter == "A" || name != String(title) else { return nil }
            words += " " + casing.cased(letterName(Character(letter)), at: m.range(at: 5).location)
            if m.range(at: 6).location != NSNotFound {
                words += " " + casing.cased(addressNumber(s.substring(with: m.range(at: 6))), at: m.range(at: 6).location)
            }
        }
        return (m.range, words)
    }

    /// "3rd Fl." → "3rd Floor".
    private static let floorOrdinal = try! NSRegularExpression(pattern:
        #"(?<![\p{L}\d])(\d{1,3})(st|nd|rd|th|ST|ND|RD|TH)[ \t]+(Fl|FL)(\.)?(?![\p{L}\d])"#)

    private static func readFloorOrdinal(_ m: NSTextCheckingResult, _ s: NSString, _ casing: inout Casing) -> Rewrite? {
        let suffix = s.substring(with: m.range(at: 2))
        let n = s.substring(with: m.range(at: 1))
        let ordinal = suffix == suffix.lowercased() ? n + suffix : casing.cased(SpokenNumbers.ordinal(Int(n) ?? 0), at: m.range.location)
        let stop = m.range(at: 4).location == NSNotFound ? "" : keptStop(before: text(after: NSMaxRange(m.range), in: s))
        return (m.range, ordinal + " " + casing.cased("Floor", at: m.range(at: 3).location) + stop)
    }

    /// "Bldg." → "Building" (with a number, the unit rule reads it).
    private static let building = try! NSRegularExpression(pattern: #"(?<![\p{L}\d])(Bldg|BLDG)(\.)?(?![\p{L}\d])"#)

    private static func readBuilding(_ m: NSTextCheckingResult, _ s: NSString, _ casing: inout Casing) -> Rewrite? {
        let stop = m.range(at: 2).location == NSNotFound ? "" : keptStop(before: text(after: NSMaxRange(m.range), in: s))
        return (m.range, casing.cased("Building", at: m.range.location) + stop)
    }

    // MARK: - Street types after a name (rules D and E)

    /// "Elm Rd.", "Astor Pl.", "Pacific Coast Hwy", "Washington Sq. Park", "Mulholland Dr.":
    /// the type after a capitalised name, with no house number. "St." is read in `readStreets`.
    private static let streetType = try! NSRegularExpression(pattern:
        #"(?<![\p{L}\d'’.])(\p{Lu}[\p{L}'’\-]*|\d{1,3}(?:st|nd|rd|th))[ \t]+(Dr|Rd|Ln|Ct|Pl|Pkwy|Hwy|Cres|Terr|Ter|Sq|Cir|Trl|Ave|Blvd)(?![\p{L}\d'’\-])(\.)?(?:[ \t]+(NE|NW|SE|SW)(?![\p{L}\d'’]))?"#)

    /// Words before a street's name that place it ("along Mulholland Dr.", "on Oak Dr."): with
    /// none, "Dr." is Doctor ("Our Family Dr. retired").
    private static let placePrepositions: Set<String> = [
        "on", "onto", "off", "along", "down", "up", "at", "to", "from", "near", "past", "via", "across", "into", "toward",
        "towards", "opposite", "behind",
    ]
    private static let titleWords: Set<String> = ["Mr", "Mrs", "Ms", "Mx", "Dr", "St", "Mt", "Sen", "Gov", "Rep", "Prof", "Gen",
                                                  "Rev", "Lt", "Col", "Capt", "Sgt", "Maj", "Adm", "Hon", "Fr", "Sr", "Jr"]
    private static let areaUnits: Set<String> = ["ft", "m", "mi", "km", "in", "yd", "yds", "feet", "foot", "meters", "metres",
                                                 "miles", "inches", "yards", "cm", "mm"]

    private static func readStreetType(_ m: NSTextCheckingResult, _ s: NSString, _ casing: inout Casing) -> Rewrite? {
        let name = s.substring(with: m.range(at: 1)), type = s.substring(with: m.range(at: 2))
        let period = m.range(at: 3).location != NSNotFound, trailing = m.range(at: 4).location != NSNotFound
        let ordinal = name.first?.isNumber == true
        if ordinal {
            // "the 9th Cir." is a court of appeals.
            guard type != "Cir" else { return nil }
        } else {
            guard name.contains(where: \.isLowercase), !starters.contains(name), !titleWords.contains(name) else { return nil }
        }
        let rest = text(after: NSMaxRange(m.range), in: s)
        var endsSentence = false, carriesOn = trailing
        let r = rest.drop { $0 == " " || $0 == "\t" }
        if trailing {
            // "Pennsylvania Ave. NW": the direction carries the address on.
        } else if r.isEmpty || r.first!.isNewline {
            endsSentence = true
        } else if r.count == rest.count {
            // Straight after the type: only punctuation ends the name.
            guard ",;:)]!?".contains(r.first!) else { return nil }
        } else if r.first == "#" {
            carriesOn = true
        } else if r.first!.isNumber {
            return nil  // "NFL Draft Rd. 1"; "Hwy 401" is a route
        } else if let next = firstWord(r) {
            if r.first!.isLowercase {
                if type == "Sq", areaUnits.contains(next) { return nil }  // "Sq. ft." is the units area's
            } else if unitWords[next] != nil || directions[next] != nil || landmarks.contains(next) {
                carriesOn = true
            } else if period, starters.contains(next) {
                endsSentence = true
            } else {
                return nil  // a name follows: "Dr. Lee", "Ave Maria"
            }
        }
        if type == "Dr" || (type == "Ave" && !period) {
            // Dr. is Doctor unless something places the name: a place word before it, or a unit,
            // a direction, a city or a ZIP after it.
            var placed = carriesOn || rest.range(of: #"^,[ \t]+\p{Lu}|^[ \t]+\d{5}(?!\d)"#, options: .regularExpression) != nil
            if !placed {
                var location = m.range.location
                for _ in 0..<4 {
                    guard let w = word(before: location, in: s) else { break }
                    if w.word.first?.isUppercase == true, !w.word.hasSuffix(".") { location = w.start; continue }
                    placed = placePrepositions.contains(w.word.lowercased())
                    break
                }
            }
            guard placed else { return nil }
        }
        var words = name + " " + casing.cased(abbreviatedTypes[type]!, at: m.range(at: 2).location)
        if period, !trailing, endsSentence { words += "." }
        if trailing {
            let d = s.substring(with: m.range(at: 4))
            words += " " + casing.cased(directions[d]!, at: m.range(at: 4).location)
        }
        return (m.range, words)
    }

    /// "Pennsylvania Avenue NW" → "Pennsylvania Avenue Northwest" (SE is a custom-lexicon term,
    /// so it's read here, before the lexicon).
    private static let typeDirection = try! NSRegularExpression(pattern:
        #"(?<![\p{L}\d])(\p{Lu}[\p{L}'’\-]*[ \t]+(?:Street|Avenue|Road|Drive|Boulevard|Lane|Way|Court|Place|Parkway|Highway|Terrace|Circle|Trail|Plaza|Square))[ \t]+(NE|NW|SE|SW)(?![\p{L}\d'’])"#)

    private static func readTypeDirection(_ m: NSTextCheckingResult, _ s: NSString, _ casing: inout Casing) -> Rewrite? {
        let d = s.substring(with: m.range(at: 2))
        return (m.range, s.substring(with: m.range(at: 1)) + " " + casing.cased(directions[d]!, at: m.range(at: 2).location))
    }

    // MARK: - Saint, Street or Suite (rule F)

    /// "St" with no period before a name: Saint after a lower-case word ("visited St Paul's"),
    /// a place prefix ("Mount St Helens") or another name ("Yves St Laurent"), or at the start.
    /// It stays Street (as the lexicon reads it) in a street ("on Main St Then…") and before a
    /// landmark or time word ("Liverpool St Station", "The Wall St Journal").
    private static let saintNoStop = try! NSRegularExpression(pattern: #"(?<![\p{L}\d'’.])St(?![\p{L}\d'’.])(?=[ \t]+\p{Lu})"#)

    private static func readSaintNoStop(_ m: NSTextCheckingResult, _ s: NSString, _ casing: inout Casing) -> Rewrite? {
        guard let next = firstWord(text(after: NSMaxRange(m.range), in: s, limit: 40)), !starters.contains(next) else { return nil }
        let before = text(before: m.range.location, in: s, limit: 120)
        if let w = word(before: m.range.location, in: s), !w.word.hasSuffix(".") {
            let previous = w.word
            if Tokenizer.isStreet(before: before) || previous.contains(where: \.isNumber) { return nil }
            if previous.first?.isUppercase == true, !Tokenizer.placePrefixes.contains(previous) {
                if isLandmark(next) || ["Main", "High"].contains(previous) { return nil }
            }
        }
        return (m.range, casing.cased("Saint", at: m.range.location))
    }

    /// "Ste." or "Ste" before a name is Sainte, said Saint: "Sault Ste. Marie", "Ste. Genevieve".
    /// Before a number it's Suite (the unit rule).
    private static let sainte = try! NSRegularExpression(pattern: #"(?<![\p{L}\d'’])Ste\.?(?=[ \t]+\p{Lu}\p{Ll})"#)

    private static func readSainte(_ m: NSTextCheckingResult, _ s: NSString, _ casing: inout Casing) -> Rewrite? {
        (m.range, casing.cased("Saint", at: m.range.location))
    }

    /// A landmark or time word, which a street's name runs into: "Liverpool St. Station",
    /// "Bourbon St. Saturday night", "the Regent St Christmas lights".
    static func isLandmark(_ word: String) -> Bool {
        landmarks.contains(word) || timeWords.contains(word) || CalendarNames.monthsInOrder.contains(word)
    }
    /// The days, and the holidays a street's lights, parade or market are named for (no saint
    /// is called Christmas).
    private static let timeWords: Set<String> = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
                                                 "Christmas", "Easter", "Halloween", "Thanksgiving"]

    // MARK: - A lettered avenue (rule O)

    /// "Ave. A" → "Avenue ay": alone, "A" is the article. ("Avenue X" is already the letter.)
    private static let letteredAvenue = try! NSRegularExpression(pattern: #"(?<![\p{L}\d])(Avenue|Ave\.?|AVENUE|AVE\.?)[ \t]+A(?![\p{L}\d'’\-])"#)

    private static func readLetteredAvenue(_ m: NSTextCheckingResult, _ s: NSString, _ casing: inout Casing) -> Rewrite? {
        let keyword = s.substring(with: m.range(at: 1))
        // "…on Fifth Ave. A man…": after a name, the period ends the sentence.
        if keyword.hasSuffix("."), let w = word(before: m.range.location, in: s), w.word.first?.isUppercase == true { return nil }
        return (m.range, casing.cased("Avenue ay", at: m.range.location))
    }

    // MARK: - Hooks in TextNormalizer and the sentence split

    /// Whether `head`, a sentence as Apple's splitter cut it (trimmed), ends in an abbreviation
    /// of this area that runs on into `next` ("Elm Rd." + "Suite 3", "Albany, N.Y." + "…"), so
    /// the two are read as one. nil leaves it to `Tokenizer.titleContinues`. Each one needs a
    /// chunk case in Tests/g2p/regression.json: the speech tests phonemize whole lines and never
    /// see the split.
    static func sentenceContinues(_ head: String, into next: String) -> Bool? {
        guard head.hasSuffix("."), let last = head.split(whereSeparator: \.isWhitespace).last else { return nil }
        let following = next.drop(while: \.isWhitespace)
        guard let first = following.first else { return nil }
        let word = firstWord(following) ?? ""
        switch last {
        case "Ste.", "Apt.", "Fl.", "Rm.":
            // A unit before its number ("Apt." + "4B"), and Sainte before a name ("Sault Ste." +
            // "Marie").
            if first.isNumber || first == "#" { return true }
            if last == "Ste.", first.isUppercase, !starters.contains(word) { return true }
            return nil
        case "Rd.", "Ave.", "Ln.", "Pl.", "Ct.", "Blvd.", "Pkwy.", "Hwy.", "Cres.", "Terr.", "Sq.", "Cir.", "Trl.":
            if first.isLowercase || unitWords[word] != nil || directions[word] != nil || landmarks.contains(word) { return true }
            return starters.contains(word) ? false : nil
        default:
            // A state in AP style, before the rest of its sentence ("Salem, Ore." + "said…").
            guard AddressPlaces.apStates[String(last)] != nil else { return nil }
            if first.isLowercase || following.hasPrefix("(AP)") { return true }
            return nil
        }
    }

    /// Street-type and place abbreviations in TextNormalizer's abbreviation list, read where they
    /// always were, near the end of the rules ("Ave." is Avenue anywhere, "Mt." Mount).
    static func abbreviationRules(british: Bool) -> [Rule] {
        var rules: [Rule] = []
        for (abbr, full) in abbreviations {
            rules.append(Rule("(?<![\\p{L}.])" + NSRegularExpression.escapedPattern(for: abbr) + "(?=\\s|$|[,;:)])") { _, _ in full })
        }
        return rules
    }

    private static let abbreviations: [(String, String)] = [("Ave.", "Avenue"), ("Blvd.", "Boulevard"), ("Mt.", "Mount")]

    private static let saint = try! NSRegularExpression(pattern: #"(?<![\p{L}.])St\."#)
    private static let nameNext = try! NSRegularExpression(pattern: "^" + TextNormalizer.namePattern)
    private static let streetEnd = try! NSRegularExpression(pattern: #"^(?:(\s*$|\s+\p{Lu})|\s|[,;:)])"#)
    private static let lastWord = try! NSRegularExpression(pattern: #"(?:^|[^\p{L}\d'’.])(\p{Lu}[\p{L}'’\-]*)\s$"#)

    /// "St.": Saint before a name ("Mount St. Helens", "Yves St. Laurent", "to St. Louis"), unless
    /// it ends a street's name (`Tokenizer.isStreet`: "5th St.", "Park on Elm St. Bring cash.");
    /// any other "St." after a word is a street ("Main St."). At the end of a sentence its period
    /// is also the full stop, so that stays ("Street."). After a name, before a landmark or time
    /// word, it's a street too ("The Wall St. Journal", "Liverpool St. Station", "Bourbon St.
    /// Saturday night"), unless the name is a place prefix ("Port St. Lucie"). Read with the
    /// marked terms in view: "Elm" in "on Elm St." is a custom-lexicon term, and seen alone "St.
    /// Bring" was "Saint Bring". Called from `TextNormalizer.normalize`, after the arrows and
    /// Roman numerals are read.
    static func readStreets(_ text: String) -> String {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let matches = saint.matches(in: text, range: all)
        guard !matches.isEmpty else { return text }
        let marks = TextNormalizer.marked.matches(in: text, range: all).map(\.range)
        func plain(_ s: String) -> String {
            TextNormalizer.marked.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "$1")
        }
        var out = "", last = 0
        for m in matches where !marks.contains(where: { NSLocationInRange(m.range.location, $0) }) {
            let start = max(0, m.range.location - 120)
            let before = plain(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
            let after = plain(ns.substring(with: NSRange(location: NSMaxRange(m.range), length: min(160, ns.length - NSMaxRange(m.range)))))
            let a = after as NSString
            var words: String?
            if streetBeforeLandmark(before, after) {
                words = "Street"
            } else if nameNext.firstMatch(in: after, range: NSRange(location: 0, length: a.length)) != nil, !Tokenizer.isStreet(before: before) {
                words = "Saint"
            } else if before.range(of: #"[\p{L}\d]\s$"#, options: .regularExpression) != nil,
                      let e = streetEnd.firstMatch(in: after, range: NSRange(location: 0, length: a.length)) {
                words = e.range(at: 1).location == NSNotFound ? "Street" : "Street."
            }
            guard let words else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + words
            last = NSMaxRange(m.range)
        }
        return out + ns.substring(from: last)
    }

    /// Whether "St." between `before` and `after` ends a street's name before a landmark or time
    /// word: "Liverpool St. Station", but not "Port St. Lucie" or "At St. Pancras".
    private static func streetBeforeLandmark(_ before: String, _ after: String) -> Bool {
        guard let next = firstWord(after), isLandmark(next), after.first == " " else { return false }
        let b = before as NSString
        guard let m = lastWord.firstMatch(in: before, range: NSRange(location: 0, length: b.length)) else { return false }
        let name = b.substring(with: m.range(at: 1))
        return name.contains(where: \.isLowercase) && !Tokenizer.placePrefixes.contains(name) && !starters.contains(name)
    }
}
