import Foundation
import SwiftData

/// Drives a library rescan and exposes progress to the UI.
///
/// Split of work: `LibraryStore` (a model actor) does the cheap disk diff and
/// all database writes; tag parsing — the expensive part — runs here in a
/// bounded `TaskGroup` so several files decode at once.
@MainActor
@Observable
final class LibraryScanner {

    private(set) var isScanning = false
    private(set) var processed = 0
    private(set) var total = 0
    private(set) var lastScanDate: Date?
    private(set) var lastError: String?
    /// What the last scan actually saw on disk, for the empty state to explain.
    private(set) var inventory = AudioFile.Inventory()

    /// How many files parse tags concurrently. High enough to keep the decoder
    /// busy, low enough not to thrash memory with embedded artwork.
    private let concurrency = 6
    /// Tracks written per save. Batching keeps SwiftData saves off the hot path.
    private let batchSize = 40
    /// The first save of a scan is deliberately tiny. On a remote library each
    /// tag read costs a network round trip, and waiting for a full batch meant
    /// the library looked empty for the first minute of the very first scan.
    private let firstBatchSize = 5

    private let container: ModelContainer
    private let offlineSync: OfflineSyncManager
    private var runningTask: Task<Void, Never>?
    /// A source may be added while the launch or foreground scan still owns
    /// the source snapshot. Run one more pass once it finishes so the new
    /// source cannot be silently skipped.
    private var rescanRequested = false

    init(container: ModelContainer, offlineSync: OfflineSyncManager) {
        self.container = container
        self.offlineSync = offlineSync
    }

