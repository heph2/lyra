import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Supplies authenticated WebDAV byte ranges to AVFoundation without ever
/// exposing a server URL or credential to the player item.
final class WebDAVAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private static let chunkSize: Int64 = 524_288
    private static let inactivePoll = Duration.milliseconds(200)

    private let source: any RemoteLibrarySource
    private let resource: RemotePlaybackResource
    private let pacing: StreamPacingPolicy
    private let pacingClock = ContinuousClock()
    private let pacingStarted: ContinuousClock.Instant
    private let delegateQueue = DispatchQueue(label: "care.davinci.lyra.webdav-asset-loader")
    private let activeLock = NSLock()
    private var active: [ObjectIdentifier: ActiveRequest] = [:]
    private var failure: LibrarySourceError?
    private var knownContentLength: Int64?
    private var playbackActive: Bool
    private var scheduledPlaybackBytes: Int64 = 0

    /// AVFoundation reports every loader failure as a generic decode error, so
    /// the reason has to be kept here or the player has nothing actionable to
    /// say about a server that cannot be reached or cannot be streamed from.
    func takeLastFailure() -> LibrarySourceError? {
        activeLock.lock()
        defer { activeLock.unlock() }
        let result = failure
        failure = nil
        return result
    }

    init(
        source: any RemoteLibrarySource,
        resource: RemotePlaybackResource,
        playbackActive: Bool = true
    ) {
        self.source = source
        self.resource = resource
        self.pacing = StreamPacingPolicy(resource: resource)
        self.pacingStarted = pacingClock.now
        self.knownContentLength = resource.contentLength > 0 ? resource.contentLength : nil
        self.playbackActive = playbackActive
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

    func setPlaybackActive(_ active: Bool) {
        activeLock.withLock { playbackActive = active }
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
                var suppliedContentInformation = false

                while true {
                    try Task.checkCancellation()
                    let totalLength = currentContentLength
                    guard let range = PlaybackRangePlanner.nextRange(
                        offset: offset,
                        requestedUpperBound: plan.upperBound,
                        totalLength: totalLength,
                        maximumLength: Self.chunkSize
                    ) else { break }

                    if let delay = reservePacingSlot(
                        bytes: range.upperBound - range.lowerBound
                    ) {
                        try await waitUntilPlaybackIsActive()
                        try await Task.sleep(for: delay)
                        try await waitUntilPlaybackIsActive()
                    }
                    let response = try await source.readRange(for: item, range: range)
                    try acceptContentLength(response.totalLength)

                    try await respond(
                        response.data,
                        contentLength: response.totalLength,
                        mimeType: response.mimeType,
                        to: loadingRequest,
                        includeContentInformation: !suppliedContentInformation
                    )
                    clearFailure()
                    suppliedContentInformation = true
                    offset = response.range.upperBound
                }
            } else {
                // Content-information-only requests still need one byte-range
                // probe to prove support and discover the authoritative length.
                let response = try await source.readRange(for: item, range: 0..<1)
                try acceptContentLength(response.totalLength)
                try await respond(
                    Data(),
                    contentLength: response.totalLength,
                    mimeType: response.mimeType,
                    to: loadingRequest,
                    includeContentInformation: true
                )
                clearFailure()
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

    private var currentContentLength: Int64? {
        activeLock.withLock { knownContentLength }
    }

    private func acceptContentLength(_ length: Int64) throws {
        let accepted = activeLock.withLock {
            if let knownContentLength { return knownContentLength == length }
            knownContentLength = length
            return true
        }
        guard accepted else { throw LibrarySourceError.unavailable }
    }

    private func clearFailure() {
        activeLock.withLock { failure = nil }
    }

    private func reservePacingSlot(bytes: Int64) -> Duration? {
        activeLock.withLock {
            let byteOffset = scheduledPlaybackBytes
            scheduledPlaybackBytes = byteOffset <= Int64.max - bytes
                ? byteOffset + bytes
                : Int64.max
            return pacing.delay(
                beforeDeliveringAt: byteOffset,
                elapsed: pacingStarted.duration(to: pacingClock.now)
            )
        }
    }

    private func waitUntilPlaybackIsActive() async throws {
        while !activeLock.withLock({ playbackActive }) {
            try Task.checkCancellation()
            try await Task.sleep(for: Self.inactivePoll)
        }
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
    let requestsToEnd: Bool
    let hasDataRequest: Bool

    init(_ request: AVAssetResourceLoadingDataRequest?) {
        guard let request else {
            start = 0
            upperBound = nil
            requestsToEnd = false
            hasDataRequest = false
            return
        }

        start = max(request.requestedOffset, request.currentOffset)
        requestsToEnd = request.requestsAllDataToEndOfResource
        hasDataRequest = requestsToEnd || request.requestedLength > 0

        if requestsToEnd {
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

enum PlaybackRangePlanner {
    static func nextRange(
        offset: Int64,
        requestedUpperBound: Int64?,
        totalLength: Int64?,
        maximumLength: Int64
    ) -> Range<Int64>? {
        guard offset >= 0, maximumLength > 0 else { return nil }
        let knownEnd = totalLength.flatMap { $0 > 0 ? $0 : nil }
        let upperLimit: Int64
        switch (requestedUpperBound, knownEnd) {
        case let (requested?, known?): upperLimit = min(requested, known)
        case let (requested?, nil): upperLimit = requested
        case let (nil, known?): upperLimit = known
        case (nil, nil): upperLimit = offset == Int64.max ? offset : offset + 1
        }
        guard offset < upperLimit else { return nil }
        return offset..<min(upperLimit, offset + min(maximumLength, Int64.max - offset))
    }
}

struct StreamPacingPolicy: Sendable {
    private static let fallbackBytesPerSecond = 1_048_576.0
    private static let targetBufferSeconds = 15.0
    private static let minimumBufferBytes: Int64 = 1_048_576
    private static let maximumBufferBytes: Int64 = 33_554_432

    let bytesPerSecond: Double
    let initialBufferBytes: Int64

    init(resource: RemotePlaybackResource) {
        if resource.duration.isFinite, resource.duration > 0, resource.contentLength > 0 {
            bytesPerSecond = Double(resource.contentLength) / resource.duration
        } else {
            bytesPerSecond = Self.fallbackBytesPerSecond
        }
        let target = Int64(bytesPerSecond * Self.targetBufferSeconds)
        initialBufferBytes = min(
            max(0, resource.contentLength),
            min(Self.maximumBufferBytes, max(Self.minimumBufferBytes, target))
        )
    }

    func delay(beforeDeliveringAt byteOffset: Int64, elapsed: Duration) -> Duration? {
        guard byteOffset >= initialBufferBytes, bytesPerSecond > 0 else { return nil }
        let scheduledSeconds = Double(byteOffset - initialBufferBytes) / bytesPerSecond
        let elapsedSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        let delay = scheduledSeconds - elapsedSeconds
        return delay > 0 ? .seconds(delay) : nil
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
