import Foundation

/// Text after `CustomLexicon.mark`, seen as it is read: each "[label](/phonemes/)" mark counts
/// as its label.
///
/// The rules after the custom lexicon run on the plain stretches between its marks, and a
/// pass after it must never rewrite inside one. But the words a mark holds still decide the
/// readings around it: "USB-C" in "65 W USB-C charger" makes W watts, "Apollo" in "Apollo XI"
/// makes XI a number. A view holds both the marked text and its reading, with offsets (UTF-16)
/// mapped between them. Before the custom lexicon there are no marks: the reading is the text.
struct LabelView {
    /// The text, with its marks.
    let text: NSString
    /// The text as it is read: every mark replaced by its label.
    let reading: NSString
    /// Each mark's range in `text`, in order.
    let marks: [NSRange]
    /// Each mark's label in `reading`, in the same order.
    let labels: [NSRange]

    /// - Parameter found: the matches of `TextNormalizer.marked` in `text`, when the caller
    ///   already has them (none, for text the custom lexicon hasn't seen).
    init(_ text: String, marks found: [NSTextCheckingResult]? = nil) {
        let ns = text as NSString
        let matches = found ?? TextNormalizer.marked.matches(in: text, range: NSRange(location: 0, length: ns.length))
        self.text = ns
        marks = matches.map(\.range)
        guard !matches.isEmpty else {
            reading = ns
            labels = []
            return
        }
        var out = "", last = 0, length = 0
        var labels: [NSRange] = []
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let label = m.range(at: 1)
            labels.append(NSRange(location: length + m.range.location - last, length: label.length))
            out += ns.substring(with: label)
            length = NSMaxRange(labels[labels.count - 1])
            last = NSMaxRange(m.range)
        }
        reading = (out + ns.substring(from: last)) as NSString
        self.labels = labels
    }

    /// The mark (in `text`) that holds `location`, if any.
    func mark(at location: Int) -> NSRange? {
        guard let i = Self.lastIndex(in: marks, atOrBefore: location), location < NSMaxRange(marks[i]) else { return nil }
        return marks[i]
    }

    /// Where `location` (in `text`) is in `reading`. Inside a mark: where its label starts.
    func readingLocation(_ location: Int) -> Int {
        guard let i = Self.lastIndex(in: marks, atOrBefore: location) else { return location }
        if location < NSMaxRange(marks[i]) { return labels[i].location }
        return NSMaxRange(labels[i]) + location - NSMaxRange(marks[i])
    }

    /// Where `location` (in `reading`) is in `text`. Inside a label: where its mark starts.
    func textLocation(_ location: Int) -> Int {
        guard let i = Self.lastIndex(in: labels, atOrBefore: location) else { return location }
        if location < NSMaxRange(labels[i]) { return marks[i].location }
        return NSMaxRange(marks[i]) + location - NSMaxRange(labels[i])
    }

    /// Up to `limit` UTF-16 units of the reading just before `location` (in `reading`).
    func reading(before location: Int, limit: Int = 120) -> String {
        let start = max(0, location - limit)
        return reading.substring(with: NSRange(location: start, length: location - start))
    }

    /// Up to `limit` UTF-16 units of the reading from `location` (in `reading`).
    func reading(after location: Int, limit: Int = 160) -> String {
        reading.substring(with: NSRange(location: location, length: min(limit, reading.length - location)))
    }

    /// The sentence of the reading that holds `location` (in `reading`), ending where
    /// `ShoutedSentences` ends one: a line break, or ". ", "! ", "? " or "…" before a space or
    /// the end. A rule's context words ("volts", "offshore", "raised") must share its sentence.
    func sentence(at location: Int) -> NSRange {
        var start = min(location, reading.length)
        while start > 0, !endsSentence(at: start - 1) { start -= 1 }
        var end = start
        while end < reading.length, !endsSentence(at: end) { end += 1 }
        return NSRange(location: start, length: min(reading.length, end + 1) - start)
    }

    private func endsSentence(at p: Int) -> Bool {
        switch reading.character(at: p) {
        case 0x0A, 0x0D: return true
        case 0x2E, 0x21, 0x3F, 0x2026:  // . ! ? …
            guard p + 1 < reading.length else { return true }
            return Unicode.Scalar(reading.character(at: p + 1)).map(Scalars.isSpace) ?? false
        default: return false
        }
    }

    /// The index of the last range that starts at or before `location`.
    private static func lastIndex(in ranges: [NSRange], atOrBefore location: Int) -> Int? {
        var lo = 0, hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ranges[mid].location <= location { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }
}

/// What a rule in TextNormalizer's list can see beyond the stretch of text it runs on.
///
/// `TextNormalizer.normalize(_:skippingMarkedSpans:british:)` runs the rules on each stretch
/// between the custom lexicon's marks, so a rule's own text stops at a marked term ("65 W " of
/// "65 W USB-C charger"). The context holds the whole text as it reads, and where the stretch
/// was in it before any rule ran. Once a rule has rewritten part of the stretch, offsets in it
/// no longer line up with the reading, so look before or after the stretch, or at its
/// sentence, rather than at a match's own offset.
struct RuleContext {
    let view: LabelView
    /// The stretch, in `view.reading`.
    let stretch: NSRange

    init(_ view: LabelView, _ stretch: NSRange) {
        self.view = view
        self.stretch = stretch
    }

    /// Text with no marks, as one stretch.
    init(_ text: String) {
        view = LabelView(text, marks: [])
        stretch = NSRange(location: 0, length: view.reading.length)
    }

    /// The reading just before the stretch: a term marked right before it counts as its label.
    func before(limit: Int = 120) -> String {
        view.reading(before: stretch.location, limit: limit)
    }

    /// The reading just after the stretch.
    func after(limit: Int = 160) -> String {
        view.reading(after: NSMaxRange(stretch), limit: limit)
    }

    /// The sentence the stretch starts in, as it reads.
    var sentence: String {
        view.reading.substring(with: view.sentence(at: stretch.location))
    }
}
