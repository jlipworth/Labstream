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

    @Test func backendMethodsAndMetadataAreAliasesAndOpenResultsRemainCompatible() throws {
        let method: MediaBrowserPlayMethod = JellyfinPlayMethod.transcode
        let source: MediaBrowserPlaybackSourceMetadata = EmbyPlaybackSourceMetadata(
            container: "mkv",
            width: 3840,
            height: 2160,
            bitrate: 40_000,
            videoCodec: "hevc",
            audioCodec: "truehd"
        )
        let legacyResult = JellyfinPlaybackOpenResult(
            url: try #require(URL(string: "https://jf.example.test/videos/item/master.m3u8")),
            playSessionId: "play-1",
            mediaSourceId: "source-1",
            playMethod: method,
            sourceMetadata: source
        )
        let neutral = MediaBrowserPlaybackOpenResult(legacyResult)

        #expect(method == .transcode)
        #expect(source.audioCodec == "truehd")
        #expect(neutral.usesServerEncoding)
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

    @Test func jellyfinOpenResultConvertsToNeutralCarrier() throws {
        let url = try #require(URL(string: "https://jf.example.test/videos/item/master.m3u8"))
        let native = JellyfinPlaybackOpenResult(
            url: url,
            playSessionId: "play-1",
            mediaSourceId: "source-1",
            playMethod: .transcode,
            requiredHTTPHeaders: ["Authorization": "MediaBrowser ..."],
            sourceMetadata: JellyfinPlaybackSourceMetadata(container: "mkv",
                                                           width: 3840,
                                                           height: 2160,
                                                           bitrate: 40_000,
                                                           videoCodec: "hevc",
                                                           audioCodec: "dts"))

        let neutral = MediaBrowserPlaybackOpenResult(native)

        #expect(neutral.url == url)
        #expect(neutral.playSessionId == "play-1")
        #expect(neutral.mediaSourceId == "source-1")
        #expect(neutral.playMethod == .transcode)
        #expect(neutral.requiredHTTPHeaders["Authorization"] == "MediaBrowser ...")
        #expect(neutral.sourceMetadata == MediaBrowserPlaybackSourceMetadata(container: "mkv",
                                                                            width: 3840,
                                                                            height: 2160,
                                                                            bitrate: 40_000,
                                                                            videoCodec: "hevc",
                                                                            audioCodec: "dts"))
        #expect(neutral.usesServerEncoding)
    }

    @Test func embyOpenResultConvertsToNeutralCarrierWithoutJellyfinTypes() throws {
        let url = try #require(URL(string: "https://emby.example.test/videos/item/master.m3u8"))
        let native = EmbyPlaybackOpenResult(
            url: url,
            playSessionId: "play-9",
            mediaSourceId: "source-9",
            playMethod: .directStream,
            requiredHTTPHeaders: ["Authorization": "Emby ...", "X-Emby-Token": "token"],
            sourceMetadata: EmbyPlaybackSourceMetadata(container: "mp4",
                                                       width: 1920,
                                                       height: 1080,
                                                       bitrate: 9_000,
                                                       videoCodec: "h264",
                                                       audioCodec: "aac"),
            usesServerEncoding: false)

        let neutral = MediaBrowserPlaybackOpenResult(native)

        #expect(neutral.url == url)
        #expect(neutral.playSessionId == "play-9")
        #expect(neutral.mediaSourceId == "source-9")
        #expect(neutral.playMethod == .directStream)
        #expect(neutral.requiredHTTPHeaders["X-Emby-Token"] == "token")
        #expect(neutral.sourceMetadata == MediaBrowserPlaybackSourceMetadata(container: "mp4",
                                                                            width: 1920,
                                                                            height: 1080,
                                                                            bitrate: 9_000,
                                                                            videoCodec: "h264",
                                                                            audioCodec: "aac"))
        #expect(!neutral.usesServerEncoding)
    }
}
