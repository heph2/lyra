import SwiftData
import SwiftUI

/// Manages where Lyra looks for music.
///
/// The point of adding folders here is durability: iOS deletes the app's own
/// folder along with the app, and there is no way for an app to prevent or even
/// be told about that. Music kept in a folder outside Lyra survives being
/// deleted and reinstalled — and can be kept in sync by whatever put it there.
struct SourcesView: View {
    @Environment(LibraryScanner.self) private var scanner
    @Environment(\.dismiss) private var dismiss
    @Query private var tracks: [Track]

    @State private var isPickingFolder = false
    @State private var pendingRemoval: MusicSource?
    /// Bumped after add/remove to re-read the registry, which is not observable.
    @State private var revision = 0

    private var sources: [MusicSource] {
        _ = revision
        return SourceRegistry.shared.allSources
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(sources) { source in
                        row(for: source)
                    }
                } header: {
                    Text("Music Folders")
                } footer: {
                    Text("Deleting Lyra also deletes the built-in **Lyra Folder** and everything in it — iOS does that on its own and no app can stop it. Music in folders you add here lives outside Lyra and survives.")
                }

                Section {
                    Button("Add Folder…", systemImage: "folder.badge.plus") {
                        isPickingFolder = true
                    }
                } footer: {
                    Text("Pick a folder in iCloud Drive, an external drive, or another app's folder. Lyra plays the files where they are and never copies, moves or deletes them.")
                }
            }
            .navigationTitle("Music Folders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $isPickingFolder,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    scanner.addFolders(urls)
                    revision += 1
                }
            }
            .confirmationDialog(
                "Remove \(pendingRemoval?.displayName ?? "")?",
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove from Lyra", role: .destructive) {
                    guard let source = pendingRemoval else { return }
                    pendingRemoval = nil
                    Task {
                        await scanner.removeSource(source.id)
                        revision += 1
                    }
                }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: {
                Text("Its tracks leave your library. The folder and your files are not touched.")
            }
        }
    }

    @ViewBuilder
    private func row(for source: MusicSource) -> some View {
        let count = tracks.count { $0.sourceID == source.id }
        let reachable = SourceRegistry.shared.isReachable(source.id)

        HStack(spacing: 12) {
            Image(systemName: source.isDropZone ? "iphone" : "folder.badge.gearshape")
                .foregroundStyle(reachable ? Color.accentColor : Color.orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                Text(subtitle(count: count, reachable: reachable, isDropZone: source.isDropZone))
                    .font(.caption)
                    .foregroundStyle(reachable ? .secondary : Color.orange)
            }

            Spacer()

            if !source.isDropZone {
                Button("Remove", systemImage: "minus.circle.fill") {
                    pendingRemoval = source
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(.red)
                .buttonStyle(.plain)
            }
        }
    }

    private func subtitle(count: Int, reachable: Bool, isDropZone: Bool) -> String {
        guard reachable else { return "Can't be reached right now" }
        let tracks = "\(count) track\(count == 1 ? "" : "s")"
        return isDropZone ? "\(tracks) · deleted with the app" : "\(tracks) · survives deleting Lyra"
    }
}
