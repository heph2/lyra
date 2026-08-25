import Foundation
import UIKit

/// The only type in Lyra that speaks HTTP. Its output is the same
/// `ScannedFile` inventory as a local folder, keeping WebDAV out of the diff,
/// model store, and UI grouping code.
final class WebDAVSource: RemoteLibrarySource, @unchecked Sendable {
    let configuration: MusicSource
    private let rootURL: URL
    private let origin: WebDAVOrigin
    private let session: URLSession
    private let sessionDelegate: WebDAVSessionDelegate
    private let ownsSession: Bool
    private let suppliedPassword: String?

    /// A source is built per request — once per file while indexing, once per
    /// offline download — so the session is shared per origin rather than
    /// owned. A session per source meant a connection pool and a TLS handshake
    /// per track, with no keep-alive between them.
    init(
        configuration: MusicSource,
        password: String? = nil,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) {
        self.configuration = configuration
        let rootURL = Self.normalizedRootURL(configuration.serverURL)
        self.rootURL = rootURL
        let origin = WebDAVOrigin(rootURL)
        self.origin = origin
        self.suppliedPassword = password

        if let sessionConfiguration {
            let delegate = WebDAVSessionDelegate(origin: origin)
            self.session = URLSession(
                configuration: sessionConfiguration,
                delegate: delegate,
                delegateQueue: nil
            )
            self.sessionDelegate = delegate
            self.ownsSession = true
        } else {
            let shared = WebDAVSessionStore.shared.session(for: origin)
            self.session = shared.session
            self.sessionDelegate = shared.delegate
            self.ownsSession = false
        }
    }

    deinit {
        if ownsSession {
            session.invalidateAndCancel()
        }
    }

    var id: String { configuration.id }
    var displayName: String { configuration.displayName }

    /// A music tree is a handful of levels deep. A server that aliases a folder
    /// into itself answers with a fresh URL every round trip, so deduplicating
    /// visited URLs can never catch the loop — only these ceilings can.
    private static let maxDepth = 24
    private static let maxDirectories = 20_000
    private static let maxFiles = 200_000
    private static let maxPlaybackRangeBytes: Int64 = 1_048_576
    /// A stalled playback range has to fail fast. `PlayerController` walks to
    /// the next track when a load fails, and the default minute-long timeout
    /// turns one unreachable server into minutes of apparent silence.
    private static let playbackRangeTimeout: TimeInterval = 15

    func scan() async throws -> [ScannedFile] {
        var pending = [(url: rootURL, depth: 0)]
        var visited = Set<String>()
        var files: [ScannedFile] = []
        LyraLog.webDAV.info("WebDAV inventory started")

        while let directory = pending.popLast() {
            guard visited.insert(directory.url.absoluteString).inserted else { continue }
            guard visited.count <= Self.maxDirectories else {
                throw LibrarySourceError.scanLimitReached
            }

            let entries: [WebDAVResponse]
            do {
                entries = try await propfind(directory.url)
            } catch LibrarySourceError.server(let status)
                where directory.depth > 0 && (status == 404 || status == 410) {
                // A subcollection can be renamed or removed between the listing
                // that named it and the request for it, and some servers name
                // hrefs that never resolve. Neither is worth failing a whole
                // library over; a missing root still is.
                LyraLog.webDAV.debug("Skipped an unlistable collection status=\(status)")
                continue
            }

            for entry in entries {
                guard let target = sameOriginURL(for: entry.href, base: directory.url),
                      let path = relativePath(for: target)
                else { continue }

                if entry.isCollection {
                    guard !path.isEmpty else { continue }
                    guard directory.depth < Self.maxDepth else {
                        throw LibrarySourceError.scanLimitReached
                    }
                    pending.append((Self.directoryURL(target), directory.depth + 1))
                } else if AudioFile.isSupported(URL(filePath: path)) {
                    guard files.count < Self.maxFiles else {
                        throw LibrarySourceError.scanLimitReached
                    }
                    files.append(ScannedFile(
                        relativePath: AudioFile.trackPath(sourceID: id, innerPath: path),
                        size: entry.size,
                        modified: entry.modified
                    ))
                }
            }
        }
        LyraLog.webDAV.info("WebDAV inventory completed directories=\(visited.count) files=\(files.count)")
        return files
    }