    var progressFraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(processed) / Double(total))
    }

    /// Rescans the drop zone. Calling this while a scan is running is a no-op,
    /// so foreground triggers and pull-to-refresh cannot stack up.
    func scan() async {
        guard !isScanning else {
            rescanRequested = true
            LyraLog.library.debug("Queued one follow-up scan")
            return
        }
        LyraLog.library.info("Library scan started")
        isScanning = true
        lastError = nil
        processed = 0
        total = 0
        defer {
            isScanning = false
            // A direct launch scan has no `runningTask` to finish the handoff.
            // In that case it owns scheduling the one requested follow-up.
            if rescanRequested, runningTask == nil {
                rescanRequested = false
                scanInBackground()
            }
        }

        let store = LibraryStore(modelContainer: container)

        do {
            let plan = try await store.planScan()
            LyraLog.library.info(
                "Scan plan total=\(plan.totalOnDisk) added=\(plan.added.count) modified=\(plan.modified.count) removed=\(plan.removedPaths.count) sourceErrors=\(plan.sourceErrors.count)"
            )

            if !plan.removedPaths.isEmpty {
                let removed = try await store.remove(paths: plan.removedPaths)
                for request in removed {
                    OfflineLibrary.removeCopy(sourceID: request.sourceID, innerPath: request.innerPath)
                }
            }

            let work = plan.workItems
            total = work.count

            if !work.isEmpty {
                try await importFiles(work, into: store)
            }

            // Cheap enough to do every scan, and keeps Caches/ honest.
            let live = try await store.liveArtworkHashes()
            ArtworkCache.shared.prune(keeping: live)

            // If the user emptied the folder, put the readme back so the app
            // does not silently vanish from the Files app.
            AudioFile.prepareDropZone()

            inventory = LibraryManager.shared.inventory()

            if !plan.sourceErrors.isEmpty {
                lastError = plan.sourceErrors.joined(separator: "\n")
            }

            await offlineSync.reconcile()
            lastScanDate = Date()
            LyraLog.library.info(
                "Library scan completed processed=\(self.processed) total=\(self.total)"
            )
        } catch {
            lastError = error.localizedDescription
            let code = DiagnosticValue.errorCode(error)
            LyraLog.library.error("Library scan failed error=\(code, privacy: .public)")
        }
    }

    // MARK: - Sources

    /// Adds folders picked in the document importer and rescans.
    func addFolders(_ urls: [URL]) {
        var added = false
        var addedCount = 0
        for url in urls where LibraryManager.shared.add(folder: url) != nil {
            added = true
            addedCount += 1
        }
        guard added else { return }
        LyraLog.library.info("Added \(addedCount) local sources")
        scanInBackground()
    }

    /// Forgets a folder and drops its tracks. The files themselves are never
    /// touched — they live outside the app and are not ours to delete.
    func removeSource(_ sourceID: String) async {
        do {
            let wasRemote = LibraryManager.shared.source(for: sourceID)?.isRemote == true
            try LibraryManager.shared.remove(sourceID: sourceID)
            let store = LibraryStore(modelContainer: container)
            try await store.removeTracks(ofSource: sourceID)
            if wasRemote {
                OfflineLibrary.removeLibrary(sourceID: sourceID)
            }
            inventory = LibraryManager.shared.inventory()
            LyraLog.library.info("Removed library source remote=\(wasRemote)")
        } catch {
            lastError = error.localizedDescription
            let code = DiagnosticValue.errorCode(error)
            LyraLog.library.error("Removing library source failed error=\(code, privacy: .public)")
        }
    }

    func testWebDAV(name: String, url: String, username: String, password: String) async throws -> Int {
        try await LibraryManager.shared.testWebDAV(
            name: name,
            urlString: url,
            username: username,
            password: password
        )
    }

    /// Returns a warning when the library was added but its password could not
    /// be stored durably. Nil means it was saved properly.
    @discardableResult
    func addWebDAV(name: String, url: String, username: String, password: String) throws -> String? {
        let added = try LibraryManager.shared.addWebDAV(
            name: name,
            urlString: url,
            username: username,
            password: password
        )
        LyraLog.library.info("Added WebDAV source")
        scanInBackground()
        return added.warning
    }

    /// Fire-and-forget wrapper for `.task` / `.onChange` call sites.
    func scanInBackground() {
        guard runningTask == nil || runningTask?.isCancelled == true else {
            rescanRequested = true
            return
        }
        runningTask = Task { [weak self] in
            await self?.scan()
            guard let self else { return }
            self.runningTask = nil
            if self.rescanRequested, !self.isScanning {
                self.rescanRequested = false
                self.scanInBackground()
            }
        }
    }

    // MARK: - Tag reading

    private func importFiles(_ files: [ScannedFile], into store: LibraryStore) async throws {
        try await indexRemoteFiles(files, into: store)

        var batch: [ImportedTrack] = []
        batch.reserveCapacity(batchSize)
        var flushAt = firstBatchSize
        let artwork = RemoteArtworkBudget()

        // Sliding window: keep `concurrency` reads in flight, consume results
        // as they land rather than waiting for the whole set.
        var next = 0
        try await withThrowingTaskGroup(of: ImportedTrack.self) { group in
            while next < files.count && next < concurrency {
                let file = files[next]
                group.addTask { await Self.importOne(file, artwork: artwork) }
                next += 1
            }

            while let result = try await group.next() {
                batch.append(result)
                processed += 1

                if next < files.count {
                    let file = files[next]
                    group.addTask { await Self.importOne(file, artwork: artwork) }
                    next += 1
                }

                if batch.count >= flushAt {
                    let flush = batch
                    batch.removeAll(keepingCapacity: true)
                    flushAt = batchSize
                    try await store.upsert(flush)
                }
            }
        }

        if !batch.isEmpty {
            try await store.upsert(batch)
        }

        // Only one track per folder paid for a full-header read, so hand its
        // cover to the rest of the album now that every row exists.
        let covers = await artwork.folderArtwork()
        if !covers.isEmpty {
            try await store.applyFolderArtwork(covers)
        }
    }

    /// Writes remote tracks into the library from the scan inventory alone,
    /// before a single tag byte is fetched.
    ///
    /// Indexing a WebDAV library means one ranged HTTP read per file. On a
    /// library of a few hundred tracks that is minutes of work, and until it
    /// finished the app showed an empty library and no reason for it. These
    /// rows are deliberately left without a size or modification date, so
    /// `planScan()` still classifies them as needing a tag read next time —
    /// an interrupted scan resumes instead of leaving filename-only titles
    /// behind forever.
    private func indexRemoteFiles(_ files: [ScannedFile], into store: LibraryStore) async throws {
        let remote = files.filter {
            LibraryManager.shared.source(for: AudioFile.split(trackPath: $0.relativePath).sourceID)?.isRemote == true
        }
        guard !remote.isEmpty else { return }

        for chunk in stride(from: 0, to: remote.count, by: 200).map({
            Array(remote[$0..<min($0 + 200, remote.count)])
        }) {
            try await store.upsert(chunk.map { file in
                var metadata = TrackMetadata()
                metadata.applyPathFallbacks(
                    relativePath: AudioFile.split(trackPath: file.relativePath).innerPath
                )
                return ImportedTrack(file: file, metadata: metadata, artworkHash: nil, isPlaceholder: true)
            })
        }
    }

    /// Bytes fetched per remote track to read its tags. Vorbis comments and
    /// ID3 frames sit at the front of the file, so this is enough for title,
    /// artist, album and duration — but usually not for embedded cover art,
    /// which is what `RemoteArtworkBudget` exists to pay for selectively.
    private static let remoteTagBytes = 128 * 1_024
    /// Bytes fetched for the one track per folder that goes looking for art.
    private static let remoteArtworkBytes = 1_024 * 1_024

    /// Parses one file's tags and caches its artwork. Never throws — a single
    /// unreadable file must not abort the scan; it lands in the library with
    /// path-derived metadata instead.
    private nonisolated static func importOne(
        _ file: ScannedFile,
        artwork: RemoteArtworkBudget
    ) async -> ImportedTrack {
        let inner = AudioFile.split(trackPath: file.relativePath).innerPath
        let sourceID = AudioFile.split(trackPath: file.relativePath).sourceID
        let fileExtension = (inner as NSString).pathExtension.lowercased()
        var artworkFolder: String?
        var metadata: TrackMetadata
        if MetadataReader.supportsRemoteHeaderMetadata(fileExtension: fileExtension),
           let remote = LibraryManager.shared.remoteSource(for: sourceID),
           let header = try? await remote.metadataHeader(for: file, maxBytes: remoteTagBytes) {
            metadata = MetadataReader.read(
                headerData: header,
                fileExtension: fileExtension,
                relativePath: inner
            )
            // Cover art usually sits past the tag prefix. Fetching a full
            // header for every track would mean downloading close to a
            // gigabyte to index a few hundred files, so exactly one track per
            // folder pays for it and the rest of the album is backfilled with
            // what it found.
            artworkFolder = RemoteArtworkBudget.key(
                source: sourceID,
                folder: AudioFile.parentFolder(ofRelativePath: inner)
            )
            if metadata.artworkData == nil,
               await artwork.claim(artworkFolder!),
               let full = try? await remote.metadataHeader(for: file, maxBytes: remoteArtworkBytes) {
                let richer = MetadataReader.read(
                    headerData: full,
                    fileExtension: fileExtension,
                    relativePath: inner
                )
                metadata.artworkData = richer.artworkData
            }
        } else if let url = LibraryManager.shared.url(forTrackPath: file.relativePath) {
            metadata = await MetadataReader.read(url: url, relativePath: inner)
        } else {
            // A source may vanish after its inventory was read. It still gets
            // a usable index entry rather than aborting the entire rescan.
            var fallback = TrackMetadata()
            fallback.applyPathFallbacks(relativePath: inner)
            metadata = fallback
        }

        var hash: String?
        if let data = metadata.artworkData {
            hash = ArtworkCache.shared.store(data)
        }
        if let artworkFolder {
            await artwork.record(hash, for: artworkFolder)
        }

        var stripped = metadata
        stripped.artworkData = nil  // already on disk; do not carry bytes further
        return ImportedTrack(file: file, metadata: stripped, artworkHash: hash)
    }
}

/// Hands out permission to spend a full-header read on cover art, once per
/// folder per scan, and remembers what that read found.
///
/// Tag reads run concurrently, so the claim has to be atomic: without it every
/// track of an album would race and all of them would pay for the same image.
actor RemoteArtworkBudget {
    private var claimed: Set<String> = []
    private var hashes: [String: String] = [:]

    static func key(source: String, folder: String) -> String { "\(source)/\(folder)" }

    func claim(_ key: String) -> Bool {
        claimed.insert(key).inserted
    }

    func record(_ hash: String?, for key: String) {
        guard let hash else { return }
        hashes[key] = hash
    }

    /// Folder → artwork hash, for the backfill that gives the rest of the
    /// album the image its one paid-for track found.
    func folderArtwork() -> [String: String] { hashes }
}
