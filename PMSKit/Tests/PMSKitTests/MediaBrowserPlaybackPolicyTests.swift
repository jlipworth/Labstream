import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PMSKit

@Suite("MediaBrowser playback policies")
struct MediaBrowserPlaybackPolicyTests {
    @Test func qualityPolicyKeepsUnlimitedAtServerMaximumWithoutCaps() {
        let policy = MediaBrowserPlaybackQualityPolicy(maxVideoBitrateKbps: 0)

        #expect(policy.maxStreamingBitrateBps == 200_000_000)
        #expect(policy.maxWidth == nil)
        #expect(policy.maxHeight == nil)
        #expect(policy.audioBitrateBps == nil)
    }

    @Test func qualityPolicyMapsFourMbpsTo720pAndAudioCap() {
        let policy = MediaBrowserPlaybackQualityPolicy(maxVideoBitrateKbps: 4_000)

        #expect(policy.maxStreamingBitrateBps == 4_000_000)
        #expect(policy.maxWidth == 1280)
        #expect(policy.maxHeight == 720)
        #expect(policy.audioBitrateBps == 256_000)
    }

    @Test func qualityPolicyMapsTwentyMbpsTo1080pAndAudioCap() {
        let policy = MediaBrowserPlaybackQualityPolicy(maxVideoBitrateKbps: 20_000)

        #expect(policy.maxStreamingBitrateBps == 20_000_000)
        #expect(policy.maxWidth == 1920)
        #expect(policy.maxHeight == 1080)
        #expect(policy.audioBitrateBps == 640_000)
    }

    @Test func qualityPolicyMapsFortyMbpsTo4KWithoutAudioCap() {
        let policy = MediaBrowserPlaybackQualityPolicy(maxVideoBitrateKbps: 40_000)

        #expect(policy.maxStreamingBitrateBps == 40_000_000)
        #expect(policy.maxWidth == 3840)
        #expect(policy.maxHeight == 2160)
        #expect(policy.audioBitrateBps == nil)
    }

    @Test func qualityPolicyConvertsMillisecondsToTicks() {
        #expect(MediaBrowserPlaybackQualityPolicy.startTicks(resumeOffsetMs: nil) == nil)
        #expect(MediaBrowserPlaybackQualityPolicy.startTicks(resumeOffsetMs: 1) == 10_000)
        #expect(MediaBrowserPlaybackQualityPolicy.startTicks(resumeOffsetMs: 123_456) == 1_234_560_000)
    }

    @Test func remoteHLSBufferingPolicyUsesDeepBufferExceptExplicitShortReopens() {
        #expect(MediaBrowserRemoteHLSBufferingPolicy.preferredForwardBufferSeconds(
            isServerEncodedHLS: false,
            preferShortBuffer: false) == MediaBrowserRemoteHLSBufferingPolicy.steadyStateForwardBufferSeconds)
        #expect(MediaBrowserRemoteHLSBufferingPolicy.preferredForwardBufferSeconds(
            isServerEncodedHLS: true,
            preferShortBuffer: false) == MediaBrowserRemoteHLSBufferingPolicy.steadyStateForwardBufferSeconds)
        #expect(MediaBrowserRemoteHLSBufferingPolicy.preferredForwardBufferSeconds(
            isServerEncodedHLS: true,
            preferShortBuffer: true) == MediaBrowserRemoteHLSBufferingPolicy.seekReopenForwardBufferSeconds)
    }

    @Test func remoteHLSBufferingPolicyWaitsOnlyForDeepBuffers() {
        #expect(MediaBrowserRemoteHLSBufferingPolicy.automaticallyWaitsToMinimizeStalling(
            isServerEncodedHLS: false,
            preferredForwardBufferSeconds: MediaBrowserRemoteHLSBufferingPolicy.steadyStateForwardBufferSeconds))
        #expect(MediaBrowserRemoteHLSBufferingPolicy.automaticallyWaitsToMinimizeStalling(
            isServerEncodedHLS: true,
            preferredForwardBufferSeconds: MediaBrowserRemoteHLSBufferingPolicy.steadyStateForwardBufferSeconds))
        #expect(!MediaBrowserRemoteHLSBufferingPolicy.automaticallyWaitsToMinimizeStalling(
            isServerEncodedHLS: true,
            preferredForwardBufferSeconds: MediaBrowserRemoteHLSBufferingPolicy.seekReopenForwardBufferSeconds))
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
