import Foundation
import Testing
@testable import Labstream

struct HLSPrewarmDiagnosticsTests {
    /// #421: a media playlist's first URI is segment 0. Treating it as a child playlist
    /// requests that segment, which starts a competing Emby transcode from zero.
    @Test func childLookupRequiresAMasterPlaylist() throws {
        let base = try #require(URL(string: "https://emby.example.internal/videos/1/main.m3u8"))
        let media = "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:2,\nhls1/main/0.m4s\n#EXT-X-ENDLIST\n"
        #expect(HLSSessionPrewarmer.childPlaylistURL(inStartPlaylist: media, baseURL: base) == nil)
        let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nmain.m3u8?VideoCodec=copy\n"
        let child = HLSSessionPrewarmer.childPlaylistURL(inStartPlaylist: master, baseURL: base)
        #expect(child?.absoluteString == "https://emby.example.internal/videos/1/main.m3u8?VideoCodec=copy")
    }

    /// #421: the Emby copy warm must start the job at the seek target, not at segment 0.
    @Test func targetSegmentLookupWalksTheTimeline() throws {
        let base = try #require(URL(string: "https://emby.example.internal/videos/1/main.m3u8"))
        let media = """
        #EXTM3U
        #EXT-X-MAP:URI="hls1/main/init.mp4"
        #EXTINF:2.0,
        hls1/main/0.m4s
        #EXTINF:2.0,
        hls1/main/1.m4s
        #EXTINF:1.5,
        hls1/main/2.m4s
        #EXT-X-ENDLIST
        """
        func segment(_ ms: Int) -> String? {
            HLSSessionPrewarmer.segmentURL(containingMs: ms, inMediaPlaylist: media, baseURL: base)?.lastPathComponent
        }
        #expect(segment(0) == "0.m4s")
        #expect(segment(1_999) == "0.m4s")
        #expect(segment(2_000) == "1.m4s")
        #expect(segment(4_400) == "2.m4s")
        #expect(segment(99_000) == "2.m4s")
        let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nmain.m3u8\n"
        #expect(HLSSessionPrewarmer.segmentURL(containingMs: 0, inMediaPlaylist: master, baseURL: base) == nil)
        let invalid = "#EXTM3U\n#EXTINF:nan,\n0.m4s\n"
        #expect(HLSSessionPrewarmer.segmentURL(containingMs: 0, inMediaPlaylist: invalid, baseURL: base) == nil)
    }

    @Test func queryClassificationUsesNamesNotSecretValues() {
        #expect(HLSSessionPrewarmer.hasStartTimeTicks("segment.ts?sTaRtTiMeTiCkS=PRIVATE_TICKS&api_key=PRIVATE_TOKEN"))
        #expect(!HLSSessionPrewarmer.hasStartTimeTicks("segment.ts?api_key=StartTimeTicks&keep=PRIVATE_TOKEN"))
        #expect(!HLSSessionPrewarmer.hasStartTimeTicks("segment.ts"))
    }

    @Test func topologySeparatesOrdinaryAndQuotedURIsWithoutRetainingValues() {
        let playlist = """
        #EXTM3U
        #EXT-X-MAP:URI="init.mp4?StartTimeTicks=PRIVATE_TICKS&api_key=PRIVATE_TOKEN"
        #EXT-X-KEY:METHOD=AES-128,URI="key?starttimeticks=PRIVATE_TICKS"
        #EXTINF:10,
        segment.ts?STARTTIMETICKS=PRIVATE_TICKS&api_key=PRIVATE_TOKEN
        #EXTINF:10,
        segment2.ts?api_key=StartTimeTicks
        """
        let topology = HLSSessionPrewarmer.playlistTopology(playlist)
        #expect(topology.kind == .media)
        #expect(topology.ordinary == 1)
        #expect(topology.quoted == 2)
        let observation = HLSSessionPrewarmer.Observation(
            phase: .child, elapsedMS: 12, httpStatus: 200, urlErrorCode: nil,
            success: true, startTimeTicksPresent: true,
            playlistKind: topology.kind,
            ordinaryURIsWithStartTimeTicks: topology.ordinary,
            quotedURIsWithStartTimeTicks: topology.quoted, timeline: HLSSessionPrewarmer.playlistTimeline(playlist))
        let description = String(reflecting: observation)
        #expect(!description.contains("PRIVATE_TICKS"))
        #expect(!description.contains("PRIVATE_TOKEN"))
        #expect(!description.contains("segment.ts"))
    }

