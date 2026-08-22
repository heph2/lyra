import AVFoundation
import Foundation

/// Reads tags out of an audio file.
///
/// `AVAsset` handles MP3/MP4/AIFF/WAV well. FLAC is the exception: iOS decodes
/// the audio but frequently exposes no metadata at all, so `FlacTagReader`
/// parses the Vorbis comment block directly when AVFoundation comes up empty.
enum MetadataReader {

    /// The remote scanner only requests a bounded prefix for formats whose
    /// tags can be read from it. MP4 and WAV metadata can live later in the
    /// file, so a ranged read would add latency without improving the index.
    static func supportsRemoteHeaderMetadata(fileExtension: String) -> Bool {
        ["flac", "mp3"].contains(fileExtension.lowercased())
    }

    static func read(url: URL, relativePath: String) async -> TrackMetadata {
        var metadata = await readViaAVFoundation(url: url)

        if url.pathExtension.lowercased() == "flac", metadata.needsTagFallback {
            if let flac = FlacTagReader.read(url: url) {
                metadata.merge(filling: flac)
            }
        }

        metadata.applyPathFallbacks(relativePath: relativePath)
        return metadata
    }

    /// Reads the tag formats whose metadata lives at the front of a file. MP4
    /// atoms can live at the end, so those intentionally fall through to the
    /// same filename/path metadata used for an untagged local file.
    static func read(headerData: Data, fileExtension: String, relativePath: String) -> TrackMetadata {
        let ext = fileExtension.lowercased()
        var metadata = switch ext {
        case "flac": FlacTagReader.read(data: headerData) ?? TrackMetadata()
        case "mp3": ID3TagReader.read(headerData) ?? TrackMetadata()
        default: TrackMetadata()
        }
        metadata.applyPathFallbacks(relativePath: relativePath)
        return metadata
    }

    // MARK: - AVFoundation

    private static func readViaAVFoundation(url: URL) async -> TrackMetadata {
        var result = TrackMetadata()
        let asset = AVURLAsset(url: url)

        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 { result.duration = seconds }
        }

