import Foundation
import Testing

@testable import Lyra

/// Builds real FLAC *headers* (no audio frames) so the parser can be tested
/// without checking binary fixtures into the repo.
private struct FlacHeaderBuilder {
    var sampleRate: UInt32 = 44_100
    var totalSamples: UInt64 = 44_100 * 180  // three minutes
    var comments: [String] = []
    var pictureBytes: Data?

    func build() -> Data {
        var data = Data("fLaC".utf8)

        var blocks: [(type: UInt8, body: Data)] = []
        blocks.append((0, streamInfoBody()))
        if !comments.isEmpty { blocks.append((4, vorbisCommentBody())) }
        if let pictureBytes { blocks.append((6, pictureBody(pictureBytes))) }

        for (index, block) in blocks.enumerated() {
            let isLast = index == blocks.count - 1
            data.append(block.type | (isLast ? 0x80 : 0x00))
            let length = UInt32(block.body.count)
            data.append(UInt8((length >> 16) & 0xFF))
            data.append(UInt8((length >> 8) & 0xFF))
            data.append(UInt8(length & 0xFF))
            data.append(block.body)
        }
        return data
    }

    /// 34 bytes: block sizes, frame sizes, a packed 64-bit word, then MD5.
    private func streamInfoBody() -> Data {
        var body = Data()
        body.append(contentsOf: [0x10, 0x00, 0x10, 0x00])        // min/max block size
        body.append(contentsOf: [0, 0, 0, 0, 0, 0])              // min/max frame size

        // sampleRate(20) | channels-1(3) | bitsPerSample-1(5) | totalSamples(36)
        let word = (UInt64(sampleRate) << 44)
            | (UInt64(1) << 41)          // 2 channels
            | (UInt64(15) << 36)         // 16 bits per sample
            | (totalSamples & 0xF_FFFF_FFFF)
        for shift in stride(from: 56, through: 0, by: -8) {
            body.append(UInt8((word >> UInt64(shift)) & 0xFF))
        }

        body.append(Data(repeating: 0, count: 16))               // MD5 of audio
        return body
    }

    /// Vorbis comments use little-endian lengths — the one place FLAC is not
    /// big-endian, and the easiest thing to get wrong.
    private func vorbisCommentBody() -> Data {
        var body = Data()
        let vendor = Data("reference libFLAC".utf8)
        body.append(uint32LE(UInt32(vendor.count)))
        body.append(vendor)
        body.append(uint32LE(UInt32(comments.count)))
        for comment in comments {
            let bytes = Data(comment.utf8)
            body.append(uint32LE(UInt32(bytes.count)))
            body.append(bytes)
        }
        return body
    }

    private func pictureBody(_ image: Data) -> Data {
        var body = Data()
        body.append(uint32BE(3))                                 // front cover
        let mime = Data("image/jpeg".utf8)
        body.append(uint32BE(UInt32(mime.count)))
        body.append(mime)
        body.append(uint32BE(0))                                 // empty description
        body.append(uint32BE(500))                               // width
        body.append(uint32BE(500))                               // height
        body.append(uint32BE(24))                                // colour depth
        body.append(uint32BE(0))                                 // indexed colours
        body.append(uint32BE(UInt32(image.count)))
        body.append(image)
        return body
    }

    private func uint32LE(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }

    private func uint32BE(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
}

@Suite("FLAC header parsing")
struct FlacTagReaderTests {

    private func write(_ data: Data, name: String = "test.flac") throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try data.write(to: url)
        return url
    }

    @Test("Vorbis comments become tags")
    func readsComments() throws {
        let builder = FlacHeaderBuilder(comments: [
            "TITLE=Idioteque",
            "ARTIST=Radiohead",
            "ALBUMARTIST=Radiohead",
            "ALBUM=Kid A",
            "GENRE=Electronic",
            "DATE=2000-10-02",
            "TRACKNUMBER=8/10",
            "DISCNUMBER=1",
        ])
        let url = try write(builder.build())

        let metadata = try #require(FlacTagReader.read(url: url))
        #expect(metadata.title == "Idioteque")
        #expect(metadata.artist == "Radiohead")
        #expect(metadata.albumArtist == "Radiohead")
        #expect(metadata.album == "Kid A")
        #expect(metadata.genre == "Electronic")
        #expect(metadata.year == 2000)
        #expect(metadata.trackNumber == 8)
        #expect(metadata.discNumber == 1)
    }

    @Test("STREAMINFO gives the duration")
    func readsDuration() throws {
        let builder = FlacHeaderBuilder(
            sampleRate: 48_000,
            totalSamples: 48_000 * 240,
            comments: ["TITLE=Long One"]
        )
        let url = try write(builder.build())

        let metadata = try #require(FlacTagReader.read(url: url))
        #expect(abs(metadata.duration - 240) < 0.01)
    }

    @Test("Embedded cover art is extracted intact")
    func readsPicture() throws {
        let image = Data((0..<512).map { UInt8($0 % 251) })
        let builder = FlacHeaderBuilder(comments: ["TITLE=With Art"], pictureBytes: image)
        let url = try write(builder.build())

        let metadata = try #require(FlacTagReader.read(url: url))
        #expect(metadata.artworkData == image)
    }

    @Test("Non-FLAC input is rejected rather than misparsed")
    func rejectsNonFlac() throws {
        let url = try write(Data("ID3\u{03}not a flac file at all".utf8), name: "fake.flac")
        #expect(FlacTagReader.read(url: url) == nil)
    }

    @Test("A truncated file does not hang or crash")
    func handlesTruncation() throws {
        var data = FlacHeaderBuilder(comments: ["TITLE=Cut Short"]).build()
        data = data.prefix(20)
        let url = try write(data, name: "truncated.flac")

        // Either nil or partial metadata is acceptable; not returning is not.
        _ = FlacTagReader.read(url: url)
    }
}
