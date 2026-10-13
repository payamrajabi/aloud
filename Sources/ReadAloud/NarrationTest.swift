import Foundation

/// The narration suite (`--test-narration Tests/narration/cases.json [--verbose]`): what
/// the player shows and says for Markdown, HTML and plain text, chunk by chunk.
enum NarrationTest {
    private struct Doc: Decodable {
        let cases: [Case]
    }
    private struct Case: Decodable {
        let name: String
        let format: String?     // markdown | html | plain | auto (default)
        let input: String
        let html: String?       // the app's HTML beside the selected text (`input`), as the player gets them
        let chunks: [Want]?
        let display: String?
        let detect: String?     // what `auto` should pick
    }
    private struct Want: Decodable {
        let speech: String
        let speed: Double?      // 1 when omitted
        let pause: Double?      // not checked when omitted
        let pauseMin: Double?
        let pauseMax: Double?
    }

    static func run(path: String, verbose: Bool) -> Int32 {
        let doc: Doc
        do {
            doc = try JSONDecoder().decode(Doc.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            print("error: \(error)")
            return 1
        }
        var failures = 0
        for c in doc.cases {
            guard let format = NarrationFormat(rawValue: c.format ?? "auto") else {
                print("✗ \(c.name): unknown format \(c.format ?? "")")
                failures += 1
                continue
            }
            var plan = NarrationPlanner.plan(NarrationDoc.parse(c.input, html: c.html, format: format))
            plan.chunks = NarrationPlanner.readable(plan.chunks)   // as the player plays them
            var problems: [String] = []
            // Every case: the highlight needs chunk ranges in order, inside the display text.
            let length = (plan.displayText as NSString).length
            var end = 0
            for (k, chunk) in plan.chunks.enumerated() {
                if chunk.range.length == 0 || chunk.range.location < end || NSMaxRange(chunk.range) > length {
                    problems.append("chunk \(k + 1) has a bad range \(chunk.range) (display length \(length))")
                }
                end = max(end, NSMaxRange(chunk.range))
            }
            for style in plan.styles where style.range.length == 0 || NSMaxRange(style.range) > length {
                problems.append("style \(style.kind) has a bad range \(style.range) (display length \(length))")
            }
            if let want = c.detect, NarrationDoc.detect(c.input).rawValue != want {
                problems.append("detected \(NarrationDoc.detect(c.input).rawValue), want \(want)")
            }
            if let want = c.display, plan.displayText != want {
                problems.append("display:\n      got  \(plan.displayText.debugDescription)\n      want \(want.debugDescription)")
            }
            if let want = c.chunks {
                if want.count != plan.chunks.count {
                    problems.append("\(plan.chunks.count) chunks, want \(want.count)")
                }
                for (k, w) in want.enumerated() where k < plan.chunks.count {
                    let got = plan.chunks[k]
                    var wrong: [String] = []
                    if got.speech != w.speech { wrong.append("speech") }
                    if abs(Double(got.speed) - (w.speed ?? 1)) > 0.001 { wrong.append("speed") }
                    if let p = w.pause, abs(got.pauseAfter - p) > 0.005 { wrong.append("pause") }
                    if let p = w.pauseMin, got.pauseAfter < p - 0.0001 { wrong.append("pause") }
                    if let p = w.pauseMax, got.pauseAfter > p + 0.0001 { wrong.append("pause") }
                    if !wrong.isEmpty {
                        problems.append("chunk \(k + 1) (\(wrong.joined(separator: ", "))):\n      got  \(describe(got))\n      want \(describe(w))")
                    }
                }
            }
            print("\(problems.isEmpty ? "✓" : "✗") \(c.name)")
            for p in problems { print("    \(p)") }
            if verbose || !problems.isEmpty {
                let display = plan.displayText as NSString
                for chunk in plan.chunks {
                    print("      · \(describe(chunk))\(verbose ? "  ← \(display.substring(with: chunk.range).debugDescription)" : "")")
                }
            }
            if verbose {
                print("      display: \(plan.displayText.debugDescription)")
                print("      styles: " + plan.styles.map { "\($0.kind)@\($0.range.location)+\($0.range.length)" }.joined(separator: " "))
            }
            failures += problems.isEmpty ? 0 : 1
        }
        print("\n\(doc.cases.count - failures)/\(doc.cases.count) passed")
        print(failures == 0 ? "PASSED" : "FAILED")
        return failures == 0 ? 0 : 1
    }

    private static func describe(_ c: Chunk) -> String {
        String(format: "%@  speed %.2f  pause %.2f", c.speech.debugDescription, c.speed, c.pauseAfter)
    }

    private static func describe(_ w: Want) -> String {
        var s = "\(w.speech.debugDescription)  speed \(String(format: "%.2f", w.speed ?? 1))"
        if let p = w.pause { s += String(format: "  pause %.2f", p) }
        if let p = w.pauseMin { s += String(format: "  pause ≥ %.2f", p) }
        if let p = w.pauseMax { s += String(format: "  pause ≤ %.2f", p) }
        return s
    }
}
