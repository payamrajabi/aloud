import Foundation

/// How the player shows a span of the display text.
struct DisplayStyle: Equatable {
    enum Kind: Equatable {
        case heading(Int), quote(Int), listItem(Int), code, strike, bold, italic, underline, link
        /// A list item's bullet, number or box, outside the chunk ranges (read, if at all,
        /// with the item's first sentence).
        case listMarker
    }
    var range: NSRange
    var kind: Kind
}

struct NarrationPlan {
    var displayText: String
    var styles: [DisplayStyle]
    var chunks: [Chunk]
}

/// Turns a `NarrationDoc` into what the player shows and says. Each block is chunked into
/// sentences as plain text always was; then the block's kind sets its delivery (a slower
/// heading with a full stop, an ordered item's number) and the pauses around it, so the
/// structure is heard without being announced.
enum NarrationPlanner {
    private struct PlacedRun {
        var range: NSRange          // in the display text
        var styles: RunStyles
        var separator = false       // between table cells
        var stressable = false      // a short emphasis, read with extra stress
        var standsAlone = false     // an image read "Image: …", not as words of its sentence
    }

    private struct Placed {
        var block: NarrationBlock
        var line: NSRange           // with the list prefix
        var content: NSRange        // without it
        var runs: [PlacedRun]
        var leadIn: Bool
    }

    private struct Piece {
        var range: NSRange
        var speech: String
        var pauseAfter: Double      // inside the block; the last piece's is set between blocks
    }

    static func plan(_ doc: NarrationDoc) -> NarrationPlan {
        let display = NSMutableString()
        var styles: [DisplayStyle] = []
        var placed: [Placed] = []
        for var block in doc.blocks {
            unbox(&block)
            guard let (body, localRuns) = layout(block) else { continue }
            if display.length > 0 { display.append("\n") }
            let lineStart = display.length
            display.append(prefix(block))
            let contentStart = display.length
            display.append(body)
            let line = NSRange(location: lineStart, length: display.length - lineStart)
            let content = NSRange(location: contentStart, length: display.length - contentStart)
            let runs = localRuns.map { run -> PlacedRun in
                var run = run
                run.range.location += contentStart
                return run
            }
            let leadIn = block.leadIn || (block.kind == .paragraph && body.trimmingCharacters(in: .whitespaces).hasSuffix(":"))
            placed.append(Placed(block: block, line: line, content: content, runs: runs, leadIn: leadIn))

            switch block.kind {
            case .heading(let level): styles.append(DisplayStyle(range: content, kind: .heading(level)))
            case .listItem(_, _, let depth):
                styles.append(DisplayStyle(range: line, kind: .listItem(depth)))
                styles.append(DisplayStyle(range: NSRange(location: lineStart + 4 * depth, length: contentStart - lineStart - 4 * depth),
                                           kind: .listMarker))
            case .code: styles.append(DisplayStyle(range: content, kind: .code))
            default: break
            }
            if block.quoteDepth > 0 { styles.append(DisplayStyle(range: line, kind: .quote(block.quoteDepth))) }
            let inline: [(RunStyles, DisplayStyle.Kind)] = [(.bold, .bold), (.italic, .italic), (.underline, .underline),
                                                             (.strike, .strike), (.link, .link), (.code, .code)]
            for run in runs where !run.separator {
                for (style, kind) in inline where run.styles.contains(style) {
                    styles.append(DisplayStyle(range: run.range, kind: kind))
                }
            }
        }

        let ns = display as NSString
        var spoken: [(index: Int, pieces: [Piece])] = []
        for (i, p) in placed.enumerated() {
            let pieces = pieces(p, in: ns)
            if !pieces.isEmpty { spoken.append((i, pieces)) }
        }
        splitOpening(&spoken, placed, in: ns)

        var chunks: [Chunk] = []
        for (k, item) in spoken.enumerated() {
            let p = placed[item.index]
            var pieces = item.pieces
            let last = pieces.count - 1
            switch p.block.kind {
            // A trailing comma becomes the full stop rather than meeting it (",.").
            case .heading:
                pieces[last].speech = fullStop(pieces[last].speech, replacing: ":;,")
            case .listItem(let ordered, let number, _):
                if ordered, let number { pieces[0].speech = "\(number). " + pieces[0].speech }
                // Answer letters are read, so "The answer is B." still makes sense. A comma, as
                // "A." reads as an abbreviation and runs into the option ("ˈA vˈinəs"). Not i, v
                // or x: in a list those are roman numerals, shown but not read.
                else if let letter = p.block.marker, letter.range(of: #"^[A-HJ-UWYZa-hj-uwyz][.)]$"#, options: .regularExpression) != nil {
                    pieces[0].speech = letter.prefix(1).uppercased() + ", " + pieces[0].speech
                }
                if !TextPrep.endsWith(pieces[last].speech, ".!?…:;") { pieces[last].speech = fullStop(pieces[last].speech, replacing: ",") }
            case .tableRow:
                pieces[last].speech = fullStop(pieces[last].speech, replacing: ":;,")
            default: break
            }
            pieces[last].pauseAfter = k == spoken.count - 1 ? 0.5 : gap(placed[item.index...spoken[k + 1].index])
            let speed = speed(p.block)
            chunks += pieces.map { Chunk(range: $0.range, speech: $0.speech, pauseAfter: $0.pauseAfter, speed: speed) }
        }
        return NarrationPlan(displayText: display as String, styles: styles, chunks: chunks)
    }

