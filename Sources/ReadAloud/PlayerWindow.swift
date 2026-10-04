import AppKit
import SwiftUI

/// A floating panel that doesn't steal focus from the app you're reading in.
final class PlayerPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let keyHandler, keyHandler(event) { return }
        super.sendEvent(event)
    }
}

final class PlayerWindowController: NSObject, NSWindowDelegate {
    let panel: PlayerPanel
    let model: PlayerModel

    init(model: PlayerModel) {
        self.model = model
        panel = PlayerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 330),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = "Read Aloud"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 380, height: 230)
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: PlayerView(model: model) { [weak self] in self?.close() })
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        if !panel.setFrameUsingName("PlayerPanel") {
            placeTopRight()
        }
        panel.setFrameAutosaveName("PlayerPanel")
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        if !panel.isVisible, !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
            placeTopRight()
        }
        panel.orderFrontRegardless()
    }

    func close() {
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        model.message = nil
    }

    private func placeTopRight() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.maxX - size.width - 20, y: area.maxY - size.height - 20))
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 49: model.togglePlay()                                          // space
        case 123: shift ? model.previousSentence() : model.skip(by: -15)     // ←
        case 124: shift ? model.nextSentence() : model.skip(by: 15)          // →
        case 53: close()                                                     // esc
        default: return false
        }
        return true
    }
}
