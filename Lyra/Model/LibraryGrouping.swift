import Foundation

/// In-memory views over the track list: albums, artists and the folder tree.
///
/// Grouping is recomputed from the flat `@Query` result rather than stored.
/// For a personal library this costs microseconds and removes a whole class of
/// stale-derived-data bugs.
enum LibraryGrouping {

    struct AlbumGroup: Identifiable, Hashable {
        var id: String
        var title: String
        var artist: String
        var year: Int
        var artworkHash: String?
        var tracks: [Track]

        static func == (lhs: AlbumGroup, rhs: AlbumGroup) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    struct ArtistGroup: Identifiable, Hashable {
        var id: String { name }
        var name: String
        var tracks: [Track]
        var albumCount: Int

        static func == (lhs: ArtistGroup, rhs: ArtistGroup) -> Bool { lhs.name == rhs.name }
        func hash(into hasher: inout Hasher) { hasher.combine(name) }
    }

    struct FolderNode: Identifiable, Hashable {
        /// Path relative to `Documents/`; "" is the root.
        var id: String
        var name: String
        var subfolders: [String]
        var tracks: [Track]

        static func == (lhs: FolderNode, rhs: FolderNode) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    // MARK: - Albums

    static func albums(from tracks: [Track]) -> [AlbumGroup] {
        var buckets: [String: [Track]] = [:]
        for track in tracks {
            buckets[track.albumKey, default: []].append(track)
        }

        return buckets.map { key, members in
            let sorted = sortedForAlbum(members)
            let first = sorted.first
            return AlbumGroup(
                id: key,
                title: first?.displayAlbum ?? "Unknown Album",
                artist: first?.groupingArtist ?? "Unknown Artist",
                year: sorted.compactMap { $0.year > 0 ? $0.year : nil }.min() ?? 0,
                artworkHash: sorted.first(where: { $0.artworkHash != nil })?.artworkHash,
                tracks: sorted
            )
        }
        .sorted {
            let left = ($0.artist.localizedLowercase, $0.year, $0.title.localizedLowercase)
            let right = ($1.artist.localizedLowercase, $1.year, $1.title.localizedLowercase)
            if left.0 != right.0 { return left.0 < right.0 }
            if left.1 != right.1 { return left.1 < right.1 }
            return left.2 < right.2
        }
    }

    /// Disc then track number, falling back to title so untagged albums still
    /// come out in a stable order.
    static func sortedForAlbum(_ tracks: [Track]) -> [Track] {
        tracks.sorted {
            if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
            if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    // MARK: - Artists

    static func artists(from tracks: [Track]) -> [ArtistGroup] {
        var buckets: [String: [Track]] = [:]
        for track in tracks {
            buckets[track.groupingArtist, default: []].append(track)
        }

        return buckets.map { name, members in
            ArtistGroup(
                name: name,
                tracks: sortedForAlbum(members),
                albumCount: Set(members.map(\.albumKey)).count
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Folders

    /// Builds the contents of one folder: its immediate subfolders and its own
    /// files. Mirrors what the user actually dropped into the Files app.
    static func folder(at path: String, tracks: [Track]) -> FolderNode {
        let prefix = path.isEmpty ? "" : path + "/"

        var subfolders = Set<String>()
        var direct: [Track] = []

        for track in tracks {
            let folder = track.folderPath
            if folder == path {
                direct.append(track)
                continue
            }
            guard !prefix.isEmpty || !folder.isEmpty else { continue }
            guard folder.hasPrefix(prefix) else { continue }

            let remainder = folder.dropFirst(prefix.count)
            guard let firstComponent = remainder.split(separator: "/").first else { continue }
            subfolders.insert(prefix + firstComponent)
        }

        return FolderNode(
            id: path,
            name: AudioFile.folderDisplayName(path),
            subfolders: subfolders.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            tracks: sortedForAlbum(direct)
        )
    }

    /// Every track at or below `path`, in folder-then-track order — what
    /// "play this folder" should queue up.
    static func tracksRecursively(under path: String, tracks: [Track]) -> [Track] {
        let prefix = path.isEmpty ? "" : path + "/"
        let matching = tracks.filter { path.isEmpty || $0.folderPath == path || $0.folderPath.hasPrefix(prefix) }
        return matching.sorted {
            if $0.folderPath != $1.folderPath {
                return $0.folderPath.localizedStandardCompare($1.folderPath) == .orderedAscending
            }
            if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
            if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}

/// Sort options for flat track lists.
enum TrackSort: String, CaseIterable, Identifiable {
    case title, artist, album, dateAdded, duration

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .dateAdded: "Recently Added"
        case .duration: "Duration"
        }
    }

    var systemImage: String {
        switch self {
        case .title: "textformat"
        case .artist: "music.mic"
        case .album: "square.stack"
        case .dateAdded: "clock"
        case .duration: "timer"
        }
    }

    func apply(to tracks: [Track]) -> [Track] {
        switch self {
        case .title:
            tracks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist:
            tracks.sorted {
                let byArtist = $0.displayArtist.localizedStandardCompare($1.displayArtist)
                if byArtist != .orderedSame { return byArtist == .orderedAscending }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        case .album:
            tracks.sorted {
                let byAlbum = $0.displayAlbum.localizedStandardCompare($1.displayAlbum)
                if byAlbum != .orderedSame { return byAlbum == .orderedAscending }
                if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
                return $0.trackNumber < $1.trackNumber
            }
        case .dateAdded:
            tracks.sorted { $0.dateAdded > $1.dateAdded }
        case .duration:
            tracks.sorted { $0.duration > $1.duration }
        }
    }
}
