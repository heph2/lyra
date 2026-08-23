import SwiftUI

struct NowPlayingView: View {
    @Environment(PlayerController.self) private var player
    @Environment(\.dismiss) private var dismiss

    /// Local mirror of the position while dragging, so the slider follows the
    /// finger instead of being yanked back by periodic time updates.
    @State private var scrubPosition: Double = 0
    @State private var showingQueue = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                LargeArtworkView(hash: player.currentTrack?.artworkHash)
                    .padding(.horizontal, 32)
                    .padding(.top, 8)

                titleBlock
                scrubber
                transportControls
                secondaryControls

                Spacer(minLength: 0)
            }
            .padding(.bottom, 16)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Queue", systemImage: "list.bullet") { showingQueue = true }
                        .disabled(player.upcoming.isEmpty)
                }
            }
            .sheet(isPresented: $showingQueue) {
                QueueView()
                    .presentationDetents([.medium, .large])
            }
            .alert(
                "Playback Problem",
                isPresented: .constant(player.errorMessage != nil),
                actions: { Button("OK", role: .cancel) {} },
                message: { Text(player.errorMessage ?? "") }
            )
        }
    }

    // MARK: - Pieces

    private var titleBlock: some View {
        VStack(spacing: 4) {
            Text(player.currentTrack?.title ?? "Nothing Playing")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(player.currentTrack?.displayArtist ?? "")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let album = player.currentTrack?.album, !album.isEmpty {
                Text(album)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 32)
    }

    private var scrubber: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { player.isScrubbing ? scrubPosition : player.currentTime },
                    set: { scrubPosition = $0 }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        scrubPosition = player.currentTime
                        player.isScrubbing = true
                    } else {
                        player.isScrubbing = false
                        player.seek(to: scrubPosition)
                    }
                }
            )
            .disabled(player.duration <= 0)

            HStack {
                Text(Self.timeString(player.isScrubbing ? scrubPosition : player.currentTime))
                    .accessibilityIdentifier("Playback elapsed")
                Spacer()
                Text("-" + Self.timeString(max(0, player.duration - (player.isScrubbing ? scrubPosition : player.currentTime))))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
    }

    private var transportControls: some View {
        HStack(spacing: 40) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.title)
            }
            .accessibilityLabel("Previous track")

            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.title)
            }
            .accessibilityLabel("Next track")
        }
        .foregroundStyle(.primary)
    }

    private var secondaryControls: some View {
        @Bindable var player = player

        return HStack(spacing: 48) {
            Button {
                player.isShuffled.toggle()
            } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(player.isShuffled ? Color.accentColor : .secondary)
            }
            .accessibilityLabel("Shuffle")
            .accessibilityValue(player.isShuffled ? "On" : "Off")

            Button { player.skip(by: -15) } label: {
                Image(systemName: "gobackward.15").foregroundStyle(.secondary)
            }
            .accessibilityLabel("Back 15 seconds")

            Button { player.skip(by: 15) } label: {
                Image(systemName: "goforward.15").foregroundStyle(.secondary)
            }
            .accessibilityLabel("Forward 15 seconds")

            Button {
                player.cycleRepeat()
            } label: {
                Image(systemName: player.repeatMode.systemImage)
                    .foregroundStyle(player.repeatMode == .off ? .secondary : Color.accentColor)
            }
            .accessibilityLabel("Repeat")
            .accessibilityValue(player.repeatMode.rawValue)
        }
        .font(.title3)
    }

    static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The upcoming tracks, reorderable and removable.
struct QueueView: View {
    @Environment(PlayerController.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let current = player.currentTrack {
                    Section("Now Playing") {
                        TrackRow(track: current)
                    }
                }

                Section("Next Up") {
                    ForEach(Array(player.upcoming.enumerated()), id: \.element.relativePath) { offset, track in
                        Button {
                            player.jumpToUpcoming(offset: offset)
                            dismiss()
                        } label: {
                            TrackRow(track: track)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { player.removeUpcoming(at: $0) }
                    .onMove { player.moveUpcoming(fromOffsets: $0, toOffset: $1) }
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
    }
}
