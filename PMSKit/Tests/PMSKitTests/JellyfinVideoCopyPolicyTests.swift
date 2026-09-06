import Foundation
import Testing
@testable import PMSKit

@Suite struct JellyfinVideoCopyPolicyTests {
    let base = URL(string: "https://jellyfin.example.internal/Videos/item/master.m3u8?ApiKey=fixture&VideoCodec=hevc&AudioCodec=aac&PlaySessionId=session&SubtitleStreamIndex=-1")!

    @Test func permitsContainerAndAudioConversionButNotVideoTransforms() {
        #expect(JellyfinVideoCopyPolicy.canAttemptCopy(videoCodec: "hevc",
            transcodeReasons: ["ContainerNotSupported", "AudioCodecNotSupported"], requiresVideoTransform: false))
        for reason in ["VideoCodecNotSupported", "VideoProfileNotSupported", "SubtitleCodecNotSupported", "Unknown"] {
            #expect(!JellyfinVideoCopyPolicy.canAttemptCopy(videoCodec: "hevc",
                transcodeReasons: [reason], requiresVideoTransform: false))
        }
        #expect(!JellyfinVideoCopyPolicy.canAttemptCopy(videoCodec: "hevc", transcodeReasons: [], requiresVideoTransform: true))
        #expect(!JellyfinVideoCopyPolicy.canAttemptCopy(videoCodec: nil, transcodeReasons: [], requiresVideoTransform: false))
    }

    @Test func copyRequestPreservesAuthorityAudioAndSelection() throws {
        let url = try #require(JellyfinVideoCopyPolicy.copyURL(base))
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        for (key, value) in ["ApiKey": "fixture", "PlaySessionId": "session", "AudioCodec": "aac",
                              "SubtitleStreamIndex": "-1", "VideoCodec": "copy", "SegmentContainer": "mp4"] {
            #expect(query.filter { $0.name == key }.map(\.value) == [value])
        }
    }

    @Test func excludesHiddenSDREncoderVariants() throws {
        let masterURL = try #require(JellyfinVideoCopyPolicy.copyURL(base))
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=70000000,VIDEO-RANGE=PQ
        main.m3u8?VideoCodec=copy&AllowVideoStreamCopy=true&AudioCodec=aac&ApiKey=fixture
        #EXT-X-STREAM-INF:BANDWIDTH=70000000,VIDEO-RANGE=SDR
        main.m3u8?VideoCodec=h264&AllowVideoStreamCopy=false
        """
        let child = try #require(JellyfinVideoCopyPolicy.copyChild(in: master, baseURL: masterURL))
        #expect(child.path.hasSuffix("/main.m3u8"))
        #expect(child.query?.contains("VideoCodec=copy") == true)
        #expect(JellyfinVideoCopyPolicy.copyChild(in: master.replacingOccurrences(of: "VideoCodec=copy", with: "VideoCodec=hevc"), baseURL: masterURL) == nil)
        #expect(JellyfinVideoCopyPolicy.copyChild(in: master.replacingOccurrences(of: "main.m3u8?VideoCodec=copy", with: "https://other.example/main.m3u8?VideoCodec=copy"), baseURL: masterURL) == nil)
        #expect(JellyfinVideoCopyPolicy.copyChild(in: master + "\n#EXT-X-MEDIA:TYPE=SUBTITLES,URI=subtitle.m3u8", baseURL: masterURL) == nil)
        #expect(JellyfinVideoCopyPolicy.copyChild(in: master.replacingOccurrences(of: "VideoCodec=copy", with: "VideoCodec=copy&videocodec=h264"), baseURL: masterURL) == nil)
    }
}
