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

    /// How many files parse tags concurrently. High enough to keep the decoder
    /// busy, low enough not to thrash memory with embedded artwork.
    private let concurrency = 6
    /// Tracks written per save. Batching keeps SwiftData saves off the hot path.
    private let batchSize = 40

    private let container: ModelContainer
    private var runningTask: Task<Void, Never>?

    init(container: ModelContainer) {
        self.container = container
    }

    var progressFraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(processed) / Double(total))
    }

    /// Rescans the drop zone. Calling this while a scan is running is a no-op,
    /// so foreground triggers and pull-to-refresh cannot stack up.
    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        lastError = nil
        processed = 0
        total = 0
        defer { isScanning = false }

        let store = LibraryStore(modelContainer: container)

        do {
            let plan = try await store.planScan()

            if !plan.removedPaths.isEmpty {
                try await store.remove(paths: plan.removedPaths)
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

            lastScanDate = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Fire-and-forget wrapper for `.task` / `.onChange` call sites.
    func scanInBackground() {
        guard runningTask == nil || runningTask?.isCancelled == true else { return }
        runningTask = Task { [weak self] in
            await self?.scan()
            self?.runningTask = nil
        }
    }

    // MARK: - Tag reading

    private func importFiles(_ files: [ScannedFile], into store: LibraryStore) async throws {
        var batch: [ImportedTrack] = []
        batch.reserveCapacity(batchSize)

        // Sliding window: keep `concurrency` reads in flight, consume results
        // as they land rather than waiting for the whole set.
        var next = 0
        try await withThrowingTaskGroup(of: ImportedTrack.self) { group in
            while next < files.count && next < concurrency {
                let file = files[next]
                group.addTask { await Self.importOne(file) }
                next += 1
            }

            while let result = try await group.next() {
                batch.append(result)
                processed += 1

                if next < files.count {
                    let file = files[next]
                    group.addTask { await Self.importOne(file) }
                    next += 1
                }

                if batch.count >= batchSize {
                    let flush = batch
                    batch.removeAll(keepingCapacity: true)
                    try await store.upsert(flush)
                }
            }
        }

        if !batch.isEmpty {
            try await store.upsert(batch)
        }
    }

    /// Parses one file's tags and caches its artwork. Never throws — a single
    /// unreadable file must not abort the scan; it lands in the library with
    /// path-derived metadata instead.
    private nonisolated static func importOne(_ file: ScannedFile) async -> ImportedTrack {
        let url = AudioFile.url(forRelativePath: file.relativePath)
        let metadata = await MetadataReader.read(url: url, relativePath: file.relativePath)

        var hash: String?
        if let data = metadata.artworkData {
            hash = ArtworkCache.shared.store(data)
        }

        var stripped = metadata
        stripped.artworkData = nil  // already on disk; do not carry bytes further
        return ImportedTrack(file: file, metadata: stripped, artworkHash: hash)
    }
}
