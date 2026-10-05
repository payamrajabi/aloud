import AppKit
import Combine
import SwiftUI

/// The small pill near the bottom of the screen while dictating.
final class DictationHUD {
    let panel: NSPanel
    private var observer: AnyCancellable?

    init(controller: DictationController) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 56),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: DictationPill(controller: controller))
        observer = controller.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.update(for: state) }
    }

    private func update(for state: DictationController.State) {
        if state == .idle {
            panel.orderOut(nil)
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

struct DictationPill: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: controller.state)
    }

    @ViewBuilder private var content: some View {
        switch controller.state {
        case .recording:
            Circle().fill(Color.red).frame(width: 8, height: 8)
            LevelBars(level: controller.level)
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Text(Self.elapsed(context.date.timeIntervalSince(controller.startedAt)))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
            }
        case .transcribing:
            ProgressView().controlSize(.small).tint(.white)
            Text("Transcribing…")
        case .downloading(let p):
            ProgressView(value: p).frame(width: 70).tint(.white)
            Text("Downloading dictation model · \(Int(p * 100))%").lineLimit(1)
        case .message(let text):
            Text(text).lineLimit(2).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        case .idle:
            EmptyView()
        }
    }

    static func elapsed(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
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
