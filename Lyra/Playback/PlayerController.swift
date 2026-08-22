import Foundation
import SwiftData
import SwiftUI

/// Single source of truth for what is playing and what comes next.
///
/// The queue is stored as a fixed list of tracks plus a separate play *order*.
/// Toggling shuffle rewrites the order without disturbing the list, so turning
/// shuffle off restores the album sequence exactly, and the queue view can show
/// what is actually coming next in either mode.
@MainActor
@Observable
final class PlayerController {

    enum RepeatMode: String, CaseIterable {
        case off, all, one

        var systemImage: String {
            switch self {
            case .off, .all: "repeat"
            case .one: "repeat.1"
            }
        }
    }

    // MARK: - Observable state

    private(set) var queue: [Track] = []
    /// Indices into `queue`, in playback order.
    private(set) var order: [Int] = []
    /// Index into `order`. -1 means nothing loaded.
    private(set) var position: Int = -1

    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var errorMessage: String?

    var isShuffled: Bool = false {
        didSet {
            guard isShuffled != oldValue else { return }
            rebuildOrder(preservingCurrent: true)
            defaults.set(isShuffled, forKey: Keys.shuffle)
        }
    }

    var repeatMode: RepeatMode = .off {
        didSet {
            guard repeatMode != oldValue else { return }
            defaults.set(repeatMode.rawValue, forKey: Keys.repeatMode)
        }
    }

    /// Set while the user drags the scrubber, so incoming time updates do not
    /// fight the gesture.
    var isScrubbing = false

    /// Drives the Now Playing sheet. Lives here rather than in a view's local
    /// state so any screen can open the full player.
    var isNowPlayingPresented = false

    // MARK: - Dependencies

