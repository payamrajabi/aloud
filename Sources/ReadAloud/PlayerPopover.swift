import AppKit
import SwiftUI

/// The player, shown as a dropdown under the menu bar icon.
final class PlayerPopover: NSObject, NSPopoverDelegate {
    let popover = NSPopover()
    private let model: PlayerModel
    private var keyMonitor: Any?

    init(model: PlayerModel, onMore: @escaping () -> Void) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PlayerView(model: model, onMore: onMore))
        popover.contentSize = NSSize(width: 420, height: 340)
    }

    var isShown: Bool { popover.isShown }

    func show(from button: NSStatusBarButton) {
        guard !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate()
        popover.contentViewController?.view.window?.makeKey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown, self.handleKey(event) else { return event }
            return nil
        }
    }

    func close() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 49: model.togglePlay()                                          // space
        case 123: shift ? model.previousSentence() : model.skip(by: -15)     // ←
        case 124: shift ? model.nextSentence() : model.skip(by: 15)          // →
        default: return false
        }
        return true
    }
}
