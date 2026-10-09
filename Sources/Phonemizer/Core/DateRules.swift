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
        guard text.contains("'") || text.contains("’") else { return text }
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
        return rules
    }

    // MARK: Step 19: clock stamps and durations

    /// H:MM:SS, then "5m ago" and compound durations ("1h 30m"): after powers, before shorthand's
    /// "~", the unit range rule, units' h, m and s, clock and ratio.
    static func durations(british: Bool) -> [Rule] {
        var rules: [Rule] = []
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
        // ISO dates: "2024-03-15" → "March 15th, 2024" (GB: "the 15th of March, 2024").
        rules.append(Rule.withContext(#"(?<![\p{L}\d\-–−./:])(\d{4})-(\d{2})-(\d{2})(?![\p{L}\d\-–]|[.,:/]\d)"#) { m, s, context in
            let year = s.substring(with: m.range(at: 1))
            guard let month = Int(s.substring(with: m.range(at: 2))), let day = Int(s.substring(with: m.range(at: 3))),
                  (1...12).contains(month), (1...31).contains(day) else { return s.substring(with: m.range) }
            let afterThe = previousWord(context.text(before: m.range, in: s)).word.lowercased() == "the"
            return written(day: day, month: month, year: year, british: british, afterThe: afterThe)
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
        // GB "Tuesday, the 3rd of May"), when a time, a time word or the end follows it. Elsewhere
        // a D/D stays a fraction or a number ("Early closing Wed 1/2 day").
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
            default: return whole
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

        // Day-first written dates: "5 March", "5th March 2024", "1 Dec.", "5–7 March" → "the 5th
        // of March, 2024", "the 5th to the 7th of March". Both voices. A year, punctuation, the
        // end, a small word or an abbreviation's period must follow, so a count before a
        // month-named noun stays ("We ran 3 March events", "5 May Day posters"), and so does a
        // number after a numeral noun ("Track 4 March to the Scaffold"). When the month's period
        // is also the full stop ("1 Dec."), the sentence keeps it.
        rules.append(Rule.withContext(#"(?<![\p{L}\d.,:/$£€¥₹₩])(\d{1,2})(st|nd|rd|th)?(?:[-–](\d{1,2})(st|nd|rd|th)?)?[ \t]("# + monthPattern + #")(\.)?(?![\p{L}\d\-])(?:,?[ \t]((?:1\d|20)\d\d)(?![\d\p{L}]))?"#) { m, s, context in
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
                    default: return whole
                    }
                }
            }
            var out = (previous.lowercased() == "the" ? "" : "the ") + "\(first)\(ordinalSuffix(first))"
            if let last { out += " to the \(last)\(ordinalSuffix(last))" }
            out += " of " + CalendarNames.monthsInOrder[month - 1]
            if hasYear { out += ", " + s.substring(with: m.range(at: 7)) }
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
