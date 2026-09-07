import Foundation
import Testing

@testable import Lyra

private final class WebDAVURLProtocol: URLProtocol, @unchecked Sendable {
    struct StubResponse: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
    }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> StubResponse)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = handler(request)
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("WebDAV source", .serialized)
struct WebDAVSourceTests {
    private func source(url: String = "https://server.example/music/") -> WebDAVSource {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDAVURLProtocol.self]
        return WebDAVSource(
            configuration: MusicSource(
                id: "webdav-test",
                displayName: "Server",
                kind: .webDAV,
                serverURL: url,
                username: "marco"
            ),
            password: "secret",
            sessionConfiguration: configuration
        )
    }

    @Test("Inventory and metadata requests use a bounded timeout")
    func boundsScanRequests() async throws {
        WebDAVURLProtocol.handler = { request in
            #expect(request.timeoutInterval == 15)
            if request.httpMethod == "PROPFIND" {
                return .init(
                    status: 207,
                    body: webDAVXML("<multistatus xmlns=\"DAV:\"><response><href>/music/</href><propstat><prop><resourcetype><collection/></resourcetype></prop></propstat></response></multistatus>")
                )
            }
            return .init(status: 200, body: Data("ID3 tiny".utf8))
        }

        let source = source()
        #expect(try await source.scan().isEmpty)
        let item = ScannedFile(
            relativePath: "@webdav-test/song.mp3",
            size: 8,
            modified: .now
        )
        #expect(try await source.metadataHeader(for: item, maxBytes: 1_024) == Data("ID3 tiny".utf8))
    }

    @Test("Nested collections, namespaces, and encoded names become stable relative paths")
    func scansNestedCollection() async throws {
        WebDAVURLProtocol.handler = { request in
            let path = request.url!.path(percentEncoded: false)
            #expect(request.httpMethod == "PROPFIND")
            #expect(request.value(forHTTPHeaderField: "Depth") == "1")
            if path == "/music/" {
                return .init(status: 207, body: webDAVXML("""
                <D:multistatus xmlns:D="DAV:">
                  <D:response><D:href>/music/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
                  <D:response><D:href>Albums/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
                  <D:response><D:href>/music/Beyonc%C3%A9%27s%20Song.mp3</D:href><D:propstat><D:prop><D:getcontentlength>1</D:getcontentlength><D:getlastmodified>Tue, 04 Jun 2024 12:34:56 GMT</D:getlastmodified></D:prop></D:propstat></D:response>
                </D:multistatus>
                """))
            }
            return .init(status: 207, body: webDAVXML("""
            <multistatus xmlns="DAV:">
              <response><href>https://server.example/music/Albums/</href><propstat><prop><resourcetype><collection/></resourcetype></prop></propstat></response>
              <response><href>/music/Albums/One%20%231%20%3F%20100%25.flac</href><propstat><prop><getcontentlength>1234</getcontentlength><getlastmodified>Tue, 04 Jun 2024 12:34:56 GMT</getlastmodified><resourcetype/></prop></propstat></response>
            </multistatus>
            """))
        }

        let files = try await source().scan()
        #expect(Set(files.map(\.relativePath)) == [
            "@webdav-test/Albums/One #1 ? 100%.flac",
            "@webdav-test/Beyoncé's Song.mp3",
        ])
        #expect(files.first { $0.relativePath.hasSuffix("One #1 ? 100%.flac") }?.size == 1234)
        #expect(files.first { $0.relativePath.hasSuffix("One #1 ? 100%.flac") }?.modified != .distantPast)
    }

    @Test("Duplicate filenames in separate folders remain separate tracks")
    func keepsDuplicateNamesSeparate() async throws {
        WebDAVURLProtocol.handler = { request in
            let body = webDAVXML("""
            <d:multistatus xmlns:d="DAV:">
              <d:response><d:href>/music/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
              <d:response><d:href>/music/A/song.mp3</d:href><d:propstat><d:prop><d:getcontentlength>1</d:getcontentlength><d:getlastmodified>Tue, 04 Jun 2024 12:34:56 GMT</d:getlastmodified></d:prop></d:propstat></d:response>
              <d:response><d:href>/music/B/song.mp3</d:href><d:propstat><d:prop><d:getcontentlength>2</d:getcontentlength><d:getlastmodified>Tue, 04 Jun 2024 12:34:56 GMT</d:getlastmodified></d:prop></d:propstat></d:response>
            </d:multistatus>
            """)
            return .init(status: 207, body: body)
        }

        let files = try await source().scan()
        #expect(Set(files.map(\.relativePath)) == ["@webdav-test/A/song.mp3", "@webdav-test/B/song.mp3"])
    }

    @Test("Root-relative rclone hrefs recurse through every collection")
    func scansRcloneStyleHierarchy() async throws {
        WebDAVURLProtocol.handler = { request in
            switch request.url!.path(percentEncoded: false) {
            case "/":
                return .init(status: 207, body: webDAVXML("""
                <D:multistatus xmlns:D="DAV:">
                  <D:response><D:href>/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
                  <D:response><D:href>/Caparezza/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
                </D:multistatus>
                """))
            case "/Caparezza/":
                return .init(status: 207, body: webDAVXML("""
                <D:multistatus xmlns:D="DAV:">
                  <D:response><D:href>/Caparezza/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
                  <D:response><D:href>/Caparezza/Museica/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
                </D:multistatus>
                """))
            case "/Caparezza/Museica/":
                return .init(status: 207, body: webDAVXML("""
                <D:multistatus xmlns:D="DAV:">
                  <D:response><D:href>/Caparezza/Museica/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
                  <D:response><D:href>/Caparezza/Museica/Album/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
                </D:multistatus>
                """))
            case "/Caparezza/Museica/Album/":
                return .init(status: 207, body: webDAVXML("""
                <D:multistatus xmlns:D="DAV:">
                  <D:response><D:href>/Caparezza/Museica/Album/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
                  <D:response><D:href>/Caparezza/Museica/Album/01.%20Canzone%20all%27entrata.wav</D:href><D:propstat><D:prop><D:getcontentlength>21572588</D:getcontentlength><D:getlastmodified>Sat, 21 Mar 2026 10:48:30 GMT</D:getlastmodified><D:resourcetype/></D:prop></D:propstat></D:response>
                </D:multistatus>
                """))
            default:
                return .init(status: 404, body: Data())
            }
        }

        let files = try await source(url: "https://server.example").scan()
        #expect(files.map(\.relativePath) == ["@webdav-test/Caparezza/Museica/Album/01. Canzone all'entrata.wav"])
    }

    @Test("A relative href resolves against the collection being listed")
    func resolvesRelativeHrefAgainstListedCollection() async throws {
        WebDAVURLProtocol.handler = { request in
            switch request.url!.path(percentEncoded: false) {
            case "/music/":
                return .init(status: 207, body: webDAVXML("""
                <D:multistatus xmlns:D="DAV:">
                  <D:response><D:href>/music/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
                  <D:response><D:href>Albums/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
                </D:multistatus>
                """))
            case "/music/Albums/":
                return .init(status: 207, body: webDAVXML("""
                <D:multistatus xmlns:D="DAV:">
                  <D:response><D:href>./</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
                  <D:response><D:href>01%20song.mp3</D:href><D:propstat><D:prop><D:getcontentlength>1</D:getcontentlength><D:getlastmodified>Tue, 04 Jun 2024 12:34:56 GMT</D:getlastmodified><D:resourcetype/></D:prop></D:propstat></D:response>
                </D:multistatus>
                """))
            default:
                return .init(status: 404, body: Data())
            }
        }

        let files = try await source().scan()
        #expect(files.map(\.relativePath) == ["@webdav-test/Albums/01 song.mp3"])
    }

    @Test("A collection that cannot be listed is skipped, not a failed scan")
    func skipsUnlistableCollection() async throws {
        WebDAVURLProtocol.handler = { request in
            switch request.url!.path(percentEncoded: false) {
            case "/music/":
                return .init(status: 207, body: webDAVXML("""
                <D:multistatus xmlns:D="DAV:">
                  <D:response><D:href>/music/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
                  <D:response><D:href>/music/Gone/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
                  <D:response><D:href>/music/here.mp3</D:href><D:propstat><D:prop><D:getcontentlength>1</D:getcontentlength><D:resourcetype/></D:prop></D:propstat></D:response>
                </D:multistatus>
                """))
            default:
                return .init(status: 404, body: Data())
            }
        }

        let files = try await source().scan()
        #expect(files.map(\.relativePath) == ["@webdav-test/here.mp3"])
    }

    @Test("Hrefs pointing at another host are dropped rather than followed with credentials")
    func ignoresForeignHosts() async throws {
        WebDAVURLProtocol.handler = { request in
            #expect(request.url?.host == "server.example")
            #expect(request.url?.port == nil)
            guard request.url?.host == "server.example", request.url?.port == nil else {
                return .init(status: 207, body: webDAVXML("""
                <D:multistatus xmlns:D="DAV:">
                  <D:response><D:href>/leaked.mp3</D:href><D:propstat><D:prop><D:getcontentlength>1</D:getcontentlength><D:resourcetype/></D:prop></D:propstat></D:response>
                </D:multistatus>
                """))
            }
            return .init(status: 207, body: webDAVXML("""
            <D:multistatus xmlns:D="DAV:">
              <D:response><D:href>/music/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
              <D:response><D:href>http://attacker.example/music/Albums/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
              <D:response><D:href>https://server.example:8443/music/other.mp3</D:href><D:propstat><D:prop><D:getcontentlength>1</D:getcontentlength><D:resourcetype/></D:prop></D:propstat></D:response>
              <D:response><D:href>https://attacker.example/music/steal.mp3</D:href><D:propstat><D:prop><D:getcontentlength>1</D:getcontentlength><D:resourcetype/></D:prop></D:propstat></D:response>
            </D:multistatus>
            """))
        }

        #expect(try await source().scan().isEmpty)
    }

    @Test("A collection that loops back into itself ends the scan with an error")
    func rejectsSelfReferentialCollection() async {
        WebDAVURLProtocol.handler = { request in
            let path = request.url!.path(percentEncoded: false)
            return .init(status: 207, body: webDAVXML("""
            <D:multistatus xmlns:D="DAV:">
              <D:response><D:href>\(path)</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
              <D:response><D:href>\(path)loop/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
            </D:multistatus>
            """))
        }

        await #expect(throws: LibrarySourceError.scanLimitReached) { try await source().scan() }
    }

    @Test("Servers spelling getlastmodified as RFC 850 or asctime still date their files")
    func parsesLegacyHTTPDates() async throws {
        WebDAVURLProtocol.handler = { _ in
            .init(status: 207, body: webDAVXML("""
            <D:multistatus xmlns:D="DAV:">
              <D:response><D:href>/music/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
              <D:response><D:href>/music/rfc850.mp3</D:href><D:propstat><D:prop><D:getcontentlength>1</D:getcontentlength><D:getlastmodified>Sunday, 06-Nov-94 08:49:37 GMT</D:getlastmodified><D:resourcetype/></D:prop></D:propstat></D:response>
              <D:response><D:href>/music/asctime.mp3</D:href><D:propstat><D:prop><D:getcontentlength>1</D:getcontentlength><D:getlastmodified>Sun Nov  6 08:49:37 1994</D:getlastmodified><D:resourcetype/></D:prop></D:propstat></D:response>
            </D:multistatus>
            """))
        }

        let files = try await source().scan()
        #expect(files.count == 2)
        #expect(files.allSatisfy { $0.modified != .distantPast })
    }

    @Test("An empty collection is a successful empty scan")
    func scansEmptyCollection() async throws {
        WebDAVURLProtocol.handler = { _ in
            .init(status: 207, body: webDAVXML("<multistatus xmlns=\"DAV:\"><response><href>/music/</href><propstat><prop><resourcetype><collection/></resourcetype></prop></propstat></response></multistatus>"))
        }
        #expect(try await source().scan().isEmpty)
    }

    @Test("Malformed responses and authentication failures are not empty scans")
    func rejectsFailures() async {
        WebDAVURLProtocol.handler = { _ in .init(status: 207, body: Data("not xml".utf8)) }
        await #expect(throws: LibrarySourceError.self) { try await source().scan() }

        WebDAVURLProtocol.handler = { _ in .init(status: 401, body: Data()) }
        await #expect(throws: LibrarySourceError.self) { try await source().scan() }
    }

    @Test("Offline downloads accept only complete HTTP responses")
    func validatesFullDownloadStatus() throws {
        let url = URL(string: "https://server.example/music/song.flac")!
        let complete = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let partial = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: nil)!
        let empty = HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!

        try WebDAVSource.validateDownloadResponse(complete)
        #expect(throws: LibrarySourceError.self) { try WebDAVSource.validateDownloadResponse(partial) }
        #expect(throws: LibrarySourceError.self) { try WebDAVSource.validateDownloadResponse(empty) }
    }

    @Test("A truncated status-200 offline download is rejected")
    func rejectsTruncatedOfflineDownload() async {
        WebDAVURLProtocol.handler = { _ in
            .init(status: 200, body: Data(repeating: 1, count: 3))
        }
        let destination = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let item = ScannedFile(
            relativePath: "@webdav-test/Album/song.mp3",
            size: 4,
            modified: .now
        )

        await #expect(throws: LibrarySourceError.self) {
            try await source().download(item, to: destination) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("A server that ignores the range is rejected rather than downloaded whole")
    func rejectsIgnoredRange() async {
        WebDAVURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-1023")
            return .init(status: 200, body: Data(repeating: 0, count: 4_096))
        }
        let item = ScannedFile(relativePath: "@webdav-test/Album/song.mp3", size: 4_096, modified: .now)
        await #expect(throws: LibrarySourceError.self) {
            try await source().metadataHeader(for: item, maxBytes: 1_024)
        }
    }

    @Test("A declared body larger than the budget is rejected from the headers alone")
    func rejectsIgnoredRangeFromContentLength() async {
        WebDAVURLProtocol.handler = { _ in
            .init(
                status: 200,
                body: Data(repeating: 0, count: 4_096),
                headers: ["Content-Length": "4096"]
            )
        }
        let item = ScannedFile(relativePath: "@webdav-test/Album/song.mp3", size: 4_096, modified: .now)
        await #expect(throws: LibrarySourceError.rangeNotSupported) {
            try await source().metadataHeader(for: item, maxBytes: 1_024)
        }
    }

    @Test("A file shorter than the requested range is accepted whole")
    func acceptsShortFileServedWithoutPartialContent() async throws {
        WebDAVURLProtocol.handler = { _ in .init(status: 200, body: Data("ID3 tiny".utf8)) }
        let item = ScannedFile(relativePath: "@webdav-test/Album/song.mp3", size: 8, modified: .now)
        let header = try await source().metadataHeader(for: item, maxBytes: 1_024)
        #expect(header == Data("ID3 tiny".utf8))
    }

    @Test("Playback ranges validate offsets, total length, and MIME type")
    func readsPlaybackRange() async throws {
        WebDAVURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path(percentEncoded: false) == "/music/Album/one song.mp3")
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=1024-2047")
            #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            return .init(
                status: 206,
                body: Data(repeating: 7, count: 1_024),
                headers: [
                    "Content-Range": "bytes 1024-2047/4096",
                    "Content-Type": "audio/mpeg",
                ]
            )
        }

        let item = ScannedFile(
            relativePath: "@webdav-test/Album/one song.mp3",
            size: 4_096,
            modified: .now
        )
        let response = try await source().readRange(for: item, range: 1_024..<2_048)

        #expect(response.range == 1_024..<2_048)
        #expect(response.totalLength == 4_096)
        #expect(response.mimeType == "audio/mpeg")
        #expect(response.data == Data(repeating: 7, count: 1_024))
    }

    @Test("A range answered without a complete length falls back to the indexed size")
    func acceptsUnknownCompleteLength() async throws {
        WebDAVURLProtocol.handler = { _ in
            .init(
                status: 206,
                body: Data(repeating: 3, count: 1_024),
                headers: ["Content-Range": "bytes 0-1023/*"]
            )
        }

        let item = ScannedFile(
            relativePath: "@webdav-test/Album/song.flac",
            size: 8_192,
            modified: .now
        )
        let response = try await source().readRange(for: item, range: 0..<1_024)

        #expect(response.range == 0..<1_024)
        #expect(response.totalLength == 8_192)
        #expect(response.data.count == 1_024)
    }

    @Test("An unknown complete length requires a usable indexed size")
    func rejectsUnknownCompleteLengthWithoutIndexedSize() async {
        WebDAVURLProtocol.handler = { _ in
            .init(
                status: 206,
                body: Data(repeating: 3, count: 1_024),
                headers: ["Content-Range": "bytes 0-1023/*"]
            )
        }
        let item = ScannedFile(
            relativePath: "@webdav-test/Album/song.flac",
            size: 0,
            modified: .now
        )

        await #expect(throws: LibrarySourceError.rangeNotSupported) {
            try await source().readRange(for: item, range: 0..<1_024)
        }
    }

    @Test("Playback rejects a server that ignores byte ranges")
    func playbackRejectsIgnoredRange() async {
        WebDAVURLProtocol.handler = { _ in
            .init(status: 200, body: Data(repeating: 0, count: 16))
        }
        let item = ScannedFile(relativePath: "@webdav-test/song.flac", size: 16, modified: .now)

        await #expect(throws: LibrarySourceError.rangeNotSupported) {
            try await source().readRange(for: item, range: 0..<16)
        }
    }

    @Test("Playback rejects mismatched and malformed Content-Range headers")
    func playbackRejectsBadContentRange() async {
        let item = ScannedFile(relativePath: "@webdav-test/song.wav", size: 4_096, modified: .now)

        WebDAVURLProtocol.handler = { _ in
            .init(
                status: 206,
                body: Data(repeating: 0, count: 1_024),
                headers: ["Content-Range": "bytes 0-1023/4096"]
            )
        }
        await #expect(throws: LibrarySourceError.rangeNotSupported) {
            try await source().readRange(for: item, range: 1_024..<2_048)
        }

        WebDAVURLProtocol.handler = { _ in
            .init(
                status: 206,
                body: Data(repeating: 0, count: 1_024),
                headers: ["Content-Range": "not-a-range"]
            )
        }
        await #expect(throws: LibrarySourceError.rangeNotSupported) {
            try await source().readRange(for: item, range: 1_024..<2_048)
        }
    }

    @Test("Playback maps authentication failures and bounds each range")
    func playbackAuthenticationAndRangeLimit() async {
        WebDAVURLProtocol.handler = { _ in .init(status: 401, body: Data()) }
        let item = ScannedFile(relativePath: "@webdav-test/song.mp3", size: 2_000_000, modified: .now)

        await #expect(throws: LibrarySourceError.signInRequired) {
            try await source().readRange(for: item, range: 0..<1_024)
        }
        await #expect(throws: LibrarySourceError.invalidConfiguration) {
            try await source().readRange(for: item, range: 0..<1_048_577)
        }
    }

}

private func webDAVXML(_ string: String) -> Data { Data(string.utf8) }
