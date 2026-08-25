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

    @Test("Downloaded-only filtering excludes local and cloud-only tracks")
    func downloadedOnlyFiltering() {
        let local = Track(relativePath: "Artist/local.flac", title: "Local")
        let cloud = Track(relativePath: "@server/Artist/cloud.flac", title: "Cloud")
        let downloaded = Track(relativePath: "@server/Artist/downloaded.flac", title: "Downloaded")
        downloaded.offlineRequested = true
        downloaded.offlineState = .availableOffline
        let stale = Track(relativePath: "@server/Artist/stale.flac", title: "Stale")
        stale.offlineRequested = true
        stale.offlineState = .modifiedRemote

        #expect(
            OfflinePresentation.downloadedTracks(from: [local, cloud, downloaded, stale]).map(\.title)
                == ["Downloaded", "Stale"]
        )
    }

    @Test("Album download progress is weighted by file size")
    func weightedAlbumProgress() {
        let first = Track(relativePath: "@server/Album/1.flac", title: "One", fileSize: 100)
        first.offlineRequested = true
        first.offlineState = .downloading
        let second = Track(relativePath: "@server/Album/2.flac", title: "Two", fileSize: 300)
        second.offlineRequested = true
        second.offlineState = .availableOffline

        let fraction = OfflinePresentation.aggregateProgress(
            for: [first, second],
            fractions: [first.relativePath: 0.5]
        )

        #expect(fraction == 0.875)
    }

    @Test("Byte progress is clamped to a displayable fraction")
    func byteProgressClamping() {
        #expect(OfflineDownloadProgress(receivedBytes: 25, totalBytes: 100).fraction == 0.25)
        #expect(OfflineDownloadProgress(receivedBytes: 120, totalBytes: 100).fraction == 1)
        #expect(OfflineDownloadProgress(receivedBytes: 1, totalBytes: 0).fraction == 0)
    }
}
