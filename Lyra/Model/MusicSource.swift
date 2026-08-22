import Foundation

/// Persisted, non-secret configuration for one library source. Passwords are
/// deliberately kept in `KeychainStore`, never alongside this value.
struct MusicSource: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case localFolder
        case webDAV
    }

    var id: String
    var displayName: String
    var kind: Kind
    /// Security-scoped bookmark for a local folder. Empty for the drop zone.
    var bookmark: Data
    var serverURL: String?
    var username: String?

    init(
        id: String,
        displayName: String,
        kind: Kind = .localFolder,
        bookmark: Data = Data(),
        serverURL: String? = nil,
        username: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.bookmark = bookmark
        self.serverURL = serverURL
        self.username = username
    }

    /// Makes libraries persisted by the folder-only version decode unchanged.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        displayName = try values.decode(String.self, forKey: .displayName)
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .localFolder
        bookmark = try values.decodeIfPresent(Data.self, forKey: .bookmark) ?? Data()
        serverURL = try values.decodeIfPresent(String.self, forKey: .serverURL)
        username = try values.decodeIfPresent(String.self, forKey: .username)
    }

    var isDropZone: Bool { id == LibraryManager.dropZoneID }
    var isRemote: Bool { kind == .webDAV }
}

protocol LibrarySource: Sendable {
    var id: String { get }
    var displayName: String { get }
    func scan() async throws -> [ScannedFile]
}

protocol RemoteLibrarySource: LibrarySource {
    /// A ranged read of the front of a file. `maxBytes` is the caller's budget:
    /// indexing a remote library means paying for every byte, so the scanner
    /// asks for the smallest prefix that answers its question.
    func metadataHeader(for item: ScannedFile, maxBytes: Int) async throws -> Data
    func download(_ item: ScannedFile, to destination: URL) async throws
}

struct LibrarySourceAvailability: Sendable, Equatable {
    var isReachable: Bool
    var detail: String?

    static let unknown = LibrarySourceAvailability(isReachable: true, detail: nil)
}

struct LibraryScanResult: Sendable {
    var files: [ScannedFile] = []
    /// Every failure is held back from removals. A failed request must never be
    /// treated as an empty remote collection.
    var unavailableSourceIDs: Set<String> = []
    var errors: [String] = []
}

enum LibrarySourceError: LocalizedError, Sendable {
    case unavailable
    case invalidConfiguration
    case signInRequired
    case notWebDAVServer
    case rangeNotSupported
    case server(status: Int)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Can't be reached right now."
        case .invalidConfiguration: "The library configuration is invalid."
        case .signInRequired: "Sign in again to this WebDAV library."
        case .notWebDAVServer: "This server did not return a WebDAV response."
        case .rangeNotSupported: "This server does not support metadata range reads."
        case .server(let status): "The server returned HTTP \(status)."
        }
    }
}

/// Owns source configuration and provides a uniform source list to scanning.
/// It stays lock-based because bookmark resolution is short and is needed by
/// the UI, the model actor, and tag-reading tasks.
final class LibraryManager: @unchecked Sendable {
    static let shared = LibraryManager()

    static let dropZoneID = "local"
    private static let defaultsKey = "library.sources"

    private let lock = NSLock()
    private var external: [MusicSource]
    /// Security-scoped access remains active while the app runs so a later
    /// playback request has the same access granted during the scan.
    private var resolved: [String: URL] = [:]
    private var availability: [String: LibrarySourceAvailability] = [:]
    /// Passwords for this launch only, never written anywhere. The Keychain is
    /// still the durable store; this exists so that a Keychain that refuses to
    /// answer — it has no entitlement, the device was just unlocked, SideStore
    /// re-signed under a different team — degrades into "works until you quit"
    /// rather than into a library that scans to zero tracks.
    private var passwords: [String: String] = [:]

    private init() {
        let data = UserDefaults.standard.data(forKey: Self.defaultsKey) ?? Data()
        external = (try? JSONDecoder().decode([MusicSource].self, from: data)) ?? []
    }

    var dropZone: MusicSource {
        MusicSource(id: Self.dropZoneID, displayName: "Lyra Folder")
    }

