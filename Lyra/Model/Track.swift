import Foundation
import SwiftData

@Model
final class Track {
    /// Source-qualified path — the stable identity of a track across app
    /// reinstalls, when the container UUID changes. Bare relative path for the
    /// drop zone, `@<source-id>/<path>` for a picked folder.
    /// See `AudioFile.trackPath(sourceID:innerPath:)`.
    @Attribute(.unique) var relativePath: String

    /// Which folder this track lives in. Defaults to the drop zone so libraries
    /// written before external folders existed migrate without a rescan.
    var sourceID: String = LibraryManager.dropZoneID

    var title: String
    var artist: String
    var albumArtist: String
    var album: String
    var genre: String
    var year: Int
    var trackNumber: Int
    var discNumber: Int

    /// Seconds. Zero means we could not determine it.
    var duration: Double

    /// Filename (without extension) of the cached artwork JPEG in
    /// `Caches/artwork/`. Nil when the file has no embedded art.
    var artworkHash: String?

    var fileSize: Int64
    /// Last-modified date of the file when we last read its tags. Lets a
    /// rescan skip re-parsing files that have not changed.
    var fileModified: Date
    var dateAdded: Date

    /// Denormalised so the folder browser can group without touching disk.
    var folderPath: String

    var playCount: Int
    var lastPlayed: Date?

    /// The user's explicit choice to keep a remote track on this device.
    /// Local-folder tracks never use this; their files are already local.
    var offlineRequested: Bool = false
    var offlineStateRaw: String = OfflineState.availableRemote.rawValue

    init(
        relativePath: String,
        title: String,
        artist: String = "",
        albumArtist: String = "",
        album: String = "",
        genre: String = "",
        year: Int = 0,
        trackNumber: Int = 0,
        discNumber: Int = 0,
        duration: Double = 0,
        artworkHash: String? = nil,
        fileSize: Int64 = 0,
        fileModified: Date = .distantPast,
        dateAdded: Date = Date(),
        playCount: Int = 0,
        lastPlayed: Date? = nil
    ) {
        let split = AudioFile.split(trackPath: relativePath)
        self.relativePath = relativePath
        self.sourceID = split.sourceID
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.artworkHash = artworkHash
        self.fileSize = fileSize
        self.fileModified = fileModified
        self.dateAdded = dateAdded
        // Folder path is relative to the track's own source, so the browser can
        // show a clean tree per folder rather than leaking the `@id` prefix.
        self.folderPath = AudioFile.parentFolder(ofRelativePath: split.innerPath)
        self.playCount = playCount
        self.lastPlayed = lastPlayed
    }
}

extension Track {
    /// A selected remote copy wins over the source URL. This remains a local-
    /// file-only helper for metadata refresh and offline reconciliation.
    var fileURL: URL? {
        OfflineLibrary.localURL(for: self) ?? LibraryManager.shared.url(forTrackPath: relativePath)
    }

    /// Resolves as late as possible because an offline download or external
    /// folder can appear or disappear after the track was queued.
    var playbackResource: PlaybackResource? {
        PlaybackResourceResolver.resolve(
            track: self,
            localURL: fileURL,
            source: LibraryManager.shared.source(for: sourceID)
        )
    }

    /// Path within its own source, without the `@id` prefix.
    var innerPath: String { AudioFile.split(trackPath: relativePath).innerPath }

    var isFromDropZone: Bool { sourceID == LibraryManager.dropZoneID }

    var offlineState: OfflineState {
        get { OfflineState(rawValue: offlineStateRaw) ?? .availableRemote }
        set { offlineStateRaw = newValue.rawValue }
    }

    /// What to show when a track has no artist tag.
    var displayArtist: String { artist.isEmpty ? "Unknown Artist" : artist }
    var displayAlbum: String { album.isEmpty ? "Unknown Album" : album }

    /// Albums are grouped by album artist so compilations and albums with
    /// guest features do not shatter into one album per track.
    var groupingArtist: String {
        if !albumArtist.isEmpty { return albumArtist }
        if !artist.isEmpty { return artist }
        return "Unknown Artist"
    }

    /// Stable key for an album across tracks.
    var albumKey: String { "\(groupingArtist)\u{1F}\(displayAlbum)" }

    var formattedDuration: String {
        guard duration.isFinite, duration > 0 else { return "--:--" }
        let total = Int(duration.rounded())
        let seconds = total % 60
        let minutes = (total / 60) % 60
        let hours = total / 3600
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
