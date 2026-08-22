import Foundation
import Testing

@testable import Lyra

@Suite("Tag value parsing")
struct MetadataParsingTests {

    @Test("Only front-tag formats receive remote metadata range reads")
    func remoteHeaderFormats() {
        #expect(MetadataReader.supportsRemoteHeaderMetadata(fileExtension: "flac"))
        #expect(MetadataReader.supportsRemoteHeaderMetadata(fileExtension: "MP3"))
        #expect(!MetadataReader.supportsRemoteHeaderMetadata(fileExtension: "wav"))
        #expect(!MetadataReader.supportsRemoteHeaderMetadata(fileExtension: "m4a"))
    }

    @Test("Track numbers arrive as plain numbers or as \"n/total\"")
    func leadingInt() {
        #expect(MetadataReader.parseLeadingInt("3/12") == 3)
        #expect(MetadataReader.parseLeadingInt("07") == 7)
        #expect(MetadataReader.parseLeadingInt("12") == 12)
        #expect(MetadataReader.parseLeadingInt("") == nil)
        #expect(MetadataReader.parseLeadingInt("none") == nil)
        // Zero is not a valid track number and must not be mistaken for one.
        #expect(MetadataReader.parseLeadingInt("0") == nil)
    }

    @Test("iTunes trkn atoms are a big-endian byte pair at offset 2")
    func iTunesNumberPair() {
        #expect(MetadataReader.parseITunesNumberPair(Data([0, 0, 0, 5, 0, 12])) == 5)
        #expect(MetadataReader.parseITunesNumberPair(Data([0, 0, 1, 0, 0, 20])) == 256)
        #expect(MetadataReader.parseITunesNumberPair(Data([0, 0])) == nil)
        #expect(MetadataReader.parseITunesNumberPair(Data([0, 0, 0, 0])) == nil)
    }

    @Test("Years come in as bare years or full ISO dates")
    func years() {
        #expect(MetadataReader.parseYear("1997") == 1997)
        #expect(MetadataReader.parseYear("1997-06-16") == 1997)
        #expect(MetadataReader.parseYear("2001-01-01T00:00:00Z") == 2001)
        #expect(MetadataReader.parseYear("") == 0)
        #expect(MetadataReader.parseYear("97") == 0)
    }
}

@Suite("Path-derived metadata fallbacks")
struct PathFallbackTests {

    @Test("An Artist/Album/NN Title tree fills in everything")
    func fullTree() {
        var metadata = TrackMetadata()
        metadata.applyPathFallbacks(relativePath: "Radiohead/Kid A/03 The National Anthem.flac")

        #expect(metadata.title == "The National Anthem")
        #expect(metadata.artist == "Radiohead")
        #expect(metadata.album == "Kid A")
        #expect(metadata.albumArtist == "Radiohead")
        #expect(metadata.trackNumber == 3)
    }

    @Test("Existing tags are never overwritten by the path")
    func doesNotClobberTags() {
        var metadata = TrackMetadata(title: "Real Title", artist: "Real Artist", album: "Real Album", trackNumber: 9)
        metadata.applyPathFallbacks(relativePath: "Wrong/Wrong Album/01 Wrong Title.mp3")

        #expect(metadata.title == "Real Title")
        #expect(metadata.artist == "Real Artist")
        #expect(metadata.album == "Real Album")
        #expect(metadata.trackNumber == 9)
    }

    @Test("A loose file at the root still gets a usable title")
    func bareFile() {
        var metadata = TrackMetadata()
        metadata.applyPathFallbacks(relativePath: "some song.mp3")

        #expect(metadata.title == "some song")
        #expect(metadata.artist.isEmpty)
        #expect(metadata.album.isEmpty)
    }

    @Test("A numeric title is not mistaken for a track number")
    func numericTitle() {
        var metadata = TrackMetadata()
        metadata.applyPathFallbacks(relativePath: "1984.mp3")

        #expect(metadata.title == "1984")
        #expect(metadata.trackNumber == 0)
    }

    @Test("Separator styles between number and title all work")
    func separators() {
        for name in ["01 - Title.mp3", "01_Title.mp3", "01.Title.mp3", "01 Title.mp3"] {
            var metadata = TrackMetadata()
            metadata.applyPathFallbacks(relativePath: name)
            #expect(metadata.title == "Title", "failed for \(name)")
            #expect(metadata.trackNumber == 1, "failed for \(name)")
        }
    }

    /// A remote scan only ever reads the front of the file, so the declared
    /// ID3 tag size routinely exceeds what arrived. The frames that did arrive
    /// still have to be read, or a WebDAV library indexes as filenames.
    @Test("An ID3 tag cut short by a ranged read still yields its text frames")
    func truncatedID3Tag() {
        var tag = Data("ID3".utf8)
        tag.append(contentsOf: [0x03, 0x00, 0x00])          // v2.3, no flags
        tag.append(contentsOf: synchsafe(2_000_000))        // claims a huge tag
        tag.append(textFrame("TIT2", "Real Title"))
        tag.append(textFrame("TPE1", "Real Artist"))
        tag.append(textFrame("TALB", "Real Album"))
        // …and then the read stopped, mid cover art.

        let metadata = MetadataReader.read(
            headerData: tag,
            fileExtension: "mp3",
            relativePath: "Folder/Album/01 Wrong.mp3"
        )

        #expect(metadata.title == "Real Title")
        #expect(metadata.artist == "Real Artist")
        #expect(metadata.album == "Real Album")
        #expect(metadata.artworkData == nil)
    }

    private func synchsafe(_ value: Int) -> [UInt8] {
        [24, 16, 8, 0].map { UInt8((value >> $0) & 0x7F) }
    }

    private func textFrame(_ identifier: String, _ text: String) -> Data {
        let body = Data([0x03]) + Data(text.utf8)  // UTF-8 encoding byte
        var frame = Data(identifier.utf8)
        let size = body.count
        frame.append(contentsOf: [
            UInt8((size >> 24) & 0xFF), UInt8((size >> 16) & 0xFF),
            UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF),
        ])
        frame.append(contentsOf: [0x00, 0x00])     // frame flags
        frame.append(body)
        return frame
    }
}
