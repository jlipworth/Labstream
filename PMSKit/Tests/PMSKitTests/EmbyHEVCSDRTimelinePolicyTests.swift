import Foundation
import Testing
@testable import PMSKit

struct EmbyHEVCSDRTimelinePolicyTests {
    private let url = URL(string: "https://emby.example.internal/videos/item/master.m3u8?TranscodeReasons=ContainerNotSupported&StartTimeTicks=90000000&PlaySessionId=fixture")!

    private func source(codec: String = "hevc", format: VideoHDRFormat = .sdr,
                        depth: Int? = 10, bitrate: Int? = 4000) -> MediaBrowserPlaybackSourceMetadata {
        MediaBrowserPlaybackSourceMetadata(bitrate: bitrate, videoCodec: codec,
            hdr: VideoHDRMetadata(format: format, bitDepth: depth, colorPrimaries: nil,
                colorTransfer: nil, colorSpace: nil, colorRange: nil,
                dolbyVision: nil, hdr10PlusPresent: nil))
    }

    private func eligible(_ source: MediaBrowserPlaybackSourceMetadata?,
                          url: URL? = nil, method: MediaBrowserPlayMethod? = .transcode,
                          enforced: Bool = false, ceiling: Int = 8000, transform: Bool = false) -> Bool {
        EmbyHEVCSDRTimelinePolicy.shouldUseNativeTimeline(url: url ?? self.url, playMethod: method,
            source: source, videoCopyEnforced: enforced, bitrateCeilingKbps: ceiling,
            requiresVideoTransform: transform)
    }

    @Test func originalAndCompatibleCappedCopyUseNativeTimeline() {
        #expect(eligible(source(), enforced: true, ceiling: 0))
        #expect(eligible(source(codec: "HEVC")))
        #expect(eligible(source(bitrate: 8000)))
    }

    @Test func excludesHDRUnknownAndOtherSourceFormats() {
        for format in VideoHDRFormat.allCases where format != .sdr {
            #expect(!eligible(source(format: format), enforced: true))
        }
        #expect(!eligible(nil))
        #expect(!eligible(MediaBrowserPlaybackSourceMetadata(videoCodec: "hevc")))
        for depth in [nil, 8, 12] as [Int?] { #expect(!eligible(source(depth: depth))) }
        for codec in ["h264", "av1", ""] { #expect(!eligible(source(codec: codec))) }
    }

    @Test func preservesEncodeAndUnknownNegotiationPaths() {
        for bitrate in [nil, 0, 8001] as [Int?] { #expect(!eligible(source(bitrate: bitrate))) }
        #expect(!eligible(source(), ceiling: 0))
        #expect(!eligible(source(), enforced: true, transform: true))
        for method in [nil, .directPlay, .directStream] as [MediaBrowserPlayMethod?] {
            #expect(!eligible(source(), method: method))
        }
        for query in ["", "TranscodeReasons=", "TranscodeReasons=VideoCodecNotSupported",
                      "TranscodeReasons=ContainerNotSupported,Unknown",
                      "TranscodeReasons=ContainerNotSupported&transcodereasons=ContainerNotSupported"] {
            #expect(!eligible(source(), url: URL(string: "https://emby.example.internal/master.m3u8?" + query)!))
        }
        #expect(!eligible(source(), url: URL(string: "https://emby.example.internal/video.mp4")!, enforced: true))
    }

    @Test func fullTimelineRetainsSessionAuthorityAndFragmentedMP4() throws {
        let original = URL(string: url.absoluteString + "&SegmentContainer=m4s&VideoCodec=hevc&AudioStreamIndex=1")!
        let full = try #require(EmbyVideoCopyPolicy.fullTimelineURL(original))
        let items = try #require(URLComponents(url: full, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(!items.contains { $0.name.lowercased() == "starttimeticks" })
        for (name, value) in [("PlaySessionId", "fixture"), ("SegmentContainer", "m4s"),
                              ("VideoCodec", "hevc"), ("AudioStreamIndex", "1")] {
            #expect(items.first { $0.name == name }?.value == value)
        }
    }
}