        // Collect every metadata item the container exposes: the common keyspace
        // plus the format-specific ones (ID3, iTunes), since track/disc number
        // and album artist only exist in the latter.
        var items: [AVMetadataItem] = (try? await asset.load(.metadata)) ?? []
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                if let formatItems = try? await asset.loadMetadata(for: format) {
                    items.append(contentsOf: formatItems)
                }
            }
        }
        guard !items.isEmpty else { return result }

        result.title = await string(in: items, .commonIdentifierTitle, .id3MetadataTitleDescription, .iTunesMetadataSongName) ?? ""
        result.artist = await string(in: items, .commonIdentifierArtist, .id3MetadataLeadPerformer, .iTunesMetadataArtist) ?? ""
        result.album = await string(in: items, .commonIdentifierAlbumName, .id3MetadataAlbumTitle, .iTunesMetadataAlbum) ?? ""
        result.albumArtist = await string(in: items, .iTunesMetadataAlbumArtist, .id3MetadataBand) ?? ""
        result.genre = await string(in: items, .id3MetadataContentType, .iTunesMetadataUserGenre, .quickTimeMetadataGenre) ?? ""

        if let raw = await string(in: items, .commonIdentifierCreationDate, .id3MetadataRecordingTime, .id3MetadataYear, .iTunesMetadataReleaseDate) {
            result.year = parseYear(raw)
        }

        if let raw = await number(in: items, .id3MetadataTrackNumber, .iTunesMetadataTrackNumber) {
            result.trackNumber = raw
        }
        if let raw = await number(in: items, .id3MetadataPartOfASet, .iTunesMetadataDiscNumber) {
            result.discNumber = raw
        }

        result.artworkData = await artwork(in: items)
        return result
    }

    // MARK: - Item extraction

    private static func string(
        in items: [AVMetadataItem],
        _ identifiers: AVMetadataIdentifier...
    ) async -> String? {
        for identifier in identifiers {
            let matches = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier)
            for item in matches {
                if let value = try? await item.load(.stringValue) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
        }
        return nil
    }

    /// Track/disc numbers arrive in three shapes depending on container:
    /// a plain number, the string "3/12", or raw big-endian bytes (iTunes).
    private static func number(
        in items: [AVMetadataItem],
        _ identifiers: AVMetadataIdentifier...
    ) async -> Int? {
        for identifier in identifiers {
            let matches = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier)
            for item in matches {
                if let value = try? await item.load(.numberValue), value.intValue > 0 {
                    return value.intValue
                }
                if let text = try? await item.load(.stringValue),
                   let parsed = parseLeadingInt(text) {
                    return parsed
                }
                if let data = try? await item.load(.dataValue),
                   let parsed = parseITunesNumberPair(data) {
                    return parsed
                }
            }
        }
        return nil
    }

    private static func artwork(in items: [AVMetadataItem]) async -> Data? {
        let identifiers: [AVMetadataIdentifier] = [
            .commonIdentifierArtwork,
            .id3MetadataAttachedPicture,
            .iTunesMetadataCoverArt,
        ]
        for identifier in identifiers {
            let matches = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier)
            for item in matches {
                if let data = try? await item.load(.dataValue), !data.isEmpty {
                    return data
                }
            }
        }
        return nil
    }

    // MARK: - Parsing helpers

    /// "3/12" → 3, "07" → 7, "" → nil
    static func parseLeadingInt(_ text: String) -> Int? {
        let digits = text.drop { !$0.isNumber }.prefix { $0.isNumber }
        guard !digits.isEmpty, let value = Int(digits), value > 0 else { return nil }
        return value
    }

    /// iTunes `trkn`/`disk` atoms are a byte blob laid out as
    /// `[0, 0, index_hi, index_lo, total_hi, total_lo, ...]`.
    static func parseITunesNumberPair(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        let value = Int(bytes[2]) << 8 | Int(bytes[3])
        return value > 0 ? value : nil
    }

    /// Accepts "1997", "1997-06-16", "1997-06-16T00:00:00Z".
    static func parseYear(_ text: String) -> Int {
        let digits = text.prefix { $0.isNumber }
        guard digits.count == 4, let year = Int(digits), (1000...3000).contains(year) else { return 0 }
        return year
    }
}

private enum ID3TagReader {
    static func read(_ data: Data) -> TrackMetadata? {
        let bytes = [UInt8](data)
        guard bytes.count >= 10, Array(bytes[0..<3]) == Array("ID3".utf8),
              (2...4).contains(Int(bytes[3]))
        else { return nil }

        let version = Int(bytes[3])
        guard let tagSize = synchsafe(bytes[6...9]) else { return nil }
        // A ranged read of a remote file usually stops inside the tag, because
        // embedded cover art is most of it. Parse the frames that did arrive:
        // the text frames come first, so the title and artist survive even
        // when the picture does not.
        let end = min(10 + tagSize, bytes.count)
        var cursor = 10
        var metadata = TrackMetadata()
        var sawFrame = false

        while cursor < end {
            let headerLength = version == 2 ? 6 : 10
            guard cursor + headerLength <= end else { break }
            let identifier: String
            let frameSize: Int
            if version == 2 {
                identifier = String(bytes: bytes[cursor..<(cursor + 3)], encoding: .ascii) ?? ""
                frameSize = Int(bytes[cursor + 3]) << 16 | Int(bytes[cursor + 4]) << 8 | Int(bytes[cursor + 5])
            } else {
                identifier = String(bytes: bytes[cursor..<(cursor + 4)], encoding: .ascii) ?? ""
                frameSize = version == 4
                    ? (synchsafe(bytes[(cursor + 4)..<(cursor + 8)]) ?? 0)
                    : Int(bytes[cursor + 4]) << 24 | Int(bytes[cursor + 5]) << 16 | Int(bytes[cursor + 6]) << 8 | Int(bytes[cursor + 7])
            }
            guard !identifier.isEmpty, frameSize > 0, cursor + headerLength + frameSize <= end else { break }
            let body = Data(bytes[(cursor + headerLength)..<(cursor + headerLength + frameSize)])
            apply(identifier: identifier, body: body, to: &metadata)
            sawFrame = true
            cursor += headerLength + frameSize
        }
        return sawFrame ? metadata : nil
    }