    /// The chunks the voice can read (English, `KokoroEngine.canRead`), as the player plays
    /// them. A chunk left out hands its pause to the one before: the paragraph before a
    /// heading still ends with the heading's pause when its last sentence was in Chinese.
    static func readable(_ chunks: [Chunk]) -> [Chunk] {
        var kept: [Chunk] = []
        for chunk in chunks {
            if KokoroEngine.canRead(chunk.speech) {
                kept.append(chunk)
            } else if let previous = kept.last, chunk.pauseAfter > previous.pauseAfter {
                kept[kept.count - 1] = Chunk(range: previous.range, speech: previous.speech, pauseAfter: chunk.pauseAfter,
                                             speed: previous.speed)
            }
        }
        return kept
    }

    // MARK: - Display

    private static func prefix(_ block: NarrationBlock) -> String {
        guard case .listItem(let ordered, let number, let depth) = block.kind else { return "" }
        let indent = String(repeating: " ", count: 4 * depth)
        let spoken = ordered ? number.map { "\($0). " } ?? "" : ""
        if let marker = block.marker { return indent + spoken + marker + " " }   // "2. ☑ "
        return indent + (spoken.isEmpty ? "• " : spoken)
    }

    /// A task list's box ("- [x] Grind them", text to every reader but GitHub's HTML) is
    /// shown as ☐ or ☑ in front of the item, never read ("ex, grind them").
    private static func unbox(_ block: inout NarrationBlock) {
        guard case .listItem = block.kind, block.marker == nil,
              let k = block.runs.firstIndex(where: { !$0.text.allSatisfy(\.isWhitespace) }),
              block.runs[k].styles.isDisjoint(with: [.code, .link, .image]),
              let box = block.runs[k].text.range(of: #"^\s*\[[ xX]\](\s+|$)"#, options: .regularExpression) else { return }
        var unboxed = block
        unboxed.runs[k].text.removeSubrange(box)
        guard TextPrep.hasWords(unboxed.text) else { return }   // "- [x]" alone is left as it is
        unboxed.marker = block.runs[k].text[box].contains { $0 == "x" || $0 == "X" } ? "☑" : "☐"
        block = unboxed
    }

    /// A block's display text and its runs (ranges local to it), with whitespace collapsed
    /// and no markup. Nil for a block with nothing to show.
    private static func layout(_ block: NarrationBlock) -> (String, [PlacedRun])? {
        switch block.kind {
        case .rule:
            return ("⸻", [])
        case .code:
            // Shown as it is, minus the blank lines around it.
            var lines = block.text.components(separatedBy: "\n")
            while let l = lines.first, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
            while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            return lines.isEmpty ? nil : (lines.joined(separator: "\n"), [])
        default:
            break
        }
        var isTable = false
        if case .tableRow = block.kind { isTable = true }
        let body = NSMutableString()
        var runs: [PlacedRun] = []
        func trimEnd() {
            while body.hasSuffix(" ") {
                body.deleteCharacters(in: NSRange(location: body.length - 1, length: 1))
                if let k = runs.lastIndex(where: { NSMaxRange($0.range) > body.length }) {
                    runs[k].range.length -= 1
                    if runs[k].range.length == 0 { runs.remove(at: k) }
                }
            }
        }
        for run in block.runs {
            if isTable && run.text == NarrationBlock.cellSeparator {
                trimEnd()
                guard body.length > 0, runs.last?.separator == false else { continue }
                runs.append(PlacedRun(range: NSRange(location: body.length, length: 3), styles: [], separator: true))
                body.append("   ")
                continue
            }
            var t = run.text.replacingOccurrences(of: "\u{FFFC}", with: "")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            if run.styles.contains(.image) {
                t = t.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { continue }
            }
            if body.length == 0 || body.hasSuffix(" ") { t = String(t.drop { $0 == " " }) }
            guard !t.isEmpty else { continue }
            runs.append(PlacedRun(range: NSRange(location: body.length, length: (t as NSString).length), styles: run.styles))
            body.append(t)
        }
        trimEnd()
        while runs.last?.separator == true {
            body.deleteCharacters(in: runs.removeLast().range)
        }
        guard body.length > 0 else { return nil }
        for k in runs.indices where runs[k].styles.contains(.image) {
            runs[k].standsAlone = imageStandsAlone(k, runs, in: body)
        }

        // A short emphasis (four words at most) is stressed; emphasis over the whole block,
        // or a heading, is left as it is.
        func isEmphasis(_ r: PlacedRun) -> Bool {
            !r.separator && !r.styles.isDisjoint(with: .emphasis) && r.styles.isDisjoint(with: [.strike, .image])
        }
        let hasPlainWords = runs.contains { r in
            !isEmphasis(r) && !r.separator && !r.styles.contains(.strike) && TextPrep.hasWords(body.substring(with: r.range))
        }
        if case .heading = block.kind {} else if hasPlainWords {
            var k = 0
            while k < runs.count {
                guard isEmphasis(runs[k]) else { k += 1; continue }
                var end = k
                while end + 1 < runs.count, isEmphasis(runs[end + 1]) { end += 1 }
                let text = runs[k...end].map { body.substring(with: $0.range) }.joined()
                let words = text.split(whereSeparator: \.isWhitespace).filter { TextPrep.hasWords(String($0)) }.count
                if (1...4).contains(words) { for j in k...end { runs[j].stressable = true } }
                k = end + 1
            }
        }
        return (body as String, runs)
    }

    /// An image is read on its own ("Image: A chart of sales.") when it stands between
    /// sentences or with nothing but other images; inside a sentence ("Click [the gear icon]
    /// and choose Settings") its alt text is read as words of the sentence.
    private static func imageStandsAlone(_ k: Int, _ runs: [PlacedRun], in body: NSString) -> Bool {
        func text(_ step: Int) -> String? {   // the nearest text before or after it, in its cell
            var j = k + step
            while runs.indices.contains(j), !runs[j].separator {
                let t = body.substring(with: runs[j].range).trimmingCharacters(in: .whitespaces)
                if !t.isEmpty, runs[j].styles.isDisjoint(with: [.image, .strike]) { return t }
                j += step
            }
            return nil
        }
        let before = text(-1).map { TextPrep.endsWith($0, ".!?…:") } ?? true
        let after = text(1).map { t -> Bool in
            // A new sentence starts with a capital or a number, not "and…" or ",".
            guard let c = t.first(where: { $0.isLetter || $0.isNumber || ",.;:!?)".contains($0) }) else { return true }
            return c.isUppercase || c.isNumber
        } ?? true
        return before && after
    }

    // MARK: - Chunks

    /// Links and images: a sentence is never cut inside one.
    private static func protectedSpans(_ p: Placed) -> [NSRange] {
        p.runs.filter { !$0.styles.isDisjoint(with: [.link, .image]) }.map(\.range)
    }

    private static func pieces(_ p: Placed, in ns: NSString) -> [Piece] {
        switch p.block.kind {
        case .code, .rule:
            return []
        case .tableRow:
            // One chunk per row, unless it's too long for one.
            let ranges = p.content.length > TextPrep.maxChunkLength ? TextPrep.split(p.content, in: ns, protected: protectedSpans(p)) : [p.content]
            return ranges.compactMap { r in
                let range = TextPrep.trim(r, in: ns)
                let speech = speech(range, p, in: ns, stress: true)
                return TextPrep.hasWords(speech) ? Piece(range: range, speech: speech, pauseAfter: 0.08) : nil
            }
        default:
            break
        }
        // An image read on its own ends its sentence, and a bold label ("Note:") is a chunk of
        // its own.
        let label = labelEnd(p, in: ns)
        let contentEnd = NSMaxRange(p.content)
        var cuts = Set(p.runs.filter { $0.standsAlone && TextPrep.hasWords(ns.substring(with: $0.range)) }.map { NSMaxRange($0.range) })
        if let label { cuts.insert(label) }
        let protected = protectedSpans(p)
        var result: [Piece] = []
        var start = p.content.location
        for end in cuts.filter({ $0 > p.content.location && $0 < contentEnd }).sorted() + [contentEnd] {
            let isLabel = end == label
            for piece in TextPrep.pieces(in: ns, range: NSRange(location: start, length: end - start), protected: protected) {
                let speech = speech(piece.range, p, in: ns, stress: !isLabel)
                guard TextPrep.hasWords(speech) else { continue }
                result.append(Piece(range: piece.range, speech: speech, pauseAfter: isLabel ? 0.3 : piece.endsSentence ? 0.25 : 0.08))
            }
            start = end
        }
        return result
    }

    /// The end of a paragraph's opening bold label ("**Note:** …"), if it has one.
    private static func labelEnd(_ p: Placed, in ns: NSString) -> Int? {
        guard p.block.kind == .paragraph else { return nil }
        var label = ""
        var end: Int?
        for run in p.runs {
            guard run.styles.contains(.bold), run.styles.isDisjoint(with: [.strike, .image]) else { break }
            label += ns.substring(with: run.range)
            end = NSMaxRange(run.range)
        }
        guard let end, label.trimmingCharacters(in: .whitespaces).hasSuffix(":"), TextPrep.hasWords(label),
              TextPrep.hasWords(ns.substring(with: NSRange(location: end, length: NSMaxRange(p.content) - end))) else { return nil }
        return end
    }

    /// The opening split (`TextPrep.openingHalves`), once, on the first chunk of the whole plan.
    private static func splitOpening(_ spoken: inout [(index: Int, pieces: [Piece])], _ placed: [Placed], in ns: NSString) {
        guard let first = spoken.first else { return }
        let p = placed[first.index]
        if case .tableRow = p.block.kind { return }
        let piece = first.pieces[0]
        guard let (a, b) = TextPrep.openingHalves(piece.range, in: ns, protected: protectedSpans(p)) else { return }
        let speechA = speech(a, p, in: ns, stress: true)
        let speechB = speech(b, p, in: ns, stress: true)
        guard TextPrep.hasWords(speechA), TextPrep.hasWords(speechB) else { return }
        spoken[0].pieces.replaceSubrange(0...0, with: [Piece(range: a, speech: speechA, pauseAfter: 0.02),
                                                       Piece(range: b, speech: speechB, pauseAfter: piece.pauseAfter)])
    }

    /// What the voice says for `range` of a block: struck text left out, an image on its
    /// own as "Image: " and its alt text, table cells joined with commas, a short emphasis
    /// as misaki's stress link "[words](+1)".
    private static func speech(_ range: NSRange, _ p: Placed, in ns: NSString, stress: Bool) -> String {
        var out = ""
        var pending = ""
        var pendingStress = false
        var newCell = false
        // Only the start of a line can hold a quote marker (plain text's "> On Monday…").
        var tableRow = false
        if case .tableRow = p.block.kind { tableRow = true }
        let lineStart = range.location == p.content.location && !tableRow
        func flush() {
            guard !pending.isEmpty else { return }
            // The cleanup first: its link-stripping would eat the stress link.
            let cleaned = TextPrep.speechCleanup(pending, lineStart: lineStart && out.isEmpty)
            out += pendingStress ? stressed(cleaned) : cleaned
            pending = ""
        }
        for run in p.runs {
            let r = NSIntersectionRange(run.range, range)
            guard r.length > 0 else { continue }
            if run.separator {
                flush()
                newCell = true
                continue
            }
            if newCell {
                // "Total:" and "12" read "Total: 12", not "Total:, 12".
                if TextPrep.hasWords(out) { out += TextPrep.endsWith(out.trimmingCharacters(in: .whitespaces), ".!?…:;,") ? " " : ", " }
                newCell = false
            }
            if run.styles.contains(.strike) {
                flush()
                out += " "
            } else if run.standsAlone {
                flush()
                // Once, by the piece that holds its start (a long table row may be cut in it).
                guard NSLocationInRange(run.range.location, range) else { continue }
                var alt = TextPrep.speechText(ns.substring(with: run.range))
                guard TextPrep.hasWords(alt) else { out += " "; continue }
                if !TextPrep.endsWith(alt, ".!?…") { alt += "." }
                out += " Image: \(alt) "
            } else {   // text, or an image inside its sentence
                let s = stress && run.stressable
                if s != pendingStress { flush(); pendingStress = s }
                pending += ns.substring(with: r)
            }
        }
        flush()
        return out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            // "This is ~~wrong~~." left "This is ."; "./scripts" keeps its space.
            .replacingOccurrences(of: " ([,.;:!?…])(?=\\s|$)", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// "[words](+1)", with the spaces and punctuation around the words left outside.
    private static func stressed(_ s: String) -> String {
        guard let first = s.firstIndex(where: { $0.isLetter || $0.isNumber }),
              let last = s.lastIndex(where: { $0.isLetter || $0.isNumber }) else { return s }
        let core = s[first...last]
        guard !core.contains(where: { "[]()".contains($0) }) else { return s }
        return String(s[..<first]) + "[" + core + "](+1)" + s[s.index(after: last)...]
    }

    /// `s` ending a sentence: a trailing mark in `replacing` becomes ".", else "." is added.
    private static func fullStop(_ s: String, replacing: String) -> String {
        if TextPrep.endsWith(s, ".!?…") { return s }
        if let last = s.last, replacing.contains(last) { return String(s.dropLast()) + "." }
        return s + "."
    }

    // MARK: - Delivery

    private static func speed(_ block: NarrationBlock) -> Float {
        if case .heading(let level) = block.kind {
            return [0.88, 0.92, 0.95][safe: level - 1] ?? 0.97
        }
        return block.quoteDepth > 0 ? 0.95 : 1
    }

    /// The silence between the last chunk of one spoken block and the next spoken block:
    /// the largest of what each boundary on the way asks for (nothing adds up), including
    /// those of blocks in between that aren't spoken (code, rules, struck text).
    private static func gap(_ seq: ArraySlice<Placed>) -> Double {
        let a = seq.first!.block, b = seq.last!.block
        if seq.count == 2 {
            if case .heading = a.kind, case .heading = b.kind { return 0.6 }
            if seq.first!.leadIn, case .listItem = b.kind { return 0.45 }
        }
        var pause = 0.0
        for (x, y) in zip(seq, seq.dropFirst()) {
            pause = max(pause, after(x.block, next: y.block), before(y.block, previous: x.block))
            if x.block.quoteDepth != y.block.quoteDepth { pause = max(pause, 0.6) }
        }
        return pause
    }

    private static func after(_ x: NarrationBlock, next y: NarrationBlock) -> Double {
        switch x.kind {
        case .heading(let level): return [0.8, 0.7, 0.6][safe: level - 1] ?? 0.5
        case .paragraph: return 0.75
        case .listItem: if case .listItem = y.kind { return 0.4 } else { return 0.75 }
        case .tableRow: if case .tableRow = y.kind { return 0.35 } else { return 0.75 }
        case .code: return 0.75
        case .rule: return 1.6
        }
    }

    private static func before(_ y: NarrationBlock, previous x: NarrationBlock) -> Double {
        switch y.kind {
        case .heading(let level): return [1.4, 1.2, 1.0][safe: level - 1] ?? 0.9
        case .paragraph, .tableRow: return 0
        case .listItem: if case .listItem = x.kind { return 0 } else { return 0.6 }
        case .code: return 0.75
        case .rule: return 1.6
        }
    }
}
