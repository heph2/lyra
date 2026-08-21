import Foundation

/// Everything about *where files live* and *which ones we care about*.
///
/// The app container's UUID changes on every reinstall, so an absolute URL
/// persisted today is garbage tomorrow. Track identity is therefore the path
/// relative to `Documents/`, and absolute URLs are always derived on demand.
enum AudioFile {

    /// Formats AVFoundation can decode natively on iOS. Deliberately no Opus,
    /// Ogg Vorbis or WMA — those would mean bundling FFmpeg.
    static let supportedExtensions: Set<String> = [
        "mp3",
        "m4a", "m4b", "aac", "adts",
        "alac",
        "flac",
        "wav", "wave",
        "aif", "aiff", "aifc",
        "caf",
        "mp4",
    ]

    /// The user-visible drop zone: "On My iPhone → Lyra" in the Files app.
    static var documentsURL: URL {
        // Documents always exists for an iOS app; a nil here means the sandbox
        // is broken and there is nothing sensible to fall back to.
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("No Documents directory in the app container")
        }
        return url
    }

    /// Makes the app visible under "On My iPhone" in the Files app.
    ///
    /// `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` are not
    /// enough on their own: iOS hides an app from the Files browser entirely
    /// while its `Documents` directory is empty. That is a chicken-and-egg
    /// problem for an app whose only import route *is* the Files app, so we
    /// drop a short readme in to make the folder appear.
    ///
    /// Only ever written when the folder is empty, so it does not come back
    /// once there is music in there.
    static func prepareDropZone() {
        let fileManager = FileManager.default
        let root = documentsURL

        let contents = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard contents?.isEmpty ?? true else { return }

        let readme = """
        Put your music in this folder.

        Drag albums or whole folders in here from Finder or the Files app.
        Any structure works, but Artist/Album/01 Title.mp3 is ideal — Lyra
        falls back to the folder names when a file has no tags.

        Supported: mp3, m4a, aac, alac, flac, wav, aiff, caf.

        Open Lyra and pull down to refresh, or just relaunch it.
        You can delete this file once you have added something.
        """

        try? readme.write(
            to: root.appending(path: "Put your music here.txt", directoryHint: .notDirectory),
            atomically: true,
            encoding: .utf8
        )
    }

    static var artworkCacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL.temporaryDirectory
        return caches.appending(path: "artwork", directoryHint: .isDirectory)
    }

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Absolute URL for a stored track path. Resolved fresh every time so it
    /// stays correct across reinstalls.
    static func url(forRelativePath path: String) -> URL {
        documentsURL.appending(path: path, directoryHint: .notDirectory)
    }

    /// Inverse of `url(forRelativePath:)`. Returns nil for anything outside
    /// `Documents/`, which we never want to persist.
    static func relativePath(for url: URL) -> String? {
        let base = documentsURL.standardizedFileURL.path(percentEncoded: false)
        let full = url.standardizedFileURL.path(percentEncoded: false)

        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard full.hasPrefix(prefix) else { return nil }
        return String(full.dropFirst(prefix.count))
    }

    /// Parent folder of a track, relative to `Documents/`. Empty string means
    /// the file sits at the root of the drop zone.
    static func parentFolder(ofRelativePath path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<slash])
    }

    /// Display name for a folder path ("Albums/Kid A" → "Kid A").
    static func folderDisplayName(_ path: String) -> String {
        path.isEmpty ? "Documents" : String(path.split(separator: "/").last ?? "")
    }
}
