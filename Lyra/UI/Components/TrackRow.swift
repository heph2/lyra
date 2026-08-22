import SwiftUI

/// One track in a list. `subtitleStyle` lets the same row serve the songs list
/// (artist — album), an album's track list (track number) and search results.
struct TrackRow: View {
    enum Leading {
        case artwork
        case trackNumber
        case none
    }

    let track: Track
    var leading: Leading = .artwork
    var subtitle: String?

    @Environment(PlayerController.self) private var player

    private var isCurrent: Bool {
        player.currentTrack?.relativePath == track.relativePath
    }

    var body: some View {
        HStack(spacing: 12) {
            leadingView

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                Text(subtitle ?? defaultSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isCurrent {
                Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel(player.isPlaying ? "Now playing" : "Paused")
            }

            offlineIndicator

            Text(track.formattedDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
    }

    @ViewBuilder
    private var leadingView: some View {
        switch leading {
        case .artwork:
            ArtworkView(hash: track.artworkHash, size: 44)
        case .trackNumber:
            Text(track.trackNumber > 0 ? "\(track.trackNumber)" : "–")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        case .none:
            EmptyView()
        }
    }

    private var defaultSubtitle: String {
        let album = track.album
        return album.isEmpty ? track.displayArtist : "\(track.displayArtist) — \(album)"
    }

    @ViewBuilder
    private var offlineIndicator: some View {
        if LibraryManager.shared.source(for: track.sourceID)?.isRemote == true {
            Group {
                switch track.offlineState {
                case .availableRemote:
                    Image(systemName: "cloud")
                        .accessibilityLabel("Available remotely")
                case .downloading:
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Downloading for offline playback")
                case .availableOffline:
                    Image(systemName: "checkmark.circle.fill")
                        .accessibilityLabel("Available offline")
                case .modifiedRemote:
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .accessibilityLabel("Updated version downloading")
                case .unavailable:
                    Image(systemName: "exclamationmark.triangle")
                        .accessibilityLabel("Offline download unavailable")
                }
            }
            .font(.caption)
            .foregroundStyle(track.offlineState == .availableOffline ? Color.green : Color.secondary)
            .frame(width: 16, height: 16)
        }
    }
}

/// Long-press / swipe actions shared by every track list.
struct TrackContextMenu: ViewModifier {
    let tracks: [Track]

    @Environment(PlayerController.self) private var player
    @Environment(OfflineSyncManager.self) private var offlineSync
    @State private var showingPlaylistPicker = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    player.playNext(tracks)
                }
                Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") {
                    player.addToQueue(tracks)
                }
                Button("Add to Playlist…", systemImage: "text.badge.plus") {
                    showingPlaylistPicker = true
                }
                if !remoteTracks.isEmpty {
                    Divider()
                    Button(downloadTitle, systemImage: "arrow.down.circle") {
                        offlineSync.download(remoteTracks)
                    }
                    if remoteTracks.contains(where: { $0.offlineRequested }) {
                        Button("Remove Offline Copy", systemImage: "trash", role: .destructive) {
                            offlineSync.removeOfflineCopies(remoteTracks)
                        }
                    }
                }
            }
            .sheet(isPresented: $showingPlaylistPicker) {
                AddToPlaylistSheet(tracks: tracks)
            }
    }

    private var remoteTracks: [Track] {
        tracks.filter { LibraryManager.shared.source(for: $0.sourceID)?.isRemote == true }
    }

    private var downloadTitle: String {
        remoteTracks.count == 1 ? "Download Offline" : "Download \(remoteTracks.count) Tracks"
    }
}

extension View {
    func trackActions(_ tracks: [Track]) -> some View {
        modifier(TrackContextMenu(tracks: tracks))
    }

    func trackActions(_ track: Track) -> some View {
        modifier(TrackContextMenu(tracks: [track]))
    }
}
