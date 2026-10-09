import Foundation

/// Dates and timestamps (Core readings, FIN-889; area "dates"): numeric and written dates,
/// weekdays, month and weekday ranges, durations, "5m ago", centuries, quarters, and the British
/// wording ("the fifteenth of March"), which is why TextNormalizer's rules are built per voice
/// (`makeRules(british:)`). Each hook runs at its own place in the list.
///
/// The rules write digits ("March 4th, 2024", "the 4th of March"), which the lexicon reads as
/// ordinals and years, so a rewritten date sounds like the same date typed out. Where the text
/// doesn't settle a reading (a count before a month-named noun, "Sat" the verb, "5m" the
/// length), a rule leaves it as it was: every rule needs a shape or a neighbour that only a date
/// has.
enum DateRules {
    typealias Rule = TextNormalizer.Rule

    // MARK: Step 2: quarter and half years

    private static let quarterYear = try! NSRegularExpression(pattern: #"(?<![\p{L}\d])(Q[1-4]|H[12]|FY)(?=['’]\d{2}(?![\p{L}\d'’]))"#)

    /// "Q3'24" → "Q3 '24": in `Phonemizer.phonemize` before the money pass, only when
    /// normalizing. Q1 to Q4, H1, H2 and FY are lexicon keys, and the apostrophe must be split
    /// off before the measures pass looks at apostrophes. Run together, the marked "Q3" and "'24"
    /// were one word; apart, they read as "Q4 '23" already does. A possessive ("Q3's") stays.
    static func splitQuarterYears(_ text: String) -> String {
        // An apostrophe and a digit, found without Foundation's `contains` (it cost more than
        // the split, on every sentence).
        guard text.unicodeScalars.contains(where: { $0 == "'" || $0 == "’" }), TextNormalizer.containsDigit(text) else { return text }
        let ns = text as NSString
        return quarterYear.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "$1 ")
    }

    // MARK: Step 16: numeric dates

    /// Year-first slash dates, then numeric dates ("3/4/2024"): after keyboard shortcuts, before
    /// units' slash compounds, ports, file paths, ISO, Ranges, clock, ratio and fractions.
    static func numericDates(british: Bool) -> [Rule] {
        var rules: [Rule] = []
        // Year first, with slashes: "2024/03/04" → "March 4th, 2024", always year-month-day.
        // Two groups ("the 2023/24 season") are a season, a dotted year first ("2024.3.1") is a
        // version, and a slash on either side is a path or a URL ("example.com/2024/03/04/post").
        rules.append(Rule.withContext(#"(?<![\p{L}\d\-–−./:])(\d{4})/(\d{1,2})/(\d{1,2})(?![\p{L}\d\-–/]|[.,:]\d)"#) { m, s, context in
            let whole = s.substring(with: m.range)
            guard let year = Int(s.substring(with: m.range(at: 1))), (1000...2099).contains(year),
                  let month = Int(s.substring(with: m.range(at: 2))), let day = Int(s.substring(with: m.range(at: 3))),
                  isDate(day: day, month: month) else { return whole }
            let afterThe = previousWord(context.text(before: m.range, in: s)).word.lowercased() == "the"
            return written(day: day, month: month, year: String(year), british: british, afterThe: afterThe)
        })
        // "3/4/2024", "03-04-2024", "3.4.2024", "03/04/24": the same separator twice. A part over
        // 12 is the day; when both could be the month, the voice decides (DECISIONS 4: US month
        // first, GB day first). The limits keep out what has the same shape: sizes, ages and
        // option lists ("8/10/12", "2/4/12 months"), versions and builds ("1.2.24", "Firmware
        // 2.1.1024"), IP addresses, file names ("3-4-2024.pdf") and formations ("4-4-2").
        rules.append(Rule.withContext(#"(?<![\p{L}\d_/.\-–−:#@$£€¥₹₩])(\d{1,2})([/.\-])(\d{1,2})\2(\d{4}|\d{2})(?![\p{L}\d]|[/.\-:]\d|\.\p{L})"#) { m, s, context in
            let whole = s.substring(with: m.range)
            let a = s.substring(with: m.range(at: 1)), b = s.substring(with: m.range(at: 3))
            let separator = s.substring(with: m.range(at: 2)), yearText = s.substring(with: m.range(at: 4))
            guard let x = Int(a), let y = Int(b), let year = Int(yearText) else { return whole }
            let previous = previousWord(context.text(before: m.range, in: s), skipping: [":"]).word.lowercased()
            if yearText.count == 4 {
                // Dots are also versions and builds: only a modern year, and not after a version word.
                guard (separator == "." ? 1900...2099 : 1000...2099).contains(year) else { return whole }
                if separator == ".", versionWords.contains(previous) { return whole }
            } else {
                // A two-digit year needs slashes and a zero ("03/04/24") or a date word before it.
                guard separator == "/", year != 0,
                      a.hasPrefix("0") || b.hasPrefix("0") || dateWords.contains(previous) else { return whole }
            }
            if case .word(let next) = follower(context.text(after: m.range, in: s, limit: 40)),
               countWords.contains(next.lowercased()) { return whole }
            guard let (day, month) = dayAndMonth(x, y, british: british) else { return whole }
            // A short year as written ("twenty-four"; "05" → "oh five"): a century would be a guess.
            let spokenYear = yearText.count == 2 && yearText.hasPrefix("0") ? "oh " + String(yearText.dropFirst()) : yearText
            return written(day: day, month: month, year: spokenYear, british: british, afterThe: previous == "the")
        })
        // A month and a year: "Exp. 03/2026", "Best before 05/2026" → "March 2026". A month
        // can't be over 12 and nobody writes a fraction over a year.
        rules.append(Rule(#"(?<![\p{L}\d_/.\-–−:#@$£€¥₹₩])(?:(Exp|EXP|exp)\.?[ \t]*:?[ \t]*)?(0?[1-9]|1[0-2])/((?:19|20)\d\d)(?![\d/]|[.,]\d)"#) { m, s in
            let expires = m.range(at: 1).location == NSNotFound ? "" : (s.substring(with: m.range(at: 1)) == "exp" ? "expires " : "Expires ")
            guard let month = Int(s.substring(with: m.range(at: 2))) else { return s.substring(with: m.range) }
            return expires + CalendarNames.monthsInOrder[month - 1] + " " + s.substring(with: m.range(at: 3))
        })
        // A month and a day with no year: "on 10/31", "due 10/24", "closed 12/24 and 12/25",
        // "11/27-11/28", "moved to 3/8". The shape is also a fraction, a score or a rating ("3/4",
        // "9/10", "24/7"), so it's a date only where the sentence says so: a word that goes with a
        // date right before it, a date noun ("The deadline was 10/31"), or a second date joined to
        // it. A common fraction ("1/2", "3/4") isn't one after "by" or "from" ("cut by 1/3"), and
        // nothing is before a measure ("from 1/2 to 3/4 cup", "1/3 of the vote"). In a range, a
        // part over 12 in either date settles the order of both ("12/24 – 1/2").
        rules.append(Rule.withContext(#"(?<![\p{L}\d_/.\-–−:#@$£€¥₹₩])(\d{1,2})/(\d{1,2})(?![\d/]|[.,]\d|\.\p{L})(?:([ \t]?[-–][ \t]?|[ \t](?:to|and|or|through|thru|until|till)[ \t])(\d{1,2})/(\d{1,2})(?![\d/]|[.,]\d|\.\p{L}))?"#) { m, s, context in
            let whole = s.substring(with: m.range)
            func number(_ i: Int) -> Int? { m.range(at: i).location == NSNotFound ? nil : Int(s.substring(with: m.range(at: i))) }
            guard let a = number(1), let b = number(2) else { return whole }
            let second = number(4).flatMap { c in number(5).map { (c, $0) } }
            // Names, not dates: "9/11", "7/7", "24/7", "50/50".
            if second == nil, namedSlashes.contains("\(a)/\(b)") { return whole }
            if case .word(let w) = follower(context.text(after: m.range, in: s, limit: 40)), fractionMeasures.contains(w.lowercased()) {
                return whole
            }
            let before = context.text(before: m.range, in: s, limit: 60)
            let previous = previousWord(before).word.lowercased()
            let fractions = isFractionShaped(a, b) || second.map { isFractionShaped($0.0, $0.1) } == true
            var cued = slashDateCues.contains(previous) && !(fractions && ["by", "from"].contains(previous))
            if !cued, previous == "to" || previous == "for" {
                let rest = before.reversed().drop { $0 == " " || $0 == "\t" }.drop { $0.isLetter }
                cued = moveVerbs.contains(previousWord(String(rest.reversed())).word.lowercased())
            }
            if !cued { cued = matches(dateNounBehind, before) }
            if !cued, second != nil, !fractions { cued = true }
            guard cued else { return whole }
            // The order: a part over 12 settles it; otherwise the voice does.
            let parts = [(a, b)] + (second.map { [$0] } ?? [])
            let dayFirst = parts.contains { $0.0 > 12 } ? true : parts.contains { $0.1 > 12 } ? false : british
            var dates: [String] = []
            for (x, y) in parts {
                let (day, month) = dayFirst ? (x, y) : (y, x)
                guard isDate(day: day, month: month) else { return whole }
                dates.append(written(day: day, month: month, year: nil, british: british, afterThe: dates.isEmpty && previous == "the"))
            }
            guard dates.count == 2 else { return dates[0] }
            let joiner = s.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
            return dates[0] + " " + (joiner == "-" || joiner == "–" ? "to" : joiner) + " " + dates[1]
        })
        return rules
    }

