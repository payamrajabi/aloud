import AppKit

/// Menu bar icon: five bars that sit still when idle, dance while reading,
/// breathe while the first audio is being generated, and dim when paused.
final class StatusIconView: NSView {
    var status: PlayerModel.Status = .idle {
        didSet {
            guard status != oldValue else { return }
            updateTimer()
            needsDisplay = true
        }
    }

    private var timer: Timer?
    private let start = Date()
    private let restingHeights: [CGFloat] = [0.35, 0.7, 1.0, 0.6, 0.3]
    private let speeds: [Double] = [7.1, 9.3, 6.2, 8.4, 10.1]
    private let phases: [Double] = [0.0, 1.3, 2.6, 0.7, 2.0]

    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // clicks go to the status button

    private func updateTimer() {
        let animating = status == .playing || status == .loading
        if animating, timer == nil {
            let t = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in self?.needsDisplay = true }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !animating {
            timer?.invalidate()
            timer = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let barWidth: CGFloat = 2.4
        let gap: CGFloat = 1.8
        let maxHeight: CGFloat = 14
        let count = restingHeights.count
        let totalWidth = CGFloat(count) * barWidth + CGFloat(count - 1) * gap
        var x = (bounds.width - totalWidth) / 2
        let t = Date().timeIntervalSince(start)

        var color = NSColor.labelColor
        if status == .paused { color = color.withAlphaComponent(0.45) }
        color.setFill()

        for i in 0..<count {
            let level: CGFloat
            switch status {
            case .idle, .paused:
                level = restingHeights[i]
            case .playing:
                level = 0.25 + 0.75 * CGFloat(abs(sin(t * speeds[i] / 2 + phases[i])))
            case .loading:
                let breath = 0.5 + 0.5 * sin(t * 4 - Double(i) * 0.6)
                level = restingHeights[i] * CGFloat(0.55 + 0.45 * breath)
            }
            let h = max(barWidth, maxHeight * level)
            let rect = NSRect(x: x, y: (bounds.height - h) / 2, width: barWidth, height: h)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + gap
        }
    }
}
