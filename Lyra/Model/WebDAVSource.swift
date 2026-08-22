import Foundation

/// The only type in Lyra that speaks HTTP. Its output is the same
/// `ScannedFile` inventory as a local folder, keeping WebDAV out of the diff,
/// model store, and UI grouping code.
final class WebDAVSource: RemoteLibrarySource, @unchecked Sendable {
    let configuration: MusicSource
    private let rootURL: URL
    private let session: URLSession
    private let suppliedPassword: String?

    init(configuration: MusicSource, password: String? = nil, session: URLSession = .shared) {
        self.configuration = configuration
        self.rootURL = Self.normalizedRootURL(configuration.serverURL)
        self.session = session
        self.suppliedPassword = password
    }

    var id: String { configuration.id }
    var displayName: String { configuration.displayName }

    /// A music tree is a handful of levels deep. A server that aliases a folder
    /// into itself answers with a fresh URL every round trip, so deduplicating
    /// visited URLs can never catch the loop — only these ceilings can.
    private static let maxDepth = 24
    private static let maxDirectories = 20_000
    private static let maxFiles = 200_000

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

        let (stream, response) = try await requestBytes(request)
        // Every exit before the body is read has to cancel the task, or the
        // session keeps pulling the whole file down for a response we already
        // rejected — a 401 library would do that once per track.
        guard let http = response as? HTTPURLResponse else {
            stream.task.cancel()
            throw LibrarySourceError.unavailable
        }
        guard http.statusCode != 401 else {
            stream.task.cancel()
            throw LibrarySourceError.signInRequired
        }
        guard (200...299).contains(http.statusCode) else {
            stream.task.cancel()
            throw LibrarySourceError.server(status: http.statusCode)
        }
        // A declared length past the budget on a non-partial response is the
        // range-ignoring server the byte loop exists to catch, and the headers
        // prove it before a single byte of the body is read.
        if http.statusCode != 206, http.expectedContentLength > Int64(limit) {
            stream.task.cancel()
            throw LibrarySourceError.rangeNotSupported
        }

        let data = try await prefix(of: stream, limit: limit, declared: http.expectedContentLength)
        LyraLog.webDAV.debug("Metadata range response status=\(http.statusCode) bytes=\(data.count)")
        if http.statusCode == 206 { return data.count > limit ? Data(data.prefix(limit)) : data }
        // A file smaller than the requested range legitimately comes back whole
        // as 200. Only a body larger than we asked for means the server ignored
        // the range and would make indexing download the entire library.
        guard data.count <= limit else { throw LibrarySourceError.rangeNotSupported }
        return data
    }

    /// Reads one byte past the budget and stops. That extra byte is what proves
    /// the server ignored `Range`, and stopping there keeps a whole album out of
    /// memory — six of these run concurrently during a scan.
    ///
    /// `declared` is the response's content length, already checked against the
    /// budget by the caller, or negative when the server sent none. Reserving
    /// against it keeps an eight-byte file from committing the whole 1 MB
    /// artwork budget up front; only a length-less chunked body pays for the
    /// ceiling.
    private func prefix(
        of stream: URLSession.AsyncBytes,
        limit: Int,
        declared: Int64
    ) async throws -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(declared >= 0 ? Int(min(declared, Int64(limit))) + 1 : limit + 1)
        do {
            for try await byte in stream {
                bytes.append(byte)
                if bytes.count > limit { break }
            }
        } catch {
            let code = DiagnosticValue.errorCode(error)
            LyraLog.webDAV.error("WebDAV body read failed error=\(code, privacy: .public)")
            throw LibrarySourceError.unavailable
        }
        stream.task.cancel()
        return Data(bytes)
    }

    func download(_ item: ScannedFile, to destination: URL) async throws {
        LyraLog.webDAV.info("WebDAV download started")
        let request = try authenticatedRequest(url: try url(for: item), method: "GET")
        let (temporaryURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw LibrarySourceError.unavailable }
        LyraLog.webDAV.debug("WebDAV download response status=\(http.statusCode)")
        if http.statusCode == 401 { throw LibrarySourceError.signInRequired }
        guard (200...299).contains(http.statusCode) else { throw LibrarySourceError.server(status: http.statusCode) }

        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let replacement = directory.appending(path: UUID().uuidString, directoryHint: .notDirectory)
        try FileManager.default.moveItem(at: temporaryURL, to: replacement)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: replacement)
        } else {
            try FileManager.default.moveItem(at: replacement, to: destination)
        }
        LyraLog.webDAV.info("WebDAV download completed")
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

    private func requestBytes(_ request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        do {
            return try await session.bytes(for: request)
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
        guard target.scheme?.lowercased() == rootURL.scheme?.lowercased(),
              target.host?.lowercased() == rootURL.host?.lowercased(),
              Self.effectivePort(target) == Self.effectivePort(rootURL)
        else {
            LyraLog.webDAV.error("Dropped a WebDAV href pointing outside the configured server")
            return nil
        }
        return target
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

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
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

private struct WebDAVResponse: Sendable {
    var href: String = ""
    var isCollection = false
    var size: Int64 = 0
    var modified: Date = .distantPast
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
