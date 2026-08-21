import SwiftUI

/// Compact transport that lives in the tab bar accessory slot. Tapping
/// anywhere but the buttons opens the full Now Playing screen.
struct MiniPlayerBar: View {
    var onTap: () -> Void

    @Environment(PlayerController.self) private var player

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(hash: player.currentTrack?.artworkHash, size: 32, cornerRadius: 5)

            VStack(alignment: .leading, spacing: 1) {
                Text(player.currentTrack?.title ?? "Nothing Playing")
                    .font(.subheadline)
                    .lineLimit(1)
                if let artist = player.currentTrack?.displayArtist {
                    Text(artist)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 32, height: 32)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.body)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next track")
        }
        .padding(.horizontal, 12)
        .contentShape(.rect)
        .onTapGesture(perform: onTap)
    }
}
