import MediaPlayer
import UIKit

/// The film as tvOS shows it outside the app, in the Control Center and to
/// Siri, and the commands it sends back to the player.
@MainActor
final class NowPlaying {
    /// The one whose film the center shows: an auto-advance can attach the
    /// next file before the last one detaches.
    private static weak var current: NowPlaying?

    private weak var model: PlayerModel?
    private var info: [String: Any] = [:]
    private var targets: [(MPRemoteCommand, Any)] = []

    init(model: PlayerModel) {
        self.model = model
    }

    func attach() {
        guard let model else { return }
        NowPlaying.current = self
        info[MPMediaItemPropertyTitle] = model.playing.title
        if !model.playing.context.isEmpty { info[MPMediaItemPropertyArtist] = model.playing.context }
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        info[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        write()
        registerCommands()
        guard let titleId = model.titleId else { return }
        Task { [weak self] in
            let image = await CoreClient.run(on: CoreClient.slow) { () -> UIImage? in
                guard let path = try? CoreClient.shared.posterFile(titleId: titleId) else { return nil }
                return UIImage(contentsOfFile: path)
            }
            guard let image, let self else { return }
            self.info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.write()
        }
    }

    func detach() {
        for (command, target) in targets { command.removeTarget(target) }
        targets = []
        guard NowPlaying.current === self else { return }
        NowPlaying.current = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: PlayerModel.seekStep)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: PlayerModel.seekStep)]
        handle(center.playCommand) { model, _ in
            if model.status == .paused || model.status == .ended { model.togglePlayback() }
            return .success
        }
        handle(center.pauseCommand) { model, _ in
            if model.status == .playing || model.status == .buffering { model.host?.bridge.pause() }
            return .success
        }
        handle(center.togglePlayPauseCommand) { model, _ in
            model.togglePlayback()
            return .success
        }
        handle(center.skipForwardCommand) { model, event in
            guard model.durationRef > 0, let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            model.seek(to: model.positionRef + event.interval)
            return .success
        }
        handle(center.skipBackwardCommand) { model, event in
            guard model.durationRef > 0, let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            model.replayWithSubtitles(until: model.positionRef)
            model.seek(to: model.positionRef - event.interval)
            return .success
        }
        handle(center.changePlaybackPositionCommand) { model, event in
            guard model.durationRef > 0, let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            model.seek(to: event.positionTime)
            return .success
        }
        handle(center.enableLanguageOptionCommand) { model, event in
            guard let id = (event as? MPChangeLanguageOptionCommandEvent)?.languageOption.identifier else {
                return .commandFailed
            }
            if let track = model.audioTracks.first(where: { "audio:\($0.index)" == id }) {
                model.selectAudio(track)
                return .success
            }
            if let track = model.subtitleTracks.first(where: { "subtitle:\($0.index)" == id }) {
                model.selectSubtitle(track)
                return .success
            }
            return .commandFailed
        }
        handle(center.disableLanguageOptionCommand) { model, event in
            guard (event as? MPChangeLanguageOptionCommandEvent)?.languageOption.languageOptionType == .legible else {
                return .commandFailed
            }
            model.selectSubtitle(nil)
            return .success
        }
    }

    /// A handler answers only for the film the center shows, and not once
    /// it has failed; a command wakes the overlay as a press would.
    private func handle(
        _ command: MPRemoteCommand,
        _ body: @escaping @MainActor (PlayerModel, MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        command.isEnabled = true
        let target = command.addTarget { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, NowPlaying.current === self, let model = self.model else {
                    return .noActionableNowPlayingItem
                }
                guard !model.status.terminal else { return .commandFailed }
                model.wake()
                return body(model, event)
            }
        }
        targets.append((command, target))
    }

    /// Called on events only: while the rate is 1 the system moves the
    /// position on by itself.
    func publish(playing: Bool, position: Double, duration: Double) {
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
        info[MPMediaItemPropertyPlaybackDuration] = duration > 0 ? duration : nil
        write()
    }

    func publishLanguages(audio: [MediaTrack], subtitle: [MediaTrack]) {
        func options(_ tracks: [MediaTrack], _ type: MPNowPlayingInfoLanguageOptionType, _ kind: String)
            -> [MPNowPlayingInfoLanguageOption]
        {
            tracks.map {
                MPNowPlayingInfoLanguageOption(
                    type: type, languageTag: LanguageTag.normalize($0.language), characteristics: nil,
                    displayName: $0.label, identifier: "\(kind):\($0.index)")
            }
        }
        let audible = options(audio, .audible, "audio")
        let legible = options(subtitle, .legible, "subtitle")
        var groups: [MPNowPlayingInfoLanguageOptionGroup] = []
        if !audible.isEmpty {
            groups.append(MPNowPlayingInfoLanguageOptionGroup(
                languageOptions: audible, defaultLanguageOption: nil, allowEmptySelection: false))
        }
        if !legible.isEmpty {
            groups.append(MPNowPlayingInfoLanguageOptionGroup(
                languageOptions: legible, defaultLanguageOption: nil, allowEmptySelection: true))
        }
        info[MPNowPlayingInfoPropertyAvailableLanguageOptions] = groups
        info[MPNowPlayingInfoPropertyCurrentLanguageOptions] =
            zip(audio + subtitle, audible + legible).filter { $0.0.selected }.map { $0.1 }
        write()
    }

    private func write() {
        guard NowPlaying.current === self else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
