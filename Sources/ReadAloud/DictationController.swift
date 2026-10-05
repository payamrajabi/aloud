import AppKit
import AVFoundation

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

    private let player: PlayerModel
    private let trigger = DictationTrigger()
    private let recorder = Recorder()
    private let downloader = ModelDownloader()
    private let queue = DispatchQueue(label: "readaloud.dictation", qos: .userInitiated)
    private var engine: ParakeetEngine?   // only touched on `queue`
    private var pushToTalk = false
    private var resumeReadingAfter = false
    private var messageTimer: Timer?

    init(player: PlayerModel) {
        self.player = player
        recorder.onLevel = { [weak self] in self?.level = $0 }
        trigger.onTap = { [weak self] in self?.toggle() }
        trigger.onHoldBegan = { [weak self] in self?.holdBegan() }
        trigger.onHoldEnded = { [weak self] in self?.holdEnded() }
        trigger.onInterrupted = { [weak self] in
            // Right ⌘ held, then another key: it was a normal shortcut like ⌘C, so back out quietly.
            if self?.pushToTalk == true { self?.cancel(quietly: true) }
        }
        trigger.onEscape = { [weak self] in
            if self?.state == .recording { self?.cancel() }
        }
    }

    func start() {
        trigger.start()
        if ParakeetEngine.isInstalled { queue.async { _ = self.loadEngine() } }
    }

    func shortcutChanged() { trigger.start() }

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
        if state == .recording { finish() }
    }

    // MARK: - Recording

    private func begin(pushToTalk: Bool) {
        guard ParakeetEngine.isInstalled else {
            downloadModel()
            return
        }
        guard SelectionReader.isTrusted else {
            show("Turn on Accessibility for Read Aloud so it can type for you.")
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
                    if granted { self.show("Microphone ready. Press \(DictationShortcut.current.short) to dictate.") }
                    else { self.show("Read Aloud needs microphone access to dictate.") }
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
        // Don't talk over yourself: pause Read Aloud while dictating.
        resumeReadingAfter = player.isPlaying
        if resumeReadingAfter { player.pause() }
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
    }

    func cancel(quietly: Bool = false) {
        guard state == .recording else { return }
        if Self.dryRun { print("   dictation: cancel"); fflush(stdout); state = .idle; return }
        _ = recorder.stop()
        state = .idle
        if !quietly { NSSound(named: "Funk")?.play() }
        resumeReading()
    }

    private func finish() {
        if Self.dryRun { print("   dictation: stop and transcribe"); fflush(stdout); state = .idle; return }
        let samples = recorder.stop()
        NSSound(named: "Pop")?.play()
        guard samples.count > ParakeetEngine.sampleRate / 3 else {  // under ~0.3 s: nothing said
            state = .idle
            resumeReading()
            return
        }
        state = .transcribing
        let started = Date()
        queue.async {
            let text = self.loadEngine()?.transcribe(samples) ?? ""
            let seconds = Date().timeIntervalSince(started)
            DispatchQueue.main.async { self.deliver(text, audioSeconds: Double(samples.count) / 16_000, took: seconds) }
        }
    }

    private func deliver(_ raw: String, audioSeconds: Double, took: Double) {
        if DebugScript.args.contains("--trace") {
            print(String(format: "   dictation: %.1fs audio transcribed in %.2fs: %@", audioSeconds, took, raw))
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .idle
        resumeReading()
        guard !text.isEmpty else {
            show("Didn't catch that.")
            return
        }
        lastTranscript = text
        insert(text)
    }

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

    // MARK: - Model

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

    private func downloadModel() {
        guard !downloader.isRunning else { return }
        state = .downloading(0)
        downloader.download(ParakeetEngine.downloadURL, into: ParakeetEngine.modelsRoot) { [weak self] p in
            self?.state = .downloading(p)
        } completion: { [weak self] error in
            guard let self else { return }
            if let error {
                self.show("Download failed: \(error.localizedDescription)")
            } else {
                self.show("Dictation is ready. Press \(DictationShortcut.current.short) to start.")
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
