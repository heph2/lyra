import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Supplies authenticated WebDAV byte ranges to AVFoundation without ever
/// exposing a server URL or credential to the player item.
final class WebDAVAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private static let chunkSize: Int64 = 524_288

    private let source: any RemoteLibrarySource
    private let resource: RemotePlaybackResource
    private let delegateQueue = DispatchQueue(label: "care.davinci.lyra.webdav-asset-loader")
    private let activeLock = NSLock()
    private var active: [ObjectIdentifier: ActiveRequest] = [:]
    private var failure: LibrarySourceError?

    /// AVFoundation reports every loader failure as a generic decode error, so
    /// the reason has to be kept here or the player has nothing actionable to
    /// say about a server that cannot be reached or cannot be streamed from.
    var lastFailure: LibrarySourceError? {
        activeLock.lock()
        defer { activeLock.unlock() }
        return failure
    }

    init(source: any RemoteLibrarySource, resource: RemotePlaybackResource) {
        self.source = source
        self.resource = resource
    }

    deinit {
        cancelAll()
    }

    func makeAsset() -> AVURLAsset {
        let suffix = resource.fileExtension.isEmpty ? "audio" : resource.fileExtension
        let url = URL(string: "lyra-webdav://resource/\(UUID().uuidString).\(suffix)")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: delegateQueue)
        return asset
    }

    func cancelAll() {
        activeLock.lock()
        let requests = Array(active.values)
        active.removeAll()
        activeLock.unlock()
        requests.forEach { $0.cancel() }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let identifier = ObjectIdentifier(loadingRequest)
        let plan = RequestPlan(loadingRequest.dataRequest)
        let activeRequest = ActiveRequest()

        activeLock.lock()
        active[identifier] = activeRequest
        activeLock.unlock()

        let task = Task { [weak self, weak loadingRequest, weak activeRequest] in
            guard let self, let activeRequest else { return }
            defer { self.remove(identifier, matching: activeRequest) }
            guard let loadingRequest else { return }
            await self.fulfill(loadingRequest, plan: plan)
        }
        activeRequest.install(task)
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let identifier = ObjectIdentifier(loadingRequest)
        activeLock.lock()
        let request = active.removeValue(forKey: identifier)
        activeLock.unlock()
        request?.cancel()
    }

    private func fulfill(
        _ loadingRequest: AVAssetResourceLoadingRequest,
        plan: RequestPlan
    ) async {
        let item = ScannedFile(
            relativePath: resource.relativePath,
            size: resource.contentLength,
            modified: .distantPast
        )

        do {
            if plan.hasDataRequest {
                var offset = plan.start
                var totalLength = resource.contentLength
                var suppliedContentInformation = false

                while true {
                    try Task.checkCancellation()

                    let requestedUpper = plan.upperBound ?? (totalLength > 0 ? totalLength : nil)
                    if let requestedUpper, offset >= requestedUpper { break }

                    let upper = min(
                        offset + Self.chunkSize,
                        requestedUpper ?? (offset + Self.chunkSize)
                    )
                    guard upper > offset else { break }

                    let response = try await source.readRange(for: item, range: offset..<upper)
                    totalLength = response.totalLength

                    try await respond(
                        response.data,
                        contentLength: response.totalLength,
                        mimeType: response.mimeType,
                        to: loadingRequest,
                        includeContentInformation: !suppliedContentInformation
                    )
                    suppliedContentInformation = true
                    offset = response.range.upperBound
                    if offset >= totalLength { break }
                }
            } else {
                // Content-information-only requests still need one byte-range
                // probe to prove support and discover the authoritative length.
                let response = try await source.readRange(for: item, range: 0..<1)
                try await respond(
                    Data(),
                    contentLength: response.totalLength,
                    mimeType: response.mimeType,
                    to: loadingRequest,
                    includeContentInformation: true
                )
            }

            await finish(loadingRequest, error: nil)
        } catch is CancellationError {
            await finish(loadingRequest, error: URLError(.cancelled))
        } catch {
            let code = DiagnosticValue.errorCode(error)
            LyraLog.playback.error("Remote playback load failed error=\(code, privacy: .public)")
            if let reason = error as? LibrarySourceError {
                activeLock.withLock { failure = reason }
            }
            await finish(loadingRequest, error: error)
        }
    }

    private func respond(
        _ data: Data,
        contentLength: Int64,
        mimeType: String?,
        to loadingRequest: AVAssetResourceLoadingRequest,
        includeContentInformation: Bool
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            delegateQueue.async { [resource] in
                guard !loadingRequest.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if includeContentInformation, let information = loadingRequest.contentInformationRequest {
                    information.contentLength = contentLength
                    information.isByteRangeAccessSupported = true
                    information.contentType = Self.contentType(
                        fileExtension: resource.fileExtension,
                        mimeType: mimeType
                    )
                }
                if !data.isEmpty {
                    loadingRequest.dataRequest?.respond(with: data)
                }
                continuation.resume()
            }
        }
    }

    private func finish(_ loadingRequest: AVAssetResourceLoadingRequest, error: (any Error)?) async {
        await withCheckedContinuation { continuation in
            delegateQueue.async {
                if !loadingRequest.isCancelled, !loadingRequest.isFinished {
                    if let error {
                        loadingRequest.finishLoading(with: error)
                    } else {
                        loadingRequest.finishLoading()
                    }
                }
                continuation.resume()
            }
        }
    }

    private func remove(_ identifier: ObjectIdentifier, matching request: ActiveRequest) {
        activeLock.lock()
        if active[identifier] === request {
            active.removeValue(forKey: identifier)
        }
        activeLock.unlock()
    }

    private static func contentType(fileExtension: String, mimeType: String?) -> String {
        if let type = UTType(filenameExtension: fileExtension) { return type.identifier }
        if let mimeType, let type = UTType(mimeType: mimeType) { return type.identifier }
        return UTType.audio.identifier
    }
}

private struct RequestPlan: Sendable {
    let start: Int64
    let upperBound: Int64?
    let requestsAllDataToEnd: Bool
    let hasDataRequest: Bool

    init(_ request: AVAssetResourceLoadingDataRequest?) {
        guard let request else {
            start = 0
            upperBound = nil
            requestsAllDataToEnd = false
            hasDataRequest = false
            return
        }

        start = max(request.requestedOffset, request.currentOffset)
        requestsAllDataToEnd = request.requestsAllDataToEndOfResource
        hasDataRequest = requestsAllDataToEnd || request.requestedLength > 0

        if requestsAllDataToEnd {
            upperBound = nil
        } else {
            let length = Int64(max(0, request.requestedLength))
            let requestedStart = max(0, request.requestedOffset)
            upperBound = requestedStart <= Int64.max - length
                ? requestedStart + length
                : Int64.max
        }
    }
}

private final class ActiveRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            task.cancel()
            return
        }
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}
