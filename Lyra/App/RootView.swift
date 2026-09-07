import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(PlayerController.self) private var player
    @Environment(LibraryScanner.self) private var scanner
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab: TabIdentifier = .library
    @State private var initialScanFinished = false

    enum TabIdentifier: Hashable {
        case library, downloads, playlists, search
    }

    var body: some View {
        @Bindable var player = player

        return TabView(selection: $selectedTab) {
            Tab("Library", systemImage: "music.note.list", value: TabIdentifier.library) {
                LibraryView()
            }
            Tab("Downloads", systemImage: "arrow.down.circle", value: TabIdentifier.downloads) {
                DownloadsView()
            }
            Tab("Playlists", systemImage: "list.bullet.rectangle", value: TabIdentifier.playlists) {
                PlaylistsView()
            }
            Tab("Search", systemImage: "magnifyingglass", value: TabIdentifier.search, role: .search) {
                SearchView()
            }
        }
        // iOS 26 parks the mini player in the tab bar itself, which is exactly
        // where a persistent transport belongs.
        .modifier(MiniPlayerAccessory(isActive: player.hasQueue) {
            player.isNowPlayingPresented = true
        })
        .tabBarMinimizeBehavior(.onScrollDown)
        .sheet(isPresented: $player.isNowPlayingPresented) {
            NowPlayingView()
        }
        .task {
            // Files dropped in before first launch should just be there.
            await scanner.scan()
            initialScanFinished = true
        }
        .onChange(of: scenePhase) { _, phase in
            // The launch transition to active races the initial task; only
            // later activations can mean the user added music in Files.
            if phase == .active, initialScanFinished {
                scanner.scanInBackground()
            }
        }
    }
}

/// Attaches the mini player only when something is queued.
///
/// The modifier has to be applied conditionally rather than returning an empty
/// view from inside it — `tabViewBottomAccessory` reserves its slot regardless
/// of what the closure produces, leaving an empty pill above the tab bar.
private struct MiniPlayerAccessory: ViewModifier {
    let isActive: Bool
    let onTap: () -> Void

    func body(content: Content) -> some View {
        if isActive {
            content.tabViewBottomAccessory {
                MiniPlayerBar(onTap: onTap)
            }
        } else {
            content
        }
    }
}
