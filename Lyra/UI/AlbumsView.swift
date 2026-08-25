import SwiftUI

struct AlbumsGridView: View {
    let albums: [LibraryGrouping.AlbumGroup]

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(albums) { album in
                    NavigationLink(value: album) {
                        AlbumCell(album: album)
                    }
                    .buttonStyle(.plain)
                    .trackActions(album.tracks)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .navigationDestination(for: LibraryGrouping.AlbumGroup.self) { album in
            AlbumDetailView(album: album)
        }
    }
}

private struct AlbumCell: View {
    let album: LibraryGrouping.AlbumGroup

    @Environment(OfflineSyncManager.self) private var offlineSync

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                ArtworkView(hash: album.artworkHash, size: proxy.size.width, cornerRadius: 8)
                    .overlay(alignment: .bottomTrailing) {
                        if album.tracks.contains(where: offlineSync.isDownloading) {
                            CircularDownloadProgressView(
                                progress: offlineSync.progress(for: album.tracks),
                                size: 30
                            )
                            .padding(8)
                            .accessibilityLabel("Album download progress")
                            .accessibilityValue(Text(offlineSync.progress(for: album.tracks), format: .percent))
                        }
                    }
            }
            .aspectRatio(1, contentMode: .fit)

            Text(album.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Text(album.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct AlbumDetailView: View {
    let album: LibraryGrouping.AlbumGroup

    @Environment(PlayerController.self) private var player

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            Section {
                ForEach(album.tracks) { track in
                    Button {
                        play(from: track)
                    } label: {
                        TrackRow(track: track, leading: .trackNumber, subtitle: subtitle(for: track))
                    }
                    .buttonStyle(.plain)
                    .trackActions(track)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(spacing: 12) {
            ArtworkView(hash: album.artworkHash, size: 200, cornerRadius: 10)

            VStack(spacing: 2) {
                Text(album.title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(album.artist)
                    .foregroundStyle(.secondary)
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            PlayAllHeader(tracks: album.tracks)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal)
    }

    private var detailLine: String {
        var parts: [String] = []
        if album.year > 0 { parts.append(String(album.year)) }
        parts.append("\(album.tracks.count) track\(album.tracks.count == 1 ? "" : "s")")

        let total = album.tracks.reduce(0) { $0 + $1.duration }
        if total > 0 {
            parts.append("\(Int((total / 60).rounded())) min")
        }
        return parts.joined(separator: " · ")
    }

    /// Only surface the track artist when it differs from the album artist —
    /// otherwise every row on a normal album repeats the same name.
    private func subtitle(for track: Track) -> String? {
        track.displayArtist == album.artist ? "" : track.displayArtist
    }

    private func play(from track: Track) {
        guard let index = album.tracks.firstIndex(where: { $0.relativePath == track.relativePath }) else { return }
        player.play(tracks: album.tracks, startAt: index)
    }
}