    @Test func masterAndUnknownClassificationAreExplicit() {
        let master = HLSSessionPrewarmer.playlistTopology("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nchild.m3u8?StartTimeTicks=secret\n")
        #expect(master.kind == .master)
        #expect(master.ordinary == 1)
        #expect(master.quoted == 0)
        let unknown = HLSSessionPrewarmer.playlistTopology("#EXTM3U\n#EXT-X-ENDLIST\n")
        #expect(unknown.kind == .unknown)
        #expect(unknown.ordinary == 0)
        #expect(unknown.quoted == 0)
    }

    @Test func phaseLabelsAreFixedAndObservationIsSendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(HLSSessionPrewarmer.Observation.self)
        #expect(HLSSessionPrewarmer.Observation.Phase.master.rawValue == "master")
        #expect(HLSSessionPrewarmer.Observation.Phase.child.rawValue == "child")
        #expect(HLSSessionPrewarmer.Observation.Phase.`init`.rawValue == "init")
        #expect(HLSSessionPrewarmer.Observation.Phase.segment.rawValue == "segment")
    }
    @Test func fullAndOffsetTimelinesExposeOnlyNumericStructure() {
        let full = HLSSessionPrewarmer.playlistTimeline("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-START:TIME-OFFSET=565.25,PRECISE=NO\n#EXTINF:10,\nprivate-folder/0.ts?api_key=PRIVATE_TOKEN\n#EXTINF:9.5,\n1.ts\n#EXT-X-ENDLIST\n")
        #expect(full.mediaSequence == 0)
        #expect(full.segmentCount == 2)
        #expect(full.totalDurationMS == 19500)
        #expect(full.startOffsetMS == 565250)
        #expect(full.endList)
        #expect(full.firstSegmentExtension == .ts)
        #expect(full.firstSegmentOrdinal == 0)
        #expect(!String(reflecting: full).contains("PRIVATE_TOKEN"))
        #expect(!String(reflecting: full).contains("private-folder"))
        let offset = HLSSessionPrewarmer.playlistTimeline("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:56\n#EXTINF:10,\n56.m4s?StartTimeTicks=PRIVATE_TICKS\n")
        #expect(offset.mediaSequence == 56)
        #expect(offset.firstSegmentOrdinal == 56)
        #expect(offset.firstSegmentExtension == .m4s)
        #expect(!offset.endList)
        #expect(offset.startOffsetMS == nil)
    }

    @Test func malformedAndNonfiniteTimelineNumbersDoNotTrap() {
        for value in ["NaN", "inf", "-inf", "bad", "1e300", "-1"] {
            let parsed = HLSSessionPrewarmer.playlistTimeline("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:bad\n#EXT-X-START:TIME-OFFSET=\(value)\n#EXTINF:\(value),\nsecret-id.mp4?token=PRIVATE_TOKEN\n")
            #expect(parsed.mediaSequence == nil)
            #expect(parsed.totalDurationMS == nil)
            #expect(parsed.firstSegmentOrdinal == nil)
            #expect(parsed.firstSegmentExtension == .mp4)
            if value != "-1" { #expect(parsed.startOffsetMS == nil) }
        }
        let negativeStart = HLSSessionPrewarmer.playlistTimeline("#EXT-X-START:TIME-OFFSET=-1.5\n")
        #expect(negativeStart.startOffsetMS == -1500)
        let other = HLSSessionPrewarmer.playlistTimeline("#EXTINF:1,\nprivate-name.secret\n")
        #expect(other.firstSegmentExtension == .other)
        #expect(other.firstSegmentOrdinal == nil)
    }

}
