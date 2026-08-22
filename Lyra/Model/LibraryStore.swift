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
    /// A row written from the scan inventory alone, before its tags were read.
    /// It carries no size or modification date, so the next `planScan()` still
    /// sees it as needing work.
    var isPlaceholder = false
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
    /// Per-source failures held back from removals, surfaced after the scan.
    var sourceErrors: [String] = []

    var workItems: [ScannedFile] { added + modified }
    var isEmpty: Bool { added.isEmpty && modified.isEmpty && removedPaths.isEmpty }
}

/// All SwiftData mutation happens here, off the main actor.
@ModelActor
actor LibraryStore {

    // MARK: - Planning

    /// Diffs a source inventory against the database. Sources return only the
    /// same cheap path/size/mtime tuple, so remote scanning does not alter the
    /// classification logic below.
    func planScan() async throws -> ScanPlan {
        let sourceScan = await LibraryManager.shared.scan()
        let onDisk = sourceScan.files
        // A source we cannot open right now is not a source with no music in
        // it. Anything belonging to one is held back from the removal list, so
        // unplugging a drive does not wipe the library and gut its playlists.
        let unreachable = sourceScan.unavailableSourceIDs

        var plan = ScanPlan()
        plan.totalOnDisk = onDisk.count
        plan.sourceErrors = sourceScan.errors

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
            let source = sourceByPath[path] ?? LibraryManager.dropZoneID
            return !unreachable.contains(source)
        }
        return plan
    }

    // MARK: - Mutation

    func remove(paths: [String]) throws -> [OfflineDownloadRequest] {
        guard !paths.isEmpty else { return [] }
        let pathSet = paths
        let tracks = try modelContext.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { pathSet.contains($0.relativePath) }
        ))
        let downloads = tracks.compactMap { track -> OfflineDownloadRequest? in
            guard LibraryManager.shared.source(for: track.sourceID)?.isRemote == true else { return nil }
            return downloadRequest(for: track)
        }
        try modelContext.delete(
            model: Track.self,
            where: #Predicate { pathSet.contains($0.relativePath) }
        )
        try modelContext.save()
        return downloads
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
                // A placeholder never overwrites a row that already exists: it
                // would replace real tags with a filename for as long as the
                // scan takes to reach that track again.
                guard !item.isPlaceholder else { continue }
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
        let changed = track.fileSize != item.file.size
            || abs(track.fileModified.timeIntervalSince(item.file.modified)) >= 1
        if changed,
           track.offlineRequested,
           track.offlineState == .availableOffline,
           LibraryManager.shared.source(for: split.sourceID)?.isRemote == true {
            // Keep the existing cache playable until the fresh source file is
            // downloaded, but surface that it no longer matches the server.
            track.offlineState = .modifiedRemote
        }
        track.title = m.title
        track.artist = m.artist
        track.albumArtist = m.albumArtist.isEmpty ? m.artist : m.albumArtist
        track.album = m.album
        track.genre = m.genre
        track.year = m.year
        track.trackNumber = m.trackNumber
        track.discNumber = m.discNumber
        track.duration = m.duration
        // A placeholder must not claim the file has been read. Leaving the
        // stat fields alone is what makes the next scan pick it up again.
        if !item.isPlaceholder {
            track.artworkHash = item.artworkHash
            track.fileSize = item.file.size
            track.fileModified = item.file.modified
        }
        track.sourceID = split.sourceID
        track.folderPath = AudioFile.parentFolder(ofRelativePath: split.innerPath)
    }

    /// Gives every artless track in a folder the cover another track in that
    /// same folder produced. Remote libraries only fetch one full header per
    /// folder, so without this an album would show art on a single row.
    func applyFolderArtwork(_ hashesByFolder: [String: String]) throws {
        var touched = false
        for (key, hash) in hashesByFolder {
            guard let separator = key.firstIndex(of: "/") else { continue }
            let sourceID = String(key[key.startIndex..<separator])
            let folder = String(key[key.index(after: separator)...])
            let tracks = try modelContext.fetch(FetchDescriptor<Track>(
                predicate: #Predicate {
                    $0.sourceID == sourceID && $0.folderPath == folder && $0.artworkHash == nil
                }
            ))
            for track in tracks {
                track.artworkHash = hash
                touched = true
            }
        }
        if touched { try modelContext.save() }
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

    // MARK: - Offline copies

    /// Marks selected remote tracks for file-backed download and returns the
    /// work that still needs doing. SwiftData persists the selection so it can
    /// resume after the app is relaunched.
    func prepareOfflineDownloads(paths: [String]) throws -> [OfflineDownloadRequest] {
        guard !paths.isEmpty else { return [] }
        let descriptor = FetchDescriptor<Track>(
            predicate: #Predicate { paths.contains($0.relativePath) }
        )
        let tracks = try modelContext.fetch(descriptor)
        var requests: [OfflineDownloadRequest] = []

        for track in tracks where LibraryManager.shared.source(for: track.sourceID)?.isRemote == true {
            track.offlineRequested = true
            if OfflineLibrary.localURL(for: track) != nil {
                track.offlineState = .availableOffline
                continue
            }
            track.offlineState = .downloading
            requests.append(downloadRequest(for: track))
        }
        try modelContext.save()
        return requests
    }

    /// Finds user-selected copies that are missing or stale after a rescan.
    func pendingOfflineDownloads() throws -> [OfflineDownloadRequest] {
        let requested = try modelContext.fetch(FetchDescriptor<Track>(
            predicate: #Predicate { $0.offlineRequested }
        ))
        var requests: [OfflineDownloadRequest] = []

        for track in requested where LibraryManager.shared.source(for: track.sourceID)?.isRemote == true {
            if track.offlineState == .availableOffline, OfflineLibrary.localURL(for: track) != nil {
                continue
            }
            track.offlineState = .downloading
            requests.append(downloadRequest(for: track))
        }
        try modelContext.save()
        return requests
    }

    /// Clears the user's selection before the cache file is removed. A
    /// cancelled in-flight download therefore cannot re-mark it as available.
    func clearOfflineDownloads(paths: [String]) throws -> [OfflineDownloadRequest] {
        guard !paths.isEmpty else { return [] }
        let descriptor = FetchDescriptor<Track>(
            predicate: #Predicate { paths.contains($0.relativePath) }
        )
        let tracks = try modelContext.fetch(descriptor)
        var removed: [OfflineDownloadRequest] = []

        for track in tracks where LibraryManager.shared.source(for: track.sourceID)?.isRemote == true {
            removed.append(downloadRequest(for: track))
            track.offlineRequested = false
            track.offlineState = .availableRemote
        }
        try modelContext.save()
        return removed
    }

    func completeOfflineDownload(path: String) throws {
        guard let track = try track(at: path), track.offlineRequested else { return }
        track.offlineState = .availableOffline
        try modelContext.save()
    }

    func failOfflineDownload(path: String) throws {
        guard let track = try track(at: path), track.offlineRequested else { return }
        // A refresh can fail after a previous copy completed. Keep that copy
        // available rather than discarding the user's only offline version.
        let hasExistingCopy = OfflineLibrary.fileURL(sourceID: track.sourceID, innerPath: track.innerPath)
            .map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        track.offlineState = hasExistingCopy ? .modifiedRemote : .availableRemote
        try modelContext.save()
    }

    private func track(at path: String) throws -> Track? {
        var descriptor = FetchDescriptor<Track>(
            predicate: #Predicate { $0.relativePath == path }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func downloadRequest(for track: Track) -> OfflineDownloadRequest {
        OfflineDownloadRequest(
            relativePath: track.relativePath,
            sourceID: track.sourceID,
            innerPath: track.innerPath
        )
    }
}
