import Foundation
import Testing
@testable import PMSKit

@Suite struct EmbyVideoCopyPolicyTests {
    let base = URL(string: "https://emby.example.internal/videos/item/master.m3u8?api_key=fixture&VideoCodec=hevc&AudioCodec=aac&PlaySessionId=session&SubtitleStreamIndex=-1")!

    @Test func usesEmbyFragmentedMP4DialectAndPreservesSelection() throws {
        let url = try #require(EmbyVideoCopyPolicy.copyURL(base))
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        for (key, value) in ["api_key": "fixture", "PlaySessionId": "session", "AudioCodec": "aac",
                             "SubtitleStreamIndex": "-1", "VideoCodec": "copy", "SegmentContainer": "m4s"] {
            #expect(query.filter { $0.name == key }.map(\.value) == [value])
        }
        let duplicate = URL(string: base.absoluteString + "&videocodec=h264&segmentcontainer=ts")!
        #expect(EmbyVideoCopyPolicy.copyURL(duplicate) == url)
    }

    @Test func transportStreamTimelineIsScopedToH264StaticRecovery() {
        #expect(EmbyVideoCopyPolicy.usesTransportStreamRecovery(videoCodec: "H264", prefersStaticRecovery: true))
        #expect(!EmbyVideoCopyPolicy.usesTransportStreamRecovery(videoCodec: "h264", prefersStaticRecovery: false))
        #expect(!EmbyVideoCopyPolicy.usesTransportStreamRecovery(videoCodec: "hevc", prefersStaticRecovery: true))
        #expect(!EmbyVideoCopyPolicy.usesTransportStreamRecovery(videoCodec: nil, prefersStaticRecovery: true))
    }

    @Test func fullTimelineRecoveryStripsOnlyStartTicks() throws {
        let primed = URL(string: base.absoluteString + "&StartTimeTicks=9000000000&starttimeticks=1")!
        let timeline = try #require(EmbyVideoCopyPolicy.fullTimelineURL(primed))
        #expect(timeline == base)
    }

    @Test func transportStreamRecoveryStillForbidsVideoEncoding() throws {
        let url = try #require(EmbyVideoCopyPolicy.copyURL(base, forceAAC: true, useMPEGTS: true))
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        for (key, value) in ["SegmentContainer": "ts", "VideoCodec": "copy", "AllowVideoStreamCopy": "true", "AudioCodec": "aac"] {
            #expect(query.filter { $0.name == key }.map(\.value) == [value])
        }
    }

    @Test func audioOnlyCompatibilityConversionNeverEnablesVideoEncoding() throws {
        let url = try #require(EmbyVideoCopyPolicy.copyURL(base, forceAAC: true))
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        for (key, value) in ["VideoCodec": "copy", "AllowVideoStreamCopy": "true",
                             "AudioCodec": "aac", "AllowAudioStreamCopy": "false"] {
            #expect(query.filter { $0.name == key }.map(\.value) == [value])
        }
    }

    @Test func transportStreamChildPreservesAuthorityAndAudioSelection() throws {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=10000000
        main.m3u8?VideoCodec=copy&api_key=fixture&PlaySessionId=session&AudioStreamIndex=2&StartTimeTicks=9000
        """
        let child = try #require(EmbyVideoCopyPolicy.copyChild(in: master, baseURL: base, forceAAC: true, useMPEGTS: true))
        let full = try #require(EmbyVideoCopyPolicy.fullTimelineURL(child))
        let query = try #require(URLComponents(url: full, resolvingAgainstBaseURL: false)?.queryItems)
        for (key, value) in ["SegmentContainer": "ts", "VideoCodec": "copy", "api_key": "fixture", "PlaySessionId": "session", "AudioStreamIndex": "2"] {
            #expect(query.filter { $0.name == key }.map(\.value) == [value])
        }
        #expect(!query.contains { $0.name.lowercased() == "starttimeticks" })
    }

    @Test func rejectsVideoTransformsAndUnknownReasons() {
        #expect(EmbyVideoCopyPolicy.canAttemptCopy(videoCodec: "hevc",
            transcodeReasons: ["ContainerNotSupported", "AudioCodecNotSupported"], requiresVideoTransform: false))
        #expect(!EmbyVideoCopyPolicy.canAttemptCopy(videoCodec: "hevc", transcodeReasons: [], requiresVideoTransform: true))
        #expect(!EmbyVideoCopyPolicy.canAttemptCopy(videoCodec: "hevc", transcodeReasons: ["Unknown"], requiresVideoTransform: false))
    }

    @Test func onlyExposesExplicitSameOriginCopyChild() throws {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=70000000
        main.m3u8?VideoCodec=copy&AllowVideoStreamCopy=true&api_key=fixture
        #EXT-X-STREAM-INF:BANDWIDTH=70000000
        main.m3u8?VideoCodec=h264&AllowVideoStreamCopy=false
        """
        let child = try #require(EmbyVideoCopyPolicy.copyChild(in: master, baseURL: base))
        #expect(child.query?.contains("SegmentContainer=m4s") == true)
        #expect(EmbyVideoCopyPolicy.copyChild(in: master.replacingOccurrences(of: "VideoCodec=copy", with: "VideoCodec=hevc"), baseURL: base) == nil)
        #expect(EmbyVideoCopyPolicy.copyChild(in: master.replacingOccurrences(of: "main.m3u8?VideoCodec=copy", with: "https://other.example/main.m3u8?VideoCodec=copy"), baseURL: base) == nil)
        #expect(EmbyVideoCopyPolicy.copyChild(in: master + "\n#EXT-X-MEDIA:TYPE=AUDIO,URI=audio.m3u8", baseURL: base) == nil)
    }
}

@Suite struct EmbyOriginalDirectPlayTests {
    @Test func copyFallbackRequestsHLSWithoutAuthorizingVideoEncoding() throws {
        let request = try EmbyPlayback.playbackInfoRequest(server: URL(string: "https://emby.example.internal")!,
            token: "fixture", identity: EmbyClientIdentity(client: "Fixture", device: "Mac", deviceId: "fixture", version: "1"),
            userId: "user", itemId: "item", maxStreamingBitrate: 200_000_000, preferVideoCopyHLS: true)
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["EnableDirectPlay"] as? Bool == false)
        #expect(body["EnableDirectStream"] as? Bool == false)
        #expect(body["AllowVideoStreamCopy"] as? Bool == true)
        #expect(body["IsPlayback"] as? Bool == false)
    }

    @Test func prefersNegotiatedDirectPlayOverOptionalTranscodeURL() throws {
        let response = try EmbyPlaybackInfoResponse.decode(from: Data(#"""
        {"PlaySessionId":"session","MediaSources":[{"Id":"source","Container":"mp4",
        "SupportsDirectPlay":true,"SupportsDirectStream":true,"SupportsTranscoding":true,
        "TranscodingUrl":"/videos/item/master.m3u8?VideoCodec=h264"}]}
        """#.utf8))
        let result = try EmbyPlayback.resolveMediaBrowserStream(response: response,
            server: URL(string: "https://emby.example.internal")!,
            identity: EmbyClientIdentity(client: "Fixture", device: "Mac", deviceId: "fixture", version: "1"),
            token: "fixture", userId: "user", itemId: "item")
        #expect(result.playMethod == .directPlay)
        #expect(!result.usesServerEncoding)
        #expect(result.url.pathExtension == "mp4")
        #expect(result.url.query?.contains("Static=true") == true)
    }
}
