import Foundation

/// Plain, `Sendable` result of reading one file's tags. Deliberately decoupled
/// from `Track` so metadata reading can happen off the model actor.
struct TrackMetadata: Sendable, Equatable {
    var title: String = ""
    var artist: String = ""
    var albumArtist: String = ""
    var album: String = ""
    var genre: String = ""
    var year: Int = 0
    var trackNumber: Int = 0
    var discNumber: Int = 0
    var duration: Double = 0
    var artworkData: Data?

    /// Fills in anything the tags did not provide, using the file's own path.
    /// A well-organised `Artist/Album/01 Title.mp3` tree carries most of the
    /// information even when the files are completely untagged.
    mutating func applyPathFallbacks(relativePath: String) {
        let components = relativePath.split(separator: "/").map(String.init)
        let filename = components.last ?? relativePath
        let stem = (filename as NSString).deletingPathExtension

        if title.isEmpty {
            title = Self.strippingLeadingTrackNumber(from: stem)
        }
        if trackNumber == 0, let leading = Self.leadingTrackNumber(in: stem) {
            trackNumber = leading
        }
        if album.isEmpty, components.count >= 2 {
            album = components[components.count - 2]
        }
        if artist.isEmpty, components.count >= 3 {
            artist = components[components.count - 3]
        }
        if albumArtist.isEmpty {
            albumArtist = artist
        }
        if title.isEmpty {
            title = stem.isEmpty ? filename : stem
        }
    }

    /// "01 - Everything In Its Right Place" → 1
    private static func leadingTrackNumber(in stem: String) -> Int? {
        let digits = stem.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3, let value = Int(digits), value > 0 else { return nil }
        return value
    }

    /// "01 - Everything In Its Right Place" → "Everything In Its Right Place"
    private static func strippingLeadingTrackNumber(from stem: String) -> String {
        var rest = Substring(stem)
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return stem }
        rest = rest.dropFirst(digits.count)

        let separators = rest.prefix { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." }
        // Require an actual separator, so "1984.mp3" keeps its name.
        guard !separators.isEmpty else { return stem }
        rest = rest.dropFirst(separators.count)

        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? stem : trimmed
    }
}
