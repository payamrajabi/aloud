import AppKit
import Combine
import ServiceManagement
import Sparkle
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, SPUStandardUserDriverDelegate,
                         UNUserNotificationCenterDelegate {
    private let model = PlayerModel()
    private(set) lazy var player = PlayerPopover(model: model) { [weak self] in self?.showSettingsMenu() }
    private var statusItem: NSStatusItem!
    private let iconView = StatusIconView()
    private let settingsMenu = NSMenu()
    private var nowPlaying: NowPlaying?
    private lazy var dictation = DictationController(player: model)
    private(set) var pill: OnScreenPill?
    private var observers: Set<AnyCancellable> = []
    private var updater: SPUStandardUpdaterController?
    /// A newer version Sparkle found on its daily check, until the person deals with it.
    private var availableUpdate: String?
    private static let updateNotificationID = "aloud-update"
    private(set) lazy var settings = SettingsWindow(player: model, dictation: dictation)

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        nowPlaying = NowPlaying(model: model)
        pill = OnScreenPill(dictation: dictation, player: model)
        // A key combination pauses on a second press, like before; a modifier tap only starts or resumes.
        dictation.onRead = { [weak self] in self?.readSelection(pausing: ShortcutAction.read.binding?.modifierKey == nil) }
        dictation.start()
        reportUnavailableShortcuts()
        dictation.shortcuts.$unavailable.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reportUnavailableShortcuts() }
            .store(in: &observers)
        model.preload()
        setUpUpdater()
        if DebugScript.isActive {
            finishLaunching(after: LegacyAppCleanup.Outcome())
        } else {
            // Quit and trash an old Read Aloud first: it may hold the shortcut, the login
            // item and the voice model we'd otherwise download.
            LegacyAppCleanup.run { [weak self] in self?.finishLaunching(after: $0) }
        }
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

    func applicationWillTerminate(_ notification: Notification) {
        // Metal aborts at exit if the language model's buffers are still alive.
        dictation.shutDown()
    }

    private func finishLaunching(after cleanup: LegacyAppCleanup.Outcome) {
        if Synthesizer.trace {
            print("   cleanup: trashed \(cleanup.trashed.map(\.path)), failed \(cleanup.failed.map(\.path)), quit others: \(cleanup.terminatedOthers), moved voice: \(cleanup.migratedVoice)")
            fflush(stdout)
        }
        if cleanup.terminatedOthers {
            dictation.shortcuts.start()  // the old app may have been holding a shortcut
        }
        if !cleanup.failed.isEmpty {
            model.message = "An older copy of Aloud is still installed. Drag “\(cleanup.failed[0].deletingPathExtension().lastPathComponent)” from Applications to the Trash."
        }
        enableLoginItemOnFirstLaunch()
        moveLoginItemIfRenamed(force: !cleanup.trashed.isEmpty)
        if cleanup.migratedVoice { model.preload() }
        // Fetch the voice soon after first launch so it's usually ready by the first read
        // (unless it was removed in Settings; then it downloads when someone next reads).
        guard !UserDefaults.standard.bool(forKey: PlayerModel.voiceRemovedKey) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.model.downloadVoiceIfNeeded() }
    }

    // MARK: - Updates

    private func setUpUpdater() {
        // Only real app builds (with a feed in Info.plist) check for updates.
        guard !DebugScript.isActive, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        UNUserNotificationCenter.current().delegate = self
        if DebugScript.args.contains("--test-update-notice") {
            // Developer check of the notification: a background check long enough after launch to count as "later".
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.updater?.updater.checkForUpdatesInBackground() }
        }
    }

    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updater?.checkForUpdates(nil)
    }

    /// A menu bar app has no Dock icon to badge, so let Sparkle remind people gently.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Right after launch Sparkle shows its own window; later in the day a window popping up
    /// out of nowhere would be rude, so we post a notification instead.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !state.userInitiated else { return }
        availableUpdate = update.displayVersionString
        if !handleShowingUpdate { postUpdateNotification(version: update.displayVersionString) }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.updateNotificationID])
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableUpdate = nil
    }

    private func postUpdateNotification(version: String) {
        let center = UNUserNotificationCenter.current()
        // Asked the first time there's an update, not at launch, so the request makes sense.
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Aloud \(version) is available"
            content.body = "Click to see what's new and install it. It only takes a moment."
            center.add(UNNotificationRequest(identifier: Self.updateNotificationID, content: content, trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier == Self.updateNotificationID {
            DispatchQueue.main.async { self.checkForUpdates() }  // brings the waiting update forward
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])  // a menu bar app always counts as "in front"
    }

    // MARK: - Reading

    /// `pausing`: the same (or no) selection pauses a playing session. Modifier taps only ever start or resume.
    func readSelection(pausing: Bool = true) {
        guard SelectionReader.isTrusted else {
            model.message = "Aloud needs Accessibility access to read your selection. Turn it on in System Settings → Privacy & Security → Accessibility, then try again."
            showPlayer()
            SelectionReader.requestAccess()
            return
        }
        let pill = self.pill?.reader
        pill?.show(.finding)
        // Reads in the background, with controls in the on-screen pill; the player only opens from the menu bar icon.
        SelectionReader.read { [weak self] text in
            guard let self else { return }
            let selection = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let current = self.model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !selection.isEmpty && !(selection == current && self.model.hasSession) {
                // The voice was removed (or never finished downloading): ask before fetching 330 MB.
                if !KokoroEngine.isModelInstalled, !self.model.isDownloadingVoice,
                   !DownloadPrompt.confirm(model: "the voice", size: "330 MB", feature: "Reading aloud") {
                    pill?.show(.hidden)
                    return
                }
                self.model.load(selection)
                pill?.show(self.model.hasSession ? .controls : .hint(self.model.message ?? "There's nothing to read in that selection."))
                // Show the voice's download progress when reading has to wait for it.
                if self.model.isDownloadingVoice { self.showPlayer() }
            } else if self.model.hasSession, !selection.isEmpty || !self.model.isAtEnd {
                pausing ? self.model.togglePlay() : self.model.play()
                pill?.show(.controls)
            } else {
                pill?.show(.hint("Select some text to read aloud."))
            }
        }
    }

    @objc private func readSelectionFromMenu() { readSelection() }

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

    // MARK: - Shortcuts and settings

    /// Says so in the player when another app holds one of the shortcuts.
    private func reportUnavailableShortcuts() {
        let taken = ShortcutAction.allCases.filter { dictation.shortcuts.unavailable.contains($0) }
        if let action = taken.first {
            model.message = "The shortcut \(action.hint) is already used by another app. Pick a different one in Settings."
        } else if model.message?.hasPrefix("The shortcut") == true {
            model.message = nil
        }
    }

    @objc func showSettings() {
        player.close()
        settings.show()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: 26)
        guard let button = statusItem.button else { return }
        button.setAccessibilityLabel("Aloud")
        button.toolTip = "Aloud — click for the player, right-click for settings"
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        iconView.frame = button.bounds
        iconView.autoresizingMask = [.width, .height]
        button.addSubview(iconView)
        settingsMenu.delegate = self

        // Reflect playback and dictation in the icon; dictation wins while it's active.
        Publishers.CombineLatest(
            Publishers.CombineLatest3(model.$isPlaying, model.$isBuffering, model.$chunkRanges),
            dictation.$state
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] _, dictationState in
                guard let self else { return }
                let state: StatusIconView.State
                switch dictationState {
                case .recording: state = .listening
                case .transcribing: state = .transcribing
                case .downloading: state = .preparing
                case .idle, .message:
                    switch self.model.status {
                    case .loading: state = .preparing
                    case .playing: state = .speaking
                    case .paused: state = .paused
                    case .idle: state = .idle
                    }
                }
                self.iconView.state = state
                self.statusItem.button?.setAccessibilityValue(state.label)
            }
            .store(in: &observers)

        // Bars follow the mic while listening, the spoken audio otherwise.
        Publishers.CombineLatest(dictation.$level, model.$outputLevel)
            .receive(on: RunLoop.main)
            .sink { [weak self] mic, output in
                guard let self else { return }
                self.iconView.level = self.iconView.state == .listening ? mic : output
            }
            .store(in: &observers)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let read = NSMenuItem(title: "Read Selection", action: #selector(readSelectionFromMenu), keyEquivalent: "")
        if let binding = ShortcutAction.read.binding { read.title += "  (\(binding.display))" }
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
        menu.addItem(.separator())

        let dictate = NSMenuItem(title: "Dictate", action: #selector(toggleDictation), keyEquivalent: "")
        if let binding = ShortcutAction.dictate.binding { dictate.title += "  (\(binding.display))" }
        dictate.target = self
        menu.addItem(dictate)
        let copyLast = NSMenuItem(title: "Copy Last Dictation", action: dictation.lastTranscript == nil ? nil : #selector(copyLastDictation), keyEquivalent: "")
        copyLast.target = self
        menu.addItem(copyLast)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
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
        let update = NSMenuItem(title: availableUpdate.map { "Update to Aloud \($0)…" } ?? "Check for Updates…",
                                action: updater == nil ? nil : #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Aloud", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc private func toggleDictation() { dictation.toggle() }

    @objc private func copyLastDictation() { dictation.copyLastTranscript() }

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

    /// Read Aloud.app became Aloud.app: point an existing login item at the new app.
    /// `force`: an old copy was just trashed, so the login item may still point at it.
    private func moveLoginItemIfRenamed(force: Bool = false) {
        let key = "loginItemPath", path = Bundle.main.bundlePath
        guard !DebugScript.isActive, force || UserDefaults.standard.string(forKey: key) != path else { return }
        UserDefaults.standard.set(path, forKey: key)
        let service = SMAppService.mainApp
        guard service.status == .enabled else { return }
        try? service.unregister()
        try? service.register()
    }
}