    // MARK: Step 19: clock stamps and durations

    /// H:MM:SS, then "5m ago" and compound durations ("1h 30m"): after powers, before shorthand's
    /// "~", the unit range rule, units' h, m and s, clock and ratio.
    static func durations(british: Bool) -> [Rule] {
        var rules: [Rule] = []
        // A time zone's offset: "(UTC-08:00)", "GMT-5", "UTC+05:30" → "UTC minus 8", "plus 5 30".
        // The clock rule took "-08:00" for eight o'clock and the minus was lost. Only right
        // after UTC or GMT (a term the lexicon may have marked).
        rules.append(Rule.withContext(#"(?<!\d)[ \t]?([+\-−])(\d{1,2})(?::?([0-5]\d))?(?![\d:\p{L}]|[.,]\d)"#) { m, s, context in
            let before = context.text(before: m.range, in: s, limit: 8)
            guard before.hasSuffix("UTC") || before.hasSuffix("GMT") else { return s.substring(with: m.range) }
            let sign = s.substring(with: m.range(at: 1)) == "+" ? "+" : "-"
            let minutes = m.range(at: 3).location == NSNotFound ? nil : s.substring(with: m.range(at: 3))
            return " " + offsetWords(sign: sign, hours: s.substring(with: m.range(at: 2)), minutes: minutes)
        })
        // H:MM:SS. A clock time after "at" or "@", after a date, before am/pm or a time zone,
        // from 13 hours, or as a log stamp (opening a line, or in brackets): "at 14:32:07" →
        // "14:32 and 7 seconds" (the clock rule reads the rest). Otherwise a duration, with zero
        // parts dropped: "2:03:59" → "2 hours 3 minutes 59 seconds", "1:00:00" → "1 hour". Ratios
        // ("1:2:4"), timecodes ("01:02:03:04") and coordinates ("51:30:26 N") are other shapes.
        let meridiem = #"(?:[ \t]?([AaPp](?:\.[ \t]?[Mm]\.?|[Mm]))(?![\p{L}]))?"#
        rules.append(Rule.withContext(#"(?<![\d:.,])(\d{1,2}):([0-5]\d):([0-5]\d)(?![\d:\p{L}]|[.,]\d)"# + meridiem) { m, s, context in
            let whole = s.substring(with: m.range)
            let hours = s.substring(with: m.range(at: 1)), minutes = s.substring(with: m.range(at: 2))
            guard let h = Int(hours), h <= 23, let mm = Int(minutes), let ss = Int(s.substring(with: m.range(at: 3))) else { return whole }
            let ampm = m.range(at: 4).location == NSNotFound ? nil : s.substring(with: m.range(at: 4))
            let before = context.text(before: m.range, in: s, limit: 60)
            let after = context.text(after: m.range, in: s, limit: 40)
            if ampm != nil || h >= 13 || isClockContext(before) || timeZoneFollows(after) {
                var out = "\(hours):\(minutes)"
                guard let ampm else { return ss == 0 ? out : out + " and \(ss) " + (ss == 1 ? "second" : "seconds") }
                guard ss > 0 else { return out + " " + ampm }
                // "9:30:15 p.m." → "9:30 p.m and 15 seconds.": the meridiem's period moves to the
                // end when it was also the full stop.
                out += " " + (ampm.hasSuffix(".") ? String(ampm.dropLast()) : ampm) + " and \(ss) " + (ss == 1 ? "second" : "seconds")
                return out + (ampm.hasSuffix(".") ? FullStop.kept(before: after, next: .capitalNotTimeWord) : "")
            }
            let parts = [(h, "hour"), (mm, "minute"), (ss, "second")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
            return parts.isEmpty ? "0 seconds" : parts.joined(separator: " ")
        })
        // "5m ago", "2h ago", "1w ago", "3 mos ago": a feed's relative stamp. Without "ago" the
        // same letters are metres or millions ("5m"), 3D and arrays ("3d", "2d"), pencils ("2H"),
        // hex ("21h") and decades ("10s"), so nothing else is touched. A price ("$5m ago") is money's.
        rules.append(Rule(#"(?<![\p{L}\d.,$£€¥₹₩])(\d+) ?(wks|wk|mos|mo|s|m|h|d|w|y)(?= ago(?![\p{L}]))"#) { m, s in
            let n = s.substring(with: m.range(at: 1))
            let unit = agoUnits[s.substring(with: m.range(at: 2))]!
            return n + " " + (TextNormalizer.isOne(n) ? unit : unit + "s")
        })
        // "Out 3d next week", "older than 30d": days, where a word for a stretch of time comes
        // before the number or after it. Elsewhere "3d" and "2d" are dimensions ("a 3d model",
        // "3d printing"), which the words around them never are.
        rules.append(Rule.withContext(#"(?<![\p{L}\d.,$£€¥₹₩])(\d{1,3})d(?![\p{L}\d'’\-])"#) { m, s, context in
            let whole = s.substring(with: m.range)
            let previous = previousWord(context.text(before: m.range, in: s)).word.lowercased()
            var days = dayCountCues.contains(previous)
            if case .word(let w) = follower(context.text(after: m.range, in: s, limit: 40)) {
                if dimensionNouns.contains(w.lowercased()) { return whole }
                days = days || dayCountFollowers.contains(w.lowercased())
            }
            guard days else { return whole }
            let n = s.substring(with: m.range(at: 1))
            return n + (n == "1" ? " day" : " days")
        })
        // "1h 30m", "2h30m", "1h 30m 15s", "2d 4h": two or three parts in falling order, at least
        // one with a one-letter unit, each after the first in range (under 60, hours under 24
        // after days). Lower case only ("4H and 2B" are pencils), and a sprint ("100m 10s") isn't
        // a time. Read without "and", as the units are written.
        let part = #"(\d+)(d|hrs|hr|h|mins|min|m|secs|sec|s)"#
        rules.append(Rule(#"(?<![\p{L}\d.,:])"# + part + " ?" + part + "(?: ?" + part + #")?(?![\p{L}\d])"#) { m, s in
            let whole = s.substring(with: m.range)
            var parts: [(value: Int, unit: String)] = []
            for g in stride(from: 1, through: 5, by: 2) where m.range(at: g).location != NSNotFound {
                guard let value = Int(s.substring(with: m.range(at: g))) else { return whole }
                parts.append((value, s.substring(with: m.range(at: g + 1))))
            }
            let ranks = parts.map { durationUnits[$0.unit]!.rank }
            guard parts.contains(where: { $0.unit.count == 1 }), zip(ranks, ranks.dropFirst()).allSatisfy({ $0 < $1 }) else { return whole }
            for (i, p) in parts.enumerated() where i > 0 {
                guard p.value < (ranks[i] == 1 ? 24 : 60) else { return whole }
            }
            if ranks[0] == 2, ranks[1] == 3, parts[0].value >= 60 { return whole }
            return parts.map { p in
                let unit = durationUnits[p.unit]!.word
                return "\(p.value) " + (p.value == 1 ? unit : unit + "s")
            }.joined(separator: " ")
        })
        return rules
    }

    // MARK: Step 22: calendar dates, weekdays, ranges and centuries

    /// ISO dates, then day-first written dates, month-first day ranges, month ranges, weekday
    /// ranges and lists, weekdays before a date, time or ordinal, weekday abbreviations, am/pm
    /// time ranges, centuries and "Jan 2024": after the unit rules, before Ranges, clock,
    /// meridiem and fractions.
    static func calendarDates(british: Bool) -> [Rule] {
        var rules: [Rule] = []
        // ISO stamps: "2025-10-01T14:30:00Z" → "October 1st, 2025, at 14:30 UTC" (the clock rule
        // reads the time; seconds go, as people say a stamp). An offset after it is read too.
        rules.append(Rule.withContext(#"(?<![\p{L}\d\-–−./:])(\d{4})-(\d{2})-(\d{2})T([01]\d|2[0-3]):([0-5]\d)(?::[0-5]\d(?:\.\d+)?)?(Z|[+\-−](\d{2}):?(\d{2}))?(?![\p{L}\d])"#) { m, s, context in
            let whole = s.substring(with: m.range)
            guard let month = Int(s.substring(with: m.range(at: 2))), let day = Int(s.substring(with: m.range(at: 3))),
                  isDate(day: day, month: month) else { return whole }
            let afterThe = previousWord(context.text(before: m.range, in: s)).word.lowercased() == "the"
            var out = written(day: day, month: month, year: s.substring(with: m.range(at: 1)), british: british, afterThe: afterThe)
                + ", at " + s.substring(with: m.range(at: 4)) + ":" + s.substring(with: m.range(at: 5))
            if m.range(at: 6).location != NSNotFound {
                let zone = s.substring(with: m.range(at: 6))
                out += zone == "Z" ? " UTC" : " UTC " + offsetWords(sign: String(zone.prefix(1)), hours: s.substring(with: m.range(at: 7)),
                                                                   minutes: s.substring(with: m.range(at: 8)))
            }
            return out
        })
        // ISO dates: "2024-03-15" → "March 15th, 2024" (GB: "the 15th of March, 2024").
        rules.append(Rule.withContext(#"(?<![\p{L}\d\-–−./:])(\d{4})-(\d{2})-(\d{2})(?![\p{L}\d\-–]|[.,:/]\d)"#) { m, s, context in
            let year = s.substring(with: m.range(at: 1))
            guard let month = Int(s.substring(with: m.range(at: 2))), let day = Int(s.substring(with: m.range(at: 3))),
                  (1...12).contains(month), (1...31).contains(day) else { return s.substring(with: m.range) }
            let afterThe = previousWord(context.text(before: m.range, in: s)).word.lowercased() == "the"
            return written(day: day, month: month, year: year, british: british, afterThe: afterThe)
        })

        // Times written with a dot, as British text writes them: "at 18.30", "07.45 BST", "the
        // 2.30 at Kempton" → "18:30" for the clock rule. The shape is also a decimal, so only
        // where the sentence says it's a time: a time zone, "hrs" or "sharp" after it, a clock
        // word right before it ("checkout 11.00", "until 17.30"), or "at" or "from" with whole
        // minutes in fives ("at 10.30", not "trading at 1.27"; "rose to 1.30 today" stays). Never
        // before a unit, a price word or "per" ("at 2.50 a kilo").
        rules.append(Rule.withContext(#"(?<![\p{L}\d.,:$£€¥₹₩])([01]?\d|2[0-3])\.([0-5]\d)(?![\d%]|[.,]\d)"#) { m, s, context in
            let whole = s.substring(with: m.range)
            guard let minutes = Int(s.substring(with: m.range(at: 2))) else { return whole }
            let after = context.text(after: m.range, in: s, limit: 40)
            let before = context.text(before: m.range, in: s, limit: 60)
            let previous = previousWord(before).word.lowercased()
            var time = false
            switch follower(after) {
            case .word(let w):
                if timeZones.contains(w) || dottedTimeFollowers.contains(w.lowercased()) { time = true }
                if notTimeFollowers.contains(w.lowercased()) { return whole }
            case .end, .mark: break
            default: return whole
            }
            if !time { time = dottedTimeCues.contains(previous) }
            if !time, ["at", "from", "until", "till", "and", "to"].contains(previous) {
                time = minutes % 5 == 0 && (previous == "at" || previous == "from" || matches(clockBehind, before))
            }
            // A race card: "the 2.30 at Kempton".
            if !time, previous == "the", matches(raceAhead, after) { time = true }
            return time ? s.substring(with: m.range(at: 1)) + ":" + s.substring(with: m.range(at: 2)) : whole
        })
        // A 24-hour time with its leading zero: "at 0645", "0700 hrs", "Kickoff 0930 sharp" → "oh
        // 6 45", "oh 7 hundred". Read digit by digit it was "zero six four five"; "1030" and "1600
        // hrs" the number reader already reads. Only with a clock word before or after it, since
        // the shape is also a PIN, a code or a part number.
        rules.append(Rule.withContext(#"(?<![\p{L}\d.,:/\-$£€¥₹₩#])0(\d)([0-5]\d)(?![\d.,:/\-]|\.\d)"#) { m, s, context in
            let whole = s.substring(with: m.range)
            let previous = previousWord(context.text(before: m.range, in: s)).word.lowercased()
            var cued = militaryCues.contains(previous)
            if !cued, case .word(let w) = follower(context.text(after: m.range, in: s, limit: 40)) {
                cued = militaryFollowers.contains(w.lowercased()) || timeZones.contains(w)
            }
            guard cued else { return whole }
            let hour = s.substring(with: m.range(at: 1)), mm = s.substring(with: m.range(at: 2))
            return (hour == "0" ? "zero zero" : "oh " + hour) + (mm == "00" ? " hundred" : mm.hasPrefix("0") ? " oh " + mm.dropFirst() : " " + mm)
        })
        // "7:30a", "6:45p" → "7:30 AM", "6:45 PM"; a bare hour only after a clock word ("at 12p",
        // "Doors 7p / Show 8p", "moved to 3p"), since "50p" and "a 5p bag" are pence.
        rules.append(Rule.withContext(#"(?<![\p{L}\d.,:$£€¥₹₩])(\d{1,2})(:[0-5]\d)?([ap])(?![\p{L}\d'’])"#) { m, s, context in
            let whole = s.substring(with: m.range)
            guard let hour = Int(s.substring(with: m.range(at: 1))), (1...12).contains(hour) else { return whole }
            if m.range(at: 2).location == NSNotFound {
                let before = context.text(before: m.range, in: s)
                let previous = previousWord(before).word.lowercased()
                var cued = CalendarNames.clockCues.contains(previous)
                if !cued, previous == "to" {
                    let rest = before.reversed().drop { $0 == " " || $0 == "\t" }.drop { $0.isLetter }
                    cued = moveVerbs.contains(previousWord(String(rest.reversed())).word.lowercased())
                }
                guard cued else { return whole }
                if case .word(let w) = follower(context.text(after: m.range, in: s, limit: 40)), penceFollowers.contains(w.lowercased()) {
                    return whole
                }
            }
            let minutes = m.range(at: 2).location == NSNotFound ? "" : s.substring(with: m.range(at: 2))
            return "\(hour)\(minutes) " + (s.substring(with: m.range(at: 3)) == "a" ? "AM" : "PM")
        })
        // "noon–2", "10–noon", "1–1½ hours": a range with a word or a fraction at one end, which
        // the range rule doesn't read ("noon, two", "one, one and a half").
        rules.append(Rule(#"(?<![\p{L}\d])(noon|midnight)[ \t]?[-–][ \t]?(?=\d{1,2}(?![\d:]|[.,]\d))"#) { m, s in
            s.substring(with: m.range(at: 1)) + " to "
        })
        rules.append(Rule(#"(?<![\p{L}\d.,/:])(\d{1,2}(?::[0-5]\d)?)[ \t]?[-–][ \t]?(?=(?:noon|midnight)(?![\p{L}]))"#) { m, s in
            s.substring(with: m.range(at: 1)) + " to "
        })
        rules.append(Rule(#"(?<![\p{L}\d.,/])(\d+)[ \t]?[-–][ \t]?(?=\d+[ \t]?[½⅓⅔¼¾])"#) { m, s in
            s.substring(with: m.range(at: 1)) + " to "
        })
        // "Aug. 1-Sept. 8" → "Aug. 1 to Sept. 8": two written dates joined by a dash, before the
        // day rule reads each and the dash was lost.
        rules.append(Rule(#"(?<![\p{L}\-])((?:"# + monthPattern + #")\.?[ \t]\d{1,2}(?:st|nd|rd|th)?)[ \t]?[-–][ \t]?(?=(?:"# + monthPattern + #")\.?[ \t]\d{1,2}(?![\d:]))"#) { m, s in
            s.substring(with: m.range(at: 1)) + " to "
        })

        // Weekdays first, so the dates after them see the day's name ("Fri 12 Jan" → "Friday the
        // 12th of January").
        //
        // Ranges with a dash, in any case ("Mon–Fri", "MON-FRI", which unshout may have lowered),
        // and two full names ("Monday-Friday"): both sides must be days, so "Mon-Khmer" and
        // "Sun-Times" stay. "to" in both voices, as a sign says it.
        rules.append(Rule.withContext(#"(?<![\p{L}\-])("# + weekdayNames + "|" + weekdayAbbreviations + #")(\.)?[ \t]?[-–—][ \t]?("# + weekdayNames + "|" + weekdayAbbreviations + #")(\.)?(?![\p{L}\d\-])"#, options: .caseInsensitive) { m, s, context in
            let first = s.substring(with: m.range(at: 1)), second = s.substring(with: m.range(at: 3))
            let period = m.range(at: 4).location != NSNotFound ? FullStop.kept(before: context.text(after: m.range, in: s), next: .capitalNotTimeWord) : ""
            return weekdayName(first) + " to " + weekdayName(second) + period
        })
        // Ranges in words ("Mon to Sat", "Mon thru Fri"): Title case or capitals on both sides,
        // since "sat to sun" in lower case is a verb and a verb.
        let day = weekdayAbbreviations + "|" + weekdayCapitals
        rules.append(Rule.withContext(#"(?<![\p{L}\-])("# + day + #")(\.)? (to|through|thru) ("# + day + #")(\.)?(?![\p{L}\d\-])"#) { m, s, context in
            let word = s.substring(with: m.range(at: 3)) == "to" ? "to" : "through"
            let period = m.range(at: 5).location != NSNotFound ? FullStop.kept(before: context.text(after: m.range, in: s), next: .capitalNotTimeWord) : ""
            return weekdayName(s.substring(with: m.range(at: 1))) + " \(word) " + weekdayName(s.substring(with: m.range(at: 4))) + period
        })
        // Lists ("Mon, Wed, Fri", "Tue/Thu", "SAT & SUN"): every item a day, never in lower case
        // ("He sat, sun on his face"). The separators stay; a slash is already silent.
        rules.append(Rule.withContext(#"(?<![\p{L}\-])(?:"# + day + #")\.?(?:(?:, | & | and |/)(?:"# + day + #")\.?)+(?![\p{L}\d\-])"#) { m, s, context in
            let list = s.substring(with: m.range)
            let ns = list as NSString
            var out = "", last = 0
            for item in listItem.matches(in: list, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: item.range.location - last))
                out += weekdayName(ns.substring(with: item.range(at: 1)))
                last = NSMaxRange(item.range)
            }
            out += ns.substring(from: last)
            // Each item's period went with it; the last one's stays when it ends the sentence.
            guard list.hasSuffix(".") else { return out }
            return out + FullStop.kept(before: context.text(after: m.range, in: s), next: .capitalNotTimeWord)
        })
        // A day before a date or a time: "Mon, 4 Mar", "Sat, Mar 5", "Mon 9:30", "Tue 9am".
        rules.append(Rule.withContext(#"(?<![\p{L}\-])("# + day + #")\.?(,)?(?=[ \t](?:\d{1,2}(?:st|nd|rd|th)?[ \t](?:"# + monthPattern + #")(?![\p{L}])|(?:"# + monthPattern + #")\.?[ \t]\d{1,2}(?![\d:])|\d{1,2}:\d{2}(?!\d)|\d{1,2}[ \t]?[AaPp]\.?[ \t]?[Mm](?![\p{L}])))"#) { m, s, context in
            let token = s.substring(with: m.range(at: 1))
            guard isWeekday(token, after: context.text(before: m.range, in: s)) else { return s.substring(with: m.range) }
            return weekdayName(token) + (m.range(at: 2).location != NSNotFound ? "," : "")
        })
        // A day before a yearless D/D makes it a date ("Tue 3/5 at noon" → "Tuesday, March 5th",
        // GB "Tuesday, the 3rd of May"). A D/D that reads as a fraction too ("Early closing Wed
        // 1/2 day") needs a time, a time word or the end after it; any other is a date whatever
        // follows ("Thu 10/16 works", "Tue 10/14 in Rm 4B").
        rules.append(Rule.withContext(#"(?<![\p{L}\-])("# + weekdayNames + "|" + day + #")\.?(,)?[ \t](\d{1,2})/(\d{1,2})(?![\d/]|[.,]\d)"#) { m, s, context in
            let whole = s.substring(with: m.range)
            let token = s.substring(with: m.range(at: 1))
            guard let x = Int(s.substring(with: m.range(at: 3))), let y = Int(s.substring(with: m.range(at: 4))),
                  isWeekday(token, after: context.text(before: m.range, in: s)) else { return whole }
            let after = context.text(after: m.range, in: s, limit: 40)
            switch follower(after) {
            case .end, .mark: break
            case .word(let w) where shortDateFollowers.contains(w): break
            case .other where after.drop(while: { $0 == " " || $0 == "\t" }).first == "@": break
            case .digit where clockAhead.firstMatch(in: after, range: NSRange(location: 0, length: (after as NSString).length)) != nil: break
            default: if isFractionShaped(x, y) { return whole }
            }
            guard let (dayOfMonth, month) = dayAndMonth(x, y, british: british) else { return whole }
            return weekdayName(token) + ", " + written(day: dayOfMonth, month: month, year: nil, british: british, afterThe: false)
        })
        // A day before an ordinal takes "the": "Fri 13th" → "Friday the 13th", "Monday 5th at
        // noon". Not before a noun ("The Friday 2nd shift").
        rules.append(Rule.withContext(#"(?<![\p{L}\-])("# + weekdayNames + "|" + day + #")\.?,?[ \t](\d{1,2})(st|nd|rd|th)(?![\p{L}\d])"#) { m, s, context in
            let whole = s.substring(with: m.range)
            let token = s.substring(with: m.range(at: 1))
            guard let n = Int(s.substring(with: m.range(at: 2))), (1...31).contains(n),
                  isWeekday(token, after: context.text(before: m.range, in: s)) else { return whole }
            switch follower(context.text(after: m.range, in: s, limit: 40)) {
            case .end, .mark: break
            case .word(let w) where w == "at" || functionWords.contains(w) || isMonth(w): break
            default: return whole
            }
            return weekdayName(token) + " the \(n)" + s.substring(with: m.range(at: 3))
        })
        // Abbreviations that are never words: "Tues", "Thurs", "Fri" (and "tues", "thurs" in
        // chat). Not in capitals on their own ("The FRI score"), and not "Thur" (a river).
        rules.append(Rule.withContext(#"(?<![\p{L}\d\-])(Tues|Thurs|Fri|tues|thurs)(\.)?(?![\p{L}\d]|-\p{L})"#) { m, s, context in
            let period = m.range(at: 2).location != NSNotFound ? FullStop.kept(before: context.text(after: m.range, in: s), next: .capitalNotTimeWord) : ""
            return weekdayName(s.substring(with: m.range(at: 1))) + period
        })
        // The others are also words and names ("Sat", "Wed", "Sun", "Mon Dieu", "Nguyen Thu"):
        // a day only right after a time word ("on Wed", "every Sun", "next Thu") and before the
        // end, a time, or a word that goes with one ("on Wed at 9"). Not before a capital ("until
        // Sun Valley"), a hyphen ("this Sun-like star") or another word ("After Thu spoke").
        rules.append(Rule.withContext(#"(?<![\p{L}])((?i:on|by|until|till|til|from|every|next|last|this|before|after|since|each)) (Mon|Tue|Weds|Wed|Thur|Thu|Sat|Sun)(\.)?(?![\p{L}\d\-])"#) { m, s, context in
            let whole = s.substring(with: m.range)
            let timeWord = s.substring(with: m.range(at: 1)), token = s.substring(with: m.range(at: 2))
            if token == "Sun", !sunTimeWords.contains(timeWord.lowercased()) { return whole }
            let after = context.text(after: m.range, in: s, limit: 40)
            if m.range(at: 3).location != NSNotFound, FullStop.ends(before: after, next: .capitalNotTimeWord) {
                return timeWord + " " + weekdayName(token) + "."
            }
            switch follower(after) {
            case .end, .mark, .digit: break
            case .word(let w) where afterTimeWordFollowers.contains(w): break
            default: return whole
            }
            return timeWord + " " + weekdayName(token)
        })
        // "Thu", "Tue" and "Weds" aren't words either, only names ("Nguyen Thu", "Tue Nguyen"): a
        // day unless a name is next to it ("See you Thu!", "Thu works for me", "the Weds meeting").
        // With a period, the next rule reads them.
        rules.append(Rule.withContext(#"(?<![\p{L}\d\-])(Thu|Tue|Weds)(?![\p{L}\d.]|-\p{L})"#) { m, s, context in
            let whole = s.substring(with: m.range)
            let (word, opens) = previousWord(context.text(before: m.range, in: s))
            // After a name ("Nguyen Thu works here"), even one opening the sentence.
            if word.first?.isUppercase == true, !opens || !sentenceStarters.contains(word) { return whole }
            // After a time word the rule above has decided ("After Thu spoke" is a name).
            if dayTimeWords.contains(word.lowercased()) { return whole }
            if case .word(let w) = follower(context.text(after: m.range, in: s, limit: 40)), w.first?.isUppercase == true,
               !CalendarNames.timeWords.contains(w) { return whole }
            return weekdayName(s.substring(with: m.range(at: 1)))
        })
        // With its period a short day is a day, wherever it stands ("scheduled for Wed., was
        // delayed", "Sat. night is the gala", "The Mon. sync"): none of the words takes one
        // mid-sentence. Not after a name ("Nguyen Thu."), and "Sun." only after punctuation or a
        // time word ("1:15 a.m. Sun. after"), never "the Sun." or "a hot Sun.". The period stays
        // when it also ends the sentence.
        rules.append(Rule.withContext(#"(?<![\p{L}\d\-])(Mon|Tue|Wed|Thu|Thur|Sat|Sun)\.(?![\p{L}\d])"#) { m, s, context in
            let whole = s.substring(with: m.range)
            let token = s.substring(with: m.range(at: 1))
            let (word, opens) = previousWord(context.text(before: m.range, in: s))
            if word.first?.isUppercase == true, !opens { return whole }
            if token == "Sun", !word.isEmpty, !sunTimeWords.contains(word.lowercased()) { return whole }
            // After "the" or "a" only before the noun it names ("The Mon. sync", "on a Mon. this
            // year"): "along the Thur." is the river.
            let after = context.text(after: m.range, in: s)
            if ["the", "a"].contains(word.lowercased()) {
                guard token != "Thur", case .word(let w) = follower(after), w.first?.isLowercase == true else { return whole }
            }
            return weekdayName(token) + FullStop.kept(before: after, next: .capitalNotTimeWord)
        })
        // Without a period "Mon", "Wed", "Sat" and "Sun" are also words and names ("Sat down",
        // "Wed in June", "the Sun is out"), so a day only where nothing else fits: in Title case,
        // not after "the", "a" or a name, and before the end, a number or a word that goes with a
        // day ("See you Sat!", "Two tix for Sat night", "Mon was rough", "back Mon the 27th").
        // "Sun" needs punctuation or a time word before it as well ("Sat 9-1, Sun closed").
        rules.append(Rule.withContext(#"(?<![\p{L}\d\-])(Mon|Wed|Sat|Sun)(?![\p{L}\d.'’]|-\p{L})"#) { m, s, context in
            let whole = s.substring(with: m.range)
            let token = s.substring(with: m.range(at: 1))
            let (word, opens) = previousWord(context.text(before: m.range, in: s))
            if ["the", "a", "an"].contains(word.lowercased()) || (word.first?.isUppercase == true && !opens) { return whole }
            let after = context.text(after: m.range, in: s, limit: 40)
            if token == "Sun" {
                guard word.isEmpty || sunTimeWords.contains(word.lowercased()) else { return whole }
                switch follower(after) {
                case .digit: break
                case .word(let w) where sunFollowers.contains(w): break
                default: return whole
                }
                return weekdayName(token)
            }
            switch follower(after) {
            case .end, .mark: break
            // A time or opening hours after it ("Sat 9-1", "Mon 10am"), not a count ("Sat 3
            // exams") or a fraction ("Wed 1/2 day").
            case .digit where matches(hoursAhead, after): break
            case .word(let w) where dayFollowers.contains(w): break
            case .word("the") where matches(ordinalAhead, after): break
            default: return whole
            }
            return weekdayName(token)
        })
        // Days as single letters: "M/W/F" → "Monday, Wednesday and Friday", "T/Th"; "M–F 9–5" →
        // "Monday to Friday". In week order only, and a pair of single letters ("M/F", "W/L") is
        // something else; a dash range needs a time after it or a word for opening hours before.
        rules.append(Rule.withContext(#"(?<![\p{L}\d/\-–])(Th|Tu|Sa|Su|[MTWFS])(?:/(Th|Tu|Sa|Su|[MTWFS])){1,6}(?![\p{L}\d/])"#) { m, s, context in
            let whole = s.substring(with: m.range)
            let letters = whole.split(separator: "/").map(String.init)
            let days = letters.compactMap { dayLetters[$0] }
            guard days.count == letters.count, zip(days, days.dropFirst()).allSatisfy({ $0.0 < $0.1 }),
                  days.count >= 3 || letters.contains(where: { $0.count == 2 }) else { return whole }
            let names = days.map { CalendarNames.weekdaysInOrder[$0] }
            return names.dropLast().joined(separator: ", ") + " and " + names.last!
        })
        rules.append(Rule.withContext(#"(?<![\p{L}\d/\-–])(Th|Tu|Sa|Su|[MTWFS])[ \t]?[-–][ \t]?(Th|Tu|Sa|Su|[MTWFS])(?![\p{L}\d/\-–])"#) { m, s, context in
            let whole = s.substring(with: m.range)
            guard let first = dayLetters[s.substring(with: m.range(at: 1))], let last = dayLetters[s.substring(with: m.range(at: 2))],
                  first < last else { return whole }
            let previous = previousWord(context.text(before: m.range, in: s)).word.lowercased()
            if case .digit = follower(context.text(after: m.range, in: s, limit: 40)) {} else if !openingWords.contains(previous) { return whole }
            return CalendarNames.weekdaysInOrder[first] + " to " + CalendarNames.weekdaysInOrder[last]
        })

