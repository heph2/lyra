import Foundation
import MediaPlayer

/// Lock screen, Control Center, Bluetooth and CarPlay transport.
///
/// The Now Playing info is *not* pushed on every tick: we publish the elapsed
/// time plus a playback rate and let the system extrapolate between updates.
/// Pushing 4×/second would burn battery for no visible gain.
@MainActor
final class NowPlayingCenter {

    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onToggle: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onSeek: ((Double) -> Void)?

    private var isWired = false

    func wireRemoteCommands() {
        guard !isWired else { return }
        isWired = true

        let center = MPRemoteCommandCenter.shared()

        // Every handler below is `@Sendable` and hops explicitly to the main
        // actor. MediaPlayer does not promise which queue it calls these on,
        // and an isolation-inheriting closure would trap rather than misbehave.
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPlay?() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPause?() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onToggle?() }
            return .success
        }
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onNext?() }
            return .success
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPrevious?() }
            return .success
        }

        // Scrubbing on the lock screen.
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.onSeek?(position) }
            return .success
        }

        // Compact Now Playing surfaces choose interval skips over track
        // navigation when both are advertised. Lyra is a music player, so the
        // Dynamic Island should reserve those controls for Previous and Next.
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false

        // No accounts, no streaming service — these have no meaning in Lyra.
        center.likeCommand.isEnabled = false
        center.dislikeCommand.isEnabled = false
        center.bookmarkCommand.isEnabled = false
        center.ratingCommand.isEnabled = false
    }

    func update(track: Track?, isPlaying: Bool, elapsed: Double, duration: Double) {
        guard let track else {
            clear()
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.displayArtist,
            MPMediaItemPropertyAlbumTitle: track.displayAlbum,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, elapsed),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]

        let length = duration > 0 ? duration : track.duration
        if length > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = length
        }
        if track.trackNumber > 0 {
            info[MPMediaItemPropertyAlbumTrackNumber] = track.trackNumber
        }
        if let image = ArtworkCache.shared.image(for: track.artworkHash) {
            // MediaPlayer calls this handler on its own private queue. Without
            // `@Sendable` the closure inherits this method's main-actor
            // isolation, Swift 6 injects an executor assertion, and the process
            // traps the first time a track with cover art starts playing.
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in
                image
            }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    /// Cheap update for play/pause and seek, leaving title and artwork alone.
    func updatePlaybackState(isPlaying: Bool, elapsed: Double) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, elapsed)
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}
