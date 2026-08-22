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
            session: URLSession(configuration: configuration)
        )
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

    @Test("A file shorter than the requested range is accepted whole")
    func acceptsShortFileServedWithoutPartialContent() async throws {
        WebDAVURLProtocol.handler = { _ in .init(status: 200, body: Data("ID3 tiny".utf8)) }
        let item = ScannedFile(relativePath: "@webdav-test/Album/song.mp3", size: 8, modified: .now)
        let header = try await source().metadataHeader(for: item, maxBytes: 1_024)
        #expect(header == Data("ID3 tiny".utf8))
    }

}

private func webDAVXML(_ string: String) -> Data { Data(string.utf8) }
