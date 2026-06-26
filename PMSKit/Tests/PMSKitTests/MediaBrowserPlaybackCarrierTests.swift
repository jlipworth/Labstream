import Foundation
import Testing
@testable import PMSKit

@Suite("MediaBrowser playback carriers")
struct MediaBrowserPlaybackCarrierTests {
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
