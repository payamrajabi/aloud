import AppKit
import CoreAudio
import SwiftUI
import UniformTypeIdentifiers

/// The Settings window: shortcuts, preferred speakers and microphones, and downloads, on one page.
final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let player: PlayerModel
    private let dictation: DictationController
    let recorder = ShortcutRecorder()
    private var keyMonitor: Any?

    init(player: PlayerModel, dictation: DictationController) {
        self.player = player
        self.dictation = dictation
        super.init()
        recorder.setSuspended = { [weak dictation] in dictation?.shortcuts.isSuspended = $0 }
    }

    var contentView: NSView? { window?.contentView }

    func show() {
        if window == nil {
            let view = SettingsView(player: player, dictation: dictation, monitor: dictation.shortcuts, recorder: recorder)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 930),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Aloud Settings"
            window.contentView = NSHostingView(rootView: view)
            window.contentMinSize = NSSize(width: 500, height: 420)
            window.contentMaxSize = NSSize(width: 500, height: 2_000)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("AloudSettings")
            if !window.setFrameUsingName("AloudSettings") { window.center() }
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // A menu bar app has no Edit or Window menu, so handle ⌘W here.
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, window.isKeyWindow, self.recorder.action == nil,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers == "w"
                else { return event }
                window.performClose(nil)
                return nil
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        recorder.end()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

struct SettingsView: View {
    @ObservedObject var player: PlayerModel
    @ObservedObject var dictation: DictationController
    @ObservedObject var monitor: ShortcutMonitor
    @ObservedObject var recorder: ShortcutRecorder
    @ObservedObject private var devices = AudioDevices.shared
    @State private var shortcutsVersion = 0  // bumps when shortcuts change, to redraw the fields
    @AppStorage(DictationController.fixTechTermsKey) private var fixTechTerms = true

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases) { action in
                    ShortcutRow(action: action, recorder: recorder, unavailable: monitor.unavailable.contains(action))
                }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Click a shortcut, then press a key combination, or tap or double-tap a modifier key such as ⌥, ⌘ or fn.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 16)
                    Button("Restore Defaults") {
                        recorder.end()
                        ShortcutAction.restoreDefaults()
                    }
                    .disabled(ShortcutAction.allCases.allSatisfy { $0.binding == $0.defaultBinding })
                }
            }
            .id(shortcutsVersion)

            DeviceSection(direction: .output, devices: devices)
            DeviceSection(direction: .input, devices: devices)

            Section {
                Toggle("Fix tech terms in dictation", isOn: $fixTechTerms)
            } header: {
                Text("Dictation")
            } footer: {
                Text("Types names like GitHub, Supabase and kubectl the way they're spelled, even when they sound like ordinary words. Words such as “gooey” or “back end” are only changed when you're clearly talking tech.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                ModelRow(title: "Voice", detail: "Reads text aloud · about \(KokoroEngine.downloadSize)", symbol: "waveform",
                         installed: KokoroEngine.isModelInstalled, progress: player.voiceDownloadProgress,
                         canRemove: player.canRemoveVoice, busy: false,
                         download: { player.downloadVoiceIfNeeded() }, remove: { player.removeVoice() })
                ModelRow(title: "Dictation", detail: "Turns speech into text · about 480 MB", symbol: "mic",
                         installed: ParakeetEngine.isInstalled, progress: dictation.modelProgress,
                         canRemove: ParakeetEngine.isInstalled, busy: dictation.isBusy,
                         download: { dictation.downloadModelNow() }, remove: { dictation.removeModel() })
                ModelRow(title: "Clean-up",
                         detail: "Tidies dictation as you speak · about \(TranscriptCleaner.downloadSize)"
                             + (TranscriptCleaner.hasRecommendedMemory ? "" : " · best with 16 GB of memory"),
                         symbol: "text.badge.checkmark",
                         installed: TranscriptCleaner.isInstalled, progress: dictation.cleanupProgress,
                         canRemove: TranscriptCleaner.isInstalled, busy: dictation.isCleanupBusy,
                         download: { dictation.downloadCleanupModel() }, remove: { dictation.removeCleanupModel() },
                         afterRemoving: "Dictation will go back to typing what Aloud heard, with only basic tidying. It won't download again unless you click Download here.")
            } header: {
                Text("Downloads")
            } footer: {
                Text("All three run entirely on your Mac. Voice and dictation download automatically the first time Aloud opens; Aloud asks before downloading them again if you remove one. Clean-up is optional and only downloads when you click Download: it fixes punctuation and drops ums, repeats and false starts while you talk. Remove it to go back to exactly what was heard.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .frame(minHeight: 420)
        .onReceive(NotificationCenter.default.publisher(for: .shortcutsChanged)) { _ in shortcutsVersion += 1 }
    }
}

