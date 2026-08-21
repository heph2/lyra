import CryptoKit
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// On-disk cache of cover art, keyed by a hash of the original embedded bytes.
///
/// Hashing the source bytes means every track on an album converges on one
/// cached file, so a 12-track album stores one image, not twelve. Files live in
/// `Caches/` so iOS can reclaim them under pressure; a rescan regenerates them.
final class ArtworkCache: @unchecked Sendable {
    static let shared = ArtworkCache()

    /// Big enough to look sharp full-screen on any current iPhone, small enough
    /// that a few thousand albums stay reasonable on disk.
    private static let maxPixelSize = 640
    private static let jpegQuality: CGFloat = 0.85

    private let memory = NSCache<NSString, UIImage>()
    private let directory = AudioFile.artworkCacheURL

    private init() {
        memory.countLimit = 120
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(for hash: String) -> URL {
        directory.appending(path: "\(hash).jpg", directoryHint: .notDirectory)
    }

    /// Downscales, re-encodes and stores `data`, returning the cache key.
    /// Returns nil when the bytes are not a decodable image.
    @discardableResult
    func store(_ data: Data) -> String? {
        let hash = Self.hash(data)
        let destination = url(for: hash)

        // Same art on another track of the same album: already done.
        guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else {
            return hash
        }
        guard let jpeg = Self.downscaledJPEG(from: data) else { return nil }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try jpeg.write(to: destination, options: .atomic)
            return hash
        } catch {
            return nil
        }
    }

    /// Synchronous read for list rows; hits memory first.
    func image(for hash: String?) -> UIImage? {
        guard let hash, !hash.isEmpty else { return nil }
        let key = hash as NSString
        if let cached = memory.object(forKey: key) { return cached }

        guard let image = UIImage(contentsOfFile: url(for: hash).path(percentEncoded: false)) else {
            return nil
        }
        memory.setObject(image, forKey: key)
        return image
    }

    func removeAll() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Deletes cached images no longer referenced by any track.
    func prune(keeping liveHashes: Set<String>) {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for file in contents ?? [] {
            let hash = file.deletingPathExtension().lastPathComponent
            if !liveHashes.contains(hash) {
                try? FileManager.default.removeItem(at: file)
                memory.removeObject(forKey: hash as NSString)
            }
        }
    }

    // MARK: - Helpers

    /// 32 hex chars of SHA-256 — collision risk here is not worth more bytes.
    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data)
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// ImageIO thumbnailing decodes at the target size instead of decoding the
    /// full image first, which matters when scanning a large library.
    private static func downscaledJPEG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }

        CGImageDestinationAddImage(destination, thumbnail, [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
        ] as CFDictionary)

        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
