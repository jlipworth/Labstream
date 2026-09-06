import Foundation
import Testing
@testable import PMSKit

@Suite struct ClientFirstPlaybackPolicyTests {
    @Test(arguments: ["copy", "directplay", "COPY"])
    func originalVideoCopyNeedsNoConsent(_ decision: String) {
        #expect(!VideoTranscodeConsentPolicy.requiresConsent(selectedQualityKbps: 0,
            approvedForCurrentItem: false, videoDecision: decision, forcesVideoEncoding: false))
    }
    @Test(arguments: ["transcode", "", "unknown"])
    func originalEncodeOrUnknownNeedsConsent(_ decision: String) {
        #expect(VideoTranscodeConsentPolicy.requiresConsent(selectedQualityKbps: 0,
            approvedForCurrentItem: false, videoDecision: decision, forcesVideoEncoding: false))
    }
    @Test func explicitOrApprovedEncodingDoesNotPromptAgain() {
        for quality in [8_000, StreamingQuality.maxTranscodedKbps] {
            #expect(!VideoTranscodeConsentPolicy.requiresConsent(selectedQualityKbps: quality,
                approvedForCurrentItem: false, videoDecision: "transcode", forcesVideoEncoding: true))
        }
        #expect(!VideoTranscodeConsentPolicy.requiresConsent(selectedQualityKbps: 0,
            approvedForCurrentItem: true, videoDecision: nil, forcesVideoEncoding: true))
        #expect(VideoTranscodeConsentPolicy.requiresConsent(selectedQualityKbps: 0,
            approvedForCurrentItem: false, videoDecision: "copy", forcesVideoEncoding: true))
    }
    let base = URL(string: "https://plex.example.internal/start.m3u8")!
    let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=70000000,VIDEO-RANGE=PQ\nchild.m3u8\n"
    @Test func hdrMediaKeepsOriginalBitsAndSameOrigin() {
        #expect(PlexHLSMediaPlaylistPolicy.mediaPlaylist(in: master, baseURL: base,
            hdrDisplayEligible: false)?.path == "/child.m3u8")
        #expect(PlexHLSMediaPlaylistPolicy.mediaPlaylist(in: master, baseURL: base,
            hdrDisplayEligible: true) == nil)
    }
    @Test func rejectsAmbiguousOrCrossOriginMaster() {
        for text in [master + "#EXT-X-STREAM-INF:VIDEO-RANGE=PQ\nother.m3u8",
                     master.replacingOccurrences(of: "child.m3u8", with: "https://other.example/child.m3u8"),
                     master.replacingOccurrences(of: "VIDEO-RANGE=PQ", with: "VIDEO-RANGE=SDR"),
                     master + "#EXT-X-MEDIA:TYPE=AUDIO,URI=audio.m3u8",
                     "#EXTM3U\n#EXT-X-STREAM-INF:VIDEO-RANGE=PQ\n"] {
            #expect(PlexHLSMediaPlaylistPolicy.mediaPlaylist(in: text, baseURL: base,
                hdrDisplayEligible: false) == nil)
        }
    }
    @Test func transportProgressDeferralHasAHardDeadline() {
        #expect(PlaybackStallDeadlinePolicy.allowsDeferral(waitingSince: 10, now: 25, interval: 15))
        #expect(!PlaybackStallDeadlinePolicy.allowsDeferral(waitingSince: 10, now: 40, interval: 15))
        #expect(!PlaybackStallDeadlinePolicy.allowsDeferral(waitingSince: 10, now: 1, interval: 15))
        #expect(!PlaybackStallDeadlinePolicy.allowsDeferral(waitingSince: 10, now: .infinity, interval: 15))
        #expect(!PlaybackStallDeadlinePolicy.allowsDeferral(waitingSince: 10, now: 10, interval: 0))
        // The copy lane retains its longer initial grace, but cannot defer forever either.
        #expect(PlaybackStallDeadlinePolicy.allowsDeferral(waitingSince: 0, now: 90, interval: 90))
        #expect(!PlaybackStallDeadlinePolicy.allowsDeferral(waitingSince: 0, now: 180, interval: 90))
    }
    @Test func hdrAttributeMayBeFirstButExtraMediaURIsAreRejected() {
        let firstAttribute = "#EXTM3U\n#EXT-X-STREAM-INF:VIDEO-RANGE=PQ,BANDWIDTH=70000000\nchild.m3u8"
        #expect(PlexHLSMediaPlaylistPolicy.mediaPlaylist(in: firstAttribute,
            baseURL: base, hdrDisplayEligible: false) != nil)
        #expect(PlexHLSMediaPlaylistPolicy.mediaPlaylist(in: master + "extra.m3u8",
            baseURL: base, hdrDisplayEligible: false) == nil)
    }

}