// MARK: - Shortcuts

private struct ShortcutRow: View {
    let action: ShortcutAction
    @ObservedObject var recorder: ShortcutRecorder
    let unavailable: Bool

    private var isRecording: Bool { recorder.action == action }

    private var note: (text: String, warning: Bool)? {
        if let problem = recorder.problem, problem.action == action { return (problem.text, true) }
        if unavailable { return ("Another app is already using this shortcut.", true) }
        if isRecording { return ("Esc cancels · Delete clears", false) }
        if action == .dictate, action.binding?.modifierKey != nil {
            return ("Or hold \(action.binding!.modifierKey!.name) while you talk.", false)
        }
        return nil
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                ShortcutField(binding: action.binding, isRecording: isRecording, preview: recorder.preview) {
                    isRecording ? recorder.end() : recorder.begin(action)
                }
                Button {
                    recorder.end()
                    recorder.assign(action.defaultBinding, to: action)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help("Use the default (\(action.defaultBinding.display))")
                .opacity(action.binding == action.defaultBinding ? 0 : 1)
                .disabled(action.binding == action.defaultBinding)
            }
        } label: {
            Text(action.title)
            if let note {
                Text(note.text)
                    .foregroundStyle(note.warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
        }
    }
}

/// A click-to-record field, like the ones in System Settings → Keyboard → Keyboard Shortcuts.
private struct ShortcutField: View {
    let binding: KeyBinding?
    let isRecording: Bool
    let preview: String
    let onClick: () -> Void

    private var text: String {
        if isRecording { return preview.isEmpty ? "Type shortcut…" : preview }
        switch binding {
        case .some(let binding): return binding.display.capitalizedFirst
        case nil: return "None"
        }
    }

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 5) {
                if case .doubleTap = binding, !isRecording {
                    Image(systemName: "hand.tap").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                Text(text)
                    .font(.system(size: 12, weight: isRecording || binding == nil ? .regular : .medium))
                    .foregroundStyle(isRecording || binding == nil ? .secondary : .primary)
            }
            .frame(minWidth: 150)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isRecording ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isRecording ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(binding.map { "\($0.display.capitalizedFirst). Click to change." } ?? "Click to set a shortcut.")
    }
}

// MARK: - Audio devices

/// A device row being dragged to a new rank.
private struct DraggedDevice: Codable, Transferable {
    let uid: String
    let direction: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

private struct DeviceSection: View {
    let direction: AudioDirection
    @ObservedObject var devices: AudioDevices
    @State private var dropTarget: String?