    func metadataHeader(for item: ScannedFile, maxBytes: Int) async throws -> Data {
        let limit = max(1, maxBytes)
        let requestURL = try url(for: item)
        var request = try authenticatedRequest(url: requestURL, method: "GET")
        request.setValue("bytes=0-\(limit - 1)", forHTTPHeaderField: "Range")

        // Declining the body from the headers is what keeps a rejected response
        // from pulling the whole file down — a 401 library, or a server whose
        // declared length past the budget proves it ignored `Range`, would
        // otherwise do that once per track.
        let (data, http) = try await body(for: request) { http in
            Self.metadataBodyBudget(for: http, limit: limit)
        }
        guard http.statusCode != 401 else { throw LibrarySourceError.signInRequired }
        guard (200...299).contains(http.statusCode) else {
            throw LibrarySourceError.server(status: http.statusCode)
        }
        if Self.metadataBodyBudget(for: http, limit: limit) == nil {
            throw LibrarySourceError.rangeNotSupported
        }
        LyraLog.webDAV.debug("Metadata range response status=\(http.statusCode) bytes=\(data.count)")
        if http.statusCode == 206 { return data.count > limit ? Data(data.prefix(limit)) : data }
        // A file smaller than the requested range legitimately comes back whole
        // as 200. Only a body larger than we asked for means the server ignored
        // the range and would make indexing download the entire library.
        guard data.count <= limit else { throw LibrarySourceError.rangeNotSupported }
        return data
    }

    func readRange(
        for item: ScannedFile,
        range: Range<Int64>
    ) async throws -> RemoteByteRangeResponse {
        let count = range.upperBound - range.lowerBound
        guard range.lowerBound >= 0,
              count > 0,
              count <= Self.maxPlaybackRangeBytes
        else { throw LibrarySourceError.invalidConfiguration }

        var request = try authenticatedRequest(url: try url(for: item), method: "GET")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = Self.playbackRangeTimeout
        // Byte offsets describe the stored audio file, not a compressed HTTP
        // representation. Asking intermediaries for identity encoding keeps
        // Content-Range and the bytes handed to AVFoundation in agreement.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(
            "bytes=\(range.lowerBound)-\(range.upperBound - 1)",
            forHTTPHeaderField: "Range"
        )

        // A validated `Content-Range` on a 206 is what proves the server
        // honoured the request, and it does so before any of the body is read,
        // so the budget below is the exact length the server promised.
        let (data, http) = try await body(for: request) { http in
            guard let promised = Self.validatedContentRange(for: http, requested: range) else { return nil }
            return Int(promised.range.upperBound - promised.range.lowerBound)
        }

        guard let responseURL = http.url, isSameOrigin(responseURL) else {
            throw LibrarySourceError.unavailable
        }
        if http.statusCode == 401 { throw LibrarySourceError.signInRequired }
        guard http.statusCode == 206 else {
            if (200...299).contains(http.statusCode) {
                throw LibrarySourceError.rangeNotSupported
            }
            throw LibrarySourceError.server(status: http.statusCode)
        }
        guard let contentRange = Self.validatedContentRange(for: http, requested: range) else {
            throw LibrarySourceError.rangeNotSupported
        }

        // RFC 9110 lets a server satisfy a range without knowing the complete
        // length and answer `/*`. The indexed size then stands in, because it
        // came from this same server's PROPFIND.
        let totalLength: Int64
        if let completeLength = contentRange.totalLength {
            totalLength = completeLength
        } else {
            guard item.size > 0, item.size >= contentRange.range.upperBound else {
                throw LibrarySourceError.rangeNotSupported
            }
            totalLength = item.size
        }
        guard totalLength >= contentRange.range.upperBound else {
            throw LibrarySourceError.rangeNotSupported
        }

