import AppKit
import MediaPlayer

/// Makes Read Aloud the Mac's "Now Playing" app while it's reading, so
/// AirPods taps, the keyboard's play/pause key and Control Center control it.
///
/// AirPods: press once to pause/resume, twice for the next sentence,
/// three times for the previous one. Control Center can also scrub.
final class NowPlaying {
    private let model: PlayerModel
    private let center = MPNowPlayingInfoCenter.default()
    private let commands = MPRemoteCommandCenter.shared()
    private lazy var artwork: MPMediaItemArtwork? = {
        guard let icon = NSApp.applicationIconImage else { return nil }
        return MPMediaItemArtwork(boundsSize: icon.size) { _ in icon }
    }()

    init(model: PlayerModel) {
        self.model = model
        handle(commands.playCommand) { $0.play() }
        handle(commands.pauseCommand) { $0.pause() }
        handle(commands.togglePlayPauseCommand) { $0.togglePlay() }
        handle(commands.nextTrackCommand) { $0.nextSentence() }
        handle(commands.previousTrackCommand) { $0.previousSentence() }
        commands.skipForwardCommand.preferredIntervals = [15]
        commands.skipBackwardCommand.preferredIntervals = [15]
        handle(commands.skipForwardCommand) { $0.skip(by: 15) }
        handle(commands.skipBackwardCommand) { $0.skip(by: -15) }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, self.model.hasSession,
                  let event = event as? MPChangePlaybackPositionCommandEvent else { return .noActionableNowPlayingItem }
            let time = event.positionTime
            self.onMain { $0.seek(to: time) }
            return .success
        }
        model.onTransportChange = { [weak self] in self?.update() }
        update()
    }

    private func handle(_ command: MPRemoteCommand, _ action: @escaping (PlayerModel) -> Void) {
        command.addTarget { [weak self] _ in
            guard let self, self.model.hasSession else { return .noActionableNowPlayingItem }
            self.onMain(action)
            return .success
        }
    }

    private func onMain(_ action: @escaping (PlayerModel) -> Void) {
        if Thread.isMainThread {
            action(model)
        } else {
            DispatchQueue.main.async { [model] in action(model) }
        }
    }

    func update() {
        let active = model.hasSession
        for command in [commands.playCommand, commands.pauseCommand, commands.togglePlayPauseCommand,
                        commands.nextTrackCommand, commands.previousTrackCommand, commands.skipForwardCommand,
                        commands.skipBackwardCommand, commands.changePlaybackPositionCommand] {
            command.isEnabled = active
        }
        guard active else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: model.title,
            MPMediaItemPropertyArtist: "Read Aloud · \(model.voice.name)",
            MPMediaItemPropertyPlaybackDuration: model.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: model.position,
            // While waiting for audio the clock shouldn't run.
            MPNowPlayingInfoPropertyPlaybackRate: model.isPlaying && !model.isBuffering ? Double(model.rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        center.playbackState = model.isPlaying ? .playing : .paused
    }
}