    private static func apply(identifier: String, body: Data, to metadata: inout TrackMetadata) {
        let text = decodedText(body)
        switch identifier {
        case "TIT2", "TT2": if metadata.title.isEmpty { metadata.title = text }
        case "TPE1", "TP1": if metadata.artist.isEmpty { metadata.artist = text }
        case "TPE2", "TP2": if metadata.albumArtist.isEmpty { metadata.albumArtist = text }
        case "TALB", "TAL": if metadata.album.isEmpty { metadata.album = text }
        case "TCON", "TCO": if metadata.genre.isEmpty { metadata.genre = text }
        case "TDRC", "TYER", "TYE": if metadata.year == 0 { metadata.year = MetadataReader.parseYear(text) }
        case "TRCK", "TRK": if metadata.trackNumber == 0 { metadata.trackNumber = MetadataReader.parseLeadingInt(text) ?? 0 }
        case "TPOS", "TPA": if metadata.discNumber == 0 { metadata.discNumber = MetadataReader.parseLeadingInt(text) ?? 0 }
        case "APIC", "PIC": if metadata.artworkData == nil { metadata.artworkData = artwork(body, isV22: identifier == "PIC") }
        default: break
        }
    }

    private static func decodedText(_ body: Data) -> String {
        guard let encoding = body.first else { return "" }
        let bytes = body.dropFirst()
        let value: String?
        switch encoding {
        case 0: value = String(data: bytes, encoding: .isoLatin1)
        case 1: value = String(data: bytes, encoding: .utf16)
        case 2: value = String(data: bytes, encoding: .utf16BigEndian)
        case 3: value = String(data: bytes, encoding: .utf8)
        default: value = nil
        }
        return (value ?? "").trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
    }

    private static func artwork(_ body: Data, isV22: Bool) -> Data? {
        guard body.count > 4 else { return nil }
        let bytes = [UInt8](body)
        let encoding = bytes[0]
        var cursor: Int
        if isV22 {
            cursor = 5 // encoding + three-byte image format + picture type
        } else {
            guard let mimeEnd = bytes[1...].firstIndex(of: 0) else { return nil }
            cursor = mimeEnd + 2 // terminator + picture type
        }
        let terminatorLength = (encoding == 1 || encoding == 2) ? 2 : 1
        while cursor + terminatorLength <= bytes.count {
            if terminatorLength == 1, bytes[cursor] == 0 { cursor += 1; break }
            if terminatorLength == 2, bytes[cursor] == 0, bytes[cursor + 1] == 0 { cursor += 2; break }
            cursor += 1
        }
        guard cursor < bytes.count else { return nil }
        return Data(bytes[cursor...])
    }

    private static func synchsafe(_ bytes: ArraySlice<UInt8>) -> Int? {
        guard bytes.count == 4, bytes.allSatisfy({ $0 & 0x80 == 0 }) else { return nil }
        return bytes.reduce(0) { ($0 << 7) | Int($1) }
    }
}

private extension TrackMetadata {
    /// True when AVFoundation gave us nothing worth keeping and it is worth
    /// paying for a manual tag parse.
    var needsTagFallback: Bool {
        title.isEmpty || artist.isEmpty || album.isEmpty || artworkData == nil
    }

    /// Copies fields from `other` only where this one is still empty.
    mutating func merge(filling other: TrackMetadata) {
        if title.isEmpty { title = other.title }
        if artist.isEmpty { artist = other.artist }
        if albumArtist.isEmpty { albumArtist = other.albumArtist }
        if album.isEmpty { album = other.album }
        if genre.isEmpty { genre = other.genre }
        if year == 0 { year = other.year }
        if trackNumber == 0 { trackNumber = other.trackNumber }
        if discNumber == 0 { discNumber = other.discNumber }
        if duration == 0 { duration = other.duration }
        if artworkData == nil { artworkData = other.artworkData }
    }
}
