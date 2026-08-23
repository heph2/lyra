import AVFoundation
import Combine
import Foundation

/// Why a load failed, and whether the failure condemns every other track from
/// the same library. Walking the queue past a server that cannot be reached
/// only repeats the same network timeout once per remaining track.
struct PlaybackFailure: Sendable, Equatable {
    let message: String
    var isSourceUnavailable: Bool = false
}

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
    var onError: ((PlaybackFailure) -> Void)? { get set }
    /// Fired on every periodic time update, for UI and Now Playing sync.
    var onTimeUpdate: ((Double) -> Void)? { get set }

    func load(resource: PlaybackResource, autoplay: Bool)
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
    var onError: ((PlaybackFailure) -> Void)?
    var onTimeUpdate: ((Double) -> Void)?

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: (any NSObjectProtocol)?
    private var statusObservation: NSKeyValueObservation?
    private var webDAVLoader: WebDAVAssetLoader?
    private var remotePreparationTask: Task<Void, Never>?
    private var wantsPlayback = false
    private var isPreparingRemote = false

    /// Cached because `AVPlayerItem.duration` is unknown until the asset loads,
    /// and the UI needs a stable value to lay out the scrubber.
    private var loadedDuration: Double = 0

    init() {
        player.actionAtItemEnd = .pause
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

    func load(resource: PlaybackResource, autoplay: Bool) {
        remotePreparationTask?.cancel()
        remotePreparationTask = nil
        webDAVLoader?.cancelAll()
        webDAVLoader = nil
        wantsPlayback = autoplay
        isPreparingRemote = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        loadedDuration = 0
        loadToken += 1
        let token = loadToken

        switch resource {
        case .local(let url):
            install(asset: AVURLAsset(url: url), remote: false, token: token)
        case .remote(let remote):
            guard let source = LibraryManager.shared.remoteSource(for: remote.sourceID) else {
                Task { @MainActor [weak self] in
                    self?.onError?(PlaybackFailure(
                        message: "This WebDAV library can't be reached right now.",
                        isSourceUnavailable: true
                    ))
                }
                return
            }

            // AVPlayer can leave a custom-scheme asset in `.unknown` forever
            // without asking its resource loader for data. Proving one tiny
            // authenticated range first gives unsupported servers a bounded,
            // actionable failure instead of an endless paused-looking player.
            remotePreparationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let probeLength = max(1, min(Int64(2), remote.contentLength))
                    let item = ScannedFile(
                        relativePath: remote.relativePath,
                        size: remote.contentLength,
                        modified: .distantPast
                    )
                    _ = try await source.readRange(for: item, range: 0..<probeLength)
                    try Task.checkCancellation()
                    guard token == self.loadToken else { return }

                    let loader = WebDAVAssetLoader(
                        source: source,
                        resource: remote,
                        playbackActive: self.wantsPlayback
                    )
                    self.webDAVLoader = loader
                    let asset = loader.makeAsset()
                    self.isPreparingRemote = true
                    self.install(asset: asset, remote: true, token: token, startPlayback: false)
                    try await Task.sleep(for: .seconds(20))
                    guard token == self.loadToken, self.isPreparingRemote else { return }
                    self.isPreparingRemote = false
                    loader.cancelAll()
                    // A status callback may already be queued when the timeout
                    // tears the item down. Invalidate it before reporting this
                    // failure so the controller cannot skip two tracks.
                    self.loadToken += 1
                    self.player.replaceCurrentItem(with: nil)
                    if let reason = loader.takeLastFailure() {
                        self.onError?(Self.failure(for: reason))
                    } else {
                        self.onError?(PlaybackFailure(
                            message: "This WebDAV track took too long to start."
                        ))
                    }
                } catch is CancellationError {
                    return
                } catch let reason as LibrarySourceError {
                    guard token == self.loadToken else { return }
                    self.isPreparingRemote = false
                    self.onError?(Self.failure(for: reason))
                } catch {
                    guard token == self.loadToken else { return }
                    self.isPreparingRemote = false
                    if let reason = self.webDAVLoader?.takeLastFailure() {
                        self.onError?(Self.failure(for: reason))
                        return
                    }
                    self.onError?(PlaybackFailure(message: "This file could not be played."))
                }
            }
        }
    }

    private func install(
        asset: AVURLAsset,
        remote: Bool,
        token: Int,
        startPlayback: Bool = true
    ) {
        // A local file has the whole track on disk, so waiting to buffer only
        // delays the first note. A streamed one has nothing but what the last
        // range returned, and starting it with no headroom stalls audibly on
        // the first network hiccup.
        player.automaticallyWaitsToMinimizeStalling = remote
        let item = remote
            ? AVPlayerItem(
                asset: asset,
                automaticallyLoadedAssetKeys: ["playable", "duration"]
            )
            : AVPlayerItem(asset: asset)
        if remote { item.preferredForwardBufferDuration = 15 }

        observeEnd(of: item)
        observeStatus(of: item, token: token)

        player.replaceCurrentItem(with: item)
        if startPlayback, wantsPlayback { player.play() }
    }

    func play() {
        wantsPlayback = true
        webDAVLoader?.setPlaybackActive(true)
        guard !isPreparingRemote else { return }
        guard player.currentItem != nil else { return }
        player.play()
    }

    func pause() {
        wantsPlayback = false
        webDAVLoader?.setPlaybackActive(false)
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
        wantsPlayback = false
        remotePreparationTask?.cancel()
        remotePreparationTask = nil
        isPreparingRemote = false
        player.pause()
        // Tearing down invalidates the load the same way replacing it does: a
        // status hop already in flight would otherwise report a duration or a
        // failure for an item this player no longer has.
        loadToken += 1
        webDAVLoader?.cancelAll()
        webDAVLoader = nil
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

    /// Identifies the load a status report belongs to. Answering "is this
    /// still the item I loaded" from `player.currentItem` instead would drop a
    /// genuine failure whenever AVPlayer has already let go of the failed item.
    private var loadToken = 0

    private func observeStatus(of item: AVPlayerItem, token: Int) {
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
                guard let self, token == self.loadToken else { return }
                switch status {
                case .readyToPlay:
                    if seconds.isFinite, seconds > 0 { self.loadedDuration = seconds }
                    if self.isPreparingRemote {
                        self.isPreparingRemote = false
                        self.remotePreparationTask?.cancel()
                        self.remotePreparationTask = nil
                        self.webDAVLoader?.setPlaybackActive(self.wantsPlayback)
                        if self.wantsPlayback { self.player.play() }
                    }
                case .failed:
                    self.isPreparingRemote = false
                    self.remotePreparationTask?.cancel()
                    self.remotePreparationTask = nil
                    self.onError?(self.failure(describedAs: message))
                default:
                    break
                }
            }
        }
    }

    /// AVFoundation turns every resource-loader error into a generic decode
    /// failure, so the reason the loader recorded is the only thing that can
    /// tell the user whether to retry or to download the album.
    private func failure(describedAs message: String?) -> PlaybackFailure {
        guard let reason = webDAVLoader?.takeLastFailure() else {
            return PlaybackFailure(message: message ?? "This file could not be played.")
        }
        return Self.failure(for: reason)
    }

    private static func failure(for reason: LibrarySourceError) -> PlaybackFailure {
        PlaybackFailure(
            message: Self.message(for: reason),
            isSourceUnavailable: Self.isSourceUnavailable(reason)
        )
    }

    private static func message(for reason: LibrarySourceError) -> String {
        switch reason {
        case .signInRequired:
            "Sign in again to this WebDAV library to play from it."
        case .rangeNotSupported:
            "This server can't be streamed from. Long-press these tracks and "
                + "choose Download Offline to play them."
        case .server(let status) where status == 404 || status == 410:
            "This track is no longer available on the WebDAV server."
        case .server(let status):
            "The WebDAV server returned HTTP \(status) for this track."
        case .invalidConfiguration:
            "This track's WebDAV location is invalid."
        default:
            "This WebDAV library can't be reached right now. Tracks you have "
                + "downloaded still play."
        }
    }

    private static func isSourceUnavailable(_ reason: LibrarySourceError) -> Bool {
        switch reason {
        case .unavailable, .signInRequired, .rangeNotSupported:
            true
        default:
            false
        }
    }
}
