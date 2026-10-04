import SwiftUI

struct PlayerView: View {
    @ObservedObject var model: PlayerModel
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer()
                Text(model.hasSession ? "Sentence \(model.currentIndex + 1) of \(model.chunkRanges.count)" : "Read Aloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(height: 14)
            if model.hasSession {
                SentenceTextView(text: model.text, ranges: model.chunkRanges, current: model.currentIndex) {
                    model.jump(to: $0)
                }
                .frame(minHeight: 90)
                .background(RoundedRectangle(cornerRadius: 10).fill(.background.opacity(0.5)))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Spacer(minLength: 0)
                Text("Select text in any app and press \(Shortcut.current.display).")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }

            if let message = model.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TimelineScrubber(model: model)
            controls
        }
        .padding(.horizontal, 16)
        .padding(.top, 9)
        .padding(.bottom, 14)
        .frame(minWidth: 380, minHeight: 230)
        .background(.regularMaterial)
        .ignoresSafeArea()
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
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let width = geo.size.width
                let total = max(model.duration, 0.001)
                let shown = dragTime ?? model.position
                let x = CGFloat(shown / total) * width
                let barHeight: CGFloat = hovering || dragTime != nil ? 7 : 5
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    ForEach(Array(model.generatedSpans.enumerated()), id: \.offset) { _, span in
                        Rectangle()
                            .fill(Color.primary.opacity(0.18))
                            .frame(width: max(0, CGFloat((span.upperBound - span.lowerBound) / total) * width))
                            .offset(x: CGFloat(span.lowerBound / total) * width)
                    }
                    Rectangle().fill(Color.accentColor).frame(width: max(0, x))
                }
                .frame(height: barHeight)
                .clipShape(Capsule())
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(Color.white)
                        .shadow(radius: 1.5)
                        .frame(width: 13, height: 13)
                        .offset(x: max(0, min(x, width)) - 6.5)
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
            .frame(height: 16)

            HStack {
                Text(Self.format(dragTime ?? model.position))
                Spacer()
                if model.isBuffering {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("Generating…")
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
