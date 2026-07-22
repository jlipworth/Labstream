import Foundation
import Testing
@testable import PMSKit

@Suite("MediaBrowser playback carriers")
struct MediaBrowserPlaybackCarrierTests {
    @Test func cleanupFactRemainsExplicitRatherThanDerivedFromPlayMethod() throws {
        let result = MediaBrowserPlaybackOpenResult(
            url: try #require(URL(string: "https://media.example.test/master.m3u8")),
            playSessionId: "play-explicit",
            mediaSourceId: "source-explicit",
            playMethod: .transcode,
            usesServerEncoding: false
        )

        #expect(result.playMethod == .transcode)
        #expect(!result.usesServerEncoding)
    }

    @Test func jellyfinResolverReturnsAuthoritativeNeutralResultWithEncodingCleanupFact() throws {
        let response = try JellyfinPlaybackInfoResponse.decode(from: Data(#"""
        {
          "PlaySessionId": "play-1",
          "MediaSources": [{
            "Id": "source-1",
            "Container": "mkv",
            "Bitrate": 40000000,
            "Width": 3840,
            "Height": 2160,
            "VideoCodec": "hevc",
            "AudioCodec": "truehd",
            "SupportsTranscoding": true,
            "TranscodingUrl": "/Videos/item/master.m3u8?api_key=server-token",
            "TranscodeReasons": ["VideoCodecNotSupported"],
            "RequiredHttpHeaders": { "X-Playback-Header": "required" }
          }]
        }
        """#.utf8))

        let result: MediaBrowserPlaybackOpenResult = try JellyfinPlayback.resolveMediaBrowserStream(
            response: response,
            server: try #require(URL(string: "https://jf.example.test/base")),
            identity: JellyfinClientIdentity(client: "Labstream",
                                              device: "Vision Pro",
                                              deviceId: "device-1",
                                              version: "1.0"),
            token: "token-1",
            itemId: "item"
        )

        #expect(result.playMethod == .transcode)
        #expect(result.usesServerEncoding)
        #expect(result.transcodeReasons == ["VideoCodecNotSupported"])
        #expect(result.requiredHTTPHeaders["X-Playback-Header"] == "required")
        #expect(result.sourceMetadata == MediaBrowserPlaybackSourceMetadata(
            container: "mkv",
            width: 3840,
            height: 2160,
            bitrate: 40_000,
            videoCodec: "hevc",
            audioCodec: "truehd"
        ))
    }

    @Test func embyResolverReturnsAuthoritativeNeutralResultWithoutLosingHeaderOrCleanupFacts() throws {
        let response = try EmbyPlaybackInfoResponse.decode(from: Data(#"""
        {
          "PlaySessionId": "play-9",
          "MediaSources": [{
            "Id": "source-9",
            "Container": "mp4",
            "Bitrate": 9000000,
            "Width": 1920,
            "Height": 1080,
            "VideoCodec": "h264",
            "AudioCodec": "aac",
            "SupportsDirectStream": true,
            "DirectStreamUrl": "/videos/item/stream.mp4?MediaSourceId=source-9",
            "TranscodeReasons": ["ContainerNotSupported"],
            "AddApiKeyToDirectStreamUrl": false,
            "RequiredHttpHeaders": { "X-Playback-Header": "required" }
          }]
        }
        """#.utf8))

        let result: MediaBrowserPlaybackOpenResult = try EmbyPlayback.resolveMediaBrowserStream(
            response: response,
            server: try #require(URL(string: "https://emby.example.test/base")),
            identity: EmbyClientIdentity(client: "Labstream",
                                          device: "Vision Pro",
                                          deviceId: "device-9",
                                          version: "1.0"),
            token: "token-9",
            userId: "user-9",
            itemId: "item"
        )

        #expect(result.playMethod == .directStream)
        #expect(!result.usesServerEncoding)
        #expect(result.transcodeReasons == ["ContainerNotSupported"])
        #expect(result.requiredHTTPHeaders["X-Playback-Header"] == "required")
        #expect(result.requiredHTTPHeaders["X-Emby-Token"] == "token-9")
        #expect(result.sourceMetadata == MediaBrowserPlaybackSourceMetadata(
            container: "mp4",
            width: 1920,
            height: 1080,
            bitrate: 9_000,
            videoCodec: "h264",
            audioCodec: "aac"
        ))
    }
}
