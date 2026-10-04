import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = PlayerModel()
    private lazy var player = PlayerWindowController(model: model)
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var accessibilityTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        registerHotKey()
        model.preload()
        enableLoginItemOnFirstLaunch()
        if !SelectionReader.isTrusted && !DebugScript.isActive {
            SelectionReader.requestAccess()
        }
        DebugScript.run(model: model, player: player)
    }

    // MARK: - Reading

    @objc func readSelection() {
        guard SelectionReader.isTrusted else {
            model.message = "Read Aloud needs Accessibility access to read your selection. Turn it on in System Settings → Privacy & Security → Accessibility, then try again."
            player.show()
            SelectionReader.requestAccess()
            return
        }
        SelectionReader.read { [weak self] text in
            guard let self else { return }
            let selection = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !selection.isEmpty {
                let same = selection == self.model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
                if same && self.model.hasSession && self.player.isVisible {
                    self.model.togglePlay()
                } else {
                    self.model.load(selection)
                }
                self.player.show()
            } else if self.model.hasSession {
                self.model.togglePlay()
                self.player.show()
            } else {
                NSSound.beep()
            }
        }
    }

    @objc private func showPlayer() { player.show() }

    // MARK: - Shortcut

    private func registerHotKey() {
        hotKey = nil
        let shortcut = Shortcut.current
        hotKey = HotKey(shortcut) { [weak self] in self?.readSelection() }
        if hotKey == nil {
            model.message = "The shortcut \(shortcut.display) is already used by another app. Pick a different one from the menu bar icon."
        }
    }

    @objc private func chooseShortcut(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        UserDefaults.standard.set(id, forKey: "shortcut")
        registerHotKey()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Read Aloud")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let shortcut = Shortcut.current

        let read = NSMenuItem(title: "Read Selection  (\(shortcut.display))", action: #selector(readSelection), keyEquivalent: "")
        read.target = self
        menu.addItem(read)
        let show = NSMenuItem(title: "Show Player", action: #selector(showPlayer), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())

        let voices = NSMenu()
        for v in Voice.all {
            let item = NSMenuItem(title: v.menuTitle, action: #selector(chooseVoice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = v.key
            item.state = v == model.voice ? .on : .off
            voices.addItem(item)
        }
        menu.addItem(submenu("Voice", voices))

        let speeds = NSMenu()
        for r: Float in [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5] {
            let item = NSMenuItem(title: PlayerView.rateLabel(r), action: #selector(chooseSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = r
            item.state = r == model.rate ? .on : .off
            speeds.addItem(item)
        }
        menu.addItem(submenu("Speed", speeds))

        let shortcuts = NSMenu()
        for s in Shortcut.presets {
            let item = NSMenuItem(title: s.display, action: #selector(chooseShortcut(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.id
            item.state = s == shortcut ? .on : .off
            shortcuts.addItem(item)
        }
        menu.addItem(submenu("Shortcut", shortcuts))
        menu.addItem(.separator())

        let trusted = SelectionReader.isTrusted
        let access = NSMenuItem(title: trusted ? "Accessibility Access: On" : "Grant Accessibility Access…",
                                action: trusted ? nil : #selector(grantAccess), keyEquivalent: "")
        access.target = self
        access.isEnabled = !trusted
        menu.addItem(access)

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Read Aloud", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc private func chooseVoice(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        model.setVoice(Voice.with(key: key))
    }

    @objc private func chooseSpeed(_ sender: NSMenuItem) {
        guard let r = sender.representedObject as? Float else { return }
        model.setRate(r)
    }

    @objc private func grantAccess() {
        SelectionReader.requestAccess()
        SelectionReader.openAccessibilitySettings()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            model.message = "Couldn't change the login setting: \(error.localizedDescription)"
            player.show()
        }
    }

    private func enableLoginItemOnFirstLaunch() {
        let key = "didOfferLoginItem"
        guard Bundle.main.bundleIdentifier != nil, !DebugScript.isActive,
              !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }
}
