import Foundation
import SwiftData

enum OfflineState: String, Codable, Sendable {
    case availableRemote
    case downloading
    case availableOffline
    case modifiedRemote
    case unavailable
}

struct OfflineDownloadRequest: Sendable, Hashable {
    var relativePath: String
    var sourceID: String
    var innerPath: String
}

/// Owns files Lyra downloaded from remote libraries. These are cache copies,
/// not user-owned source files, so clearing them is always safe.
enum OfflineLibrary {
    private static let folderName = "Libraries"

    /// Application Support is backed up, so a multi-gigabyte offline selection
    /// would inflate every device backup even though every byte of it can be
    /// downloaded again. Excluding the directory itself covers every copy
    /// underneath it, whenever it is created.
    ///
    /// Resolved once: every path lookup goes through here, so doing the
    /// directory creation and the backup-exclusion check per call would cost
    /// three filesystem round trips per track of a selection.
    private static let librariesURL: URL? = {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }

        var directory = base.appending(path: folderName, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let excluded = try? directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        if excluded != true {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
        }
        return directory
    }()

    static func fileURL(sourceID: String, innerPath: String) -> URL? {
        guard sourceID != LibraryManager.dropZoneID,
              !sourceID.isEmpty,
              !sourceID.contains("/"),
              !sourceID.contains("..")
        else { return nil }

        let components = innerPath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }

        guard let base = librariesURL else { return nil }

        var url = base
            .appending(path: sourceID, directoryHint: .isDirectory)
            .appending(path: "Music", directoryHint: .isDirectory)
        for (index, component) in components.enumerated() {
            url.append(
                path: String(component),
                directoryHint: index == components.endIndex - 1 ? .notDirectory : .isDirectory
            )
        }
        return url
    }

    static func localURL(for track: Track) -> URL? {
        guard track.offlineRequested,
              track.offlineState != .availableRemote,
              track.offlineState != .unavailable,
              let url = fileURL(sourceID: track.sourceID, innerPath: track.innerPath),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    static func removeCopy(sourceID: String, innerPath: String) {
        guard let url = fileURL(sourceID: sourceID, innerPath: innerPath) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func removeLibrary(sourceID: String) {
        guard let probe = fileURL(sourceID: sourceID, innerPath: "placeholder") else { return }
        let library = probe
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try? FileManager.default.removeItem(at: library)
    }
}

/// Coordinates user-selected, file-backed WebDAV downloads. A selection is
/// persistent; it is retried after later rescans when a remote file changes.
@MainActor
@Observable
final class OfflineSyncManager {
    private let container: ModelContainer
    private let concurrency = 3
    private var pending: [OfflineDownloadRequest] = []
    private var active: [String: Task<Void, Never>] = [:]

    private(set) var activeDownloads = 0
    private(set) var lastError: String?

    init(container: ModelContainer) {
        self.container = container
    }

    func download(_ tracks: [Track]) {
        let paths = Set(tracks.filter(isRemote).map(\.relativePath))
        guard !paths.isEmpty else { return }
        LyraLog.offline.info("Offline selection requested tracks=\(paths.count)")

        Task {
            let store = LibraryStore(modelContainer: container)
            do {
                enqueue(try await store.prepareOfflineDownloads(paths: Array(paths)))
            } catch {
                lastError = error.localizedDescription
                let code = DiagnosticValue.errorCode(error)
                LyraLog.offline.error("Preparing offline downloads failed error=\(code, privacy: .public)")
            }
        }
    }

    func removeOfflineCopies(_ tracks: [Track]) {
        let paths = Set(tracks.filter(isRemote).map(\.relativePath))
        guard !paths.isEmpty else { return }
        LyraLog.offline.info("Offline copies removal requested tracks=\(paths.count)")

        for path in paths {
            active.removeValue(forKey: path)?.cancel()
        }
        pending.removeAll { paths.contains($0.relativePath) }
        activeDownloads = active.count

        Task {
            let store = LibraryStore(modelContainer: container)
            do {
                let removed = try await store.clearOfflineDownloads(paths: Array(paths))
                for request in removed {
                    OfflineLibrary.removeCopy(sourceID: request.sourceID, innerPath: request.innerPath)
                }
            } catch {
                lastError = error.localizedDescription
                let code = DiagnosticValue.errorCode(error)
                LyraLog.offline.error("Removing offline copies failed error=\(code, privacy: .public)")
            }
        }
    }

    /// Called after a scan so remote modifications redownload only files the
    /// user explicitly chose to keep offline.
    func reconcile() async {
        let store = LibraryStore(modelContainer: container)
        do {
            let requests = try await store.pendingOfflineDownloads()
            LyraLog.offline.info("Offline reconciliation found pending=\(requests.count)")
            enqueue(requests)
        } catch {
            lastError = error.localizedDescription
            let code = DiagnosticValue.errorCode(error)
            LyraLog.offline.error("Offline reconciliation failed error=\(code, privacy: .public)")
        }
    }

    private func isRemote(_ track: Track) -> Bool {
        LibraryManager.shared.source(for: track.sourceID)?.isRemote == true
    }

    private func enqueue(_ requests: [OfflineDownloadRequest]) {
        let known = Set(pending.map(\.relativePath)).union(active.keys)
        let additions = requests.filter { !known.contains($0.relativePath) }
        pending.append(contentsOf: additions)
        LyraLog.offline.debug("Offline queue added=\(additions.count) pending=\(self.pending.count)")
        startPendingDownloads()
    }

    private func startPendingDownloads() {
        while active.count < concurrency, !pending.isEmpty {
            let request = pending.removeFirst()
            guard let source = LibraryManager.shared.remoteSource(for: request.sourceID),
                  let destination = OfflineLibrary.fileURL(sourceID: request.sourceID, innerPath: request.innerPath)
            else {
                complete(request, result: .failure(LibrarySourceError.unavailable))
                continue
            }

            let task = Task { [weak self] in
                do {
                    let item = ScannedFile(relativePath: request.relativePath, size: 0, modified: .distantPast)
                    try await source.download(item, to: destination)
                    self?.complete(request, result: .success(()))
                } catch {
                    self?.complete(request, result: .failure(error))
                }
            }
            active[request.relativePath] = task
            activeDownloads = active.count
        }
    }

    private func complete(_ request: OfflineDownloadRequest, result: Result<Void, any Error>) {
        active.removeValue(forKey: request.relativePath)
        activeDownloads = active.count

        Task {
            let store = LibraryStore(modelContainer: container)
            switch result {
            case .success:
                try? await store.completeOfflineDownload(path: request.relativePath)
                LyraLog.offline.info("Offline download completed remaining=\(self.pending.count)")
            case .failure(let error):
                // Deselecting a downloading track cancels its URLSession task,
                // which surfaces as URLError.cancelled rather than
                // CancellationError — that is a user action, not a failure.
                if !Self.isCancellation(error) {
                    lastError = error.localizedDescription
                    let code = DiagnosticValue.errorCode(error)
                    LyraLog.offline.error("Offline download failed error=\(code, privacy: .public)")
                }
                try? await store.failOfflineDownload(path: request.relativePath)
            }
            startPendingDownloads()
        }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }
}
