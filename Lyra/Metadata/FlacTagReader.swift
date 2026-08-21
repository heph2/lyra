import Foundation

/// Minimal native FLAC metadata parser.
///
/// iOS decodes FLAC audio fine, but `AVAsset` routinely reports no metadata for
/// it. Rather than bundling a tag library, we read the handful of header blocks
/// we care about: STREAMINFO (duration), VORBIS_COMMENT (tags) and PICTURE
/// (cover art). Only the header region is read — never the audio frames.
///
/// Format reference: <https://xiph.org/flac/format.html>
enum FlacTagReader {

    private enum BlockType: UInt8 {
        case streamInfo = 0
        case vorbisComment = 4
        case picture = 6
    }

    /// Refuse absurd embedded images rather than paging a huge blob into memory.
    private static let maxPictureBytes = 16 * 1024 * 1024
    /// A metadata block larger than this is a malformed or hostile file.
    private static let maxBlockBytes = 32 * 1024 * 1024

    static func read(url: URL) -> TrackMetadata? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let magic = try? handle.read(upToCount: 4), magic == Data("fLaC".utf8) else {
            return nil
        }

        var metadata = TrackMetadata()
        var offset: UInt64 = 4
        var sawAnything = false

        // FLAC guarantees STREAMINFO first and marks the final block, so this
        // walk always terminates on a well-formed file.
        while true {
            guard let header = try? handle.read(upToCount: 4), header.count == 4 else { break }
            offset += 4

            let bytes = [UInt8](header)
            let isLast = bytes[0] & 0x80 != 0
            let rawType = bytes[0] & 0x7F
            let length = Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
            guard length >= 0, length <= maxBlockBytes else { break }

            switch BlockType(rawValue: rawType) {
            case .streamInfo:
                if let body = try? handle.read(upToCount: length), body.count == length {
                    if let seconds = parseStreamInfoDuration(body) { metadata.duration = seconds }
                    sawAnything = true
                }
            case .vorbisComment:
                if let body = try? handle.read(upToCount: length), body.count == length {
                    applyVorbisComments(body, to: &metadata)
                    sawAnything = true
                }
            case .picture:
                if metadata.artworkData == nil, length <= maxPictureBytes,
                   let body = try? handle.read(upToCount: length), body.count == length {
                    metadata.artworkData = parsePicture(body)
                    sawAnything = true
                } else {
                    try? handle.seek(toOffset: offset + UInt64(length))
                }
            case nil:
                try? handle.seek(toOffset: offset + UInt64(length))
            }

            offset += UInt64(length)
            // Blocks we consumed left the handle at `offset` already; blocks we
            // skipped were seeked explicitly. Re-seek defensively either way.
            try? handle.seek(toOffset: offset)

            if isLast { break }
        }

        return sawAnything ? metadata : nil
    }

    // MARK: - STREAMINFO

    /// Sample rate is 20 bits at bit offset 144; total sample count is 36 bits
    /// at bit offset 172, both inside the 34-byte STREAMINFO block.
    private static func parseStreamInfoDuration(_ body: Data) -> Double? {
        let b = [UInt8](body)
        guard b.count >= 34 else { return nil }

        let sampleRate = UInt32(b[10]) << 12 | UInt32(b[11]) << 4 | UInt32(b[12]) >> 4
        guard sampleRate > 0 else { return nil }

        var totalSamples = UInt64(b[13] & 0x0F) << 32
        totalSamples |= UInt64(b[14]) << 24
        totalSamples |= UInt64(b[15]) << 16
        totalSamples |= UInt64(b[16]) << 8
        totalSamples |= UInt64(b[17])
        guard totalSamples > 0 else { return nil }

        return Double(totalSamples) / Double(sampleRate)
    }

    // MARK: - VORBIS_COMMENT

    /// Vorbis comments are `KEY=value` UTF-8 strings with **little-endian**
    /// length prefixes — the one place FLAC is not big-endian.
    private static func applyVorbisComments(_ body: Data, to metadata: inout TrackMetadata) {
        var cursor = 0
        guard let vendorLength = readUInt32LE(body, at: &cursor) else { return }
        cursor += Int(vendorLength)

        guard let count = readUInt32LE(body, at: &cursor), count < 10_000 else { return }

        for _ in 0..<count {
            guard let length = readUInt32LE(body, at: &cursor),
                  length <= UInt32(body.count),
                  cursor + Int(length) <= body.count
            else { return }

            let range = body.startIndex + cursor ..< body.startIndex + cursor + Int(length)
            cursor += Int(length)

            guard let comment = String(data: body[range], encoding: .utf8),
                  let equals = comment.firstIndex(of: "=")
            else { continue }

            let key = comment[comment.startIndex..<equals].uppercased()
            let value = String(comment[comment.index(after: equals)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch key {
            case "TITLE": if metadata.title.isEmpty { metadata.title = value }
            case "ARTIST": if metadata.artist.isEmpty { metadata.artist = value }
            case "ALBUMARTIST", "ALBUM ARTIST":
                if metadata.albumArtist.isEmpty { metadata.albumArtist = value }
            case "ALBUM": if metadata.album.isEmpty { metadata.album = value }
            case "GENRE": if metadata.genre.isEmpty { metadata.genre = value }
            case "DATE", "YEAR":
                if metadata.year == 0 { metadata.year = MetadataReader.parseYear(value) }
            case "TRACKNUMBER":
                if metadata.trackNumber == 0 {
                    metadata.trackNumber = MetadataReader.parseLeadingInt(value) ?? 0
                }
            case "DISCNUMBER":
                if metadata.discNumber == 0 {
                    metadata.discNumber = MetadataReader.parseLeadingInt(value) ?? 0
                }
            default: break
            }
        }
    }

    // MARK: - PICTURE

    /// Layout: type(4) mimeLen(4) mime desc Len(4) desc w(4) h(4) depth(4)
    /// colors(4) dataLen(4) data — all big-endian.
    private static func parsePicture(_ body: Data) -> Data? {
        var cursor = 0
        guard readUInt32BE(body, at: &cursor) != nil else { return nil }       // picture type

        guard let mimeLength = readUInt32BE(body, at: &cursor) else { return nil }
        cursor += Int(mimeLength)

        guard let descLength = readUInt32BE(body, at: &cursor) else { return nil }
        cursor += Int(descLength)

        // width, height, colour depth, indexed colour count
        for _ in 0..<4 {
            guard readUInt32BE(body, at: &cursor) != nil else { return nil }
        }

        guard let dataLength = readUInt32BE(body, at: &cursor),
              dataLength > 0,
              cursor + Int(dataLength) <= body.count
        else { return nil }

        let range = body.startIndex + cursor ..< body.startIndex + cursor + Int(dataLength)
        return Data(body[range])
    }

    // MARK: - Byte helpers

    private static func readUInt32LE(_ data: Data, at cursor: inout Int) -> UInt32? {
        guard cursor >= 0, cursor + 4 <= data.count else { return nil }
        let i = data.startIndex + cursor
        let value = UInt32(data[i])
            | UInt32(data[i + 1]) << 8
            | UInt32(data[i + 2]) << 16
            | UInt32(data[i + 3]) << 24
        cursor += 4
        return value
    }

    private static func readUInt32BE(_ data: Data, at cursor: inout Int) -> UInt32? {
        guard cursor >= 0, cursor + 4 <= data.count else { return nil }
        let i = data.startIndex + cursor
        let value = UInt32(data[i]) << 24
            | UInt32(data[i + 1]) << 16
            | UInt32(data[i + 2]) << 8
            | UInt32(data[i + 3])
        cursor += 4
        return value
    }
}
