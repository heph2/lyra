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
