import SwiftUI

struct PlayerView: View {
    @ObservedObject var model: PlayerModel
    var onMore: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text(model.hasSession ? "Sentence \(model.currentIndex + 1) of \(model.chunkRanges.count)" : "Aloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if model.hasSession {
                    Button { model.stop() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Stop reading")
                }
                Button(action: onMore) {
                    Image(systemName: "ellipsis.circle").font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Settings")
            }
            .frame(height: 16)
            if model.hasSession {
                SentenceTextView(text: model.text, ranges: model.chunkRanges, current: model.currentIndex) {
                    model.jump(to: $0)
                }
                .frame(minHeight: 90)
                .mask(
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.06),
                        .init(color: .black, location: 0.86),
                        .init(color: .clear, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                )
            } else {
                WelcomeView()
            }

            if let progress = model.voiceDownloadProgress, model.hasSession {
                VoiceDownloadRow(progress: progress, waiting: true)
            }

            if let message = model.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let progress = model.voiceDownloadProgress, !model.hasSession {
                VoiceDownloadRow(progress: progress, waiting: false)  // in the empty timeline's place
            } else {
                TimelineScrubber(model: model)
            }
            controls
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(width: 420, height: 340)
    }

    private var controls: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5], id: \.self) { r in
                    Button(Self.rateLabel(Float(r))) { model.setRate(Float(r)) }
                }
            } label: {
                Text(Self.rateLabel(model.rate)).monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Playback speed")

            Spacer()

            iconButton("backward.end.fill", help: "Previous sentence (⇧←)") { model.previousSentence() }
            iconButton("gobackward.15", help: "Back 15 seconds (←)") { model.skip(by: -15) }
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 38))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(!model.hasSession)
            .help("Play / pause (space)")
            iconButton("goforward.15", help: "Forward 15 seconds (→)") { model.skip(by: 15) }
            iconButton("forward.end.fill", help: "Next sentence (⇧→)") { model.nextSentence() }

            Spacer()

            Menu {
                ForEach(Voice.all) { v in
                    Button {
                        model.setVoice(v)
                    } label: {
                        if v == model.voice { Label(v.menuTitle, systemImage: "checkmark") } else { Text(v.menuTitle) }
                    }
                }
            } label: {
                Text(model.voice.name)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Voice")
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.hasSession)
        .help(help)
    }

    static func rateLabel(_ r: Float) -> String {
        let s = String(format: "%g", r)
        return "\(s)×"
    }
}

extension Voice {
    var menuTitle: String {
        "\(name) — \(accent == .british ? "British" : "American")"
    }
}

/// Timeline with played, generated and remaining portions, draggable to seek.
struct TimelineScrubber: View {
    @ObservedObject var model: PlayerModel
    @State private var dragTime: Double?

    var body: some View {
        VStack(spacing: 4) {
            SeekBar(model: model, dragTime: $dragTime)
                .frame(height: 16)

            HStack {
                Text(Self.format(dragTime ?? model.position))
                Spacer()
                if model.isBuffering {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text(model.isDownloadingVoice ? "Waiting for the voice…" : "Generating…")
                    }
                }
                Spacer()
                Text("-" + Self.format(max(0, model.duration - (dragTime ?? model.position))))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The bar itself: played, generated and remaining portions, and a knob to drag. `dragTime` is
/// where the knob is while it's dragged.
struct SeekBar: View {
    @ObservedObject var model: PlayerModel
    @Binding var dragTime: Double?
    var played = Color.accentColor
    var generated = Color.primary.opacity(0.18)
    var track = Color.primary.opacity(0.10)
    var height: CGFloat = 5  // 2 more while hovered or dragged
    var knob: CGFloat = 13
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let total = max(model.duration, 0.001)
            let shown = dragTime ?? model.position
            let x = CGFloat(shown / total) * width
            let barHeight = hovering || dragTime != nil ? height + 2 : height
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                ForEach(Array(model.generatedSpans.enumerated()), id: \.offset) { _, span in
                    Rectangle()
                        .fill(generated)
                        .frame(width: max(0, CGFloat((span.upperBound - span.lowerBound) / total) * width))
                        .offset(x: CGFloat(span.lowerBound / total) * width)
                }
                Rectangle().fill(played).frame(width: max(0, x))
            }
            .frame(height: barHeight)
            .clipShape(Capsule())
            .overlay(alignment: .leading) {
                Circle()
                    .fill(Color.white)
                    .shadow(radius: 1.5)
                    .frame(width: knob, height: knob)
                    .offset(x: max(0, min(x, width)) - knob / 2)
                    .opacity(model.hasSession ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard model.hasSession else { return }
                        dragTime = Double(max(0, min(g.location.x, width)) / width) * total
                    }
                    .onEnded { _ in
                        if let t = dragTime { model.seek(to: t) }
                        dragTime = nil
                    }
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: barHeight)
        }
    }
}

