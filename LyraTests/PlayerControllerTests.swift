import Foundation
import MediaPlayer
import SwiftData
import Testing

@testable import Lyra

/// Stand-in for `AVPlayerEngine` so queue, shuffle and repeat behaviour can be
/// tested without touching AVFoundation or an audio session.
@MainActor
final class FakeEngine: PlaybackEngine {
    var onTrackFinished: (() -> Void)?
    var onError: ((PlaybackFailure) -> Void)?
    var onTimeUpdate: ((Double) -> Void)?

    private(set) var loadedResources: [PlaybackResource] = []
    var loadedURLs: [URL] {
        loadedResources.compactMap {
            guard case .local(let url) = $0 else { return nil }
            return url
        }
    }
    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 200

    func load(resource: PlaybackResource, autoplay: Bool) {
        loadedResources.append(resource)
        currentTime = 0
        isPlaying = autoplay
    }

    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func seek(to seconds: Double) { currentTime = seconds }
    func stop() { isPlaying = false; currentTime = 0 }

    /// Simulates the current item reaching its end. A real player is parked at
    /// the end of the item when it reports this, which is how the controller
    /// tells a file that played from one that finished without ever playing.
    func finishTrack() {
        currentTime = duration
        onTrackFinished?()
    }
}

@Suite("Playback queue")
@MainActor
struct PlayerControllerTests {

    private func makeController() throws -> (PlayerController, FakeEngine) {
        let schema = Schema([Track.self, Playlist.self])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let engine = FakeEngine()
        let controller = PlayerController(container: container, engine: engine)
        // Persisted defaults must not leak between runs of the test suite.
        controller.isShuffled = false
        controller.repeatMode = .off
        return (controller, engine)
    }

    private func tracks(_ count: Int) -> [Track] {
        (1...count).map { Track(relativePath: "t\($0).mp3", title: "Track \($0)", duration: 200) }
    }

    @Test("Remote controls advertise track navigation instead of interval skips")
    func remoteControlsPreferTracks() throws {
        _ = try makeController()
        let center = MPRemoteCommandCenter.shared()

        #expect(center.nextTrackCommand.isEnabled)
        #expect(center.previousTrackCommand.isEnabled)
        #expect(!center.skipForwardCommand.isEnabled)
        #expect(!center.skipBackwardCommand.isEnabled)
    }

    @Test("Playing a list starts at the requested index")
    func startsAtIndex() throws {
        let (player, _) = try makeController()
        let list = tracks(5)
        player.play(tracks: list, startAt: 2)

        #expect(player.currentTrack?.title == "Track 3")
        #expect(player.isPlaying)
        #expect(player.upcoming.map(\.title) == ["Track 4", "Track 5"])
    }

    @Test("A finished track advances to the next one")
    func advancesOnFinish() throws {
        let (player, engine) = try makeController()
        player.play(tracks: tracks(3), startAt: 0)
        engine.finishTrack()

        #expect(player.currentTrack?.title == "Track 2")
    }

    @Test("Repeat off stops at the end instead of looping")
    func stopsAtEnd() throws {
        let (player, engine) = try makeController()
        player.play(tracks: tracks(2), startAt: 1)
        engine.finishTrack()

        #expect(player.currentTrack?.title == "Track 2")
        #expect(!player.isPlaying)
    }

    @Test("Repeat all wraps around")
    func repeatAll() throws {
        let (player, engine) = try makeController()
        player.repeatMode = .all
        player.play(tracks: tracks(2), startAt: 1)
        engine.finishTrack()

        #expect(player.currentTrack?.title == "Track 1")
        #expect(player.isPlaying)
    }

    @Test("Repeat one replays the same track, but Next still moves on")
    func repeatOne() throws {
        let (player, engine) = try makeController()
        player.repeatMode = .one
        player.play(tracks: tracks(3), startAt: 0)

        engine.finishTrack()
        #expect(player.currentTrack?.title == "Track 1")

        player.next()  // user-initiated overrides repeat-one
        #expect(player.currentTrack?.title == "Track 2")
    }

