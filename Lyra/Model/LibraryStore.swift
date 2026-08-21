import Foundation
import SwiftData

/// One audio file as found on disk. Cheap to produce — stat only, no tag parsing.
struct ScannedFile: Sendable, Equatable {
    var relativePath: String
    var size: Int64
    var modified: Date
}

/// A file plus its parsed tags, ready to be written into the store.
struct ImportedTrack: Sendable {
    var file: ScannedFile
    var metadata: TrackMetadata
    var artworkHash: String?
}

/// What a rescan needs to do, computed before any expensive tag reading.
struct ScanPlan: Sendable {
    var added: [ScannedFile] = []
    /// Files whose size or modification date changed since we last read them.
    var modified: [ScannedFile] = []
    /// Tracks in the database whose files are gone.
    var removedPaths: [String] = []
    /// Total files seen on disk, including untouched ones.
    var totalOnDisk: Int = 0

    var workItems: [ScannedFile] { added + modified }
    var isEmpty: Bool { added.isEmpty && modified.isEmpty && removedPaths.isEmpty }
}

/// All SwiftData mutation happens here, off the main actor.
@ModelActor
actor LibraryStore {

    // MARK: - Planning

    /// Walks `Documents/` and diffs it against the database. Only stats files,
    /// so this stays fast even on a large library; tag reading is the caller's
    /// job and happens concurrently afterwards.
    func planScan() throws -> ScanPlan {
        let onDisk = SourceRegistry.shared.enumerateAudioFiles()
        // A source we cannot open right now is not a source with no music in
        // it. Anything belonging to one is held back from the removal list, so
        // unplugging a drive does not wipe the library and gut its playlists.
        let unreachable = SourceRegistry.shared.unreachableSourceIDs()

        var plan = ScanPlan()
        plan.totalOnDisk = onDisk.count

        let existing = try modelContext.fetch(FetchDescriptor<Track>())
        var known: [String: (size: Int64, modified: Date)] = [:]
        var sourceByPath: [String: String] = [:]
        known.reserveCapacity(existing.count)
        for track in existing {
            known[track.relativePath] = (track.fileSize, track.fileModified)
            sourceByPath[track.relativePath] = track.sourceID
        }

        var seen = Set<String>()
        seen.reserveCapacity(onDisk.count)

        for file in onDisk {
            seen.insert(file.relativePath)
            guard let previous = known[file.relativePath] else {
                plan.added.append(file)
                continue
            }
            // Sub-second timestamp jitter is not worth re-parsing tags over.
            let sameTime = abs(previous.modified.timeIntervalSince(file.modified)) < 1
            if previous.size != file.size || !sameTime {
                plan.modified.append(file)
            }
        }

        plan.removedPaths = known.keys.filter { path in
            guard !seen.contains(path) else { return false }
            let source = sourceByPath[path] ?? SourceRegistry.dropZoneID
            return !unreachable.contains(source)
        }
        return plan
    }

    // MARK: - Mutation

    func remove(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let pathSet = paths
        try modelContext.delete(
            model: Track.self,
            where: #Predicate { pathSet.contains($0.relativePath) }
        )
        try modelContext.save()
    }

    /// Inserts new tracks and refreshes changed ones, preserving play counts.
    func upsert(_ batch: [ImportedTrack]) throws {
        guard !batch.isEmpty else { return }

        let paths = batch.map(\.file.relativePath)
        let descriptor = FetchDescriptor<Track>(
            predicate: #Predicate { paths.contains($0.relativePath) }
        )
        let existing = try modelContext.fetch(descriptor)
        var byPath = Dictionary(existing.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })

        for item in batch {
            if let track = byPath[item.file.relativePath] {
                apply(item, to: track)
            } else {
                let track = Track(relativePath: item.file.relativePath, title: item.metadata.title)
                apply(item, to: track)
                modelContext.insert(track)
                byPath[item.file.relativePath] = track
            }
        }
        try modelContext.save()
    }

    /// Copies parsed values onto a track. Play count, last-played date and the
    /// original `dateAdded` are intentionally left alone.
    private func apply(_ item: ImportedTrack, to track: Track) {
        let m = item.metadata
        let split = AudioFile.split(trackPath: item.file.relativePath)
        track.title = m.title
        track.artist = m.artist
        track.albumArtist = m.albumArtist.isEmpty ? m.artist : m.albumArtist
        track.album = m.album
        track.genre = m.genre
        track.year = m.year
        track.trackNumber = m.trackNumber
        track.discNumber = m.discNumber
        track.duration = m.duration
        track.artworkHash = item.artworkHash
        track.fileSize = item.file.size
        track.fileModified = item.file.modified
        track.sourceID = split.sourceID
        track.folderPath = AudioFile.parentFolder(ofRelativePath: split.innerPath)
    }

    func trackCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<Track>())
    }

    /// Artwork hashes still referenced by at least one track, so the cache can
    /// drop everything else.
    func liveArtworkHashes() throws -> Set<String> {
        var descriptor = FetchDescriptor<Track>(
            predicate: #Predicate { $0.artworkHash != nil }
        )
        descriptor.propertiesToFetch = [\.artworkHash]
        return Set(try modelContext.fetch(descriptor).compactMap(\.artworkHash))
    }

    func recordPlay(relativePath: String, at date: Date) throws {
        var descriptor = FetchDescriptor<Track>(
            predicate: #Predicate { $0.relativePath == relativePath }
        )
        descriptor.fetchLimit = 1
        guard let track = try modelContext.fetch(descriptor).first else { return }
        track.playCount += 1
        track.lastPlayed = date
        try modelContext.save()
    }

    /// Drops every track belonging to a source the user has removed.
    func removeTracks(ofSource sourceID: String) throws {
        try modelContext.delete(
            model: Track.self,
            where: #Predicate { $0.sourceID == sourceID }
        )
        try modelContext.save()
    }
}