    var allSources: [MusicSource] {
        lock.lock()
        defer { lock.unlock() }
        return [dropZone] + external
    }

    func displayName(for sourceID: String) -> String {
        if sourceID == Self.dropZoneID { return dropZone.displayName }
        lock.lock()
        defer { lock.unlock() }
        return external.first { $0.id == sourceID }?.displayName ?? "Missing Library"
    }

    func source(for sourceID: String) -> MusicSource? {
        if sourceID == Self.dropZoneID { return dropZone }
        lock.lock()
        defer { lock.unlock() }
        return external.first { $0.id == sourceID }
    }

    func availability(for sourceID: String) -> LibrarySourceAvailability {
        lock.lock()
        defer { lock.unlock() }
        return availability[sourceID] ?? .unknown
    }

    // MARK: - Source changes

    @discardableResult
    func add(folder url: URL) -> MusicSource? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData() else { return nil }

        lock.lock()
        let alreadyKnown = external.contains { source in
            guard source.kind == .localFolder, let existing = resolved[source.id] else { return false }
            return existing.standardizedFileURL == url.standardizedFileURL
        }
        guard !alreadyKnown else {
            lock.unlock()
            return nil
        }

        let source = MusicSource(id: UUID().uuidString, displayName: url.lastPathComponent, bookmark: bookmark)
        external.append(source)
        persistLocked()
        lock.unlock()
        _ = baseURL(for: source.id)
        return source
    }

    /// Adds a WebDAV library. `warning` is non-nil when the library works now
    /// but its password could not be stored durably — a case worth telling the
    /// user about, and not worth refusing the whole library over.
    func addWebDAV(
        name: String,
        urlString: String,
        username: String,
        password: String
    ) throws -> (source: MusicSource, warning: String?) {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil
        else { throw LibrarySourceError.invalidConfiguration }

        let source = MusicSource(
            id: UUID().uuidString,
            displayName: name.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: .webDAV,
            serverURL: url.absoluteString,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !source.displayName.isEmpty else { throw LibrarySourceError.invalidConfiguration }

        var warning: String?
        do {
            try KeychainStore.setPassword(password, for: source.id)
        } catch {
            let detail = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            warning = "Added, but the password could not be saved to the Keychain (\(detail)). "
                + "The library works until you quit Lyra; after that you will have to add it again."
        }

        lock.lock()
        passwords[source.id] = password
        external.append(source)
        persistLocked()
        lock.unlock()
        return (source, warning)
    }

    /// The password for a remote library: this launch's copy first, then the
    /// Keychain. Nil means the user has to sign in again.
    func password(for sourceID: String) -> String? {
        lock.lock()
        let cached = passwords[sourceID]
        lock.unlock()
        if let cached { return cached }

        guard let stored = try? KeychainStore.password(for: sourceID) else { return nil }
        lock.lock()
        passwords[sourceID] = stored
        lock.unlock()
        return stored
    }

    func remove(sourceID: String) throws {
        guard sourceID != Self.dropZoneID else { return }
        // Delete the secret first. If Keychain is unavailable, retain the
        // configuration instead of leaving an orphaned password behind.
        try KeychainStore.deletePassword(for: sourceID)
        lock.lock()
        passwords.removeValue(forKey: sourceID)
        if let url = resolved.removeValue(forKey: sourceID) {
            url.stopAccessingSecurityScopedResource()
        }
        external.removeAll { $0.id == sourceID }
        availability.removeValue(forKey: sourceID)
        persistLocked()
        lock.unlock()
    }

    func testWebDAV(name: String, urlString: String, username: String, password: String) async throws -> Int {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil
        else { throw LibrarySourceError.invalidConfiguration }
        let source = MusicSource(
            id: UUID().uuidString,
            displayName: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "WebDAV" : name,
            kind: .webDAV,
            serverURL: url.absoluteString,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let files = try await WebDAVSource(configuration: source, password: password).scan()
        return files.count
    }

    private func persistLocked() {
        let data = (try? JSONEncoder().encode(external)) ?? Data()
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    // MARK: - Local resolution

    func baseURL(for sourceID: String) -> URL? {
        if sourceID == Self.dropZoneID { return AudioFile.documentsURL }

        lock.lock()
        if let cached = resolved[sourceID] {
            lock.unlock()
            return cached
        }
        guard let source = external.first(where: { $0.id == sourceID }), source.kind == .localFolder else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        var stale = false
        guard let url = try? URL(resolvingBookmarkData: source.bookmark, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource()
        else {
            setAvailability(.init(isReachable: false, detail: "Can't be reached right now"), for: sourceID)
            return nil
        }

        lock.lock()
        resolved[sourceID] = url
        availability[sourceID] = .init(isReachable: true, detail: nil)
        if stale, let refreshed = try? url.bookmarkData(),
           let index = external.firstIndex(where: { $0.id == sourceID }) {
            external[index].bookmark = refreshed
            persistLocked()
        }
        lock.unlock()
        return url
    }

    /// Local tracks have a filesystem URL. Remote-only tracks deliberately do
    /// not: Phase 2 indexes them, while downloading/playback is Phase 3.
    func url(forTrackPath path: String) -> URL? {
        let split = AudioFile.split(trackPath: path)
        guard let source = source(for: split.sourceID), source.kind == .localFolder,
              let base = baseURL(for: split.sourceID)
        else { return nil }
        return base.appending(path: split.innerPath, directoryHint: .notDirectory)
    }

    // MARK: - Scanning

    func scan() async -> LibraryScanResult {
        let configurations = allSources
        var result = LibraryScanResult()

        // Source scans stay sequential. Both TaskGroup and explicitly owned
        // child tasks have produced reproducible Swift runtime memory faults on
        // a physical device while returning a source id beside scan results.
        for configuration in configurations {
            let source = makeSource(configuration)
            do {
                let files = try await source.scan()
                result.files.append(contentsOf: files)
                setAvailability(.init(isReachable: true, detail: nil), for: configuration.id)
            } catch {
                result.unavailableSourceIDs.insert(configuration.id)
                let description = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
                result.errors.append("\(configuration.displayName): \(description)")
                setAvailability(.init(isReachable: false, detail: description), for: configuration.id)
            }
        }

        return result
    }

    func remoteSource(for sourceID: String) -> (any RemoteLibrarySource)? {
        guard let configuration = source(for: sourceID), configuration.kind == .webDAV else { return nil }
        return WebDAVSource(configuration: configuration)
    }

    func inventory() -> AudioFile.Inventory {
        var total = 0
        var audio = 0
        var skipped = Set<String>()
        for source in allSources where source.kind == .localFolder {
            guard let root = baseURL(for: source.id) else { continue }
            let sourceInventory = AudioFile.inventory(of: root)
            total += sourceInventory.totalFiles
            audio += sourceInventory.audioFiles
            skipped.formUnion(sourceInventory.unsupportedExtensions)
        }
        return AudioFile.Inventory(totalFiles: total, audioFiles: audio, unsupportedExtensions: skipped.sorted())
    }

    private func makeSource(_ configuration: MusicSource) -> any LibrarySource {
        switch configuration.kind {
        case .localFolder:
            LocalFolderSource(configuration: configuration)
        case .webDAV:
            WebDAVSource(configuration: configuration)
        }
    }

    private func setAvailability(_ value: LibrarySourceAvailability, for sourceID: String) {
        lock.lock()
        availability[sourceID] = value
        lock.unlock()
    }
}

final class LocalFolderSource: LibrarySource, @unchecked Sendable {
    let configuration: MusicSource

    init(configuration: MusicSource) {
        self.configuration = configuration
    }

    var id: String { configuration.id }
    var displayName: String { configuration.displayName }

    func scan() async throws -> [ScannedFile] {
        guard let root = LibraryManager.shared.baseURL(for: id) else {
            throw LibrarySourceError.unavailable
        }
        return Self.enumerateAudioFiles(in: root, sourceID: id)
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
        var files: [ScannedFile] = []
        for case let url as URL in enumerator {
            guard AudioFile.isSupported(url),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            let path = url.standardizedFileURL.path(percentEncoded: false)
            guard path.hasPrefix(prefix) else { continue }
            files.append(ScannedFile(
                relativePath: AudioFile.trackPath(sourceID: sourceID, innerPath: String(path.dropFirst(prefix.count))),
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast
            ))
        }
        return files
    }
}