    @Test("Repeat one moves on when the track finished without ever playing")
    func repeatOneSkipsTrackThatNeverPlayed() throws {
        let (player, engine) = try makeController()
        player.repeatMode = .one
        player.play(tracks: tracks(2), startAt: 0)

        // A zero-length or audio-less file reaches its end at position 0.
        engine.duration = 0
        engine.finishTrack()

        #expect(player.currentTrack?.title == "Track 2")
    }

    @Test("Repeat one stops instead of spinning when nothing in the queue ever plays")
    func repeatOneStopsWhenNothingPlays() throws {
        let (player, engine) = try makeController()
        player.repeatMode = .one
        player.play(tracks: tracks(2), startAt: 0)

        engine.duration = 0
        engine.finishTrack()
        engine.finishTrack()

        #expect(!player.isPlaying)
        #expect(player.errorMessage != nil)
    }

    @Test("Repeat one skips a track that cannot be reached instead of replaying the last one")
    func repeatOneSkipsUnreachableTrack() throws {
        let (player, engine) = try makeController()
        player.repeatMode = .one
        let unreachable = Track(relativePath: "@missing-source/gone.mp3", title: "Gone", duration: 200)
        let reachable = Track(relativePath: "reachable.mp3", title: "Reachable", duration: 200)
        player.play(tracks: [unreachable, reachable], startAt: 0)

        #expect(player.currentTrack?.title == "Reachable")
        #expect(engine.loadedURLs.count == 1)
        #expect(engine.loadedURLs.last?.lastPathComponent == "reachable.mp3")
    }

    @Test("Repeat one stops rather than claiming playback when nothing in the queue can be reached")
    func repeatOneStopsWhenNothingIsReachable() throws {
        let (player, engine) = try makeController()
        player.repeatMode = .one
        let list = (1...3).map { Track(relativePath: "@missing-source/t\($0).mp3", title: "T\($0)", duration: 200) }
        player.play(tracks: list, startAt: 0)

        #expect(engine.loadedURLs.isEmpty)
        #expect(!player.isPlaying)
        #expect(player.errorMessage != nil)
    }

    @Test("Previous restarts the track when past three seconds")
    func previousRestarts() throws {
        let (player, _) = try makeController()
        player.play(tracks: tracks(3), startAt: 1)
        player.seek(to: 10)

        player.previous()
        #expect(player.currentTrack?.title == "Track 2")
        #expect(player.currentTime == 0)

        player.previous()  // now near the start, so step back
        #expect(player.currentTrack?.title == "Track 1")
    }

    @Test("Shuffle keeps the current track and permutes the rest")
    func shufflePreservesCurrent() throws {
        let (player, _) = try makeController()
        player.play(tracks: tracks(6), startAt: 3)
        let before = player.currentTrack?.title

        player.isShuffled = true
        #expect(player.currentTrack?.title == before)
        #expect(player.upcoming.count == 5)
        #expect(Set(player.upcoming.map(\.title)).count == 5)  // no duplicates
    }

    @Test("Turning shuffle off restores the original order")
    func unshuffleRestoresOrder() throws {
        let (player, _) = try makeController()
        player.play(tracks: tracks(5), startAt: 0)

        player.isShuffled = true
        player.isShuffled = false

        #expect(player.currentTrack?.title == "Track 1")
        #expect(player.upcoming.map(\.title) == ["Track 2", "Track 3", "Track 4", "Track 5"])
    }

    @Test("Play Next inserts directly after the current track")
    func playNextInserts() throws {
        let (player, _) = try makeController()
        player.play(tracks: tracks(3), startAt: 0)

        let extra = Track(relativePath: "extra.mp3", title: "Jumped Queue", duration: 100)
        player.playNext([extra])

        #expect(player.upcoming.first?.title == "Jumped Queue")
        #expect(player.upcoming.map(\.title) == ["Jumped Queue", "Track 2", "Track 3"])
    }

    @Test("Add to Queue appends to the end")
    func addToQueueAppends() throws {
        let (player, _) = try makeController()
        player.play(tracks: tracks(2), startAt: 0)

        let extra = Track(relativePath: "extra.mp3", title: "Last", duration: 100)
        player.addToQueue([extra])

        #expect(player.upcoming.map(\.title) == ["Track 2", "Last"])
    }

