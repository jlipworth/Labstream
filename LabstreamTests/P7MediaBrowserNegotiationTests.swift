#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

@MainActor
struct P7MediaBrowserNegotiationTests {
    private let url = URL(string: "https://media.invalid/PlaybackInfo")!
    private let payload = Data(#"{"PlaySessionId":"minted-session","MediaSources":[{"Id":"source-s","Container":" MP4 , m4v ","SupportsDirectPlay":true,"MediaStreams":[{"Type":"Audio","Index":1,"Codec":"aac"},{"Type":"Audio","Index":3,"Codec":"dts"}]}]}"#.utf8)

    @Test func adaptersKeepMintedSessionExactSourceAndSelectedAudio() async throws {
        let decision = try await MediaBrowserDownloadNegotiator.negotiate(
            request: { URLRequest(url: url) },
            send: { request in
                #expect(request.url == url)
                return (payload, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, decode: EmbyPlaybackInfoResponse.decode,
            decide: { try EmbyPlayback.downloadDecision(response: $0,
                preferredMediaSourceId: "source-s", audioStreamIndex: 3) })
        #expect(decision.playSessionId == "minted-session")
        #expect(decision.mediaSourceId == "source-s")
        #expect(decision.audioCodec == "dts")
        #expect(decision.container == "mp4")
        #expect(!OfflineDownloadDecision.compatibleRemuxEligibility(videoCodec: "h264",
            audioCodec: decision.audioCodec, sourceContainer: decision.container).copiesAudio)
    }

    @Test func explicitMissingSourceFailsClosed() async throws {
        await #expect(throws: EmbyPlaybackError.preferredMediaSourceUnavailable("missing")) {
            try await MediaBrowserDownloadNegotiator.negotiate(
                request: { URLRequest(url: url) },
                send: { _ in (payload, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!) },
                decode: EmbyPlaybackInfoResponse.decode,
                decide: { try EmbyPlayback.downloadDecision(response: $0, preferredMediaSourceId: "missing") })
        }
    }

    @Test func httpFailureNeverDecodesOrDecides() async {
        await #expect(throws: DownloadManager.DownloadError.transferFailed("PlaybackInfo HTTP 403")) {
            try await MediaBrowserDownloadNegotiator.negotiate(
                request: { URLRequest(url: url) },
                send: { _ in (Data(), HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!) },
                decode: { _ -> Int in Issue.record("HTTP failure reached decode"); return 0 },
                decide: { $0 })
        }
    }
}
#endif
