import AppKit
import AVFoundation
import Phonemizer

/// Dictation: record the microphone, transcribe with Parakeet on this Mac,
/// and type the text into whatever app has focus.
final class DictationController: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(Double)
        case recording
        case transcribing
        case message(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var startedAt = Date()
    private(set) var lastTranscript: String?
    /// The last dictation as the engine heard it, before tech terms were fixed: the way
    /// back when the fixer got a word wrong.
    private(set) var lastHeard: String?
    /// 0…1 while the dictation model downloads, nil otherwise.
    @Published private(set) var modelProgress: Double?

    private let player: PlayerModel
    let shortcuts = ShortcutMonitor()
    private let recorder = Recorder()
    private let downloader = ModelDownloader()
    private let queue = DispatchQueue(label: "readaloud.dictation", qos: .userInitiated)
    private var engine: ParakeetEngine?   // only touched on `queue`
    private var pushToTalk = false
    private var resumeReadingAfter = false
    private var messageTimer: Timer?
    private lazy var streamer = StreamingTranscriber(queue: queue) { [weak self] in self?.loadEngine() }
    private var pollTimer: Timer?
    private var downloadProgress: Double = 0
    private var showDownload = false   // only show progress once someone has tried to dictate

    init(player: PlayerModel) {
        self.player = player
        recorder.onLevel = { [weak self] in self?.level = $0 }
        shortcuts.onDictate = { [weak self] in self?.toggle() }
        shortcuts.isRecording = { [weak self] in self?.state == .recording }
        shortcuts.onHoldBegan = { [weak self] in self?.holdBegan() }
        shortcuts.onHoldEnded = { [weak self] in self?.holdEnded() }
        shortcuts.onInterrupted = { [weak self] in
            // Right ⌘ held, then another key: it was a normal shortcut like ⌘C, so back out quietly.
            if self?.pushToTalk == true { self?.cancel(quietly: true) }
        }
        shortcuts.onCancel = { [weak self] in
            if self?.state == .recording { self?.cancel() }
        }
    }

    func start() {
        shortcuts.start()
        queue.async { _ = Self.corrector }
        if ParakeetEngine.isInstalled {
            queue.async { _ = self.loadEngine() }
        } else {
            // Fetch the dictation model quietly soon after first launch so it's
            // ready by the time someone tries it (unless they removed it in Settings).
            if !UserDefaults.standard.bool(forKey: Self.removedKey) { downloadModelInBackground(after: 8) }
        }
    }

    /// The voice comes first: wait for its download to finish before starting this one.
    private func downloadModelInBackground(after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if self.player.isDownloadingVoice {
                self.downloadModelInBackground(after: 5)
            } else {
                self.downloadModel(visible: false)
            }
        }
    }

    /// The reading shortcut.
    var onRead: (() -> Void)? {
        get { shortcuts.onRead }
        set { shortcuts.onRead = newValue }
    }

    /// "Double-tap right ⌥", for messages.
    private static var dictateInstruction: String {
        ShortcutAction.dictate.binding?.instruction ?? "Choose Dictate in the menu bar menu"
    }

    // MARK: - Triggers

    func toggle() {
        switch state {
        case .recording: finish()
        case .idle, .message: begin(pushToTalk: false)
        default: break
        }
    }

    private func holdBegan() {
        switch state {
        case .idle, .message: begin(pushToTalk: true)
        default: break
        }
    }

    private func holdEnded() {
        // A hold never ends a recording that a tap started; the next press of the key does.
        if state == .recording, pushToTalk { finish() }
    }

    // MARK: - Recording

    private func begin(pushToTalk: Bool) {
        guard ParakeetEngine.isInstalled else {
            // Already on its way (first launch): show progress. Otherwise ask before fetching 480 MB.
            if downloader.isRunning || DownloadPrompt.confirm(model: "dictation", size: "480 MB", feature: "Dictation") {
                downloadModel(visible: true)
            }
            return
        }
        guard SelectionReader.isTrusted else {
            show("Turn on Accessibility for Aloud so it can type for you.")
            SelectionReader.requestAccess()
            return
        }
        if Self.dryRun { startRecording(pushToTalk: pushToTalk); return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startRecording(pushToTalk: pushToTalk)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted { self.show("Microphone ready. \(Self.dictateInstruction) to dictate.") }
                    else { self.show("Aloud needs microphone access to dictate.") }
                }
            }
        default:
            show("Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone.")
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private static let dryRun = DebugScript.args.contains("--dry-dictation")

    private func startRecording(pushToTalk: Bool) {
        if Self.dryRun {
            print("   dictation: start (\(pushToTalk ? "hold to talk" : "tap to toggle"))"); fflush(stdout)
            self.pushToTalk = pushToTalk
            state = .recording
            return
        }
        // Don't talk over yourself: pause reading while dictating.
        resumeReadingAfter = player.isPlaying
        if resumeReadingAfter { player.pause() }
        streamer.reset()
        do {
            try recorder.start()
        } catch {
            show("Couldn't start the microphone: \(error.localizedDescription)")
            resumeReading()
            return
        }
        self.pushToTalk = pushToTalk
        level = 0
        startedAt = Date()
        messageTimer?.invalidate()
        state = .recording
        NSSound(named: "Tink")?.play()
        // Transcribe finished stretches while you're still talking.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.streamer.poll(available: self.recorder.sampleCount, read: self.recorder.read)
        }
    }

    func cancel(quietly: Bool = false) {
        guard state == .recording else { return }
        if Self.dryRun { print("   dictation: cancel"); fflush(stdout); state = .idle; return }
        pollTimer?.invalidate()
        _ = recorder.stop()
        streamer.reset()
        state = .idle
        if !quietly { NSSound(named: "Funk")?.play() }
        resumeReading()
    }

    private func finish() {
        if Self.dryRun { print("   dictation: stop and transcribe"); fflush(stdout); state = .idle; return }
        pollTimer?.invalidate()
        let samples = recorder.stop()
        NSSound(named: "Pop")?.play()
        guard samples.count > ParakeetEngine.sampleRate / 3 else {  // under ~0.3 s: nothing said
            streamer.reset()
            state = .idle
            resumeReading()
            return
        }
        state = .transcribing
        let started = Date()
        // Most of the recording is already transcribed; only the tail is left.
        streamer.finish(all: samples) { text, _ in
            self.deliver(text, audioSeconds: Double(samples.count) / 16_000, took: Date().timeIntervalSince(started))
        }
    }

    private func deliver(_ raw: String, audioSeconds: Double, took: Double) {
        let trace = DebugScript.args.contains("--trace")
        if trace {
            print(String(format: "   dictation: %.1fs recording, text ready %.2fs after stopping: %@", audioSeconds, took, raw))
        }
        let heard = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .idle
        resumeReading()
        guard !heard.isEmpty else {
            show("Didn't catch that.")
            return
        }
        let text = Self.fixesTechTerms ? Self.corrector.correct(heard) : heard
        if trace, text != heard { print("   dictation: tech terms fixed: \(text)") }
        lastTranscript = text
        lastHeard = heard
        insert(text)
    }

    // MARK: - Tech terms

    /// The Settings switch "Fix tech terms in dictation" (on unless it's been turned off).
    static let fixTechTermsKey = "fixTechTermsInDictation"
    static var fixesTechTerms: Bool { UserDefaults.standard.object(forKey: fixTechTermsKey) as? Bool ?? true }

    /// The lexicons in reverse ("super base" → Supabase). Built once, on the dictation
    /// queue at launch (a few tens of milliseconds for the full list).
    static let corrector = DictationCorrector(LexiconFiles.shared)

    private func resumeReading() {
        if resumeReadingAfter { player.play() }
        resumeReadingAfter = false
    }

    // MARK: - Typing the result

    /// Pastes into the focused app, then puts your clipboard back.
    private func insert(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = SelectionReader.snapshot(pasteboard)
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))  // tell clipboard managers to skip it
        pasteboard.writeObjects([item])
        let written = pasteboard.changeCount
        DispatchQueue.global(qos: .userInitiated).async {
            SelectionReader.waitForModifiersReleased()
            SelectionReader.postCommand(key: 9)  // ⌘V
            usleep(400_000)
            DispatchQueue.main.async {
                // Only restore if nothing else touched the clipboard in the meantime.
                if pasteboard.changeCount == written { SelectionReader.restore(pasteboard, saved) }
            }
        }
    }

    func copyLastTranscript() {
        guard let lastTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }

    /// Whether fixing tech terms changed the last dictation (so "as heard" is different).
    var lastDictationWasFixed: Bool { lastHeard != nil && lastHeard != lastTranscript }

    func copyLastHeard() {
        guard let lastHeard else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastHeard, forType: .string)
    }

    // MARK: - Model

    /// Set when someone removes the model in Settings: it's then fetched only when they next dictate.
    private static let removedKey = "dictationModelRemoved"

    /// Dictating right now: the model can't be removed until it's done.
    var isBusy: Bool { state == .recording || state == .transcribing }

    /// From Settings: download without the HUD; Settings shows the progress.
    func downloadModelNow() { downloadModel(visible: false) }

    func removeModel() {
        guard ParakeetEngine.isInstalled, !isBusy else { return }
        UserDefaults.standard.set(true, forKey: Self.removedKey)
        queue.async {
            self.engine = nil
            try? FileManager.default.removeItem(at: ParakeetEngine.modelDirectory)
            DispatchQueue.main.async { self.objectWillChange.send() }
        }
    }

    private func loadEngine() -> ParakeetEngine? {
        if let engine { return engine }
        do {
            engine = try ParakeetEngine()
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { self.show(message) }
        }
        return engine
    }

    private func downloadModel(visible: Bool) {
        if visible {
            showDownload = true
            state = .downloading(downloadProgress)
        }
        guard !downloader.isRunning, !ParakeetEngine.isInstalled else { return }
        downloadProgress = 0
        modelProgress = 0
        downloader.download(ParakeetEngine.downloadURL, into: ModelStore.root) { [weak self] p in
            guard let self else { return }
            self.downloadProgress = p
            self.modelProgress = p
            if self.showDownload { self.state = .downloading(p) }
        } completion: { [weak self] error in
            guard let self else { return }
            let wasShown = self.showDownload
            self.showDownload = false
            self.modelProgress = nil
            if DebugScript.args.contains("--trace") {
                print("   dictation: model download finished, error: \(error?.localizedDescription ?? "none"), installed: \(ParakeetEngine.isInstalled)")
                fflush(stdout)
            }
            if let error {
                if wasShown { self.show("Download failed: \(error.localizedDescription)") }
            } else {
                UserDefaults.standard.removeObject(forKey: Self.removedKey)
                if wasShown { self.show("Dictation is ready. \(Self.dictateInstruction) to start.") }
                self.queue.async { _ = self.loadEngine() }
            }
        }
    }

    private func show(_ message: String) {
        state = .message(message)
        messageTimer?.invalidate()
        messageTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            if case .message = self?.state { self?.state = .idle }
        }
    }

    // MARK: - Debug

    func debugSet(_ s: State) {
        state = s
        level = 0.75
        startedAt = Date().addingTimeInterval(-7)
    }

    func debugTranscribe(_ samples: [Float]) -> String {
        loadEngine()?.transcribe(samples) ?? ""
    }
}
