import SwiftData
import SwiftUI

@main
struct LyraApp: App {
    private let container: ModelContainer

    @State private var player: PlayerController
    @State private var scanner: LibraryScanner

    init() {
        let container = Self.makeContainer()
        self.container = container
        _player = State(initialValue: PlayerController(container: container))
        _scanner = State(initialValue: LibraryScanner(container: container))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(player)
                .environment(scanner)
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
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            do {
                return try ModelContainer(
                    for: schema,
                    configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                )
            } catch {
                fatalError("Could not create even an in-memory model container: \(error)")
            }
        }
    }
}
