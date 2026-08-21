import SwiftData
import SwiftUI

struct SearchView: View {
    @Query private var tracks: [Track]
    @Environment(PlayerController.self) private var player

    @State private var query = ""
    @AppStorage("search.sort") private var sort: TrackSort = .title

    /// Case- and diacritic-insensitive match across the fields people actually
    /// search by. Done in memory: a personal library is small, and this avoids
    /// rebuilding a `#Predicate` on every keystroke.
    private var results: [Track] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        let matched = tracks.filter { track in
            track.title.matches(needle)
                || track.artist.matches(needle)
                || track.albumArtist.matches(needle)
                || track.album.matches(needle)
                || track.genre.matches(needle)
        }
        return sort.apply(to: matched)
    }

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView(
                        "Search Your Library",
                        systemImage: "magnifyingglass",
                        description: Text("Find songs by title, artist, album or genre.")
                    )
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    resultsList
                }
            }
            .navigationTitle("Search")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort By", selection: $sort) {
                            ForEach(TrackSort.allCases) { option in
                                Label(option.label, systemImage: option.systemImage).tag(option)
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Songs, artists, albums")
    }

    private var resultsList: some View {
        List {
            Section {
                PlayAllHeader(tracks: results)
                    .listRowSeparator(.hidden)
            }
            Section("\(results.count) result\(results.count == 1 ? "" : "s")") {
                ForEach(results) { track in
                    TrackButton(track: track, tracks: results)
                }
            }
        }
        .listStyle(.plain)
    }
}

private extension String {
    /// Substring match ignoring case, accents and width — so "bjork" finds
    /// "Björk".
    func matches(_ needle: String) -> Bool {
        guard !isEmpty else { return false }
        return range(of: needle, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
    }
}
