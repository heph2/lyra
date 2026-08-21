import Foundation
import SwiftData

/// A playlist stores ordered `Track.relativePath` values rather than a SwiftData
/// relationship. The path is already the stable identity of a track, so this
/// survives rescans and reinstalls, keeps ordering trivial (it is just an array),
/// and avoids the ordered-relationship sharp edges in SwiftData.
///
/// The trade-off: no referential integrity. A path whose file has been deleted
/// simply drops out at resolve time — see `resolveTracks(in:)`.
@Model
final class Playlist {
    var name: String
    var trackPaths: [String]
    var dateCreated: Date
    var dateModified: Date

    init(name: String, trackPaths: [String] = [], dateCreated: Date = Date()) {
        self.name = name
        self.trackPaths = trackPaths
        self.dateCreated = dateCreated
        self.dateModified = dateCreated
    }
}

extension Playlist {
    var trackCount: Int { trackPaths.count }

    /// Appends only paths not already present, so double-adding is a no-op.
    func append(paths: [String]) {
        let existing = Set(trackPaths)
        let additions = paths.filter { !existing.contains($0) }
        guard !additions.isEmpty else { return }
        trackPaths.append(contentsOf: additions)
        dateModified = Date()
    }

    func remove(atOffsets offsets: IndexSet) {
        trackPaths.remove(atOffsets: offsets)
        dateModified = Date()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        trackPaths.move(fromOffsets: source, toOffset: destination)
        dateModified = Date()
    }

    /// Fetches the tracks for this playlist, in playlist order, silently
    /// dropping paths whose files are no longer in the library.
    func resolveTracks(in context: ModelContext) -> [Track] {
        guard !trackPaths.isEmpty else { return [] }
        let paths = trackPaths
        let descriptor = FetchDescriptor<Track>(
            predicate: #Predicate { paths.contains($0.relativePath) }
        )
        guard let found = try? context.fetch(descriptor) else { return [] }

        let byPath = Dictionary(found.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        return paths.compactMap { byPath[$0] }
    }
}
