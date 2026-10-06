import AppKit

/// Menu bar icon. Same language as the KitchenOS voice tab: the `waveform`
/// symbol sits still when idle, pulses while something is getting ready, and
/// ripples while it's speaking, thinking or listening (red while listening).
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
    }

    var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            apply()
        }
    }

    private let imageView = NSImageView()
    private let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))!

    override init(frame: NSRect) {
        super.init(frame: frame)
        symbol.isTemplate = true
        imageView.image = symbol
        imageView.imageScaling = .scaleNone
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(reduceMotionChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        apply()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // clicks go to the status button

    @objc private func reduceMotionChanged() { apply() }

    private func apply() {
        imageView.contentTintColor = state == .listening ? .systemRed : nil
        imageView.alphaValue = state == .paused ? 0.45 : 1
        imageView.removeAllSymbolEffects(animated: false)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        switch state {
        case .idle, .paused:
            break
        case .preparing:
            imageView.addSymbolEffect(.pulse, options: .repeating)
        case .speaking, .transcribing:
            imageView.addSymbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
        case .listening:
            imageView.addSymbolEffect(.variableColor.iterative.dimInactiveLayers.reversing, options: .repeating)
        }
    }
}