    @Test("Upcoming tracks can be removed and reordered")
    func queueEditing() throws {
        let (player, _) = try makeController()
        player.play(tracks: tracks(4), startAt: 0)

        player.removeUpcoming(at: IndexSet(integer: 0))   // drop Track 2
        #expect(player.upcoming.map(\.title) == ["Track 3", "Track 4"])

        player.moveUpcoming(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(player.upcoming.map(\.title) == ["Track 4", "Track 3"])
    }

    @Test("Tapping a queued track jumps straight to it")
    func jumpToUpcoming() throws {
        let (player, _) = try makeController()
        player.play(tracks: tracks(4), startAt: 0)

        player.jumpToUpcoming(offset: 1)  // Track 3
        #expect(player.currentTrack?.title == "Track 3")
    }

    @Test("An unplayable file skips forward rather than stalling the queue")
    func errorSkipsTrack() throws {
        let (player, engine) = try makeController()
        player.play(tracks: tracks(3), startAt: 0)

        engine.onError?(PlaybackFailure(message: "Corrupt file"))
        #expect(player.currentTrack?.title == "Track 2")
    }

    @Test("An unreachable library stops the queue instead of timing out on every track")
    func sourceFailureStopsQueue() throws {
        let (player, engine) = try makeController()
        player.repeatMode = .all
        player.play(tracks: tracks(5), startAt: 0)

        engine.onError?(PlaybackFailure(
            message: "This server can't be streamed from.",
            isSourceUnavailable: true
        ))

        #expect(player.isPlaying == false)
        #expect(player.errorMessage == "This server can't be streamed from.")
        // The failure condemns every remaining track from the same library, so
        // nothing after the first load may be attempted.
        #expect(engine.loadedResources.count == 1)
    }

    @Test("A queue of unplayable files stops instead of looping under repeat-all")
    func unplayableQueueStopsUnderRepeatAll() throws {
        let (player, engine) = try makeController()
        player.repeatMode = .all
        player.play(tracks: tracks(3), startAt: 0)

        for _ in 0..<4 { engine.onError?(PlaybackFailure(message: "Corrupt file")) }

        #expect(player.isPlaying == false)
        #expect(player.errorMessage == "None of these tracks can be played right now.")
        // Initial load plus one attempt per track, and nothing after the queue
        // has been proven unplayable.
        #expect(engine.loadedURLs.count == 4)
    }

    @Test("Audio that actually progresses clears earlier failures")
    func progressClearsFailureCount() throws {
        let (player, engine) = try makeController()
        player.repeatMode = .all
        player.play(tracks: tracks(2), startAt: 0)

        engine.onError?(PlaybackFailure(message: "Corrupt file"))
        engine.onTimeUpdate?(5)
        engine.onError?(PlaybackFailure(message: "Corrupt file"))

        #expect(player.currentTrack?.title == "Track 1")
        #expect(player.isPlaying)
    }

    @Test("A long queue of unreachable files gives up instead of exhausting the stack")
    func unreachableQueueSkipsIteratively() throws {
        let (player, engine) = try makeController()
        player.repeatMode = .all
        // A source id that was never registered resolves to no base URL, so
        // every one of these tracks looks like an unplugged drive.
        let missing = (1...2_000).map {
            Track(relativePath: "@missing/t\($0).mp3", title: "Track \($0)", duration: 200)
        }
        player.play(tracks: missing, startAt: 0)

        #expect(player.isPlaying == false)
        #expect(player.errorMessage == "None of these tracks are in a folder Lyra can reach right now.")
        #expect(engine.loadedURLs.isEmpty)
    }

    @Test("Reaching the end of a track clears earlier failures")
    func finishingClearsFailureCount() throws {
        let (player, engine) = try makeController()
        player.repeatMode = .all
        player.play(tracks: tracks(2), startAt: 0)

        engine.onError?(PlaybackFailure(message: "Corrupt file"))
        // No time update: a file short enough to finish inside one observer
        // tick never reports a non-zero position.
        engine.finishTrack()
        engine.onError?(PlaybackFailure(message: "Corrupt file"))
        engine.onError?(PlaybackFailure(message: "Corrupt file"))

        #expect(player.currentTrack?.title == "Track 1")
        #expect(player.isPlaying)
        #expect(player.errorMessage == nil)
    }

    @Test("A file that ends without playing does not clear earlier failures")
    func instantFinishKeepsFailureCount() throws {
        let (player, engine) = try makeController()
        player.repeatMode = .all
        player.play(tracks: tracks(2), startAt: 0)
        // A zero-length or audio-less file reaches its end at position 0.
        engine.duration = 0

        engine.onError?(PlaybackFailure(message: "Corrupt file"))
        engine.finishTrack()
        engine.onError?(PlaybackFailure(message: "Corrupt file"))
        engine.onError?(PlaybackFailure(message: "Corrupt file"))

        #expect(player.isPlaying == false)
        #expect(player.errorMessage == "None of these tracks can be played right now.")
    }

    @Test("An unreachable queue reports the whole queue, not the last track tried")
    func unreachableQueueUnderRepeatOff() throws {
        let (player, engine) = try makeController()
        let missing = (1...3).map {
            Track(relativePath: "@missing/t\($0).mp3", title: "Track \($0)", duration: 200)
        }
        player.play(tracks: missing, startAt: 0)

        #expect(player.isPlaying == false)
        #expect(engine.loadedURLs.isEmpty)
        #expect(player.errorMessage == "None of these tracks are in a folder Lyra can reach right now.")
    }

    @Test("Skipping only part of a queue says so rather than blaming every track")
    func partiallyUnreachableQueue() throws {
        let (player, _) = try makeController()
        let mixed = [
            Track(relativePath: "t1.mp3", title: "Track 1", duration: 200),
            Track(relativePath: "@missing/t2.mp3", title: "Track 2", duration: 200),
            Track(relativePath: "@missing/t3.mp3", title: "Track 3", duration: 200),
        ]
        player.play(tracks: mixed, startAt: 1)

        #expect(player.isPlaying == false)
        #expect(player.errorMessage == "The rest of these tracks aren't in a folder Lyra can reach right now.")
    }

    @Test("Seeking is clamped to the track length")
    func seekClamping() throws {
        let (player, _) = try makeController()
        player.play(tracks: tracks(1), startAt: 0)

        player.seek(to: -50)
        #expect(player.currentTime == 0)

        player.seek(to: 99_999)
        #expect(player.currentTime == player.duration)
    }

    @Test("Playback resolution prefers a local copy over a remote stream")
    func playbackResolutionPrefersLocalCopy() {
        let track = Track(
            relativePath: "@remote/Album/Song.FLAC",
            title: "Song",
            fileSize: 42_000
        )
        let source = MusicSource(
            id: "remote",
            displayName: "Server",
            kind: .webDAV,
            serverURL: "https://server.example/music/",
            username: "listener"
        )
        let local = URL(filePath: "/tmp/Song.FLAC")

        #expect(PlaybackResourceResolver.resolve(track: track, localURL: local, source: source) == .local(local))
    }

    @Test("A remote-only track resolves to a non-secret stream descriptor")
    func playbackResolutionBuildsRemoteDescriptor() {
        let track = Track(
            relativePath: "@remote/Album/Song.FLAC",
            title: "Song",
            fileSize: 42_000
        )
        let source = MusicSource(
            id: "remote",
            displayName: "Server",
            kind: .webDAV,
            serverURL: "https://server.example/music/",
            username: "listener"
        )

        #expect(PlaybackResourceResolver.resolve(track: track, localURL: nil, source: source) == .remote(
            RemotePlaybackResource(
                sourceID: "remote",
                relativePath: "@remote/Album/Song.FLAC",
                contentLength: 42_000,
                duration: 0,
                fileExtension: "flac"
            )
        ))
        #expect(PlaybackResourceResolver.resolve(track: track, localURL: nil, source: nil) == nil)
    }
}
