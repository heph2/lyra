import Foundation
import SwiftData
import Testing

@testable import Lyra

private func makeTrack(
    _ path: String,
    title: String? = nil,
    artist: String = "",
    albumArtist: String = "",
    album: String = "",
    track: Int = 0,
    disc: Int = 0,
    duration: Double = 180
) -> Track {
    Track(
        relativePath: path,
        title: title ?? (path as NSString).lastPathComponent,
        artist: artist,
        albumArtist: albumArtist,
        album: album,
        trackNumber: track,
        discNumber: disc,
        duration: duration
    )
}

@Suite("Path handling")
struct AudioFileTests {

    @Test("Only known audio extensions are picked up")
    func extensionFiltering() {
        #expect(AudioFile.isSupported(URL(filePath: "/x/song.mp3")))
        #expect(AudioFile.isSupported(URL(filePath: "/x/song.FLAC")))     // case-insensitive
        #expect(AudioFile.isSupported(URL(filePath: "/x/song.m4a")))
        #expect(!AudioFile.isSupported(URL(filePath: "/x/cover.jpg")))
        #expect(!AudioFile.isSupported(URL(filePath: "/x/notes.txt")))
        // Deliberately unsupported: would need FFmpeg.
        #expect(!AudioFile.isSupported(URL(filePath: "/x/song.opus")))
        #expect(!AudioFile.isSupported(URL(filePath: "/x/song.ogg")))
    }

    @Test("Relative paths round-trip through the Documents directory")
    func roundTrip() throws {
        let url = AudioFile.url(forRelativePath: "Artist/Album/01 Song.mp3")
        let back = try #require(AudioFile.relativePath(for: url))
        #expect(back == "Artist/Album/01 Song.mp3")
    }

    @Test("Files outside Documents are refused, not silently accepted")
    func rejectsOutsidePaths() {
        #expect(AudioFile.relativePath(for: URL(filePath: "/etc/passwd")) == nil)
    }

    @Test("Parent folder extraction")
    func parentFolders() {
        #expect(AudioFile.parentFolder(ofRelativePath: "A/B/c.mp3") == "A/B")
        #expect(AudioFile.parentFolder(ofRelativePath: "c.mp3") == "")
        #expect(AudioFile.folderDisplayName("A/B") == "B")
        #expect(AudioFile.folderDisplayName("") == "Documents")
    }
}

@Suite("Local folder source")
struct LocalFolderSourceTests {

    @Test("A selected folder recursively exposes supported music")
    func enumeratesNestedMusic() throws {
        let root = URL.temporaryDirectory.appending(
            path: "LyraLocalSource-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let album = root.appending(path: "Artist/Album", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data().write(to: album.appending(path: "01 Song.wav"))
        try Data().write(to: album.appending(path: "cover.jpg"))

        let files = LocalFolderSource.enumerateAudioFiles(in: root, sourceID: "picked-folder")

        #expect(files.map(\.relativePath) == ["@picked-folder/Artist/Album/01 Song.wav"])
    }
}

@Suite("Grouping")
struct LibraryGroupingTests {

    private var sample: [Track] {
        [
            makeTrack("RH/Kid A/01.flac", title: "Everything", artist: "Radiohead", albumArtist: "Radiohead", album: "Kid A", track: 1),
            makeTrack("RH/Kid A/02.flac", title: "Kid A", artist: "Radiohead", albumArtist: "Radiohead", album: "Kid A", track: 2),
            makeTrack("RH/Amnesiac/01.flac", title: "Packt", artist: "Radiohead", albumArtist: "Radiohead", album: "Amnesiac", track: 1),
            makeTrack("VA/Comp/01.mp3", title: "Guest Song", artist: "Someone Else", albumArtist: "Various Artists", album: "Comp", track: 1),
        ]
    }

    @Test("Albums group by album artist, so features do not split them")
    func albumGrouping() {
        let albums = LibraryGrouping.albums(from: sample)
        #expect(albums.count == 3)

        let kidA = albums.first { $0.title == "Kid A" }
        #expect(kidA?.tracks.count == 2)
        #expect(kidA?.artist == "Radiohead")

        // The compilation stays under its album artist rather than the guest.
        let comp = albums.first { $0.title == "Comp" }
        #expect(comp?.artist == "Various Artists")
    }

