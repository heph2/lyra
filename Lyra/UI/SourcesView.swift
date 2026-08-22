import SwiftData
import SwiftUI

/// Manages the places Lyra indexes. Local folders remain in place; WebDAV
/// libraries are indexed remotely and are not downloaded until offline sync.
struct SourcesView: View {
    @Environment(LibraryScanner.self) private var scanner
    @Environment(\.dismiss) private var dismiss
    @Query private var tracks: [Track]

    @State private var isPickingFolder = false
    @State private var isAddingWebDAV = false
    @State private var isChoosingType = false
    @State private var pendingRemoval: MusicSource?
    /// The manager is lock-based rather than observable, so source edits and
    /// connection tests explicitly refresh this view's snapshot.
    @State private var revision = 0

    private var sources: [MusicSource] {
        _ = revision
        // `LibraryManager` is deliberately not observable. Reading this
        // scanner value makes reachability errors and post-scan counts redraw.
        _ = scanner.lastScanDate
        return LibraryManager.shared.allSources
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(sources) { source in
                        row(for: source)
                    }
                } header: {
                    Text("Library Sources")
                } footer: {
                    Text("Local folders stay where they are. Choose tracks or albums from a WebDAV library to keep offline.")
                }

                Section {
                    Button("Add Library", systemImage: "plus") {
                        isChoosingType = true
                    }
                }
            }
            .navigationTitle("Library Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $isPickingFolder,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    scanner.addFolders(urls)
                    revision += 1
                }
            }
            .confirmationDialog("Add Library", isPresented: $isChoosingType, titleVisibility: .visible) {
                Button("Local Folder", systemImage: "folder") { isPickingFolder = true }
                Button("WebDAV Server", systemImage: "externaldrive.connected.to.line.below") {
                    isAddingWebDAV = true
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Remove \(pendingRemoval?.displayName ?? "")?",
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove from Lyra", role: .destructive) {
                    guard let source = pendingRemoval else { return }
                    pendingRemoval = nil
                    Task {
                        await scanner.removeSource(source.id)
                        revision += 1
                    }
                }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: {
                Text("Its tracks leave your library. The folder, server, and files are not touched.")
            }
            .sheet(isPresented: $isAddingWebDAV) {
                WebDAVLibraryForm {
                    revision += 1
                    isAddingWebDAV = false
                }
            }
        }
    }

    @ViewBuilder
    private func row(for source: MusicSource) -> some View {
        let count = tracks.count { $0.sourceID == source.id }
        let status = LibraryManager.shared.availability(for: source.id)

        HStack(spacing: 12) {
            Image(systemName: icon(for: source))
                .foregroundStyle(status.isReachable ? Color.accentColor : Color.orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                Text(subtitle(count: count, source: source, status: status))
                    .font(.caption)
                    .foregroundStyle(status.isReachable ? .secondary : Color.orange)
            }

            Spacer()

            if !source.isDropZone {
                Button("Remove", systemImage: "minus.circle.fill") {
                    pendingRemoval = source
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(.red)
                .buttonStyle(.plain)
            }
        }
    }

    private func icon(for source: MusicSource) -> String {
        if source.isDropZone { return "iphone" }
        return source.isRemote ? "externaldrive.connected.to.line.below" : "folder.badge.gearshape"
    }

    private func subtitle(count: Int, source: MusicSource, status: LibrarySourceAvailability) -> String {
        guard status.isReachable else { return status.detail ?? "Can't be reached right now" }
        let trackLabel = "\(count) track\(count == 1 ? "" : "s")"
        if source.isDropZone { return "\(trackLabel) · deleted with the app" }
        return source.isRemote ? "\(trackLabel) · WebDAV" : "\(trackLabel) · local folder"
    }
}

private struct WebDAVLibraryForm: View {
    @Environment(LibraryScanner.self) private var scanner

    let onAdded: () -> Void
    @State private var name = ""
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isTesting = false
    @State private var message: Message?

    private struct Message: Equatable {
        var text: String
        var isError: Bool
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("URL", text: $url)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .textContentType(.username)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                }

                Section {
                    Button("Test Connection", systemImage: "checkmark.circle") {
                        testConnection()
                    }
                    .disabled(isTesting || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if isTesting {
                        Label {
                            Text("Searching for tracks…")
                                .foregroundStyle(.secondary)
                        } icon: {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.accentColor)
                        }
                    }
                    if let message {
                        Text(message.text)
                            .foregroundStyle(message.isError ? Color.red : Color.green)
                    }
                }
            }
            .navigationTitle("WebDAV Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onAdded)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func testConnection() {
        isTesting = true
        message = nil
        Task {
            do {
                let count = try await scanner.testWebDAV(name: name, url: url, username: username, password: password)
                message = Message(text: "Connected. Found \(count) audio file\(count == 1 ? "" : "s").", isError: false)
            } catch {
                message = Message(text: error.localizedDescription, isError: true)
            }
            isTesting = false
        }
    }

    private func add() {
        do {
            let warning = try scanner.addWebDAV(
                name: name, url: url, username: username, password: password
            )
            // A library that works but could not store its password is still
            // worth keeping — the user just needs to know it will not survive
            // a relaunch, so the form stays open to say so.
            if let warning {
                message = Message(text: warning, isError: true)
            } else {
                onAdded()
            }
        } catch {
            message = Message(text: error.localizedDescription, isError: true)
        }
    }
}
