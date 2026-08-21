import AVFoundation
import Foundation

/// Reads tags out of an audio file.
///
/// `AVAsset` handles MP3/MP4/AIFF/WAV well. FLAC is the exception: iOS decodes
/// the audio but frequently exposes no metadata at all, so `FlacTagReader`
/// parses the Vorbis comment block directly when AVFoundation comes up empty.
enum MetadataReader {

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
