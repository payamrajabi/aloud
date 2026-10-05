import AppKit
import Combine
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = PlayerModel()
    private(set) lazy var player = PlayerPopover(model: model) { [weak self] in self?.showSettingsMenu() }
    private var statusItem: NSStatusItem!
    private let iconView = StatusIconView()
    private let settingsMenu = NSMenu()
    private var hotKey: HotKey?
    private var nowPlaying: NowPlaying?
    private lazy var dictation = DictationController(player: model)
    private(set) var dictationHUD: DictationHUD?
    private var observers: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        registerHotKey()
        nowPlaying = NowPlaying(model: model)
        dictationHUD = DictationHUD(controller: dictation)
        dictation.start()
        model.preload()
        enableLoginItemOnFirstLaunch()
        if !DebugScript.isActive {
            if !UserDefaults.standard.bool(forKey: "didWelcome") {
                // First launch: open the player so people see where it lives and how to start.
                UserDefaults.standard.set(true, forKey: "didWelcome")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.showPlayer() }
            } else if !SelectionReader.isTrusted {
                SelectionReader.requestAccess()
            }
        }
        DebugScript.run(model: model, app: self)
    }

    // MARK: - Reading

    @objc func readSelection() {
        guard SelectionReader.isTrusted else {
            model.message = "Read Aloud needs Accessibility access to read your selection. Turn it on in System Settings → Privacy & Security → Accessibility, then try again."
            showPlayer()
            SelectionReader.requestAccess()
            return
        }
        // Reads in the background; the player only opens from the menu bar icon.
        SelectionReader.read { [weak self] text in
            guard let self else { return }
            let selection = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let current = self.model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !selection.isEmpty && !(selection == current && self.model.hasSession) {
                self.model.load(selection)
                if self.model.message != nil && !self.model.hasSession { self.showPlayer() }
            } else if self.model.hasSession {
                self.model.togglePlay()
            } else {
                NSSound.beep()
            }
        }
    }

    var statusButton: NSStatusBarButton? { statusItem.button }

    @objc func showPlayer() {
        guard let button = statusItem.button else { return }
        player.show(from: button)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showSettingsMenu()
        } else if player.isShown {
            player.close()
        } else {
            showPlayer()
        }
    }

    private func showSettingsMenu() {
        player.close()
        guard let button = statusItem.button else { return }
        statusItem.menu = settingsMenu      // attach briefly so the menu drops from the icon
        button.performClick(nil)
        statusItem.menu = nil
    }

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
        statusItem = NSStatusBar.system.statusItem(withLength: 26)
        guard let button = statusItem.button else { return }
        button.setAccessibilityLabel("Read Aloud")
        button.toolTip = "Read Aloud — click for the player, right-click for settings"
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        iconView.frame = button.bounds
        iconView.autoresizingMask = [.width, .height]
        button.addSubview(iconView)
        settingsMenu.delegate = self

        // Reflect playback state in the icon.
        Publishers.CombineLatest3(model.$isPlaying, model.$isBuffering, model.$chunkRanges)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.iconView.status = self.model.status
            }
            .store(in: &observers)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let shortcut = Shortcut.current

        let read = NSMenuItem(title: "Read Selection  (\(shortcut.display))", action: #selector(readSelection), keyEquivalent: "")
        read.target = self
        menu.addItem(read)
        let show = NSMenuItem(title: "Show Player", action: #selector(showPlayer), keyEquivalent: "")
        show.isEnabled = true
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

        let dictate = NSMenuItem(title: "Dictate  (\(DictationShortcut.current.short))", action: #selector(toggleDictation), keyEquivalent: "")
        dictate.target = self
        menu.addItem(dictate)
        let dictationShortcuts = NSMenu()
        for option in DictationShortcut.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(chooseDictationShortcut(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == DictationShortcut.current ? .on : .off
            dictationShortcuts.addItem(item)
        }
        menu.addItem(submenu("Dictation Shortcut", dictationShortcuts))
        let copyLast = NSMenuItem(title: "Copy Last Dictation", action: dictation.lastTranscript == nil ? nil : #selector(copyLastDictation), keyEquivalent: "")
        copyLast.target = self
        menu.addItem(copyLast)
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

    @objc private func toggleDictation() { dictation.toggle() }

    @objc private func copyLastDictation() { dictation.copyLastTranscript() }

    @objc private func chooseDictationShortcut(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        UserDefaults.standard.set(id, forKey: "dictationShortcut")
        dictation.shortcutChanged()
    }

    var dictationController: DictationController { dictation }

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
            showPlayer()
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
