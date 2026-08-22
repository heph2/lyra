import Testing

@testable import Lyra

@Suite("Offline library cache")
struct OfflineLibraryTests {

    @Test("Remote cache paths stay inside an app-owned library directory")
    func cachePath() throws {
        let url = try #require(OfflineLibrary.fileURL(
            sourceID: "remote-library",
            innerPath: "Artist/Album/01 Song.flac"
        ))

        #expect(url.path.hasSuffix("Libraries/remote-library/Music/Artist/Album/01 Song.flac"))
    }

    @Test("Cache paths reject source and file traversal")
    func rejectsTraversal() {
        #expect(OfflineLibrary.fileURL(sourceID: "../server", innerPath: "song.flac") == nil)
        #expect(OfflineLibrary.fileURL(sourceID: "server", innerPath: "Artist/../song.flac") == nil)
        #expect(OfflineLibrary.fileURL(sourceID: "server", innerPath: "/song.flac") == nil)
    }

    @Test("Remote tracks begin as unselected")
    func trackDefaults() {
        let track = Track(relativePath: "@server/Artist/song.flac", title: "Song")
        #expect(!track.offlineRequested)
        #expect(track.offlineState == .availableRemote)
    }
}
