import Foundation
import Testing
@testable import PMSKit

/// GH #196 spike (b): inject Dolby Vision signalling attributes into master playlists so a
/// copy-remuxed DV bitstream is *signalled* as DV to AVPlayer instead of read as plain HEVC.
@Suite("PlaylistRewriter DV injection")
struct PlaylistRewriterDVTests {
    private let upstream = URL(string: "https://plex.example.internal:32400")!
    private let loopback = URL(string: "http://127.0.0.1:8888")!

    private func rewriter(_ injection: MediaSessionDolbyVisionInjection?) -> PlaylistRewriter {
        PlaylistRewriter(upstreamBase: upstream,
                         loopbackBase: loopback,
                         dolbyVisionInjection: injection)
    }

    private let masterPlaylist = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=62723000,CODECS="hvc1.2.4.L153.B0,ec-3",RESOLUTION=3840x2160
    video.m3u8
    """

    private let mediaPlaylist = """
    #EXTM3U
    #EXT-X-TARGETDURATION:6
    #EXTINF:6.006,
    segment0.ts
    """

    @Test func injectsSupplementalCodecsAndVideoRangeOnMaster() {
        let injection = MediaSessionDolbyVisionInjection(supplementalCodecs: "dvh1.08.06/db1p",
                                                         videoRange: "PQ")
        let out = String(decoding: rewriter(injection).rewrite(Data(masterPlaylist.utf8),
                                                               contentType: "application/vnd.apple.mpegurl"),
                         as: UTF8.self)
        let streamInf = out.split(separator: "\n").first { $0.hasPrefix("#EXT-X-STREAM-INF:") }!
        #expect(streamInf.contains(#"SUPPLEMENTAL-CODECS="dvh1.08.06/db1p""#))
        #expect(streamInf.contains("VIDEO-RANGE=PQ"))
        // URI line untouched.
        #expect(out.contains("\nvideo.m3u8"))
    }

    @Test func doesNotDuplicateExistingAttributes() {
        let already = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1000,CODECS="hvc1",SUPPLEMENTAL-CODECS="dvh1.08.06/db1p",VIDEO-RANGE=PQ
        video.m3u8
        """
        let injection = MediaSessionDolbyVisionInjection(supplementalCodecs: "dvh1.08.06/db1p",
                                                         videoRange: "PQ")
        let out = String(decoding: rewriter(injection).rewrite(Data(already.utf8),
                                                               contentType: "application/vnd.apple.mpegurl"),
                         as: UTF8.self)
        #expect(out.components(separatedBy: "SUPPLEMENTAL-CODECS").count == 2)
        #expect(out.components(separatedBy: "VIDEO-RANGE").count == 2)
    }

    @Test func leavesMediaPlaylistsUntouched() {
        let injection = MediaSessionDolbyVisionInjection(supplementalCodecs: "dvh1.08.06/db1p",
                                                         videoRange: "PQ")
        let out = rewriter(injection).rewrite(Data(mediaPlaylist.utf8),
                                              contentType: "application/vnd.apple.mpegurl")
        #expect(out == Data(mediaPlaylist.utf8))
    }

    @Test func nilInjectionLeavesMasterUntouched() {
        let out = rewriter(nil).rewrite(Data(masterPlaylist.utf8),
                                        contentType: "application/vnd.apple.mpegurl")
        #expect(out == Data(masterPlaylist.utf8))
    }

    @Test func injectionDerivedFromDolbyVisionInfo() {
        // HDR10-compatible base layers (compat 1/6) → PQ + db1p brand.
        let p8c1 = MediaSessionDolbyVisionInjection.forDolbyVision(
            VideoDolbyVisionInfo(profile: 8, level: 6, blCompatibilityID: 1,
                                 rpuPresent: true, elPresent: false, blPresent: true))
        #expect(p8c1 == MediaSessionDolbyVisionInjection(supplementalCodecs: "dvh1.08.06/db1p",
                                                         videoRange: "PQ"))
        // HLG-compatible (compat 4) → HLG + db4h.
        let p8c4 = MediaSessionDolbyVisionInjection.forDolbyVision(
            VideoDolbyVisionInfo(profile: 8, level: 5, blCompatibilityID: 4,
                                 rpuPresent: true, elPresent: false, blPresent: true))
        #expect(p8c4 == MediaSessionDolbyVisionInjection(supplementalCodecs: "dvh1.08.05/db4h",
                                                         videoRange: "HLG"))
        // P5 (compat 0) has no supplemental/fallback form — never inject.
        let p5 = MediaSessionDolbyVisionInjection.forDolbyVision(
            VideoDolbyVisionInfo(profile: 5, level: 6, blCompatibilityID: 0,
                                 rpuPresent: true, elPresent: nil, blPresent: true))
        #expect(p5 == nil)
        // Unknown compat → never inject (claiming DV the segments may not carry causes
        // exactly the garbage this issue exists to prevent).
        let unknown = MediaSessionDolbyVisionInjection.forDolbyVision(
            VideoDolbyVisionInfo(profile: 7, level: 6, blCompatibilityID: nil,
                                 rpuPresent: true, elPresent: true, blPresent: true))
        #expect(unknown == nil)
    }
}
