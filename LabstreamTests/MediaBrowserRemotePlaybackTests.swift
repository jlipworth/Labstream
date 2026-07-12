import Foundation
import PMSKit
import Testing
@testable import Labstream

@MainActor
struct MediaBrowserRemotePlaybackTests {
    @Test func backendTaggedRemotePreservesEveryNeutralPlaybackFact() throws {
        let url = try #require(URL(string: "https://media.example.test/video/master.m3u8"))
        let source = MediaBrowserPlaybackSourceMetadata(container: "mkv",
                                                        width: 3840,
                                                        height: 2160,
                                                        bitrate: 40_000,
                                                        videoCodec: "hevc",
                                                        audioCodec: "truehd")
        let result = MediaBrowserPlaybackOpenResult(url: url,
                                                    playSessionId: "play-1",
                                                    mediaSourceId: "source-1",
                                                    playMethod: .transcode,
                                                    requiredHTTPHeaders: ["X-Required": "yes"],
                                                    sourceMetadata: source,
                                                    usesServerEncoding: true)

        let remote = MediaBrowserRemotePlayback(backend: .emby, result: result)

        #expect(remote.backend == .emby)
        #expect(remote.url == url)
        #expect(remote.headers == ["X-Required": "yes"])
        #expect(remote.playSessionId == "play-1")
        #expect(remote.mediaSourceId == "source-1")
        #expect(remote.playMethod == .transcode)
        #expect(remote.sourceMetadata == source)
        #expect(remote.usesServerEncoding)
    }

    @Test func cleanupPolicyPreservesBackendSpecificBehavior() throws {
        let url = try #require(URL(string: "https://media.example.test/video.mp4"))
        let direct = MediaBrowserPlaybackOpenResult(url: url,
                                                    playSessionId: "play-direct",
                                                    mediaSourceId: "source-direct",
                                                    playMethod: .directPlay,
                                                    usesServerEncoding: false)

        #expect(MediaBrowserRemotePlayback(backend: .jellyfin, result: direct).requiresActiveEncodingStop)
        #expect(!MediaBrowserRemotePlayback(backend: .emby, result: direct).requiresActiveEncodingStop)
    }
}
