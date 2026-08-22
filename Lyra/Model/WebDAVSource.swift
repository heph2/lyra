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

    func scan() async throws -> [ScannedFile] {
        var pending = [rootURL]
        var visited = Set<String>()
        var files: [ScannedFile] = []

        while let directory = pending.popLast() {
            let key = directory.absoluteString
            guard visited.insert(key).inserted else { continue }

            for entry in try await propfind(directory) {
                guard let path = relativePath(for: entry.href) else { continue }
                if entry.isCollection {
                    if !path.isEmpty, let child = requestURL(for: entry.href) {
                        pending.append(child)
                    }
                } else if AudioFile.isSupported(URL(filePath: path)) {
                    files.append(ScannedFile(
                        relativePath: AudioFile.trackPath(sourceID: id, innerPath: path),
                        size: entry.size,
                        modified: entry.modified
                    ))
                }
            }
        }
        return files
    }

    func metadataHeader(for item: ScannedFile, maxBytes: Int) async throws -> Data {
        let requestURL = try url(for: item)
        var request = try authenticatedRequest(url: requestURL, method: "GET")
        request.setValue("bytes=0-\(max(1, maxBytes) - 1)", forHTTPHeaderField: "Range")

        let (data, response) = try await requestData(request)
        guard let http = response as? HTTPURLResponse else { throw LibrarySourceError.unavailable }
        if http.statusCode == 401 { throw LibrarySourceError.signInRequired }
        if http.statusCode == 206 { return data }
        guard (200...299).contains(http.statusCode) else {
            throw LibrarySourceError.server(status: http.statusCode)
        }
        // A file smaller than the requested range legitimately comes back whole
        // as 200. Only a body larger than we asked for means the server ignored
        // the range and would make indexing download the entire library.
        guard data.count <= maxBytes else { throw LibrarySourceError.rangeNotSupported }
        return data
    }

    func download(_ item: ScannedFile, to destination: URL) async throws {
        let request = try authenticatedRequest(url: try url(for: item), method: "GET")
        let (temporaryURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw LibrarySourceError.unavailable }
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
        if http.statusCode == 401 { throw LibrarySourceError.signInRequired }
        guard http.statusCode == 207 else {
            if (200...299).contains(http.statusCode) { throw LibrarySourceError.notWebDAVServer }
            throw LibrarySourceError.server(status: http.statusCode)
        }
        guard let responses = WebDAVMultistatusParser.parse(data) else {
            throw LibrarySourceError.notWebDAVServer
        }
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

    /// Server hrefs may be absolute or relative and retain percent encoding.
    /// Convert them once at the boundary so stored paths never depend on the
    /// server's URL spelling.
    private func relativePath(for href: String) -> String? {
        guard let target = requestURL(for: href) else { return nil }
        let rootPath = rootURL.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let targetPath = target.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if rootPath.isEmpty { return targetPath }
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else { return nil }
        return String(targetPath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func requestURL(for href: String) -> URL? {
        guard !href.isEmpty else { return nil }
        return URL(string: href, relativeTo: rootURL)?.absoluteURL
    }

    private static func normalizedRootURL(_ raw: String?) -> URL {
        guard let raw, let url = URL(string: raw) else { return URL(string: "http://invalid.local/")! }
        return url.hasDirectoryPath ? url : url.appendingPathComponent("")
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

    private static func httpDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: string)
    }
}
