import SwiftUI

/// Browses the library the way it sits on disk.
///
/// People who curate their own music think in folders — `Artist/Album/…` — and
/// that structure is often more accurate than the tags. The whole tree is
/// derived from `Track.folderPath`, so browsing never touches the filesystem.
struct FolderBrowserView: View {
    let path: String
    let tracks: [Track]

    @Environment(PlayerController.self) private var player

    private var node: LibraryGrouping.FolderNode {
        LibraryGrouping.folder(at: path, tracks: tracks)
    }

    var body: some View {
        let node = node

        List {
            if !node.subfolders.isEmpty || !node.tracks.isEmpty {
                Section {
                    PlayAllHeader(tracks: LibraryGrouping.tracksRecursively(under: path, tracks: tracks))
                        .listRowSeparator(.hidden)
                }
            }

            if !node.subfolders.isEmpty {
                Section {
                    ForEach(node.subfolders, id: \.self) { subfolder in
                        NavigationLink(value: FolderRoute(path: subfolder)) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(AudioFile.folderDisplayName(subfolder))
                                    Text(countLabel(for: subfolder))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }

            if !node.tracks.isEmpty {
                Section {
                    ForEach(node.tracks) { track in
                        TrackButton(track: track, tracks: node.tracks)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationDestination(for: FolderRoute.self) { route in
            FolderBrowserView(path: route.path, tracks: tracks)
                .navigationTitle(AudioFile.folderDisplayName(route.path))
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func countLabel(for subfolder: String) -> String {
        let count = LibraryGrouping.tracksRecursively(under: subfolder, tracks: tracks).count
        return "\(count) track\(count == 1 ? "" : "s")"
    }
}

/// Distinct from a bare `String` so the navigation destination does not collide
/// with other string-valued links.
struct FolderRoute: Hashable {
    let path: String
}