    private let engine: any PlaybackEngine
    private let session = AudioSessionManager()
    private let nowPlaying = NowPlayingCenter()
    private let container: ModelContainer
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let shuffle = "playback.shuffle"
        static let repeatMode = "playback.repeatMode"
    }

    /// True when playback was paused by the system rather than by the user, so
    /// we know whether resuming after an interruption is appropriate.
    private var wasPlayingBeforeInterruption = false

    /// Guards against spinning through a queue whose tracks cannot be played.
    /// A resolved URL is not proof of playback, so this is cleared only once
    /// audio actually progresses — an engine error arrives after the load that
    /// would otherwise have reset it.
    private var consecutiveLoadFailures = 0

    init(container: ModelContainer, engine: (any PlaybackEngine)? = nil) {
        self.container = container
        self.engine = engine ?? AVPlayerEngine()

        isShuffled = defaults.bool(forKey: Keys.shuffle)
        if let raw = defaults.string(forKey: Keys.repeatMode),
           let mode = RepeatMode(rawValue: raw) {
            repeatMode = mode
        }

        wireEngine()
        wireSession()
        wireRemoteCommands()
    }

    // MARK: - Derived state

    var currentTrack: Track? {
        guard order.indices.contains(position) else { return nil }
        let index = order[position]
        return queue.indices.contains(index) ? queue[index] : nil
    }

    var hasQueue: Bool { !queue.isEmpty }

    /// Tracks after the current one, in play order.
    var upcoming: [Track] {
        guard position >= 0, position + 1 < order.count else { return [] }
        return order[(position + 1)...].compactMap { queue.indices.contains($0) ? queue[$0] : nil }
    }

    var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    var remainingTime: Double { max(0, duration - currentTime) }

    // MARK: - Transport

    /// Replaces the queue with `tracks` and starts at `index` (an index into
    /// `tracks` as given, regardless of shuffle).
    func play(tracks: [Track], startAt index: Int = 0) {
        guard !tracks.isEmpty, tracks.indices.contains(index) else { return }
        LyraLog.playback.info("Loading playback queue tracks=\(tracks.count)")

        consecutiveLoadFailures = 0
        queue = tracks
        order = Array(tracks.indices)
        if isShuffled {
            var rest = order.filter { $0 != index }
            rest.shuffle()
            order = [index] + rest
            position = 0
        } else {
            position = index
        }
        loadCurrent(autoplay: true)
    }

    /// Plays a single track without disturbing an existing queue's contents —
    /// used by "play this album/playlist from here" call sites that pass the
    /// full list instead.
    func play(track: Track) {
        play(tracks: [track], startAt: 0)
    }

    func togglePlayPause() {
        guard currentTrack != nil else { return }
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func resume() {
        guard currentTrack != nil else { return }
        session.activate()
        engine.play()
        isPlaying = true
        nowPlaying.updatePlaybackState(isPlaying: true, elapsed: currentTime)
    }

    func pause() {
        engine.pause()
        isPlaying = false
        nowPlaying.updatePlaybackState(isPlaying: false, elapsed: currentTime)
    }

    /// Advances one track. `userInitiated` distinguishes tapping Next (which
    /// ignores repeat-one) from a track ending naturally.
    func next(userInitiated: Bool = true) {
        advance(userInitiated ? .userInitiated : .trackFinished)
    }

    /// Why we are leaving the current track. Only a track that actually played
    /// to its end may be replayed by repeat-one: replaying one we could not
    /// load would resume the *previous* item's audio under the new track's
    /// name, and would trap the queue on a file that never plays.
    private enum Advance {
        case userInitiated
        case trackFinished
        case trackUnplayable
    }

    private func advance(_ reason: Advance) {
        guard !order.isEmpty else { return }

        // Asking for a different track is a fresh attempt, not a continuation
        // of a run of failures.
        if reason == .userInitiated { consecutiveLoadFailures = 0 }

        if reason == .trackFinished, repeatMode == .one, currentTrack != nil {
            seek(to: 0)
            engine.play()
            isPlaying = true
            return
        }

        if moveToNextPosition(reason) {
            loadCurrent(autoplay: true)
        }
    }

    /// Moves `position` to the next track to try, without loading it. Returns
    /// false when the queue is over — `finishQueue` has already run and there
    /// is nothing left to load. Kept separate from `advance` so `loadCurrent`
    /// can walk past unplayable tracks in a loop instead of recursing.
    private func moveToNextPosition(_ reason: Advance) -> Bool {
        if position + 1 < order.count {
            position += 1
            return true
        }

        // End of queue.
        switch repeatMode {
        case .all:
            if isShuffled { rebuildOrder(preservingCurrent: false) }
            position = 0
            return true
        case .off, .one:
            if reason == .userInitiated {
                // Tapping Next at the end wraps rather than dead-ending.
                position = 0
                return true
            }
            finishQueue()
            return false
        }
    }

    /// Restarts the current track, or goes back one if we are near its start —
    /// the behaviour every music player has trained people to expect.
    func previous() {
        guard !order.isEmpty else { return }

        if currentTime > 3 {
            seek(to: 0)
            return
        }
        if position > 0 {
            consecutiveLoadFailures = 0
            position -= 1
            loadCurrent(autoplay: true)
        } else {
            seek(to: 0)
        }
    }

    func seek(to seconds: Double) {
        let clamped = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
        engine.seek(to: clamped)
        currentTime = clamped
        nowPlaying.updatePlaybackState(isPlaying: isPlaying, elapsed: clamped)
    }

    func skip(by delta: Double) {
        seek(to: currentTime + delta)
    }

    func stop() {
        engine.stop()
        isPlaying = false
        currentTime = 0
        duration = 0
        position = -1
        queue = []
        order = []
        nowPlaying.clear()
        session.deactivate()
    }

    func cycleRepeat() {
        repeatMode = switch repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    // MARK: - Queue editing

    /// Inserts tracks immediately after the current one.
    func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if queue.isEmpty {
            play(tracks: tracks, startAt: 0)
            return
        }
        let newIndices = appendToQueue(tracks)
        let insertAt = min(position + 1, order.count)
        order.insert(contentsOf: newIndices, at: insertAt)
    }

    /// Appends tracks to the end of the play order.
    func addToQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if queue.isEmpty {
            play(tracks: tracks, startAt: 0)
            return
        }
        order.append(contentsOf: appendToQueue(tracks))
    }

    /// Removes an upcoming track. `offset` is relative to `upcoming`.
    func removeUpcoming(at offsets: IndexSet) {
        let base = position + 1
        let targets = offsets.map { base + $0 }.filter { order.indices.contains($0) }.sorted(by: >)
        for index in targets {
            order.remove(at: index)
        }
    }

    func moveUpcoming(fromOffsets source: IndexSet, toOffset destination: Int) {
        let base = position + 1
        guard base <= order.count else { return }
        var tail = Array(order[base...])
        tail.move(fromOffsets: source, toOffset: destination)
        order.replaceSubrange(base..., with: tail)
    }

    /// Jumps to a track in the upcoming list.
    func jumpToUpcoming(offset: Int) {
        let target = position + 1 + offset
        guard order.indices.contains(target) else { return }
        consecutiveLoadFailures = 0
        position = target
        loadCurrent(autoplay: true)
    }

    private func appendToQueue(_ tracks: [Track]) -> [Int] {
        let start = queue.count
        queue.append(contentsOf: tracks)
        return Array(start..<queue.count)
    }

    // MARK: - Internals

    /// Loads the track at `position`, skipping forward over any that cannot be
    /// reached. The skip is a loop rather than a recursive call into `advance`:
    /// the failure bound is the queue length, so a 2,000-track library on an
    /// unplugged drive would otherwise nest 2,000 frames deep and overflow the
    /// main thread stack before the give-up message could be shown.
    private func loadCurrent(autoplay: Bool) {
        var skipped = 0
        while let track = currentTrack {
            // The folder this track lives in may be gone — an external drive
            // unplugged, a permission revoked. Skip it rather than stalling,
            // but give up once we have tried the whole queue, or an unreachable
            // folder plus repeat-all would spin forever.
            guard let url = track.fileURL else {
                if LibraryManager.shared.source(for: track.sourceID)?.isRemote == true {
                    LyraLog.playback.notice("Playback blocked because remote track is not offline")
                    errorMessage = "\(track.title) has not been downloaded yet. "
                        + "Long-press it and choose Download Offline to play it."
                    finishQueue()
                    return
                }
                LyraLog.playback.notice("Playback skipped unreachable local track")
                skipped += 1
                guard registerLoadFailure(
                    "\(track.title) is in a folder Lyra can't reach right now.",
                    whenQueueExhausted: Self.noTrackReachable
                ) else { return }
                guard moveToNextPosition(.trackUnplayable) else { break }
                continue
            }

            errorMessage = nil
            currentTime = 0
            duration = track.duration

            session.activate()
            engine.load(url: url, autoplay: autoplay)
            isPlaying = autoplay

            nowPlaying.update(track: track, isPlaying: autoplay, elapsed: 0, duration: track.duration)
            recordPlay(of: track)
            return
        }

        // The walk ended without loading anything. Under the default
        // repeat-off, `moveToNextPosition` finishes the queue before the
        // failure count can exceed it, so naming the last track skipped would
        // blame one arbitrary file for a whole unreachable folder.
        if skipped > 0 {
            errorMessage = skipped >= order.count ? Self.noTrackReachable : Self.restNotReachable
        }
    }

    private static let noTrackReachable =
        "None of these tracks are in a folder Lyra can reach right now."
    private static let restNotReachable =
        "The rest of these tracks aren't in a folder Lyra can reach right now."

    /// Counts a failed attempt and reports whether another track is worth
    /// trying. Shared by "the file is not there" and "the engine refused it":
    /// both leave the queue walking forever under repeat-all if nothing counts
    /// the failures, and only one of them is visible before a load is
    /// attempted.
    private func registerLoadFailure(_ message: String, whenQueueExhausted exhausted: String) -> Bool {
        consecutiveLoadFailures += 1
        guard consecutiveLoadFailures <= order.count else {
            errorMessage = exhausted
            finishQueue()
            return false
        }
        errorMessage = message
        return true
    }

    private func finishQueue() {
        consecutiveLoadFailures = 0
        engine.pause()
        isPlaying = false
        currentTime = 0
        engine.seek(to: 0)
        nowPlaying.updatePlaybackState(isPlaying: false, elapsed: 0)
    }

    /// Regenerates `order` for the current shuffle setting.
    /// `preservingCurrent` keeps the playing track where it is, so toggling
    /// shuffle never interrupts what you are listening to.
    private func rebuildOrder(preservingCurrent: Bool) {
        guard !queue.isEmpty else { return }
        let currentIndex = order.indices.contains(position) ? order[position] : nil

        if isShuffled {
            var indices = Array(queue.indices)
            if preservingCurrent, let currentIndex {
                indices.removeAll { $0 == currentIndex }
                indices.shuffle()
                order = [currentIndex] + indices
                position = 0
            } else {
                indices.shuffle()
                order = indices
                position = order.isEmpty ? -1 : 0
            }
        } else {
            order = Array(queue.indices)
            position = currentIndex.flatMap { order.firstIndex(of: $0) } ?? 0
        }
    }

    private func recordPlay(of track: Track) {
        let path = track.relativePath
        let container = container
        Task.detached {
            let store = LibraryStore(modelContainer: container)
            try? await store.recordPlay(relativePath: path, at: Date())
        }
    }

    // MARK: - Wiring

    private func wireEngine() {
        engine.onTimeUpdate = { [weak self] seconds in
            guard let self, !self.isScrubbing else { return }
            self.currentTime = seconds
            // Audio moving is the only proof a track really played.
            if seconds > 0 { self.consecutiveLoadFailures = 0 }
            // Duration is only known once the asset loads; adopt it when it
            // differs from the tag-derived value.
            let engineDuration = self.engine.duration
            if engineDuration > 0, abs(engineDuration - self.duration) > 0.5 {
                self.duration = engineDuration
                self.nowPlaying.update(
                    track: self.currentTrack,
                    isPlaying: self.isPlaying,
                    elapsed: seconds,
                    duration: engineDuration
                )
            }
        }

        engine.onTrackFinished = { [weak self] in
            guard let self else { return }
            // Playing through to the end is proof the track was fine, and a
            // file short enough to finish inside one observer tick never
            // reports a non-zero time. A zero-length or audio-less file reaches
            // the end at position 0 without ever playing, so that is not proof.
            if self.engine.currentTime > 0 { self.consecutiveLoadFailures = 0 }
            self.next(userInitiated: false)
        }

        engine.onError = { [weak self] message in
            guard let self, self.currentTrack != nil else { return }
            LyraLog.playback.error("Playback engine reported a track error")
            // A single corrupt file should not stall the whole queue, and a
            // queue of them should not be walked forever.
            guard self.registerLoadFailure(
                message,
                whenQueueExhausted: "None of these tracks can be played right now."
            ) else { return }
            self.advance(.trackUnplayable)
        }
    }

    private func wireSession() {
        session.configure()

        session.onInterruptionBegan = { [weak self] in
            guard let self else { return }
            self.wasPlayingBeforeInterruption = self.isPlaying
            self.pause()
        }

        session.onInterruptionEndedShouldResume = { [weak self] in
            guard let self, self.wasPlayingBeforeInterruption else { return }
            self.resume()
        }

        session.onRouteDisconnected = { [weak self] in
            self?.pause()
        }
    }

    private func wireRemoteCommands() {
        nowPlaying.onPlay = { [weak self] in self?.resume() }
        nowPlaying.onPause = { [weak self] in self?.pause() }
        nowPlaying.onToggle = { [weak self] in self?.togglePlayPause() }
        nowPlaying.onNext = { [weak self] in self?.next() }
        nowPlaying.onPrevious = { [weak self] in self?.previous() }
        nowPlaying.onSeek = { [weak self] seconds in self?.seek(to: seconds) }
        nowPlaying.onSkip = { [weak self] delta in self?.skip(by: delta) }
        nowPlaying.wireRemoteCommands()
    }
}
