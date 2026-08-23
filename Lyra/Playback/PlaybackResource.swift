import Foundation

/// The final result of resolving a track for playback. Remote descriptors are
/// deliberately non-secret: only `WebDAVSource` may turn one into an
/// authenticated request.
enum PlaybackResource: Sendable, Equatable {
    case local(URL)
    case remote(RemotePlaybackResource)

    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }
}

struct RemotePlaybackResource: Sendable, Equatable {
    let sourceID: String
    let relativePath: String
    let contentLength: Int64
    let fileExtension: String
}

enum PlaybackResourceResolver {
    static func resolve(track: Track, localURL: URL?, source: MusicSource?) -> PlaybackResource? {
        if let localURL { return .local(localURL) }
        guard source?.isRemote == true else { return nil }
        return .remote(RemotePlaybackResource(
            sourceID: track.sourceID,
            relativePath: track.relativePath,
            contentLength: track.fileSize,
            fileExtension: URL(filePath: track.innerPath).pathExtension.lowercased()
        ))
    }
}
