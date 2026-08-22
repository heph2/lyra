import SwiftData
import SwiftUI

@main
struct LyraApp: App {
    private let container: ModelContainer

    @State private var player: PlayerController
    @State private var scanner: LibraryScanner
    @State private var offlineSync: OfflineSyncManager

    init() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        LyraLog.app.info("Launching Lyra version \(version, privacy: .public) build \(build, privacy: .public)")

        // Before anything else: without this the app never shows up in the
        // Files app, and there is no other way to get music in.
        AudioFile.prepareDropZone()

        let container = Self.makeContainer()
        let offlineSync = OfflineSyncManager(container: container)
        self.container = container
        _player = State(initialValue: PlayerController(container: container))
        _scanner = State(initialValue: LibraryScanner(container: container, offlineSync: offlineSync))
        _offlineSync = State(initialValue: offlineSync)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(player)
                .environment(scanner)
                .environment(offlineSync)
        }
        .modelContainer(container)
    }

    /// The library database lives in Application Support, deliberately *not* in
    /// `Documents/` — that folder is the user's own drop zone, visible in the
    /// Files app, and should contain only their music.
    ///
    /// If the store cannot be opened (a schema change on a sideloaded build, a
    /// corrupt file) we fall back to an in-memory store so the app still runs
    /// and a rescan can rebuild everything from the files on disk.
    private static func makeContainer() -> ModelContainer {
        let schema = Schema([Track.self, Playlist.self])

        do {
            // `Application Support` does not exist in a fresh app container, and
            // SwiftData will not create it — without this the store silently
            // fails and the whole library evaporates on every launch.
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let configuration = ModelConfiguration(
                schema: schema,
                url: base.appending(path: "Lyra.store", directoryHint: .notDirectory)
            )
            let container = try ModelContainer(for: schema, configurations: configuration)
            LyraLog.app.info("Opened persistent library store")
            return container
        } catch {
            let code = DiagnosticValue.errorCode(error)
            LyraLog.app.error("Persistent library store failed with \(code, privacy: .public); using memory")
            do {
                return try ModelContainer(
                    for: schema,
                    configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                )
            } catch {
                let code = DiagnosticValue.errorCode(error)
                LyraLog.app.fault("In-memory library store failed with \(code, privacy: .public)")
                fatalError("Could not create even an in-memory model container: \(error)")
            }
        }
    }
}
