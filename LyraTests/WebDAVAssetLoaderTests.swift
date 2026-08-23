import AVFoundation
import Foundation
import Testing

@testable import Lyra

@Suite("WebDAV asset loader", .serialized)
struct WebDAVAssetLoaderTests {
    @Test("AVFoundation reads a remote WAV through bounded byte ranges")
    func loadsRemoteAsset() async throws {
        let audio = makeWAV(seconds: 1)
        let source = InMemoryRangeSource(data: audio)
        let loader = WebDAVAssetLoader(
            source: source,
            resource: RemotePlaybackResource(
                sourceID: source.id,
                relativePath: "@stream-test/Album/test.wav",
                contentLength: Int64(audio.count),
                duration: 1,
                fileExtension: "wav"
            )
        )

        let asset = loader.makeAsset()
        let watchdog = Task {
            try await Task.sleep(for: .seconds(5))
            loader.cancelAll()
        }
        defer { watchdog.cancel() }

        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            Issue.record("AVFoundation failed after ranges \(source.requestedRanges): \(error)")
            return
        }
        let seconds = CMTimeGetSeconds(duration)

        #expect(seconds.isFinite)
        #expect(seconds > 0.9 && seconds < 1.1)
        #expect(!source.requestedRanges.isEmpty)
        #expect(source.requestedRanges.allSatisfy { $0.count <= 524_288 })
        loader.cancelAll()
    }

    @Test("Range planning clamps AVFoundation probes to the known file end")
    func clampsRangesToFileEnd() {
        #expect(PlaybackRangePlanner.nextRange(
            offset: 900,
            requestedUpperBound: 2_000,
            totalLength: 1_000,
            maximumLength: 512
        ) == 900..<1_000)
        #expect(PlaybackRangePlanner.nextRange(
            offset: 1_000,
            requestedUpperBound: 2_000,
            totalLength: 1_000,
            maximumLength: 512
        ) == nil)
    }

    @Test("To-end playback is paced after a bounded initial buffer")
    func pacesReadAhead() {
        let policy = StreamPacingPolicy(resource: RemotePlaybackResource(
            sourceID: "stream-test",
            relativePath: "@stream-test/track.flac",
            contentLength: 3_000_000,
            duration: 45,
            fileExtension: "flac"
        ))

        #expect(policy.initialBufferBytes >= 1_048_576)
        #expect(policy.initialBufferBytes < 3_000_000)
        #expect(policy.delay(
            beforeDeliveringAt: policy.initialBufferBytes + 524_288,
            elapsed: .zero
        ) != nil)
    }
}

private final class InMemoryRangeSource: RemoteLibrarySource, @unchecked Sendable {
    let id = "stream-test"
    let displayName = "Stream Test"

    private let data: Data
    private let lock = NSLock()
    private var ranges: [Range<Int64>] = []

    init(data: Data) {
        self.data = data
    }

    var requestedRanges: [Range<Int64>] {
        lock.withLock { ranges }
    }

    func scan() async throws -> [ScannedFile] { [] }

    func metadataHeader(for item: ScannedFile, maxBytes: Int) async throws -> Data {
        Data(data.prefix(maxBytes))
    }

    func readRange(
        for item: ScannedFile,
        range: Range<Int64>
    ) async throws -> RemoteByteRangeResponse {
        let upper = min(range.upperBound, Int64(data.count))
        guard range.lowerBound >= 0, range.lowerBound < upper else {
            throw LibrarySourceError.server(status: 416)
        }

        lock.withLock {
            ranges.append(range.lowerBound..<upper)
        }

        return RemoteByteRangeResponse(
            data: data.subdata(in: Int(range.lowerBound)..<Int(upper)),
            range: range.lowerBound..<upper,
            totalLength: Int64(data.count),
            mimeType: "audio/wav"
        )
    }

    func download(_ item: ScannedFile, to destination: URL) async throws {
        throw LibrarySourceError.unavailable
    }
}

private func makeWAV(seconds: Int) -> Data {
    let sampleRate: UInt32 = 8_000
    let channels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let sampleCount = sampleRate * UInt32(seconds)
    let pcmBytes = sampleCount * UInt32(channels) * UInt32(bitsPerSample / 8)

    var data = Data()
    data.append(Data("RIFF".utf8))
    appendLittleEndian(UInt32(36) + pcmBytes, to: &data)
    data.append(Data("WAVE".utf8))
    data.append(Data("fmt ".utf8))
    appendLittleEndian(UInt32(16), to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(channels, to: &data)
    appendLittleEndian(sampleRate, to: &data)
    appendLittleEndian(sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8), to: &data)
    appendLittleEndian(channels * (bitsPerSample / 8), to: &data)
    appendLittleEndian(bitsPerSample, to: &data)
    data.append(Data("data".utf8))
    appendLittleEndian(pcmBytes, to: &data)
    data.append(Data(repeating: 0, count: Int(pcmBytes)))
    return data
}

private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}