    @Test("Album tracks come out in disc then track order")
    func albumTrackOrder() {
        let tracks = [
            makeTrack("a/3.mp3", title: "Third", album: "X", track: 3, disc: 1),
            makeTrack("a/1.mp3", title: "First", album: "X", track: 1, disc: 1),
            makeTrack("a/d2.mp3", title: "Disc Two", album: "X", track: 1, disc: 2),
        ]
        let ordered = LibraryGrouping.sortedForAlbum(tracks)
        #expect(ordered.map(\.title) == ["First", "Third", "Disc Two"])
    }

    @Test("Artists are grouped and album-counted")
    func artistGrouping() {
        let artists = LibraryGrouping.artists(from: sample)
        let radiohead = artists.first { $0.name == "Radiohead" }
        #expect(radiohead?.tracks.count == 3)
        #expect(radiohead?.albumCount == 2)
    }

    @Test("The folder tree shows immediate children only")
    func folderTree() {
        let tracks = [
            makeTrack("Rock/Band/a.mp3"),
            makeTrack("Rock/Band/b.mp3"),
            makeTrack("Rock/Other/c.mp3"),
            makeTrack("loose.mp3"),
        ]

        let local = LibraryManager.dropZoneID
        let root = LibraryGrouping.folder(at: "", sourceID: local, tracks: tracks)
        #expect(root.subfolders == ["Rock"])
        #expect(root.tracks.count == 1)

        let rock = LibraryGrouping.folder(at: "Rock", sourceID: local, tracks: tracks)
        #expect(rock.subfolders == ["Rock/Band", "Rock/Other"])
        #expect(rock.tracks.isEmpty)
    }

    @Test("Playing a folder queues everything beneath it")
    func recursiveTracks() {
        let tracks = [
            makeTrack("Rock/Band/a.mp3"),
            makeTrack("Rock/Other/c.mp3"),
            makeTrack("Jazz/d.mp3"),
        ]
        let local = LibraryManager.dropZoneID
        #expect(LibraryGrouping.tracksRecursively(under: "Rock", sourceID: local, tracks: tracks).count == 2)
        #expect(LibraryGrouping.tracksRecursively(under: "", sourceID: local, tracks: tracks).count == 3)
    }

    @Test("Folder browsing keeps sources apart")
    func foldersAreScopedToTheirSource() {
        let external = "11111111-2222-3333-4444-555555555555"
        let tracks = [
            makeTrack("Albums/One/a.mp3"),
            makeTrack(AudioFile.trackPath(sourceID: external, innerPath: "Albums/One/b.mp3")),
        ]

        // Same folder name in two different sources must not merge.
        let localRoot = LibraryGrouping.folder(at: "", sourceID: LibraryManager.dropZoneID, tracks: tracks)
        #expect(localRoot.subfolders == ["Albums"])
        #expect(LibraryGrouping.tracksRecursively(
            under: "Albums", sourceID: LibraryManager.dropZoneID, tracks: tracks
        ).count == 1)

        #expect(LibraryGrouping.tracksRecursively(
            under: "Albums", sourceID: external, tracks: tracks
        ).count == 1)
    }
}

@Suite("Source-qualified track paths")
struct TrackPathTests {

    @Test("Drop-zone paths stay bare, so old libraries keep working")
    func dropZoneRoundTrip() {
        let path = AudioFile.trackPath(
            sourceID: LibraryManager.dropZoneID,
            innerPath: "Artist/Album/01 Song.mp3"
        )
        #expect(path == "Artist/Album/01 Song.mp3")

        let split = AudioFile.split(trackPath: path)
        #expect(split.sourceID == LibraryManager.dropZoneID)
        #expect(split.innerPath == "Artist/Album/01 Song.mp3")
    }

