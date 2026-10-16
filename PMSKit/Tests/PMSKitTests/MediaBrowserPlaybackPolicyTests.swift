import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PMSKit

@Suite("MediaBrowser playback policies")
struct MediaBrowserPlaybackPolicyTests {
    struct QualityRow: Sendable, CustomTestStringConvertible {
        let kbps: Int
        let maxStreamingBitrateBps: Int
        let maxWidth: Int?
        let maxHeight: Int?
        let audioBitrateBps: Int?

        var testDescription: String { "\(kbps) kbps" }
    }

    @Test(arguments: [
        // Unlimited stays at the server maximum without resolution or audio caps.
        QualityRow(kbps: 0, maxStreamingBitrateBps: 200_000_000,
                   maxWidth: nil, maxHeight: nil, audioBitrateBps: nil),
        QualityRow(kbps: 4_000, maxStreamingBitrateBps: 4_000_000,
                   maxWidth: 1280, maxHeight: 720, audioBitrateBps: 256_000),
        QualityRow(kbps: 20_000, maxStreamingBitrateBps: 20_000_000,
                   maxWidth: 1920, maxHeight: 1080, audioBitrateBps: 640_000),
        // 4K keeps audio uncapped.
        QualityRow(kbps: 40_000, maxStreamingBitrateBps: 40_000_000,
                   maxWidth: 3840, maxHeight: 2160, audioBitrateBps: nil),
    ])
    func qualityPolicyMapsBitrateToResolutionAndAudioCaps(_ row: QualityRow) {
        let policy = MediaBrowserPlaybackQualityPolicy(maxVideoBitrateKbps: row.kbps)

        #expect(policy.maxStreamingBitrateBps == row.maxStreamingBitrateBps)
        #expect(policy.maxWidth == row.maxWidth)
        #expect(policy.maxHeight == row.maxHeight)
        #expect(policy.audioBitrateBps == row.audioBitrateBps)
    }

    @Test func qualityPolicyConvertsMillisecondsToTicks() {
        #expect(MediaBrowserPlaybackQualityPolicy.startTicks(resumeOffsetMs: nil) == nil)
        #expect(MediaBrowserPlaybackQualityPolicy.startTicks(resumeOffsetMs: 1) == 10_000)
        #expect(MediaBrowserPlaybackQualityPolicy.startTicks(resumeOffsetMs: 123_456) == 1_234_560_000)
    }

    @Test func activeEncodingStopPolicyConfirmsOnlySuccessfulOrGoneStatuses() {
        for status in [200, 204, 299, 400, 404, 410] {
            #expect(MediaBrowserActiveEncodingStopPolicy.isConfirmedStopped(httpStatus: status))
        }
        for status in [nil, 300, 401, 403, 409, 429, 500, 503] as [Int?] {
            #expect(!MediaBrowserActiveEncodingStopPolicy.isConfirmedStopped(httpStatus: status))
        }
    }

    @Test func activeEncodingStopExecutorSendsRequestAndInterpretsHTTPStatus() async {
        enum StubError: Error { case http(Int), transport }
        let url = URL(string: "https://media.example.test/Videos/ActiveEncodings")!
        let request = URLRequest(url: url)
        var sentRequests: [URLRequest] = []

        let success = await MediaBrowserActiveEncodingStopExecutor.stop(
            playSessionId: "play-session",
            makeRequest: { request },
            send: { sentRequests.append($0) },
            httpStatus: { _ in nil })
        #expect(success)
        #expect(sentRequests.map(\.url) == [url])

        let gone = await MediaBrowserActiveEncodingStopExecutor.stop(
            playSessionId: "play-session",
            makeRequest: { request },
            send: { _ in throw StubError.http(404) },
            httpStatus: { error in
                guard case StubError.http(let status) = error else { return nil }
                return status
            })
        #expect(gone)

        let unauthorized = await MediaBrowserActiveEncodingStopExecutor.stop(
            playSessionId: "play-session",
            makeRequest: { request },
            send: { _ in throw StubError.http(401) },
            httpStatus: { error in
                guard case StubError.http(let status) = error else { return nil }
                return status
            })
        #expect(!unauthorized)

        let transport = await MediaBrowserActiveEncodingStopExecutor.stop(
            playSessionId: "play-session",
            makeRequest: { request },
            send: { _ in throw StubError.transport },
            httpStatus: { _ in nil })
        #expect(!transport)
    }

    @Test func activeEncodingStopExecutorRejectsEmptySessionAndBuilderFailure() async {
        struct BuilderError: Error {}
        let request = URLRequest(url: URL(string: "https://media.example.test/Videos/ActiveEncodings")!)
        var didBuild = false
        var didSend = false

        let emptySession = await MediaBrowserActiveEncodingStopExecutor.stop(
            playSessionId: "",
            makeRequest: { didBuild = true; return request },
            send: { _ in didSend = true },
            httpStatus: { _ in nil })
        #expect(!emptySession)
        #expect(!didBuild)
        #expect(!didSend)

        let builderFailure = await MediaBrowserActiveEncodingStopExecutor.stop(
            playSessionId: "play-session",
            makeRequest: { throw BuilderError() },
            send: { _ in didSend = true },
            httpStatus: { _ in nil })
        #expect(!builderFailure)
        #expect(!didSend)
    }

}
