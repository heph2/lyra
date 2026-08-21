import SwiftUI

struct ArtistsListView: View {
    let artists: [LibraryGrouping.ArtistGroup]

    var body: some View {
        List(artists) { artist in
            NavigationLink(value: artist) {
                HStack(spacing: 12) {
                    ArtworkView(
                        hash: artist.tracks.first(where: { $0.artworkHash != nil })?.artworkHash,
                        size: 44,
                        cornerRadius: 22
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artist.name).lineLimit(1)
                        Text("\(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s") · \(artist.tracks.count) track\(artist.tracks.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .trackActions(artist.tracks)
        }
        .listStyle(.plain)
        .navigationDestination(for: LibraryGrouping.ArtistGroup.self) { artist in
            ArtistDetailView(artist: artist)
        }
    }
}

struct ArtistDetailView: View {
    let artist: LibraryGrouping.ArtistGroup

    private var albums: [LibraryGrouping.AlbumGroup] {
        LibraryGrouping.albums(from: artist.tracks)
    }

    var body: some View {
        List {
            Section {
                PlayAllHeader(tracks: artist.tracks)
                    .listRowSeparator(.hidden)
            }

            ForEach(albums) { album in
                Section {
                    ForEach(album.tracks) { track in
                        TrackButton(track: track, tracks: album.tracks, leading: .trackNumber)
                    }
                } header: {
                    NavigationLink(value: album) {
                        HStack(spacing: 10) {
                            ArtworkView(hash: album.artworkHash, size: 36, cornerRadius: 5)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(album.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                if album.year > 0 {
                                    Text(String(album.year))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .textCase(nil)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: LibraryGrouping.AlbumGroup.self) { album in
            AlbumDetailView(album: album)
        }
    }
}

/// A tappable track row that plays within the list it belongs to.
struct TrackButton: View {
    let track: Track
    let tracks: [Track]
    var leading: TrackRow.Leading = .artwork
    var subtitle: String?

    @Environment(PlayerController.self) private var player

    var body: some View {
        Button {
            guard let index = tracks.firstIndex(where: { $0.relativePath == track.relativePath }) else { return }
            player.play(tracks: tracks, startAt: index)
        } label: {
            TrackRow(track: track, leading: leading, subtitle: subtitle)
        }
        .buttonStyle(.plain)
        .trackActions(track)
    }
}
