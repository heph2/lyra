import SwiftData
import SwiftUI

struct LibraryView: View {
    enum Section: String, CaseIterable, Identifiable {
        case songs, albums, artists, folders
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    @AppStorage("library.section") private var section: Section = .songs
    @AppStorage("library.sort") private var sort: TrackSort = .title

    @Environment(LibraryScanner.self) private var scanner
    @Query private var tracks: [Track]

    var body: some View {
        NavigationStack {
            Group {
                if tracks.isEmpty {
                    EmptyLibraryView()
                } else {
                    content
                }
            }
            .navigationTitle("Library")
            // Inline, because the segmented picker is pinned directly beneath
            // the bar — a large title would be pushed out from under it.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .safeAreaInset(edge: .top, spacing: 0) {
                if !tracks.isEmpty {
                    sectionPicker
                }
            }
            .overlay(alignment: .top) {
                if scanner.isScanning {
                    ScanProgressBar()
                }
            }
            .refreshable { await scanner.scan() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .songs:
            SongsListView(tracks: sort.apply(to: tracks))
        case .albums:
            AlbumsGridView(albums: LibraryGrouping.albums(from: tracks))
        case .artists:
            ArtistsListView(artists: LibraryGrouping.artists(from: tracks))
        case .folders:
            FolderBrowserView(path: "", tracks: tracks)
        }
    }

    private var sectionPicker: some View {
        Picker("Section", selection: $section) {
            ForEach(Section.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if section == .songs {
                    Picker("Sort By", selection: $sort) {
                        ForEach(TrackSort.allCases) { option in
                            Label(option.label, systemImage: option.systemImage).tag(option)
                        }
                    }
                }
                Divider()
                Button("Rescan Library", systemImage: "arrow.clockwise") {
                    scanner.scanInBackground()
                }
            } label: {
                Label("Options", systemImage: "ellipsis.circle")
            }
        }
    }
}

// MARK: - Songs

struct SongsListView: View {
    let tracks: [Track]

    @Environment(PlayerController.self) private var player

    var body: some View {
        List {
            if tracks.count > 1 {
                PlayAllHeader(tracks: tracks)
            }
            ForEach(tracks) { track in
                Button {
                    play(from: track)
                } label: {
                    TrackRow(track: track)
                }
                .buttonStyle(.plain)
                .trackActions(track)
            }
        }
        .listStyle(.plain)
    }

    private func play(from track: Track) {
        guard let index = tracks.firstIndex(where: { $0.relativePath == track.relativePath }) else { return }
        player.play(tracks: tracks, startAt: index)
    }
}

/// Shuffle-all / play-all pair that sits at the top of every track list.
struct PlayAllHeader: View {
    let tracks: [Track]

    @Environment(PlayerController.self) private var player

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.isShuffled = false
                player.play(tracks: tracks, startAt: 0)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            Button {
                player.isShuffled = true
                player.play(tracks: tracks, startAt: Int.random(in: tracks.indices))
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 10))
        .listRowSeparator(.hidden)
    }
}

// MARK: - Empty & progress states

struct EmptyLibraryView: View {
    @Environment(LibraryScanner.self) private var scanner

    var body: some View {
        ContentUnavailableView {
            Label("No Music Yet", systemImage: "music.note.house")
        } description: {
            VStack(spacing: 14) {
                Text(explanation)
                diagnostics
            }
        } actions: {
            Button("Rescan", systemImage: "arrow.clockwise") {
                scanner.scanInBackground()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// The three cases worth distinguishing: nothing there, files there but
    /// none playable, or files there that we should have picked up.
    private var explanation: LocalizedStringKey {
        let inventory = scanner.inventory

        if inventory.totalFiles == 0 {
            return """
            Open the **Files** app, go to *On My iPhone → Lyra*, and drop your \
            music folders in. Then pull down to refresh.

            That folder has to be the one Lyra created — a folder you make \
            yourself under *On My iPhone* belongs to the Files app, and Lyra \
            cannot read it.
            """
        }
        if inventory.audioFiles == 0 {
            return "Lyra found files in its folder, but none in a format it can play."
        }
        return "Lyra found playable files but could not add them. Try rescanning."
    }

    @ViewBuilder
    private var diagnostics: some View {
        let inventory = scanner.inventory

        if inventory.totalFiles > 0 {
            VStack(spacing: 4) {
                Text("\(inventory.totalFiles) file\(inventory.totalFiles == 1 ? "" : "s") in Lyra's folder, \(inventory.audioFiles) playable")
                if !inventory.unsupportedExtensions.isEmpty {
                    Text("Skipped: " + inventory.unsupportedExtensions.map { "." + $0 }.joined(separator: " "))
                }
                Text("Supported: mp3, m4a, aac, alac, flac, wav, aiff, caf")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }

        if let error = scanner.lastError {
            Text(error)
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }
}

struct ScanProgressBar: View {
    @Environment(LibraryScanner.self) private var scanner

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(scanner.total > 0
                     ? "Reading tags… \(scanner.processed) of \(scanner.total)"
                     : "Scanning library…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if scanner.total > 0 {
                ProgressView(value: scanner.progressFraction)
                    .progressViewStyle(.linear)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.default, value: scanner.isScanning)
    }
}
