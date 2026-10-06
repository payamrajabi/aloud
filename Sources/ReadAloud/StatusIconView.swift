import AppKit

/// Menu bar icon: five bars in the `waveform` silhouette. They follow the live
/// audio level while listening (red) or reading aloud, rippling out from the
/// centre; breathe while getting ready; sweep while transcribing; sit still
/// when idle and dim when paused. Reduce Motion keeps them still.
final class StatusIconView: NSView {
    enum State: Equatable {
        case idle
        case preparing      // first audio generating, or the dictation model downloading
        case speaking       // reading aloud
        case paused
        case listening      // recording a dictation
        case transcribing

        var label: String {
            switch self {
            case .idle: "Ready"
            case .preparing: "Getting ready"
            case .speaking: "Reading aloud"
            case .paused: "Paused"
            case .listening: "Listening"
            case .transcribing: "Transcribing"
            }
        }

        var followsLevel: Bool { self == .listening || self == .speaking }
    }

    var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            if state.followsLevel { resetLevel() }
            updateTimer()
            needsDisplay = true
        }
    }

    /// Live loudness, 0…1 (already perceptually mapped). Used while listening or speaking.
    var level: Float = 0

    private var timer: Timer?
    private let start = Date()
    private let restingHeights: [CGFloat] = [0.35, 0.7, 1.0, 0.6, 0.3]
    private let historyLag = [4, 2, 0, 2, 4]    // frames behind the newest level, per bar
    private var smoothed: Float = 0
    private var history = [Float](repeating: 0, count: 8)
    private var head = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(reduceMotionChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // clicks go to the status button

    @objc private func reduceMotionChanged() {
        updateTimer()
        needsDisplay = true
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func updateTimer() {
        let animating = state != .idle && state != .paused && !reduceMotion
        if animating, timer == nil {
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.frameTick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !animating {
            timer?.invalidate()
            timer = nil
        }
    }

    private func resetLevel() {
        smoothed = 0
        history = history.map { _ in 0 }
        head = 0
    }

    private func frameTick() {
        if state.followsLevel {
            let target = min(1, max(0, level))
            smoothed += (target - smoothed) * (target > smoothed ? 0.5 : 0.15)  // fast attack, slow release
            head = (head + 1) % history.count
            history[head] = smoothed
        }
        needsDisplay = true
    }

    private func pastLevel(_ framesAgo: Int) -> CGFloat {
        CGFloat(history[(head - framesAgo + history.count) % history.count])
    }

    /// Bar heights as a fraction of the full height, for the current frame.
    func barLevels(at t: TimeInterval) -> [CGFloat] {
        guard !reduceMotion else { return restingHeights }
        return restingHeights.indices.map { i in
            switch state {
            case .listening, .speaking:
                return restingHeights[i] * (0.18 + 0.82 * pastLevel(historyLag[i]))
            case .preparing:
                let breath = 0.5 + 0.5 * sin(t * 4 - Double(i) * 0.6)
                return restingHeights[i] * CGFloat(0.55 + 0.45 * breath)
            case .idle, .paused, .transcribing:
                return restingHeights[i]
            }
        }
    }

    /// Per-bar opacity: a left-to-right highlight sweeps across while transcribing.
    private func barAlpha(_ i: Int, at t: TimeInterval) -> CGFloat {
        guard state == .transcribing, !reduceMotion else { return 1 }
        let count = Double(restingHeights.count)
        let sweep = (t * 1.6).truncatingRemainder(dividingBy: 1) * (count + 2) - 1  // runs a little past each edge
        let distance = abs(Double(i) - sweep)
        return CGFloat(0.35 + 0.65 * max(0, 1 - distance / 1.5))
    }

    override func draw(_ dirtyRect: NSRect) {
        let barWidth: CGFloat = 2.4
        let gap: CGFloat = 1.8
        let maxHeight: CGFloat = 14
        let count = restingHeights.count
        let totalWidth = CGFloat(count) * barWidth + CGFloat(count - 1) * gap
        var x = (bounds.width - totalWidth) / 2
        let t = Date().timeIntervalSince(start)
        let levels = barLevels(at: t)

        let base: NSColor = state == .listening ? .systemRed : .labelColor
        let dim: CGFloat = state == .paused ? 0.45 : 1

        for i in 0..<count {
            base.withAlphaComponent(dim * barAlpha(i, at: t)).setFill()
            let h = max(barWidth, maxHeight * levels[i])
            let rect = NSRect(x: x, y: (bounds.height - h) / 2, width: barWidth, height: h)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + gap
        }
    }
}
