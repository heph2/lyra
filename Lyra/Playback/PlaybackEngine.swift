import AVFoundation
import Combine
import Foundation

/// The audio output layer, kept behind a protocol so the `AVPlayer`
/// implementation can be swapped for an `AVAudioEngine` one when gapless
/// playback is added, without touching the queue logic or the UI.
@MainActor
protocol PlaybackEngine: AnyObject {
    var isPlaying: Bool { get }
    var currentTime: Double { get }
    var duration: Double { get }

    /// Fired when the current item plays through to its natural end.
    var onTrackFinished: (() -> Void)? { get set }
    /// Fired when an item fails to load or decode.
    var onError: ((String) -> Void)? { get set }
    /// Fired on every periodic time update, for UI and Now Playing sync.
    var onTimeUpdate: ((Double) -> Void)? { get set }

    func load(url: URL, autoplay: Bool)
    func play()
    func pause()
    func seek(to seconds: Double)
    func stop()
}

/// `AVPlayer`-backed engine: one `AVPlayerItem` per track.
///
/// We deliberately do not use `AVQueuePlayer` — the queue, shuffle and repeat
/// rules live in `PlayerController` where they can be reasoned about and
/// reordered, rather than being smeared across AVFoundation's internal queue.
@MainActor
final class AVPlayerEngine: PlaybackEngine {

    var onTrackFinished: (() -> Void)?
    var onError: ((String) -> Void)?
    var onTimeUpdate: ((Double) -> Void)?

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: (any NSObjectProtocol)?
    private var statusObservation: NSKeyValueObservation?

    /// Cached because `AVPlayerItem.duration` is unknown until the asset loads,
    /// and the UI needs a stable value to lay out the scrubber.
    private var loadedDuration: Double = 0

    init() {
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        installTimeObserver()
    }

    // Both observers hold the player and must be torn down explicitly; running
    // the deinit on the actor is what lets it touch that state.
    isolated deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    // MARK: - PlaybackEngine

    var isPlaying: Bool { player.timeControlStatus == .playing || player.rate > 0 }

    var currentTime: Double {
        let seconds = CMTimeGetSeconds(player.currentTime())
        return seconds.isFinite ? max(0, seconds) : 0
    }

    var duration: Double { loadedDuration }

    func load(url: URL, autoplay: Bool) {
        // Local files only: no buffering, no network, so a plain item is fine.
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)

        loadedDuration = 0
        observeEnd(of: item)
        observeStatus(of: item)

        player.replaceCurrentItem(with: item)
        if autoplay { player.play() }
    }

    func play() {
        guard player.currentItem != nil else { return }
        player.play()
    }

    func pause() {
        player.pause()
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        // Exact seek: scrubbing that snaps to keyframes feels broken in music.
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        onTimeUpdate?(seconds)
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        loadedDuration = 0
    }

    // MARK: - Observation

    private func installTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let seconds = CMTimeGetSeconds(time)
                if seconds.isFinite { self.onTimeUpdate?(max(0, seconds)) }
            }
        }
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onTrackFinished?()
            }
        }
    }

    private func observeStatus(of item: AVPlayerItem) {
        // KVO on `status` fires on whichever queue AVFoundation happens to be
        // using, never reliably the main one. Read what we need here, then hop
        // to the main actor with plain values — `assumeIsolated` would trap.
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let seconds = CMTimeGetSeconds(item.duration)
            let message = item.error?.localizedDescription

            Task { @MainActor [weak self] in
                // Dropping the observation on the next `load` does not cancel a
                // hop that is already queued, so a stale failure would arrive
                // after the controller moved on and skip a healthy track.
                guard let self, item === self.player.currentItem else { return }
                switch status {
                case .readyToPlay:
                    if seconds.isFinite, seconds > 0 { self.loadedDuration = seconds }
                case .failed:
                    self.onError?(message ?? "This file could not be played.")
                default:
                    break
                }
            }
        }
    }
}