        let expected = contentRange.range.upperBound - contentRange.range.lowerBound
        guard Int64(data.count) == expected else { throw LibrarySourceError.unavailable }
        LyraLog.webDAV.debug(
            "Playback range response status=206 requested=\(count) delivered=\(data.count)"
        )
        return RemoteByteRangeResponse(
            data: data,
            range: contentRange.range,
            totalLength: totalLength,
            mimeType: http.mimeType
        )
    }

    private static func metadataBodyBudget(for response: HTTPURLResponse, limit: Int) -> Int? {
        guard response.statusCode != 401, (200...299).contains(response.statusCode) else { return nil }
        if response.statusCode != 206, response.expectedContentLength > Int64(limit) { return nil }
        return limit
    }

    private static func validatedContentRange(
        for response: HTTPURLResponse,
        requested: Range<Int64>
    ) -> HTTPContentRange? {
        guard response.statusCode == 206,
              let value = response.value(forHTTPHeaderField: "Content-Range"),
              let promised = HTTPContentRange.parse(value),
              promised.range.lowerBound == requested.lowerBound,
              promised.range.upperBound <= requested.upperBound
        else { return nil }
        return promised
    }

    /// Collects a response body in whole delegate chunks, stopping one byte
    /// past the budget the headers earned. That extra byte is what proves the
    /// server ignored `Range`; bounding it a `UInt8` at a time was affordable
    /// for a one-shot metadata prefix and is not for every chunk of a streamed
    /// track.
    ///
    /// `budget` runs on the response headers before any body arrives. Returning
    /// `nil` declines the body entirely and hands the caller the headers to map
    /// into an error.
    private func body(
        for request: URLRequest,
        budget: @escaping @Sendable (HTTPURLResponse) -> Int?
    ) async throws -> (Data, HTTPURLResponse) {
        let transfer = BoundedBodyTransfer(budget: budget)
        let task = session.dataTask(with: request)
        sessionDelegate.begin(transfer, for: task)
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    transfer.attach(continuation)
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        } catch {
            if Self.isCancellation(error) { throw CancellationError() }
            let code = DiagnosticValue.errorCode(error)
            LyraLog.webDAV.error("WebDAV body read failed error=\(code, privacy: .public)")
            throw LibrarySourceError.unavailable
        }
    }

    func download(
        _ item: ScannedFile,
        to destination: URL,
        progress: @escaping @Sendable (OfflineDownloadProgress) -> Void
    ) async throws {
        LyraLog.webDAV.info("WebDAV download started")
        var request = try authenticatedRequest(url: try url(for: item), method: "GET")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        if !ownsSession {
            try await WebDAVBackgroundDownloads.shared.download(
                request,
                sourceID: id,
                innerPath: AudioFile.split(trackPath: item.relativePath).innerPath,
                expectedBytes: item.size,
                expectedModified: item.modified,
                origin: origin,
                progress: progress
            )
            return
        }

        // Injected sessions are used by deterministic URLProtocol tests. Real
        // downloads use the background delegate below, which reports each byte
        // callback and survives the app being suspended.
        let (temporaryURL, response) = try await session.download(for: request)
        try Self.validateDownloadResponse(response)
        if item.size > 0 {
            let size = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size.map(Int64.init) == item.size else { throw LibrarySourceError.unavailable }
        }
        try Self.installDownload(at: temporaryURL, destination: destination)
        progress(.init(receivedBytes: item.size, totalBytes: item.size))
        LyraLog.webDAV.info("WebDAV download completed")
    }

    static func cancelDownload(sourceID: String, innerPath: String) async {
        await WebDAVBackgroundDownloads.shared.cancel(sourceID: sourceID, innerPath: innerPath)
    }

    static func cancelDownloads(sourceID: String) async {
        await WebDAVBackgroundDownloads.shared.cancel(sourceID: sourceID, innerPath: nil)
    }

    static func validateDownloadResponse(_ response: URLResponse?) throws {
        guard let http = response as? HTTPURLResponse else { throw LibrarySourceError.unavailable }
        LyraLog.webDAV.debug("WebDAV download response status=\(http.statusCode)")
        if http.statusCode == 401 { throw LibrarySourceError.signInRequired }
        guard http.statusCode == 200 else {
            if (200...299).contains(http.statusCode) {
                throw LibrarySourceError.unavailable
            }
            throw LibrarySourceError.server(status: http.statusCode)
        }
    }

    fileprivate static func installDownload(at temporaryURL: URL, destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let replacement = directory.appending(path: UUID().uuidString, directoryHint: .notDirectory)
        try FileManager.default.moveItem(at: temporaryURL, to: replacement)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: replacement)
        } else {
            try FileManager.default.moveItem(at: replacement, to: destination)
        }
    }

    private func propfind(_ directory: URL) async throws -> [WebDAVResponse] {
        var request = try authenticatedRequest(url: directory, method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8" ?>
        <propfind xmlns="DAV:"><prop><getcontentlength/><getlastmodified/><resourcetype/><displayname/></prop></propfind>
        """.utf8)

        let (data, response) = try await requestData(request)
        guard let http = response as? HTTPURLResponse else { throw LibrarySourceError.unavailable }
        LyraLog.webDAV.debug("PROPFIND response status=\(http.statusCode) bytes=\(data.count)")
        if http.statusCode == 401 { throw LibrarySourceError.signInRequired }
        guard http.statusCode == 207 else {
            if (200...299).contains(http.statusCode) { throw LibrarySourceError.notWebDAVServer }
            throw LibrarySourceError.server(status: http.statusCode)
        }
        guard let responses = WebDAVMultistatusParser.parse(data) else {
            throw LibrarySourceError.notWebDAVServer
        }
        LyraLog.webDAV.debug("PROPFIND parsed entries=\(responses.count)")
        return responses
    }

    private func authenticatedRequest(url: URL, method: String) throws -> URLRequest {
        guard let password = suppliedPassword ?? LibraryManager.shared.password(for: id) else {
            throw LibrarySourceError.signInRequired
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        let username = configuration.username ?? ""
        let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func requestData(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            let code = DiagnosticValue.errorCode(error)
            LyraLog.webDAV.error("WebDAV request failed error=\(code, privacy: .public)")
            throw LibrarySourceError.unavailable
        }
    }

    private func url(for item: ScannedFile) throws -> URL {
        let split = AudioFile.split(trackPath: item.relativePath)
        guard split.sourceID == id,
              !split.innerPath.isEmpty,
              !split.innerPath.split(separator: "/").contains("..")
        else { throw LibrarySourceError.invalidConfiguration }
        return rootURL.appending(path: split.innerPath, directoryHint: .notDirectory)
    }

    /// Hrefs are server-controlled and every request carries HTTP Basic
    /// credentials, so a target that leaves the configured origin is dropped
    /// rather than followed — otherwise a hostile or compromised server harvests
    /// the password by naming a host of its choosing. RFC 4918 also allows a
    /// bare relative reference, which only resolves correctly against the
    /// collection being listed, not against the library root.
    private func sameOriginURL(for href: String, base: URL) -> URL? {
        guard !href.isEmpty, let target = URL(string: href, relativeTo: base)?.absoluteURL else {
            return nil
        }
        guard isSameOrigin(target) else {
            LyraLog.webDAV.error("Dropped a WebDAV href pointing outside the configured server")
            return nil
        }
        return target
    }

    private func isSameOrigin(_ target: URL) -> Bool {
        WebDAVOrigin(target) == origin
    }

    /// Server hrefs may be absolute or relative and retain percent encoding.
    /// Convert them once at the boundary so stored paths never depend on the
    /// server's URL spelling.
    private func relativePath(for target: URL) -> String? {
        let rootPath = rootURL.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let targetPath = target.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if rootPath.isEmpty { return targetPath }
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else { return nil }
        return String(targetPath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    /// A collection href may arrive without its trailing slash. Restoring it
    /// keeps the URL usable as the resolution base for the children's hrefs.
    private static func directoryURL(_ url: URL) -> URL {
        url.hasDirectoryPath ? url : url.appendingPathComponent("")
    }

    private static func normalizedRootURL(_ raw: String?) -> URL {
        guard let raw, let url = URL(string: raw) else { return URL(string: "http://invalid.local/")! }
        return directoryURL(url)
    }
}

/// Reconnects iOS background-session wakeups to the source-owned download
/// delegate. Keeping this delegate in the WebDAV file preserves the network
/// boundary even though SwiftUI installs it as the application delegate.
final class WebDAVBackgroundAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        WebDAVBackgroundDownloads.shared.handleEvents(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}

private struct BackgroundDownloadDescriptor: Codable, Sendable {
    var id: UUID
    var sourceID: String
    var innerPath: String
    var expectedBytes: Int64
    var expectedModified: Date

    var encoded: String? {
        try? JSONEncoder().encode(self).base64EncodedString()
    }

    static func decode(_ value: String?) -> Self? {
        guard let value, let data = Data(base64Encoded: value) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// One durable session per WebDAV library. iOS owns these transfers while Lyra
/// is suspended or terminated; rebuilding the same identifier on launch
/// reconnects the delegate to work the system kept running.
private final class WebDAVBackgroundDownloads: @unchecked Sendable {
    static let shared = WebDAVBackgroundDownloads()
    private static let identifierPrefix =
        (Bundle.main.bundleIdentifier ?? "care.davinci.lyra") + ".webdav-download."

    private let lock = NSLock()
    private var clients: [String: WebDAVBackgroundDownloadClient] = [:]

    func download(
        _ request: URLRequest,
        sourceID: String,
        innerPath: String,
        expectedBytes: Int64,
        expectedModified: Date,
        origin: WebDAVOrigin,
        progress: @escaping @Sendable (OfflineDownloadProgress) -> Void
    ) async throws {
        let client = client(for: sourceID, origin: origin)
        try await client.download(
            request,
            innerPath: innerPath,
            expectedBytes: expectedBytes,
            expectedModified: expectedModified,
            progress: progress
        )
    }

    func cancel(sourceID: String, innerPath: String?) async {
        guard let source = LibraryManager.shared.source(for: sourceID),
              let rawURL = source.serverURL,
              let url = URL(string: rawURL)
        else { return }
        await client(for: sourceID, origin: WebDAVOrigin(url)).cancel(innerPath: innerPath)
    }

    func handleEvents(identifier: String, completionHandler: @escaping @Sendable () -> Void) {
        guard identifier.hasPrefix(Self.identifierPrefix) else {
            completionHandler()
            return
        }
        let sourceID = String(identifier.dropFirst(Self.identifierPrefix.count))
        guard let source = LibraryManager.shared.source(for: sourceID),
              let rawURL = source.serverURL,
              let url = URL(string: rawURL)
        else {
            completionHandler()
            return
        }
        client(for: sourceID, origin: WebDAVOrigin(url))
            .setBackgroundCompletionHandler(completionHandler)
    }

    private func client(for sourceID: String, origin: WebDAVOrigin) -> WebDAVBackgroundDownloadClient {
        lock.lock()
        defer { lock.unlock() }
        if let client = clients[sourceID] { return client }
        let client = WebDAVBackgroundDownloadClient(
            identifier: Self.identifierPrefix + sourceID,
            sourceID: sourceID,
            origin: origin
        )
        clients[sourceID] = client
        return client
    }
}

private final class WebDAVBackgroundDownloadClient: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Transfer {
        var continuation: CheckedContinuation<Void, any Error>
        var progress: @Sendable (OfflineDownloadProgress) -> Void
    }

    private let sourceID: String
    private let origin: WebDAVOrigin
    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]
    private var taskDescriptors: [Int: BackgroundDownloadDescriptor] = [:]
    private var registeredTasks: [Int: URLSessionTask] = [:]
    private var terminalOutcomes: [Int: Result<Void, any Error>] = [:]
    private var installationErrors: [Int: any Error] = [:]
    private var cancelledTransfers = Set<UUID>()
    private var wholeSourceCancelled = false
    private var backgroundCompletionHandler: (@Sendable () -> Void)?
    private var backgroundEventsFinished = false
    private var session: URLSession!

    init(identifier: String, sourceID: String, origin: WebDAVOrigin) {
        self.sourceID = sourceID
        self.origin = origin
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func download(
        _ request: URLRequest,
        innerPath: String,
        expectedBytes: Int64,
        expectedModified: Date,
        progress: @escaping @Sendable (OfflineDownloadProgress) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard !lock.withLock({ wholeSourceCancelled }) else { throw CancellationError() }
        lock.withLock { backgroundEventsFinished = false }

        let tasks = await session.allTasks
        try Task.checkCancellation()
        let registeredIDs = lock.withLock { Set(transfers.keys) }
        let candidates = tasks.compactMap { task -> (URLSessionDownloadTask, BackgroundDownloadDescriptor)? in
            guard let task = task as? URLSessionDownloadTask,
                  let descriptor = BackgroundDownloadDescriptor.decode(task.taskDescription),
                  descriptor.sourceID == sourceID,
                  descriptor.innerPath == innerPath
            else { return nil }
            return (task, descriptor)
        }
        let stale = candidates.filter {
            $0.1.expectedBytes != expectedBytes || $0.1.expectedModified != expectedModified
        }
        lock.withLock {
            for (_, descriptor) in stale { cancelledTransfers.insert(descriptor.id) }
        }
        stale.forEach { $0.0.cancel() }

        let restoredTask = candidates.first {
            $0.0.state != .canceling
                && $0.0.state != .completed
                && !registeredIDs.contains($0.0.taskIdentifier)
                && $0.1.expectedBytes == expectedBytes
                && $0.1.expectedModified == expectedModified
        }?.0

        let task = restoredTask ?? session.downloadTask(with: request)
        let descriptor = restoredTask.flatMap {
            BackgroundDownloadDescriptor.decode($0.taskDescription)
        } ?? BackgroundDownloadDescriptor(
            id: UUID(),
            sourceID: sourceID,
            innerPath: innerPath,
            expectedBytes: expectedBytes,
            expectedModified: expectedModified
        )
        guard let encoded = descriptor.encoded else { throw LibrarySourceError.invalidConfiguration }
        task.taskDescription = encoded

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var immediate: Result<Void, any Error>?
                var shouldCancel = false
                lock.withLock {
                    if Task.isCancelled
                        || wholeSourceCancelled
                        || cancelledTransfers.contains(descriptor.id) {
                        immediate = .failure(CancellationError())
                        shouldCancel = true
                    } else if let outcome = terminalOutcomes.removeValue(forKey: task.taskIdentifier) {
                        immediate = outcome
                    } else if transfers[task.taskIdentifier] != nil {
                        immediate = .failure(LibrarySourceError.unavailable)
                    } else {
                        transfers[task.taskIdentifier] = Transfer(
                            continuation: continuation,
                            progress: progress
                        )
                        taskDescriptors[task.taskIdentifier] = descriptor
                        registeredTasks[task.taskIdentifier] = task
                    }
                }

                if let immediate {
                    if shouldCancel { task.cancel() }
                    continuation.resume(with: immediate)
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    func cancel(innerPath: String?) async {
        let knownTasks: [URLSessionTask] = lock.withLock {
            if innerPath == nil { wholeSourceCancelled = true }
            var matches: [URLSessionTask] = []
            for (taskID, descriptor) in taskDescriptors
                where innerPath == nil || descriptor.innerPath == innerPath {
                cancelledTransfers.insert(descriptor.id)
                if let task = registeredTasks[taskID] { matches.append(task) }
            }
            return matches
        }
        knownTasks.forEach { $0.cancel() }

        let knownIDs = Set(knownTasks.map(\.taskIdentifier))
        for task in await session.allTasks where !knownIDs.contains(task.taskIdentifier) {
            guard let descriptor = BackgroundDownloadDescriptor.decode(task.taskDescription),
                  descriptor.sourceID == sourceID,
                  innerPath == nil || descriptor.innerPath == innerPath
            else { continue }
            lock.withLock { cancelledTransfers.insert(descriptor.id) }
            task.cancel()
        }
    }

    func setBackgroundCompletionHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if backgroundEventsFinished {
            backgroundEventsFinished = false
            lock.unlock()
            DispatchQueue.main.async(execute: handler)
        } else {
            backgroundCompletionHandler = handler
            lock.unlock()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let progress = transfers[downloadTask.taskIdentifier]?.progress
        lock.unlock()
        let descriptor = BackgroundDownloadDescriptor.decode(downloadTask.taskDescription)
        let expected = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite
            : descriptor?.expectedBytes ?? 0
        progress?(.init(receivedBytes: totalBytesWritten, totalBytes: expected))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try WebDAVSource.validateDownloadResponse(downloadTask.response)
            guard let descriptor = BackgroundDownloadDescriptor.decode(downloadTask.taskDescription),
                  descriptor.sourceID == sourceID
            else { throw LibrarySourceError.invalidConfiguration }

            try installDownload(at: location, descriptor: descriptor)
        } catch {
            lock.lock()
            installationErrors[downloadTask.taskIdentifier] = error
            lock.unlock()
        }
    }

    private func installDownload(at location: URL, descriptor: BackgroundDownloadDescriptor) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !wholeSourceCancelled,
              !cancelledTransfers.contains(descriptor.id),
              let destination = OfflineLibrary.fileURL(
                sourceID: descriptor.sourceID,
                innerPath: descriptor.innerPath
              )
        else { throw CancellationError() }
        if descriptor.expectedBytes > 0 {
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size.map(Int64.init) == descriptor.expectedBytes else {
                throw LibrarySourceError.unavailable
            }
        }
        try WebDAVSource.installDownload(at: location, destination: destination)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let result: Result<Void, any Error>
        lock.lock()
        let installationError = installationErrors.removeValue(forKey: task.taskIdentifier)
        if let installationError {
            result = .failure(installationError)
        } else if let error {
            if (error as? URLError)?.code == .cancelled {
                result = .failure(CancellationError())
            } else {
                result = .failure(LibrarySourceError.unavailable)
            }
        } else {
            result = .success(())
        }

        let transfer = transfers.removeValue(forKey: task.taskIdentifier)
        taskDescriptors.removeValue(forKey: task.taskIdentifier)
        registeredTasks.removeValue(forKey: task.taskIdentifier)
        if transfer == nil {
            // `allTasks` and continuation registration are separate system
            // callbacks. Retaining the terminal result closes the gap where a
            // restored task finishes between them.
            terminalOutcomes[task.taskIdentifier] = result
        }
        lock.unlock()

        transfer?.continuation.resume(with: result)
        if case .success = result {
            LyraLog.webDAV.info("WebDAV background download completed")
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        if handler == nil { backgroundEventsFinished = true }
        lock.unlock()
        if let handler { DispatchQueue.main.async(execute: handler) }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let target = request.url, WebDAVOrigin(target) == origin else {
            LyraLog.webDAV.error("Blocked a WebDAV download redirect outside the configured server")
            completionHandler(nil)
            return
        }
        var request = request
        if let authorization = task.originalRequest?.value(forHTTPHeaderField: "Authorization") {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        completionHandler(request)
    }
}

private struct WebDAVResponse: Sendable {
    var href: String = ""
    var isCollection = false
    var size: Int64 = 0
    var modified: Date = .distantPast
}

private struct WebDAVOrigin: Sendable, Hashable {
    let scheme: String?
    let host: String?
    let port: Int?

    init(_ url: URL) {
        scheme = url.scheme?.lowercased()
        host = url.host?.lowercased()
        if let explicit = url.port {
            port = explicit
        } else {
            switch scheme {
            case "https": port = 443
            case "http": port = 80
            default: port = nil
            }
        }
    }
}

/// One session per origin, kept for the life of the process. Sessions are the
/// connection pool: rebuilding one per `WebDAVSource` meant a fresh TLS
/// handshake for every indexed track.
private final class WebDAVSessionStore: @unchecked Sendable {
    static let shared = WebDAVSessionStore()

    private let lock = NSLock()
    private var sessions: [WebDAVOrigin: (session: URLSession, delegate: WebDAVSessionDelegate)] = [:]

    func session(for origin: WebDAVOrigin) -> (session: URLSession, delegate: WebDAVSessionDelegate) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[origin] { return existing }

        let delegate = WebDAVSessionDelegate(origin: origin)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        sessions[origin] = (session, delegate)
        return (session, delegate)
    }
}

/// Accumulates one bounded response body. The lock is what makes it safe to
/// hand to URLSession's delegate queue while the caller awaits it.
private final class BoundedBodyTransfer: @unchecked Sendable {
    private let budget: @Sendable (HTTPURLResponse) -> Int?
    private let lock = NSLock()
    private var limit: Int?
    private var buffer = Data()
    private var response: HTTPURLResponse?
    /// Set when we stopped the transfer ourselves, so the cancellation that
    /// follows is the expected end of a successful read rather than a failure.
    private var stopped = false
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>?
    private var outcome: Result<(Data, HTTPURLResponse), any Error>?

    init(budget: @escaping @Sendable (HTTPURLResponse) -> Int?) {
        self.budget = budget
    }

    func attach(_ continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>) {
        lock.lock()
        if let outcome {
            lock.unlock()
            continuation.resume(with: outcome)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func allow(_ response: HTTPURLResponse) -> Bool {
        lock.lock()
        self.response = response
        guard let allowance = budget(response) else {
            stopped = true
            lock.unlock()
            return false
        }
        limit = allowance
        buffer.reserveCapacity(allowance + 1)
        lock.unlock()
        return true
    }

    func append(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, let limit else { return false }
        let room = limit + 1 - buffer.count
        guard room > 0 else {
            stopped = true
            return false
        }
        buffer.append(data.count <= room ? data : data.prefix(room))
        if buffer.count > limit {
            stopped = true
            return false
        }
        return true
    }

    func finish(_ error: (any Error)?) {
        lock.lock()
        let result: Result<(Data, HTTPURLResponse), any Error>
        if let response, stopped || error == nil {
            result = .success((buffer, response))
        } else {
            result = .failure(error ?? LibrarySourceError.unavailable)
        }
        outcome = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class WebDAVSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let origin: WebDAVOrigin
    private let lock = NSLock()
    private var transfers: [ObjectIdentifier: BoundedBodyTransfer] = [:]

    init(origin: WebDAVOrigin) {
        self.origin = origin
    }

    func begin(_ transfer: BoundedBodyTransfer, for task: URLSessionTask) {
        lock.lock()
        transfers[ObjectIdentifier(task)] = transfer
        lock.unlock()
    }

    private func transfer(for task: URLSessionTask) -> BoundedBodyTransfer? {
        lock.lock()
        defer { lock.unlock() }
        return transfers[ObjectIdentifier(task)]
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let transfer = transfer(for: dataTask) else {
            completionHandler(.allow)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        completionHandler(transfer.allow(http) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = transfer(for: dataTask) else { return }
        if !transfer.append(data) { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let transfer = transfers.removeValue(forKey: ObjectIdentifier(task))
        lock.unlock()
        transfer?.finish(error)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let target = request.url, WebDAVOrigin(target) == origin else {
            LyraLog.webDAV.error("Blocked a WebDAV redirect outside the configured server")
            completionHandler(nil)
            return
        }

        var request = request
        if let authorization = task.originalRequest?.value(forHTTPHeaderField: "Authorization") {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        completionHandler(request)
    }
}

private struct HTTPContentRange: Sendable, Equatable {
    let range: Range<Int64>
    /// `nil` for the `/*` a server sends when it can satisfy the range without
    /// knowing the complete length. RFC 9110 allows it, so refusing to parse it
    /// would make such a server unstreamable even though every range works.
    let totalLength: Int64?

    static func parse(_ value: String) -> HTTPContentRange? {
        let unitAndValue = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard unitAndValue.count == 2, unitAndValue[0].lowercased() == "bytes" else { return nil }

        let boundsAndTotal = unitAndValue[1].split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard boundsAndTotal.count == 2 else { return nil }
        let total: Int64?
        if boundsAndTotal[1] == "*" {
            total = nil
        } else {
            guard let parsed = Int64(boundsAndTotal[1]), parsed > 0 else { return nil }
            total = parsed
        }

        let bounds = boundsAndTotal[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let lower = Int64(bounds[0]),
              let inclusiveUpper = Int64(bounds[1]),
              lower >= 0,
              inclusiveUpper >= lower,
              inclusiveUpper < Int64.max
        else { return nil }
        return HTTPContentRange(range: lower..<(inclusiveUpper + 1), totalLength: total)
    }
}

/// `XMLParser` reports element names differently across servers. Matching the
/// local name makes `D:href`, `d:href`, and unprefixed DAV XML equivalent.
private final class WebDAVMultistatusParser: NSObject, XMLParserDelegate {
    private var responses: [WebDAVResponse] = []
    private var current: WebDAVResponse?
    private var element = ""
    private var text = ""
    private var sawMultistatus = false

    static func parse(_ data: Data) -> [WebDAVResponse]? {
        let delegate = WebDAVMultistatusParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.sawMultistatus else { return nil }
        return delegate.responses
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let local = Self.localName(qName ?? elementName)
        element = local
        text = ""
        if local == "multistatus" { sawMultistatus = true }
        if local == "response" { current = WebDAVResponse() }
        if local == "collection" { current?.isCollection = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let local = Self.localName(qName ?? elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch local {
        case "href": current?.href = value
        case "getcontentlength": current?.size = Int64(value) ?? 0
        case "getlastmodified": current?.modified = Self.httpDate(value) ?? .distantPast
        case "response":
            if let current, !current.href.isEmpty { responses.append(current) }
            current = nil
        default: break
        }
        element = ""
        text = ""
    }

    private static func localName(_ name: String) -> String {
        (name.split(separator: ":").last ?? Substring(name)).lowercased()
    }

    /// HTTP allows three date spellings. Parsing only RFC 1123 turned every
    /// entry from a server using the others into `.distantPast`, which a rescan
    /// then never saw as modified, so edited tags were never refreshed.
    private static let httpDateFormats = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEEE, dd-MMM-yy HH:mm:ss zzz",
        "EEE MMM d HH:mm:ss yyyy",
    ]

    private static func httpDate(_ string: String) -> Date? {
        // asctime pads single-digit days with a second space.
        let normalized = string.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in httpDateFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: normalized) { return date }
        }
        return nil
    }
}