    @Test("External paths carry their source and round-trip")
    func externalRoundTrip() {
        let id = "11111111-2222-3333-4444-555555555555"
        let path = AudioFile.trackPath(sourceID: id, innerPath: "Album/Song.flac")
        #expect(path == "@\(id)/Album/Song.flac")

        let split = AudioFile.split(trackPath: path)
        #expect(split.sourceID == id)
        #expect(split.innerPath == "Album/Song.flac")
    }

    @Test("Awkward characters in paths survive the round trip")
    func trickyCharacters() {
        let id = "abc-123"
        for inner in [
            "Sigur Rós/( )/01 Untitled #1.flac",
            "AC⚡DC/Back in Black/song 100%.mp3",
            "Someone's Album/what? maybe.m4a",
            "Deeply/Nested/Set/Of/Folders/track.wav",
        ] {
            let split = AudioFile.split(trackPath: AudioFile.trackPath(sourceID: id, innerPath: inner))
            #expect(split.sourceID == id, "failed for \(inner)")
            #expect(split.innerPath == inner, "failed for \(inner)")
        }
    }

    @Test("A track records which source it belongs to")
    func trackDerivesItsSource() {
        let id = "deadbeef"
        let track = Track(
            relativePath: AudioFile.trackPath(sourceID: id, innerPath: "Album/Song.flac"),
            title: "Song"
        )
        #expect(track.sourceID == id)
        #expect(track.innerPath == "Album/Song.flac")
        // The @id prefix must not leak into the browsable folder tree.
        #expect(track.folderPath == "Album")
        #expect(!track.isFromDropZone)
    }
}

@Suite("Sorting")
struct TrackSortTests {

    @Test("Recently added sorts newest first")
    func dateAdded() {
        let old = makeTrack("a.mp3", title: "Old")
        old.dateAdded = Date(timeIntervalSince1970: 1000)
        let new = makeTrack("b.mp3", title: "New")
        new.dateAdded = Date(timeIntervalSince1970: 2000)

        #expect(TrackSort.dateAdded.apply(to: [old, new]).map(\.title) == ["New", "Old"])
    }

    @Test("Title sort is natural, so track 10 follows track 9")
    func naturalTitleOrder() {
        let tracks = [makeTrack("x", title: "Song 10"), makeTrack("y", title: "Song 9")]
        #expect(TrackSort.title.apply(to: tracks).map(\.title) == ["Song 9", "Song 10"])
    }
}

@Suite("Playlists")
@MainActor
struct PlaylistTests {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Track.self, Playlist.self])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test("Adding the same track twice is a no-op")
    func deduplicatesOnAppend() {
        let playlist = Playlist(name: "Mix")
        playlist.append(paths: ["a.mp3", "b.mp3"])
        playlist.append(paths: ["b.mp3", "c.mp3"])
        #expect(playlist.trackPaths == ["a.mp3", "b.mp3", "c.mp3"])
    }

    @Test("Reordering preserves membership")
    func reorder() {
        let playlist = Playlist(name: "Mix", trackPaths: ["a", "b", "c"])
        playlist.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(playlist.trackPaths == ["c", "a", "b"])
    }

    @Test("Resolution keeps playlist order, not database order")
    func resolvesInPlaylistOrder() throws {
        let context = try makeContext()
        for path in ["a.mp3", "b.mp3", "c.mp3"] {
            context.insert(makeTrack(path, title: path))
        }
        try context.save()

        let playlist = Playlist(name: "Mix", trackPaths: ["c.mp3", "a.mp3", "b.mp3"])
        #expect(playlist.resolveTracks(in: context).map(\.relativePath) == ["c.mp3", "a.mp3", "b.mp3"])
    }

    @Test("A path whose file is gone drops out instead of crashing")
    func skipsMissingTracks() throws {
        let context = try makeContext()
        context.insert(makeTrack("a.mp3", title: "A"))
        try context.save()

        let playlist = Playlist(name: "Mix", trackPaths: ["a.mp3", "deleted.mp3"])
        #expect(playlist.resolveTracks(in: context).map(\.relativePath) == ["a.mp3"])
    }
}