/// First run: the voice model is downloading in the background.
struct VoiceDownloadRow: View {
    let progress: Double
    let waiting: Bool   // someone already asked to read

    var body: some View {
        let percent = Int((progress * 100).rounded(.down))
        VStack(alignment: .leading, spacing: 5) {
            Text(waiting
                 ? "Downloading the voice… \(percent)%. Reading starts as soon as it's ready."
                 : "Downloading the voice (about 330 MB, once)… \(percent)%")
                .font(.callout)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shown when nothing is being read: how to use the app, and the one permission it needs.
struct WelcomeView: View {
    @State private var trusted = SelectionReader.isTrusted
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer(minLength: 0)
            Label {
                Text(LocalizedStringKey(Self.readText))
            } icon: {
                Image(systemName: "text.cursor")
            }
            Label {
                Text(LocalizedStringKey(Self.dictateText))
            } icon: {
                Image(systemName: "mic")
            }
            Label {
                Text("Everything runs in the background. Click the bars in the menu bar to see this player.")
            } icon: {
                Image(systemName: "menubar.arrow.up.rectangle")
            }
            if trusted {
                Label("Accessibility access is on.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text("Aloud needs **Accessibility** access to see the text you select and type what you dictate.")
                    } icon: {
                        Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    }
                    Button("Open Accessibility Settings") {
                        SelectionReader.requestAccess()
                        SelectionReader.openAccessibilitySettings()
                    }
                    .controlSize(.large)
                    .padding(.leading, 28)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(poll) { _ in trusted = SelectionReader.isTrusted }
    }

    /// "double-tap **left ⌥**", "press **⌃⌥R**", "tap **right ⌥**".
    private static func phrase(_ binding: KeyBinding) -> String {
        switch binding {
        case .combo: return "press **\(binding.display)**"
        case .tap(let key): return "tap **\(key.name)**"
        case .doubleTap(let key): return "double-tap **\(key.name)**"
        }
    }

    private static var readText: String {
        guard let binding = ShortcutAction.read.binding else {
            return "Select text in any app, then choose Read Selection from the menu bar icon. Set a shortcut in Settings."
        }
        let pause = binding.modifierKey == nil ? "Press it again to pause." : "Pause with the controls that appear, or your AirPods."
        return "Select text in any app, then \(phrase(binding)). \(pause)"
    }

    private static var dictateText: String {
        let typed = "Your words are typed wherever your cursor is."
        guard let start = ShortcutAction.dictate.binding else {
            return "To dictate, choose Dictate from the menu bar icon. \(typed)"
        }
        let key = start.modifierKey, end = ShortcutAction.finishDictation.binding
        let finish: String
        if end == start {
            finish = key == nil ? "press it again" : "tap it again"
        } else if let key, end == .tap(key) {
            finish = "tap it once"
        } else if let end {
            finish = phrase(end)
        } else {
            finish = "choose Dictate again from the menu bar icon"
        }
        let hold = key == nil ? "" : " (or hold it while you talk)"
        return "To dictate, \(phrase(start)), speak, and \(finish) to finish\(hold). \(typed)"
    }
}