    var body: some View {
        let list = devices.list(direction)
        let current = devices.current(direction)
        Section {
            if list.isEmpty {
                Text(direction == .output ? "No speakers or headphones are connected." : "No microphones are connected.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(list.enumerated()), id: \.element.uid) { index, entry in
                DeviceRow(entry: entry, rank: index + 1, direction: direction,
                          connected: devices.isConnected(entry.uid, for: direction),
                          inUse: entry.uid == current, isDefault: entry.uid == devices.systemDefault[direction],
                          dropAbove: dropTarget == entry.uid)
                    .draggable(DraggedDevice(uid: entry.uid, direction: direction.rawValue)) {
                        Label(entry.name, systemImage: "line.3.horizontal").padding(6)
                    }
                    .dropDestination(for: DraggedDevice.self) { items, _ in
                        guard let item = items.first, item.direction == direction.rawValue,
                              let from = list.firstIndex(where: { $0.uid == item.uid }) else { return false }
                        move(list, from: from, to: index)
                        return true
                    } isTargeted: { targeted in
                        if targeted { dropTarget = entry.uid } else if dropTarget == entry.uid { dropTarget = nil }
                    }
                    .contextMenu {
                        Button("Move to Top") { move(list, from: index, to: 0) }.disabled(index == 0)
                        Button("Move Up") { move(list, from: index, to: index - 1) }.disabled(index == 0)
                        Button("Move Down") { move(list, from: index, to: index + 1) }.disabled(index == list.count - 1)
                        if !devices.isConnected(entry.uid, for: direction) {
                            Divider()
                            Button("Forget This Device") { devices.forget(entry.uid, for: direction) }
                        }
                    }
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text(direction == .output ? "Speakers" : "Microphones")
                Spacer()
                if devices.isCustom(direction) {
                    Button("Follow macOS") { devices.followSystem(direction) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Use whichever \(direction == .output ? "output" : "input") is selected in System Settings → Sound")
                }
            }
        } footer: {
            Text(devices.isCustom(direction)
                 ? "Aloud uses the highest one on the list that's connected. Drag to reorder."
                 : "Aloud follows your Mac's Sound settings. Drag to set your own order, and Aloud will use the highest one that's connected.")
                .foregroundStyle(.secondary)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// `to` is the row the device lands on; moving down puts it below that row, moving up above it.
    private func move(_ list: [AudioDevices.Entry], from: Int, to: Int) {
        guard from != to else { return }
        var order = list
        order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        devices.setOrder(order, for: direction)
    }
}

private struct DeviceRow: View {
    let entry: AudioDevices.Entry
    let rank: Int
    let direction: AudioDirection
    let connected: Bool
    let inUse: Bool
    let isDefault: Bool
    let dropAbove: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("\(rank)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 22)
                .foregroundStyle(connected ? .primary : .tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .foregroundStyle(connected ? .primary : .secondary)
                if !connected {
                    Text("Not connected").font(.caption).foregroundStyle(.tertiary)
                } else if isDefault {
                    Text("macOS default").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if inUse {
                Text("In use")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.15)))
            }
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .overlay {
            if dropAbove {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2).padding(-4)
            }
        }
    }

    private var symbol: String {
        let name = entry.name.lowercased()
        switch entry.transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if name.contains("airpods max") { return "airpodsmax" }
            if name.contains("airpods pro") { return "airpodspro" }
            if name.contains("airpods") { return "airpods" }
            return "headphones"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI: return "display"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "waveform"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: return "iphone"
        default:
            if name.contains("display") { return "display" }
            if name.contains("headphone") { return "headphones" }
            if entry.transport == kAudioDeviceTransportTypeBuiltIn { return direction == .output ? "laptopcomputer" : "mic" }
            return direction == .output ? "hifispeaker" : "mic"
        }
    }
}

// MARK: - Downloads

private struct ModelRow: View {
    let title: String
    let detail: String
    let symbol: String
    let installed: Bool
    let progress: Double?
    let canRemove: Bool
    /// In use right now, so it can't be removed yet.
    let busy: Bool
    let download: () -> Void
    let remove: () -> Void
    /// What the Remove confirmation says happens afterwards.
    var afterRemoving = "Aloud will ask before downloading it again the next time you use it."
    @State private var confirmingRemove = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let progress {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .frame(width: 90)
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
            } else if installed {
                Label {
                    Text("Downloaded").foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .font(.callout)
                if canRemove {
                    Button("Remove") { confirmingRemove = true }
                        .controlSize(.small)
                        .disabled(busy)
                        .help(busy ? "Finish dictating first" : "Delete the model to free up space")
                }
            } else {
                Button("Download", action: download)
            }
        }
        .padding(.vertical, 2)
        .confirmationDialog("Remove the \(title.lowercased()) model?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive, action: remove)
        } message: {
            Text(afterRemoving)
        }
    }
}