        // Day-first written dates: "5 March", "5th March 2024", "1 Dec.", "5–7 March" → "the 5th
        // of March, 2024", "the 5th to the 7th of March". Both voices. A year, punctuation, the
        // end, a small word or an abbreviation's period must follow, so a count before a
        // month-named noun stays ("We ran 3 March events", "5 May Day posters"), and so does a
        // number after a numeral noun ("Track 4 March to the Scaffold"). When the month's period
        // is also the full stop ("1 Dec."), the sentence keeps it.
        rules.append(Rule.withContext(#"(?<![\p{L}\d.,:/$£€¥₹₩])(\d{1,2})(st|nd|rd|th)?(?:[-–](\d{1,2})(st|nd|rd|th)?)?[ \t]("# + monthPattern + #")(\.)?(?![\p{L}\d\-])(?:,?[ \t]((?:1\d|20)\d\d(?![\d\p{L}])|\d{3,4}(?=[ \t]?(?:BC|BCE|AD|CE)(?![\p{L}]))))?"#) { m, s, context in
            let whole = s.substring(with: m.range)
            guard let first = Int(s.substring(with: m.range(at: 1))), let month = monthNumber(s.substring(with: m.range(at: 5))) else { return whole }
            let last = m.range(at: 3).location == NSNotFound ? nil : Int(s.substring(with: m.range(at: 3)))
            guard isDate(day: first, month: month), last.map({ $0 > first && isDate(day: $0, month: month) }) ?? true else { return whole }
            let previous = previousWord(context.text(before: m.range, in: s)).word
            if numeralNouns.contains(previous.lowercased()) { return whole }
            let after = context.text(after: m.range, in: s, limit: 40)
            let hasYear = m.range(at: 7).location != NSNotFound
            var period = ""
            if !hasYear {
                if m.range(at: 6).location != NSNotFound {
                    // An abbreviation's period: a month, not a noun ("1 Dec. Tuesday is free").
                    period = FullStop.kept(before: after, next: .capitalNotTimeWord)
                } else {
                    switch follower(after) {
                    case .end, .mark: break
                    case .word(let w) where functionWords.contains(w): break
                    // A dash and another date: "Mon 13 Oct – Fri 17 Oct".
                    case .other where matches(dateDashAhead, after): break
                    default: return whole
                    }
                }
            }
            var out = (previous.lowercased() == "the" ? "" : "the ") + "\(first)\(ordinalSuffix(first))"
            if let last { out += " to the \(last)\(ordinalSuffix(last))" }
            out += " of " + CalendarNames.monthsInOrder[month - 1]
            if hasYear { out += ", " + spokenYear(s.substring(with: m.range(at: 7))) }
            return out + period
        })
        // Month-first day ranges: "March 5–7" → "March 5th to 7th" (GB "March the 5th to the
        // 7th"). Going down it's a score ("May 3-1"), left to Ranges.
        rules.append(Rule.withContext(#"(?<![\p{L}\-])("# + monthPattern + #")\.?[ \t](\d{1,2})(?:st|nd|rd|th)?[-–](\d{1,2})(?:st|nd|rd|th)?(?![\d:\p{L}])"#) { m, s, context in
            let whole = s.substring(with: m.range)
            guard let month = monthNumber(s.substring(with: m.range(at: 1))),
                  let first = Int(s.substring(with: m.range(at: 2))), let last = Int(s.substring(with: m.range(at: 3))),
                  last > first, isDate(day: first, month: month), isDate(day: last, month: month) else { return whole }
            let name = CalendarNames.monthsInOrder[month - 1]
            let the = british && !isAttributive(context.text(before: m.range, in: s)) ? "the " : ""
            return "\(name) \(the)\(first)\(ordinalSuffix(first)) to \(the)\(last)\(ordinalSuffix(last))"
        })
        // Month ranges: "Jan–Mar" → "January to March", "May-June". Both sides must be months
        // ("Mar-a-Lago", "Jun-ho", "May-Britt"), and "a May-December romance" is an idiom.
        rules.append(Rule.withContext(#"(?<![\p{L}\-])("# + monthPattern + #")\.?[ \t]?[-–—][ \t]?("# + monthPattern + #")(\.)?(?![\p{L}\d\-])"#) { m, s, context in
            let after = context.text(after: m.range, in: s, limit: 40)
            if case .word(let w) = follower(after), monthIdioms.contains(w.lowercased()) { return s.substring(with: m.range) }
            guard let first = monthNumber(s.substring(with: m.range(at: 1))), let second = monthNumber(s.substring(with: m.range(at: 2))) else {
                return s.substring(with: m.range)
            }
            let period = m.range(at: 3).location != NSNotFound ? FullStop.kept(before: after, next: .capitalNotTimeWord) : ""
            return CalendarNames.monthsInOrder[first - 1] + " to " + CalendarNames.monthsInOrder[second - 1] + period
        })
        // Time ranges with am/pm: "9am–5pm" → "9am to 5pm", "10-4pm" → "10 to 4pm" (the dash was
        // a pause); the meridiem rule reads the rest.
        rules.append(Rule(#"(?<![\d:.,])(\d{1,2})(:[0-5]\d)?([ \t]?[AaPp]\.?[ \t]?[Mm]\.?)?[ \t]?[-–][ \t]?(\d{1,2})(:[0-5]\d)?(?=[ \t]?[AaPp](?:\.[ \t]?[Mm]\.?|[Mm])(?![\p{L}]))"#) { m, s in
            func group(_ i: Int) -> String { m.range(at: i).location == NSNotFound ? "" : s.substring(with: m.range(at: i)) }
            guard let from = Int(group(1)), let to = Int(group(4)), (1...12).contains(from), (1...12).contains(to) else {
                return s.substring(with: m.range)
            }
            return group(1) + group(2) + group(3) + " to " + group(4) + group(5)
        })
        // Centuries: "18th c." → "18th century", "19th cent.", "18th-c." → "18th-century". A
        // capital "C." only after "the" ("the 17th C."): "5th C" is also a class section.
        rules.append(Rule.withContext(#"(?<![\p{L}\d])(\d{1,2})(st|nd|rd|th)([ \-]?)(c|cent|C)\.(?![\p{L}\d])"#) { m, s, context in
            let whole = s.substring(with: m.range)
            guard let n = Int(s.substring(with: m.range(at: 1))), (1...21).contains(n) else { return whole }
            if s.substring(with: m.range(at: 4)) == "C", previousWord(context.text(before: m.range, in: s)).word.lowercased() != "the" { return whole }
            let joiner = s.substring(with: m.range(at: 3)) == "-" ? "-" : " "
            return "\(n)" + s.substring(with: m.range(at: 2)) + joiner + "century"
                + FullStop.kept(before: context.text(after: m.range, in: s), next: .capitalNotTimeWord)
        })
        // An abbreviated month before a year: "Jan 2024" → "January 2024" (it was "jan").
        rules.append(Rule(#"(?<![\p{L}\-])(Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sept|Sep|Oct|Nov|Dec)\.?[ \t]((?:1\d|20)\d\d)(?![\d\p{L}])"#) { m, s in
            (CalendarNames.months[s.substring(with: m.range(at: 1)).lowercased()] ?? s.substring(with: m.range(at: 1))) + " " + s.substring(with: m.range(at: 2))
        })
        return rules
    }

    // MARK: Step 23: "Jan 5" and "Feb."

    /// "Jan 5" and "Feb.": after the clock, ratio and "5pm" rules, before the fractions.
    static func monthDays(british: Bool) -> [Rule] {
        var rules: [Rule] = []
        // "Jan 5" / "January 5, 2024" → "January 5th"; GB "January the 5th" (also "March 5th" →
        // "March the 5th") where the date stands on its own: before a year, punctuation, the end
        // or a small word, or after a weekday. Not before a noun ("the March 15 deadline"). A
        // count or a score after a month stays a number: "In March 2 people left", "in May 3-1"
        // (Ranges made it "3 to 1"), "May 2 of us join?".
        let monthNames = "Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sept|Sep|Oct|Nov|Dec|January|February|March|April|June|July|August|September|October|November|December"
        rules.append(Rule.withContext(#"\b("# + monthNames + #")\.?\s+(\d{1,2})(st|nd|rd|th)?(?![\d:])\b"#) { m, s, context in
            let whole = s.substring(with: m.range)
            let ordinal = m.range(at: 3).location != NSNotFound
            if ordinal && !british { return whole }
            let name = s.substring(with: m.range(at: 1))
            let month = CalendarNames.months[name.lowercased()] ?? name
            let day = Int(s.substring(with: m.range(at: 2))) ?? 0
            let before = context.text(before: m.range, in: s)
            let after = context.text(after: m.range, in: s, limit: 40)
            if !ordinal {
                let range = NSRange(location: 0, length: (after as NSString).length)
                let previous = previousWord(before).word
                if previous == "in" || previous == "In", yearAhead.firstMatch(in: after, range: range) == nil { return whole }
                if countAhead.firstMatch(in: after, range: range) != nil { return whole }
                if let score = scoreAhead.firstMatch(in: after, range: range),
                   let other = Int((after as NSString).substring(with: score.range(at: 1))), other < day { return whole }
                // A month that is also a name or a verb, before a count of something: "Give Jan 10
                // minutes", "May 3 people join?", "Thousands March 3 Miles". Not after a word that
                // goes with a date ("on March 3 voters…", "the June 5 primaries").
                if countingMonths.contains(name), case .word(let w) = follower(after), isPluralNoun(w.lowercased()),
                   !monthCountGuards.contains(previous.lowercased()) { return whole }
            }
            let suffix = ordinal ? s.substring(with: m.range(at: 3)) : ordinalSuffix(day)
            guard british else { return "\(month) \(day)\(suffix)" }
            if standsAlone(before: before, after: after) { return "\(month) the \(day)\(suffix)" }
            return ordinal ? whole : "\(month) \(day)\(suffix)"
        })
        // "Feb." on its own → "February", keeping the period when it also ends the sentence
        // ("…is due 24 Dec." lost its final fall).
        rules.append(Rule.withContext(#"\b(Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sept|Sep|Oct|Nov|Dec)\.(?=\s|$)"#) { m, s, context in
            let name = s.substring(with: m.range(at: 1))
            return (CalendarNames.months[name.lowercased()] ?? name)
                + FullStop.kept(before: context.text(after: m.range, in: s), next: .capitalNotTimeWord)
        })
        // "Sept" without its period is never a word: "in Sept, the highest…".
        rules.append(Rule(#"(?<![\p{L}\-])Sept(?![\p{L}\d.\-])"#) { _, _ in "September" })
        // A dash between two dates, as the rules above wrote them, is "to": "the 13th of October –
        // Friday the 17th of October", "Friday, December 5th – Sunday, December 7th, 2025".
        rules.append(Rule(#"(?<=\d(?:st|nd|rd|th)|of[ \t](?:"# + CalendarNames.monthsInOrder.joined(separator: "|") + #")|\b(?:1\d|20)\d\d)[ \t]*[-–—][ \t]*(?=(?:"#
                          + weekdayNames + "|" + CalendarNames.monthsInOrder.joined(separator: "|") + #")(?![\p{L}])|the[ \t]\d)"#) { _, _ in " to " })
        return rules
    }

    // MARK: Helpers

    private static let monthPattern = "January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sept|Sep|Oct|Nov|Dec"
    private static let weekdayNames = "Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday"
    private static let weekdayAbbreviations = "Mon|Tues|Tue|Weds|Wed|Thurs|Thur|Thu|Fri|Sat|Sun"
    private static let weekdayCapitals = "MON|TUES|TUE|WEDS|WED|THURS|THUR|THU|FRI|SAT|SUN"
    private static let weekdays = ["mon": "Monday", "tue": "Tuesday", "tues": "Tuesday", "wed": "Wednesday", "weds": "Wednesday",
                                   "thu": "Thursday", "thur": "Thursday", "thurs": "Thursday", "fri": "Friday", "sat": "Saturday", "sun": "Sunday"]
    private static let fullWeekdays = Set(weekdayNames.split(separator: "|").map(String.init))
    private static let listItem = try! NSRegularExpression(pattern: "(" + weekdayAbbreviations + "|" + weekdayCapitals + #")\.?"#)

    /// The full name of a weekday or its abbreviation, in any case: "MON" → "Monday".
    private static func weekdayName(_ token: String) -> String {
        let key = token.lowercased()
        return weekdays[key] ?? key.prefix(1).uppercased() + key.dropFirst()
    }

    /// Whether a weekday abbreviation is the day here. "Sun" is also the star, a paper and a
    /// company ("The Sun", "the Toronto Sun"); "Mon", "Wed", "Thu" and "Sat" are also names and
    /// words ("Nguyen Thu", "Mon Dieu") after "the" or a name; in capitals "SAT" and "SUN" are
    /// an exam and a paper outside a range or list. Full names are always days.
    private static func isWeekday(_ token: String, after before: String) -> Bool {
        let key = token.lowercased()
        guard weekdays[key] != nil else { return true }
        if token == token.uppercased(), key == "sat" || key == "sun" { return false }
        let (word, opens) = previousWord(before)
        let capital = word.first?.isUppercase == true
        switch key {
        case "sun": return word.lowercased() != "the" && !capital
        case "mon", "wed", "weds", "thu", "thur", "sat": return word.lowercased() != "the" && !(capital && !opens)
        default: return true
        }
    }

    private static func isMonth(_ word: String) -> Bool { monthNumber(word) != nil }

    /// 1 to 12 for a month's name or abbreviation, as written ("March", "Sept").
    private static func monthNumber(_ name: String) -> Int? {
        if let i = CalendarNames.monthsInOrder.firstIndex(of: name) { return i + 1 }
        guard name.first?.isUppercase == true, let full = CalendarNames.months[name.lowercased()] else { return nil }
        return CalendarNames.monthsInOrder.firstIndex(of: full).map { $0 + 1 }
    }

    private static let monthLengths = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

    private static func isDate(day: Int, month: Int) -> Bool {
        (1...12).contains(month) && (1...monthLengths[month - 1]).contains(day)
    }

    /// The day and month of a numeric date "a/b": a part over 12 is the day, and when both could
    /// be the month the voice decides (US month first, GB day first). Nil when it can't be a date.
    private static func dayAndMonth(_ a: Int, _ b: Int, british: Bool) -> (Int, Int)? {
        let pair: (Int, Int)
        if (13...31).contains(a), (1...12).contains(b) {
            pair = (a, b)
        } else if (13...31).contains(b), (1...12).contains(a) {
            pair = (b, a)
        } else if (1...12).contains(a), (1...12).contains(b) {
            pair = british ? (a, b) : (b, a)
        } else {
            return nil
        }
        return isDate(day: pair.0, month: pair.1) ? pair : nil
    }

    /// A date as each voice says it: "March 4th, 2024" (US), "the 4th of March, 2024" (GB),
    /// without a second "the" after one already in the text.
    private static func written(day: Int, month: Int, year: String?, british: Bool, afterThe: Bool) -> String {
        let name = CalendarNames.monthsInOrder[month - 1]
        let tail = year.map { ", " + $0 } ?? ""
        if british { return (afterThe ? "" : "the ") + "\(day)\(ordinalSuffix(day)) of \(name)" + tail }
        return "\(name) \(day)\(ordinalSuffix(day))" + tail
    }

    /// A year as written, but a three-digit one ("753 BC") as people say it: "7 53", "7 oh 5".
    private static func spokenYear(_ year: String) -> String {
        guard year.count == 3, !year.hasSuffix("00") else { return year }
        let d = Array(year)
        return d[1] == "0" ? "\(d[0]) oh \(d[2])" : "\(d[0]) \(d[1])\(d[2])"
    }

    private static func ordinalSuffix(_ day: Int) -> String {
        (11...13).contains(day % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][day % 10] ?? "th"
    }

    /// The word just before a match (letters and apostrophes, past spaces and `skipping`), and
    /// whether it opens its sentence (nothing, or an end mark or a colon, before it).
    private static func previousWord(_ text: String, skipping: Set<Character> = []) -> (word: String, opens: Bool) {
        var end = text.endIndex
        while end > text.startIndex {
            let c = text[text.index(before: end)]
            guard c == " " || c == "\t" || skipping.contains(c) else { break }
            end = text.index(before: end)
        }
        var start = end
        while start > text.startIndex {
            let c = text[text.index(before: start)]
            guard c.isLetter || c == "'" || c == "’" else { break }
            start = text.index(before: start)
        }
        var k = start
        while k > text.startIndex, " \t\"“‘([".contains(text[text.index(before: k)]) { k = text.index(before: k) }
        let opens = k == text.startIndex || ".!?:…\n\r".contains(text[text.index(before: k)])
        return (String(text[start..<end]), opens)
    }

    /// What comes after a match, past spaces and tabs.
    private enum Follower {
        /// The end of the text or of a line.
        case end
        /// Punctuation that closes a phrase: , ; : ! ? ) . … or a closing quote.
        case mark
        case digit
        case word(String)
        case other
    }

    private static let closers: Set<Character> = [",", ";", ":", "!", "?", ")", "]", ".", "…", "\"", "”", "’"]

    private static func follower(_ rest: String) -> Follower {
        var i = rest.startIndex
        while i < rest.endIndex, rest[i] == " " || rest[i] == "\t" { i = rest.index(after: i) }
        guard i < rest.endIndex else { return .end }
        let c = rest[i]
        if c.isNewline { return .end }
        if c.isNumber { return .digit }
        if closers.contains(c) { return .mark }
        guard c.isLetter else { return .other }
        var e = i
        while e < rest.endIndex, rest[e].isLetter || rest[e] == "'" || rest[e] == "’" { e = rest.index(after: e) }
        return .word(String(rest[i..<e]))
    }

    /// Small words that can follow a date standing on its own ("on 5 March the board met"), but
    /// not a count before a noun ("3 March events"). "I" counts too.
    private static let functionWords: Set<String> = [
        "the", "at", "in", "on", "to", "until", "till", "from", "and", "or", "through", "when", "with", "for", "by", "but", "as",
        "is", "was", "will", "we", "it", "this", "that", "he", "she", "they", "I",
    ]
    /// Words after which a two-digit year can end a numeric date ("Paid on 3/4/24").
    private static let dateWords: Set<String> = [
        "on", "by", "until", "till", "from", "since", "before", "after", "due", "dated", "date", "born", "died", "expires", "expiry",
        "exp", "expired", "signed", "issued", "effective", "valid", "through", "thru", "starting", "ending", "paid", "posted",
        "updated", "shipped", "delivered",
    ]
    /// Words before a dotted number that make it a version ("version 2.1.2024").
    private static let versionWords: Set<String> = ["version", "ver", "v", "build", "release", "firmware", "update", "patch", "rev", "revision", "kernel", "driver"]
    /// Words after a numeric shape that make it a count or a list of sizes ("2/4/12 months").
    private static let countWords: Set<String> = ["days", "weeks", "months", "years", "hours", "minutes", "seconds", "mins", "hrs", "sizes", "mm", "cm", "inches", "times", "points"]
    /// Nouns before a number that make it a label, not a day ("Track 4 March to the Scaffold").
    /// The Roman pass keeps its own list.
    private static let numeralNouns: Set<String> = ["track", "chapter", "part", "section", "page", "room", "item", "step", "episode", "platform", "gate"]
    private static let monthIdioms: Set<String> = ["romance", "relationship", "marriage", "couple", "affair"]
    /// Months that are also names or verbs ("Jan", "May", "March"), so a number after them may
    /// count something.
    private static let countingMonths: Set<String> = ["Jan", "April", "May", "June", "March"]
    /// Words before such a month that make it a date even before a plural ("on March 3 voters
    /// went", "the June 5 primaries").
    private static let monthCountGuards: Set<String> = [
        "on", "by", "until", "till", "from", "since", "before", "after", "through", "of", "the", "this", "last", "next", "every",
        "each", "early", "late", "mid", "starting", "ending", "due", "dated", "effective", "in",
    ]
    /// Plural nouns that don't end in "s".
    private static let irregularPlurals: Set<String> = ["people", "children", "men", "women", "feet", "teeth", "mice", "geese", "staff", "folks"]
    /// Words that end in "s" without being a plural noun.
    private static let notPlurals: Set<String> = [
        "is", "was", "has", "does", "this", "its", "his", "hers", "ours", "yours", "theirs", "always", "sometimes",
        "perhaps", "towards", "besides", "plus", "minus", "less", "unless", "thus", "us", "yes", "as", "news", "whereas",
        "afterwards", "nevertheless", "across", "ago",
    ]

    /// Whether `word` (lower case) is a plural noun as far as its letters tell: "minutes",
    /// "slides", "people"; not "is", "this" or "across".
    private static func isPluralNoun(_ word: String) -> Bool {
        if irregularPlurals.contains(word) { return true }
        guard word.count >= 3, word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"), !word.hasSuffix("is"),
              !word.hasSuffix("'s"), !word.hasSuffix("’s") else { return false }
        return !notPlurals.contains(word)
    }

    /// Words after a dotted number that make it a time ("07.45 BST", "at 10.30 tomorrow").
    private static let dottedTimeFollowers: Set<String> = ["hrs", "hours", "h", "sharp", "local", "onwards", "onward"]
    /// Words after a dotted number that make it a number, whatever came before ("at 2.50 a kilo").
    private static let notTimeFollowers: Set<String> = [
        "per", "a", "an", "each", "percent", "points", "pts", "times", "x", "euros", "dollars", "pounds", "pence", "kg", "kilo",
        "kilos", "km", "m", "miles", "metres", "meters", "seconds", "secs", "litres", "liters", "goals", "runs", "inches", "cm",
        "mm", "ft", "lb", "lbs", "oz", "grams", "g", "million", "billion", "thousand", "against", "versus", "vs",
    ]
    /// Words right before a dotted number that make it a time ("checkout 11.00", "Doors 19.30").
    private static let dottedTimeCues: Set<String> = [
        "checkout", "doors", "departs", "departure", "depart", "departing", "arrives", "arrival", "arrive", "arriving", "kickoff",
        "curfew", "opens", "closes", "leaves", "starts", "begins", "ends", "until", "till", "before", "after",
    ]
    /// A time just before "and" or "to": "from 9.30 to 10.30", "between 9:30 and 10.30".
    private static let clockBehind = try! NSRegularExpression(pattern: #"\d{1,2}[.:][0-5]\d[ \t]+(?:to|and|until|till)[ \t]*$"#)
    /// "at" and a place after a race's time: "the 2.30 at Kempton".
    private static let raceAhead = try! NSRegularExpression(pattern: #"^[ \t]+at[ \t]+\p{Lu}"#)
    /// Words before a 24-hour "0645" that make it a time.
    private static let militaryCues: Set<String> = [
        "at", "by", "until", "till", "from", "before", "after", "departs", "departed", "departing", "departure", "arrives",
        "arrived", "arriving", "arrival", "landed", "lands", "leaves", "kickoff", "reveille", "takeoff", "eta", "etd",
    ]
    /// Words after a 24-hour "0645" that make it a time ("0700 hrs", "0930 sharp").
    private static let militaryFollowers: Set<String> = ["hrs", "hours", "hr", "h", "local", "sharp", "zulu"]
    /// Words after "12p" that make it pence, even after a clock word ("at 5p each").
    private static let penceFollowers: Set<String> = [
        "each", "per", "a", "an", "off", "coin", "coins", "piece", "pieces", "bag", "bags", "charge", "more", "less", "cheaper",
        "extra", "rise", "fall", "increase", "cut", "stamp", "stamps", "tax", "levy",
    ]

    /// A time zone's offset as said: "minus 8", "plus 5 30" (UTC−08:00, +05:30).
    private static func offsetWords(sign: String, hours: String, minutes: String?) -> String {
        let h = Int(hours).map(String.init) ?? hours
        let mm = minutes.flatMap { $0 == "00" || $0.isEmpty ? nil : $0 }
        return (sign == "+" ? "plus " : "minus ") + h + (mm.map { " " + $0 } ?? "")
    }

    /// Words before "3d" that make it days ("Out 3d", "older than 30d", "every 2d").
    private static let dayCountCues: Set<String> = [
        "out", "off", "for", "every", "last", "past", "within", "over", "than", "after", "about", "around", "only", "just",
        "first", "next", "another",
    ]
    /// Words after "3d" that make it days ("3d next week", "2d left").
    private static let dayCountFollowers: Set<String> = ["next", "left", "later", "remaining", "early", "late", "old", "notice", "ago", "streak", "trial", "window", "off"]
    /// Words after "3d" that make it a dimension, whatever came before ("in 3d printing").
    private static let dimensionNouns: Set<String> = [
        "printing", "printer", "printers", "printed", "print", "prints", "model", "models", "modeling", "modelling", "glasses",
        "movie", "movies", "film", "films", "effect", "effects", "graphics", "scan", "scanner", "scans", "view", "space", "render",
        "rendering", "art", "animation", "game", "games", "shape", "shapes", "object", "objects", "image", "images", "plot",
        "array", "arrays", "vector", "matrix", "grid", "world", "design", "designs", "geometry", "audio", "sound", "puzzle",
    ]

    /// Single-letter days, Monday first: "M/W/F", "T/Th", "M–F".
    private static let dayLetters: [String: Int] = ["M": 0, "T": 1, "Tu": 1, "W": 2, "Th": 3, "F": 4, "S": 5, "Sa": 5, "Su": 6]
    /// Words before a dash between two day letters that make it opening hours ("Open M–F").
    private static let openingWords: Set<String> = ["open", "opens", "hours", "closed", "available", "daily", "weekdays", "staffed", "from"]
    /// Words after "Mon", "Wed" or "Sat" with no period that make it the day.
    private static let dayFollowers: Set<String> = [
        "night", "morning", "afternoon", "evening", "at", "and", "or", "to", "through", "thru", "is", "was", "works", "will",
        "would", "closed", "open", "only", "off", "too", "again", "then", "instead", "from", "until", "till", "before", "after",
    ]
    /// Words after "Sun" that make it the day ("Sat 9-1, Sun closed").
    private static let sunFollowers: Set<String> = [
        "closed", "open", "only", "off", "night", "morning", "afternoon", "evening", "at", "and", "to", "through", "thru",
    ]
    /// A time or opening hours after a day: "9-1", "10:30", "10am", "9 a.m.", "9." at the end.
    private static let hoursAhead = try! NSRegularExpression(pattern: #"^[ \t]+\d{1,2}(?:[:\-–][ \t]?\d|[ \t]?[AaPp]\.?[ \t]?[Mm](?![\p{L}])|[ \t]*(?:$|[,;)!?]|\.(?!\d)))"#)
    private static let sentenceStarters = Set(Tokenizer.sentenceStarters)
    /// The time words the rule for "on Wed" reads after.
    private static let dayTimeWords: Set<String> = ["on", "by", "until", "till", "til", "from", "every", "next", "last", "this", "before", "after", "since", "each"]
    /// "the 27th" after a day: "back Mon the 27th".
    private static let ordinalAhead = try! NSRegularExpression(pattern: #"^[ \t]+the[ \t]+\d{1,2}(?:st|nd|rd|th)(?![\p{L}\d])"#)
    /// Words before a D/D with no year that make it a date ("on 10/31", "due 10/24", "closed
    /// 12/24", "Leaving 6/15, back 6/22").
    private static let slashDateCues: Set<String> = [
        "on", "by", "until", "till", "til", "through", "thru", "from", "since", "before", "after", "due", "dated", "starting",
        "ending", "effective", "expires", "expiring", "valid", "closed", "leaving", "back", "returning", "posted", "updated",
        "shipped", "delivered", "born", "died", "deadline",
    ]
    /// Slashed numbers that name something: "on 9/11" is the attacks, not September 11th.
    private static let namedSlashes: Set<String> = ["9/11", "7/7", "24/7", "50/50"]
    /// Verbs before "to" or "for" that make a D/D after them a date ("Moved to 3/8").
    private static let moveVerbs: Set<String> = ["moved", "move", "pushed", "push", "postponed", "rescheduled", "delayed", "changed", "bumped", "brought"]
    /// A date noun and a verb right before a D/D: "The deadline was 10/31", "Last day is 31/12".
    private static let dateNounBehind = try! NSRegularExpression(pattern: #"(?i)(?<![\p{L}])(?:day|date|deadline|birthday|anniversary)[ \t]+(?:is|was|will[ \t]+be|falls[ \t]+on)[ \t]*$"#)
    /// Words after a D/D that make it a fraction of something: "1/2 cup", "3/4 in", "1/3 of".
    private static let fractionMeasures: Set<String> = [
        "of", "cup", "cups", "c", "tsp", "tbsp", "teaspoon", "teaspoons", "tablespoon", "tablespoons", "oz", "ounce", "ounces",
        "lb", "lbs", "pound", "pounds", "inch", "inches", "in", "ft", "foot", "feet", "mile", "miles", "mi", "gallon",
        "gallons", "pint", "pints", "quart", "quarts", "liter", "liters", "litre", "litres", "kg", "g", "mm", "cm", "m", "km",
        "yard", "yards", "acre", "acres", "hour", "hours", "stick", "sticks", "share", "shares", "point", "points",
    ]

    /// Whether n/d reads as a fraction as easily as a date: halves, thirds and quarters, and odd
    /// eighths and sixteenths ("Wed 1/2 day", "3/8 inch"). "10/16" is no one's fraction.
    private static func isFractionShaped(_ n: Int, _ d: Int) -> Bool {
        n < d && ([2, 3, 4].contains(d) || [8, 16, 32, 64].contains(d) && n % 2 == 1)
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }
    /// What can follow a weekday and a D/D that is a date: a time or a time word.
    private static let shortDateFollowers: Set<String> = ["at", "from", "to", "until", "and", "or"]
    private static let afterTimeWordFollowers: Set<String> = ["at", "morning", "afternoon", "evening", "night", "and", "or", "to", "through"]
    /// The time words "Sun" can follow as a day: not "from Sun", "by Sun" (the company).
    private static let sunTimeWords: Set<String> = ["on", "every", "next", "last", "this", "until", "till", "each"]
    private static let agoUnits = ["s": "second", "m": "minute", "h": "hour", "d": "day", "w": "week", "wk": "week", "wks": "week",
                                   "mo": "month", "mos": "month", "y": "year"]
    private static let durationUnits: [String: (rank: Int, word: String)] = [
        "d": (0, "day"), "h": (1, "hour"), "hr": (1, "hour"), "hrs": (1, "hour"), "m": (2, "minute"), "min": (2, "minute"),
        "mins": (2, "minute"), "s": (3, "second"), "sec": (3, "second"), "secs": (3, "second"),
    ]
    private static let timeZones: Set<String> = [
        "UTC", "GMT", "BST", "CET", "CEST", "EET", "EST", "EDT", "CST", "CDT", "MST", "MDT", "PST", "PDT", "AKST", "HST", "IST",
        "JST", "KST", "AEST", "AEDT", "ET", "CT", "MT", "PT", "Z", "Eastern", "Pacific", "Central", "Mountain", "Atlantic",
    ]

    /// A dash and another date after a date: "– Fri 17 Oct", "- 7 March".
    private static let dateDashAhead = try! NSRegularExpression(pattern: #"^[ \t]*[-–—][ \t]*(?:\d|"# + weekdayNames + "|" + weekdayAbbreviations + "|" + monthPattern + ")")
    private static let clockAhead = try! NSRegularExpression(pattern: #"^[ \t]*\d{1,2}(?::\d{2}|[ \t]?[AaPp]\.?[ \t]?[Mm](?![\p{L}]))"#)
    private static let yearAhead = try! NSRegularExpression(pattern: #"^,[ \t]*\d{4}(?!\d)"#)
    private static let countAhead = try! NSRegularExpression(pattern: #"^[ \t]+of[ \t]+(?:us|them|you)(?![\p{L}])"#)
    private static let scoreAhead = try! NSRegularExpression(pattern: #"^[ \t]+to[ \t]+(\d{1,2})(?!\d)"#)
    private static let dateBehind = try! NSRegularExpression(pattern: #"(?:(?:1\d|20)\d\d|\d{1,2}(?:st|nd|rd|th)?[ \t](?:"# + monthPattern + #")\.?|(?:"# + monthPattern + #")\.?[ \t]\d{1,2}(?:st|nd|rd|th)?),?[ \t]+$"#)

    /// Whether an H:MM:SS after `before` is a clock time by what comes before it: "at" or "@", a
    /// date, an opening bracket or the start of a line (a log stamp).
    private static func isClockContext(_ before: String) -> Bool {
        let trimmed = before.reversed().drop { $0 == " " || $0 == "\t" }
        guard let last = trimmed.first, !last.isNewline else { return true }
        if last == "@" || last == "[" { return true }
        if previousWord(before).word.lowercased() == "at" { return true }
        return dateBehind.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) != nil
    }

    private static func timeZoneFollows(_ after: String) -> Bool {
        if case .word(let w) = follower(after) { return timeZones.contains(w) }
        return false
    }

    /// Whether a month comes right after a determiner or a possessive, so its date describes a
    /// noun ("the March 15 deadline", "this March 5 event", "Leeds's March 5 match").
    private static func isAttributive(_ before: String) -> Bool {
        let word = previousWord(before).word
        return ["the", "a", "an", "this", "that", "its"].contains(word.lowercased()) || word.hasSuffix("'s") || word.hasSuffix("’s")
    }

    /// Whether a month-first date stands on its own, so the British voice says "March the 5th":
    /// a weekday before it, or a year, punctuation, the end or a small word after it; never right
    /// after a determiner.
    private static func standsAlone(before: String, after: String) -> Bool {
        if isAttributive(before) { return false }
        let previous = previousWord(before, skipping: [","]).word
        if weekdays[previous.lowercased()] != nil || fullWeekdays.contains(previous) { return true }
        switch follower(after) {
        case .end, .mark: return true
        case .word(let w): return functionWords.contains(w)
        default: return false
        }
    }
}
