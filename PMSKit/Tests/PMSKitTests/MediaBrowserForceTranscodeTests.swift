import Foundation
import Testing
@testable import PMSKit

/// GH #196: the DV P5 guard forces a server tone-map transcode by disabling the
/// direct-play / direct-stream / video-copy lanes in the PlaybackInfo body.
@Suite("MediaBrowser force-transcode PlaybackInfo")
struct MediaBrowserForceTranscodeTests {
    private let jfServer = URL(string: "https://jellyfin.example.test/base")!
    private let jfIdentity = JellyfinClientIdentity(client: "VisionPlay", device: "Apple Vision Pro",
                                                    deviceId: "device-123", version: "0.1.0")
    private let embyServer = URL(string: "https://emby.example.test/emby")!
    private let embyIdentity = EmbyClientIdentity(client: "VisionPlay", device: "Apple Vision Pro",
                                                  deviceId: "device-123", version: "0.1.0")

    private func bodyJSON(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func jellyfinForceTranscodeDisablesCopyLanes() throws {
        let request = try JellyfinPlayback.playbackInfoRequest(
            server: jfServer, token: "token-abc", identity: jfIdentity,
            itemId: "movie-1", userId: "user-1", maxStreamingBitrate: 8_000_000,
            forcePlaybackTranscode: true)
        let body = try bodyJSON(request)
        #expect(body["EnableDirectPlay"] as? Bool == false)
        #expect(body["EnableDirectStream"] as? Bool == false)
        #expect(body["AllowVideoStreamCopy"] as? Bool == false)
        // The transcode escape hatch and audio copy must stay open.
        #expect(body["EnableTranscoding"] as? Bool == true)
        #expect(body["AllowAudioStreamCopy"] as? Bool == true)
    }

    @Test func jellyfinDefaultKeepsCopyLanes() throws {
        let request = try JellyfinPlayback.playbackInfoRequest(
            server: jfServer, token: "token-abc", identity: jfIdentity,
            itemId: "movie-1", userId: "user-1", maxStreamingBitrate: 8_000_000)
        let body = try bodyJSON(request)
        #expect(body["EnableDirectPlay"] as? Bool == true)
        #expect(body["EnableDirectStream"] as? Bool == true)
        #expect(body["AllowVideoStreamCopy"] as? Bool == true)
    }

    @Test func embyForceTranscodeDisablesCopyLanes() throws {
        let request = try EmbyPlayback.playbackInfoRequest(
            server: embyServer, token: "token-abc", identity: embyIdentity,
            userId: "user-1", itemId: "movie-1", maxStreamingBitrate: 8_000_000,
            forcePlaybackTranscode: true)
        let body = try bodyJSON(request)
        #expect(body["EnableDirectPlay"] as? Bool == false)
        #expect(body["EnableDirectStream"] as? Bool == false)
        #expect(body["AllowVideoStreamCopy"] as? Bool == false)
        #expect(body["EnableTranscoding"] as? Bool == true)
        #expect(body["AllowAudioStreamCopy"] as? Bool == true)
    }

    @Test func embyDefaultKeepsCopyLanes() throws {
        let request = try EmbyPlayback.playbackInfoRequest(
            server: embyServer, token: "token-abc", identity: embyIdentity,
            userId: "user-1", itemId: "movie-1", maxStreamingBitrate: 8_000_000)
        let body = try bodyJSON(request)
        #expect(body["EnableDirectPlay"] as? Bool == true)
        #expect(body["EnableDirectStream"] as? Bool == true)
        #expect(body["AllowVideoStreamCopy"] as? Bool == true)
    }
}
