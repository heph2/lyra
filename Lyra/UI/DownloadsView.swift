import SwiftData
import SwiftUI

struct DownloadsView: View {
    @Environment(OfflineSyncManager.self) private var offlineSync
    @Environment(PlayerController.self) private var player
    @Query(sort: \Track.title) private var tracks: [Track]

    private var downloads: [Track] {
        tracks.filter(\.offlineRequested)
    }

    private var inProgress: [Track] {
        downloads.filter(offlineSync.isDownloading)
    }

    private var completed: [Track] {
        OfflinePresentation.downloadedTracks(from: downloads).filter { !offlineSync.isDownloading($0) }
    }

    private var pending: [Track] {
        downloads.filter { track in
            !offlineSync.isDownloading(track)
                && track.offlineState != .availableOffline
                && track.offlineState != .modifiedRemote
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if downloads.isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Long-press a remote song or album and choose Download Offline.")
                    )
                } else {
                    List {
                        Section {
                            LabeledContent("Overall Progress") {
                                Text(offlineSync.progress(for: downloads), format: .percent)
                                    .monospacedDigit()
                            }
                            ProgressView(value: offlineSync.progress(for: downloads))
                        }

                        if !inProgress.isEmpty {
                            Section("Downloading") {
                                ForEach(inProgress) { track in
                                    downloadRow(track)
                                }
                            }
                        }

                        if !pending.isEmpty {
                            Section("Waiting to Retry") {
                                ForEach(pending) { track in
                                    downloadRow(track)
                                }
                            }
                        }

                        if !completed.isEmpty {
                            Section("Downloaded") {
                                ForEach(completed) { track in
                                    downloadRow(track)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) {
                if let error = offlineSync.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(.bar)
                }
            }
        }
    }

    private func downloadRow(_ track: Track) -> some View {
        Button {
            let index = downloads.firstIndex { $0.relativePath == track.relativePath } ?? 0
            player.play(tracks: downloads, startAt: index)
        } label: {
            TrackRow(track: track)
        }
        .buttonStyle(.plain)
        .trackActions(track)
    }
}
