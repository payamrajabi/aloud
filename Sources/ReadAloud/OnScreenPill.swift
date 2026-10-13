import AppKit
import Combine
import SwiftUI

/// The pill near the bottom of the screen. Tapping the dictation key shows a record dot at once,
/// which widens into the dictation pill, or, on a double-tap, into controls for what's being read.
final class OnScreenPill {
    enum Mode: Equatable {
        case armed  // first tap: listening, though a second tap may still make it a read
        case finding  // second tap: fetching the selection
        case dictating, transcribing
        case downloading(Double)
        case message(String)
        case reading
    }

    final class State: ObservableObject {
        @Published var mode: Mode?
    }

    let panel: NSPanel
    let reader: ReaderPill
    private let dictation: DictationController
    private let state = State()
    private var observers: Set<AnyCancellable> = []
    private var updateScheduled = false

    init(dictation: DictationController, player: PlayerModel) {
        self.dictation = dictation
        reader = ReaderPill(model: player)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 56),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = FirstClickHostingView(rootView: PillView(state: state, dictation: dictation, player: player))
        dictation.objectWillChange.sink { [weak self] _ in self?.setNeedsUpdate() }.store(in: &observers)
        reader.objectWillChange.sink { [weak self] _ in self?.setNeedsUpdate() }.store(in: &observers)
    }

    /// Several things often change at once (a double-tap drops a dictation and starts a read):
    /// show only where they land.
    private func setNeedsUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async {
            self.updateScheduled = false
            self.update()
        }
    }

    /// Dictation comes first; reading shows when there's no dictation.
    private var mode: Mode? {
        switch dictation.state {
        case .recording: return dictation.isProvisional ? .armed : .dictating
        case .transcribing: return .transcribing
        case .downloading(let p): return .downloading(p)
        case .message(let text): return .message(text)
        case .idle: break
        }
        switch reader.phase {
        case .hidden: return nil
        case .finding: return .finding
        case .controls: return .reading
        case .hint(let text): return .message(text)
        }
    }

    /// `--slow-pill` plays the changes ten times slower, to check them.
    private static let slowMotion: Double = DebugScript.args.contains("--slow-pill") ? 10 : 1

    private func update() {
        let mode = self.mode
        guard mode != state.mode else { return }
        withAnimation(.spring(response: 0.34 * Self.slowMotion, dampingFraction: 0.86)) { state.mode = mode }
        panel.ignoresMouseEvents = mode != .reading
        guard mode != nil else {
            // Let it shrink away first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Self.slowMotion) { [weak self] in
                if self?.state.mode == nil { self?.panel.orderOut(nil) }
            }
            return
        }
        if !panel.isVisible {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            if let area = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: area.minY + 28))
            }
        }
        panel.orderFrontRegardless()
    }
}

/// What the pill shows for reading, as the reading shortcut asks.
final class ReaderPill: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case finding  // fetching the selection
        case controls  // play/pause and a playhead for the session
        case hint(String)  // e.g. nothing selected; clears itself
    }

    @Published private(set) var phase: Phase = .hidden
    private let model: PlayerModel
    private var timer: Timer?
    private var observer: AnyCancellable?

    init(model: PlayerModel) {
        self.model = model
        observer = model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.sessionChanged() }
    }

    func show(_ phase: Phase) {
        timer?.invalidate()
        timer = nil
        self.phase = phase
        switch phase {
        case .finding: hide(after: 3)  // in case the selection never arrives
        case .hint: hide(after: 2.5)
        default: break
        }
    }

    private func hide(after delay: TimeInterval) {
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.timer = nil
            self?.phase = .hidden
        }
    }

    /// The controls go when reading stops, and a moment after it finishes; paused, they stay.
    private func sessionChanged() {
        guard phase == .controls else { return }
        if !model.hasSession {
            show(.hidden)
        } else if model.isPlaying || !model.isAtEnd {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            hide(after: 1.5)
        }
    }
}

/// Clicks on the reading controls work straight away, without bringing Aloud forward first.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct PillView: View {
    @ObservedObject var state: OnScreenPill.State
    @ObservedObject var dictation: DictationController
    @ObservedObject var player: PlayerModel
    @Namespace private var space

    var body: some View {
        ZStack {
            if let mode = state.mode {
                // One shape that changes width; only what's inside it fades from one mode to the next.
                ZStack { content(mode) }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(minHeight: 40)
                    .background(Capsule().fill(Color.black.opacity(0.82)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
                    .clipShape(Capsule())
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func content(_ mode: OnScreenPill.Mode) -> some View {
        switch mode {
        case .armed:
            RecordDot()
                .matchedGeometryEffect(id: "dot", in: space)
                .frame(width: 40, height: 40)
        case .finding:
            Image(systemName: "play.fill")
                .matchedGeometryEffect(id: "play", in: space)
                .frame(width: 40, height: 40)
        case .dictating:
            HStack(spacing: 10) {
                RecordDot().matchedGeometryEffect(id: "dot", in: space)
                LevelBars(level: dictation.level)
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    Text(Self.elapsed(context.date.timeIntervalSince(dictation.startedAt)))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 16)
        case .transcribing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Transcribing…")
            }
            .padding(.horizontal, 16)
        case .downloading(let p):
            HStack(spacing: 10) {
                ProgressView(value: p).frame(width: 70).tint(.white)
                Text("Downloading dictation model · \(Int(p * 100))%").lineLimit(1)
            }
            .padding(.horizontal, 16)
        case .message(let text):
            Text(text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .fixedSize()  // as wide as the text, up to 360, then a second line
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
        case .reading:
            ReadingControls(model: player, space: space)
        }
    }

    static func elapsed(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct RecordDot: View {
    var body: some View {
        Circle().fill(Color.red).frame(width: 10, height: 10)
    }
}

/// Play/pause, a playhead to drag, the time left, and stop.
private struct ReadingControls: View {
    @ObservedObject var model: PlayerModel
    let space: Namespace.ID
    @State private var dragTime: Double?

    var body: some View {
        HStack(spacing: 10) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .matchedGeometryEffect(id: "play", in: space)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(model.isPlaying ? "Pause" : "Play")
            SeekBar(model: model, dragTime: $dragTime, played: .white, generated: .white.opacity(0.32),
                    track: .white.opacity(0.18), height: 4, knob: 11)
                .frame(height: 28)
            Text("-" + TimelineScrubber.format(max(0, model.duration - (dragTime ?? model.position))))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize()
            Button { model.stop() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.6))
            .help("Stop reading")
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .frame(width: 320)
    }
}

/// Live microphone level as a small row of bars, louder in the middle.
struct LevelBars: View {
    let level: Float
    private let weights: [Float] = [0.45, 0.7, 0.9, 1.0, 0.9, 0.7, 0.45]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.white)
                    .frame(width: 3, height: CGFloat(4 + 16 * min(1, level * weights[i] * 1.2)))
            }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
