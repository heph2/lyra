import SwiftUI

/// Root of the Folders tab.
///
/// With only the built-in drop zone there is nothing to choose between, so it
/// browses straight into it. Once the user has added folders of their own, the
/// top level becomes the list of those folders.
struct FolderBrowserView: View {
    let tracks: [Track]

    private var sources: [MusicSource] { LibraryManager.shared.allSources }

    var body: some View {
        if sources.count <= 1 {
            FolderContentsView(path: "", sourceID: LibraryManager.dropZoneID, tracks: tracks)
        } else {
            List(sources) { source in
                let count = LibraryGrouping.tracksRecursively(
                    under: "",
                    sourceID: source.id,
                    tracks: tracks
                ).count
                let reachable = LibraryManager.shared.availability(for: source.id).isReachable

                NavigationLink(value: FolderRoute(path: "", sourceID: source.id)) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.displayName)
                            Text(reachable
                                 ? "\(count) track\(count == 1 ? "" : "s")"
                                 : "Unavailable — folder can't be reached")
                                .font(.caption)
                                .foregroundStyle(reachable ? .secondary : Color.orange)
                        }
                    } icon: {
                        Image(systemName: source.isDropZone ? "iphone" : "folder.badge.gearshape")
                            .foregroundStyle(reachable ? Color.accentColor : Color.orange)
                    }
                }
            }
            .listStyle(.plain)
            .navigationDestination(for: FolderRoute.self) { route in
                FolderContentsView(path: route.path, sourceID: route.sourceID, tracks: tracks)
                    .navigationTitle(route.path.isEmpty
                                     ? LibraryManager.shared.displayName(for: route.sourceID)
                                     : AudioFile.folderDisplayName(route.path))
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

/// One folder's contents: subfolders, then the tracks sitting directly in it.
struct FolderContentsView: View {
    let path: String
    let sourceID: String
    let tracks: [Track]

    private var node: LibraryGrouping.FolderNode {
        LibraryGrouping.folder(at: path, sourceID: sourceID, tracks: tracks)
    }

    var body: some View {
        let node = node

        List {
            if !node.subfolders.isEmpty || !node.tracks.isEmpty {
                Section {
                    PlayAllHeader(tracks: LibraryGrouping.tracksRecursively(
                        under: path,
                        sourceID: sourceID,
                        tracks: tracks
                    ))
                    .listRowSeparator(.hidden)
                }
            }

            if !node.subfolders.isEmpty {
                Section {
                    ForEach(node.subfolders, id: \.self) { subfolder in
                        NavigationLink(value: FolderRoute(path: subfolder, sourceID: sourceID)) {
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
            FolderContentsView(path: route.path, sourceID: route.sourceID, tracks: tracks)
                .navigationTitle(AudioFile.folderDisplayName(route.path))
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func countLabel(for subfolder: String) -> String {
        let count = LibraryGrouping.tracksRecursively(
            under: subfolder,
            sourceID: sourceID,
            tracks: tracks
        ).count
        return "\(count) track\(count == 1 ? "" : "s")"
    }
}

/// Distinct from a bare `String` so the navigation destination does not collide
/// with other string-valued links.
struct FolderRoute: Hashable {
    let path: String
    let sourceID: String
}
