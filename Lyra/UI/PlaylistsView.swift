import SwiftData
import SwiftUI

struct PlaylistsView: View {
    @Query(sort: \Playlist.dateModified, order: .reverse) private var playlists: [Playlist]
    @Environment(\.modelContext) private var context

    @State private var showingNewPlaylist = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            Group {
                if playlists.isEmpty {
                    ContentUnavailableView {
                        Label("No Playlists", systemImage: "list.bullet.rectangle")
                    } description: {
                        Text("Make a playlist, then add tracks from anywhere in your library with a long press.")
                    } actions: {
                        Button("New Playlist", systemImage: "plus") { startCreating() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Playlists")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Playlist", systemImage: "plus") { startCreating() }
                }
            }
            .alert("New Playlist", isPresented: $showingNewPlaylist) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { create() }
            }
        }
    }

    private var list: some View {
        List {
            ForEach(playlists) { playlist in
                NavigationLink(value: playlist) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlist.name)
                        Text("\(playlist.trackCount) track\(playlist.trackCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete(perform: delete)
        }
        .navigationDestination(for: Playlist.self) { playlist in
            PlaylistDetailView(playlist: playlist)
        }
    }

    private func startCreating() {
        newName = ""
        showingNewPlaylist = true
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        context.insert(Playlist(name: name))
        try? context.save()
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            context.delete(playlists[index])
        }
        try? context.save()
    }
}

struct PlaylistDetailView: View {
    @Bindable var playlist: Playlist

    @Environment(\.modelContext) private var context
    @Environment(PlayerController.self) private var player

    @State private var isRenaming = false
    @State private var draftName = ""

    private var tracks: [Track] {
        playlist.resolveTracks(in: context)
    }

    var body: some View {
        let tracks = tracks

        Group {
            if tracks.isEmpty {
                ContentUnavailableView(
                    "Empty Playlist",
                    systemImage: "music.note.list",
                    description: Text("Long-press any track in your library and choose *Add to Playlist*.")
                )
            } else {
                List {
                    Section {
                        PlayAllHeader(tracks: tracks)
                            .listRowSeparator(.hidden)
                    }
                    Section {
                        ForEach(tracks) { track in
                            TrackButton(track: track, tracks: tracks)
                        }
                        .onDelete { offsets in
                            playlist.remove(atOffsets: offsets)
                            try? context.save()
                        }
                        .onMove { source, destination in
                            playlist.move(fromOffsets: source, toOffset: destination)
                            try? context.save()
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Rename", systemImage: "pencil") {
                        draftName = playlist.name
                        isRenaming = true
                    }
                    if !tracks.isEmpty {
                        Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") {
                            player.addToQueue(tracks)
                        }
                    }
                    EditButton()
                } label: {
                    Label("Options", systemImage: "ellipsis.circle")
                }
            }
        }
        .alert("Rename Playlist", isPresented: $isRenaming) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                playlist.name = name
                playlist.dateModified = Date()
                try? context.save()
            }
        }
    }
}

/// Sheet shown by the "Add to Playlist…" context-menu action.
struct AddToPlaylistSheet: View {
    let tracks: [Track]

    @Query(sort: \Playlist.dateModified, order: .reverse) private var playlists: [Playlist]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var newName = ""
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("New Playlist…", systemImage: "plus") {
                        newName = defaultName
                        isCreating = true
                    }
                }

                if !playlists.isEmpty {
                    Section("Existing") {
                        ForEach(playlists) { playlist in
                            Button {
                                add(to: playlist)
                            } label: {
                                HStack {
                                    Text(playlist.name).foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(playlist.trackCount)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(tracks.count == 1 ? "Add to Playlist" : "Add \(tracks.count) Tracks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("New Playlist", isPresented: $isCreating) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { createAndAdd() }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Seed the name from the tracks themselves — usually the album they came
    /// from, which is what you want nine times out of ten.
    private var defaultName: String {
        let albums = Set(tracks.map(\.displayAlbum))
        return albums.count == 1 ? (albums.first ?? "New Playlist") : "New Playlist"
    }

    private func add(to playlist: Playlist) {
        playlist.append(paths: tracks.map(\.relativePath))
        try? context.save()
        dismiss()
    }

    private func createAndAdd() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let playlist = Playlist(name: name, trackPaths: tracks.map(\.relativePath))
        context.insert(playlist)
        try? context.save()
        dismiss()
    }
}
