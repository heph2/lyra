import Foundation

/// A folder Lyra reads music from.
///
/// There is always the built-in drop zone (the app's own `Documents/`), plus
/// any number of folders the user picks elsewhere — iCloud Drive, another app's
/// shared folder, an external drive. Those are reached through security-scoped
/// bookmarks and, crucially, live outside the app container: iOS deletes the
/// container when the app is deleted, so anything kept there is the only music
/// that survives an uninstall or a reinstall.
struct MusicSource: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var displayName: String
    /// Security-scoped bookmark. Empty for the built-in drop zone, which needs
    /// no permission.
    var bookmark: Data

    var isDropZone: Bool { id == SourceRegistry.dropZoneID }
}

/// Owns the list of sources, resolves their bookmarks, and enumerates audio
/// files across all of them.
///
/// Thread-safe by lock rather than by actor: the scanner reaches in from a
/// `TaskGroup`, `LibraryStore` from a model actor, and the UI from the main
/// actor, and every operation here is short.
final class SourceRegistry: @unchecked Sendable {
    static let shared = SourceRegistry()

    static let dropZoneID = "local"
    private static let defaultsKey = "library.sources"

    private let lock = NSLock()
    private var external: [MusicSource]
    /// Resolved base URLs, keyed by source id. Security-scoped access is
    /// started once on resolve and held for the lifetime of the process.
    private var resolved: [String: URL] = [:]
    /// Sources whose bookmark could not be resolved this launch — an unplugged
    /// drive, a folder the user deleted, a revoked permission.
    private var unreachable: Set<String> = []

    private init() {
        let data = UserDefaults.standard.data(forKey: Self.defaultsKey) ?? Data()
        external = (try? JSONDecoder().decode([MusicSource].self, from: data)) ?? []
    }

    // MARK: - The source list

    var dropZone: MusicSource {
        MusicSource(id: Self.dropZoneID, displayName: "Lyra Folder", bookmark: Data())
    }

    /// The drop zone first, then user-added folders in the order they were added.
    var allSources: [MusicSource] {
        lock.lock()
        defer { lock.unlock() }
        return [dropZone] + external
    }

    var externalSources: [MusicSource] {
        lock.lock()
        defer { lock.unlock() }
        return external
    }

    func displayName(for sourceID: String) -> String {
        if sourceID == Self.dropZoneID { return dropZone.displayName }
        lock.lock()
        defer { lock.unlock() }
        return external.first { $0.id == sourceID }?.displayName ?? "Missing Folder"
    }

    func isReachable(_ sourceID: String) -> Bool {
        baseURL(for: sourceID) != nil
    }

    // MARK: - Adding and removing

    /// Bookmarks a folder chosen in the document picker. The caller must not
    /// have stopped security-scoped access on `url` yet.
    ///
    /// Returns nil when the folder is already known or cannot be bookmarked.
    @discardableResult
    func add(folder url: URL) -> MusicSource? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let bookmark = try? url.bookmarkData() else { return nil }

        lock.lock()
        // Re-picking the same folder should be a no-op rather than a duplicate.
        let alreadyKnown = external.contains { source in
            guard let existing = resolved[source.id] else { return false }
            return existing.standardizedFileURL == url.standardizedFileURL
        }
        guard !alreadyKnown else {
            lock.unlock()
            return nil
        }

        let source = MusicSource(
            id: UUID().uuidString,
            displayName: url.lastPathComponent,
            bookmark: bookmark
        )
        external.append(source)
        persistLocked()
        lock.unlock()

        // Prime the cache so the very next scan can see it.
        _ = baseURL(for: source.id)
        return source
    }

    func remove(sourceID: String) {
        guard sourceID != Self.dropZoneID else { return }
        lock.lock()
        defer { lock.unlock() }

        if let url = resolved.removeValue(forKey: sourceID) {
            url.stopAccessingSecurityScopedResource()
        }
        external.removeAll { $0.id == sourceID }
        unreachable.remove(sourceID)
        persistLocked()
    }

    private func persistLocked() {
        let data = (try? JSONEncoder().encode(external)) ?? Data()
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    // MARK: - Resolution

    /// The folder a source points at, or nil when it cannot be reached.
    func baseURL(for sourceID: String) -> URL? {
        if sourceID == Self.dropZoneID { return AudioFile.documentsURL }

        lock.lock()
        if let cached = resolved[sourceID] {
            lock.unlock()
            return cached
        }
        guard let source = external.first(where: { $0.id == sourceID }) else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: source.bookmark,
            bookmarkDataIsStale: &isStale
        ), url.startAccessingSecurityScopedResource() else {
            lock.lock()
            unreachable.insert(sourceID)
            lock.unlock()
            return nil
        }

        lock.lock()
        resolved[sourceID] = url
        unreachable.remove(sourceID)
        // A stale bookmark still resolves; refreshing it keeps it working after
        // the folder is moved or renamed.
        if isStale, let refreshed = try? url.bookmarkData(),
           let index = external.firstIndex(where: { $0.id == sourceID }) {
            external[index].bookmark = refreshed
            persistLocked()
        }
        lock.unlock()

        return url
    }

    /// Absolute URL for a source-qualified track path.
    func url(forTrackPath path: String) -> URL? {
        let (sourceID, innerPath) = AudioFile.split(trackPath: path)
        guard let base = baseURL(for: sourceID) else { return nil }
        return base.appending(path: innerPath, directoryHint: .notDirectory)
    }

    // MARK: - Enumeration

    /// Every audio file across every reachable source, with source-qualified
    /// paths.
    func enumerateAudioFiles() -> [ScannedFile] {
        allSources.flatMap { source in
            guard let base = baseURL(for: source.id) else { return [ScannedFile]() }
            return Self.enumerateAudioFiles(in: base, sourceID: source.id)
        }
    }

    /// Source ids we could not open this launch. Their tracks must be left
    /// alone by the scan rather than treated as deleted — unplugging a drive
    /// should not wipe the library or gut every playlist that referenced it.
    func unreachableSourceIDs() -> Set<String> {
        for source in allSources { _ = baseURL(for: source.id) }
        lock.lock()
        defer { lock.unlock() }
        return unreachable
    }

    func inventory() -> AudioFile.Inventory {
        var total = 0
        var audio = 0
        var skipped = Set<String>()

        for source in allSources {
            guard let base = baseURL(for: source.id) else { continue }
            let counts = AudioFile.inventory(of: base)
            total += counts.totalFiles
            audio += counts.audioFiles
            skipped.formUnion(counts.unsupportedExtensions)
        }

        return AudioFile.Inventory(
            totalFiles: total,
            audioFiles: audio,
            unsupportedExtensions: skipped.sorted()
        )
    }

    static func enumerateAudioFiles(in root: URL, sourceID: String) -> [ScannedFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let base = root.standardizedFileURL.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"

        var results: [ScannedFile] = []
        for case let url as URL in enumerator {
            guard AudioFile.isSupported(url) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }

            let full = url.standardizedFileURL.path(percentEncoded: false)
            guard full.hasPrefix(prefix) else { continue }
            let innerPath = String(full.dropFirst(prefix.count))

            results.append(ScannedFile(
                relativePath: AudioFile.trackPath(sourceID: sourceID, innerPath: innerPath),
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast
            ))
        }
        return results
    }
}
