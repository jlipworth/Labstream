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

extension MediaBrowserForceTranscodeTests {
    /// GH #196 retest: an explicit subtitles-Off (-1 sentinel) must also drop the in-manifest
    /// subtitle renditions, or AVFoundation re-shows forced/default renditions after select(nil).
    @Test func jellyfinSubtitlesOffDropsManifestRenditions() throws {
        let offReq = try JellyfinPlayback.playbackInfoRequest(
            server: jfServer, token: "token-abc", identity: jfIdentity,
            itemId: "movie-1", userId: "user-1", maxStreamingBitrate: 8_000_000,
            subtitleStreamIndex: -1)
        let offBody = try bodyJSON(offReq)
        let offProfile = try #require(offBody["DeviceProfile"] as? [String: Any])
        let offTranscoding = try #require(offProfile["TranscodingProfiles"] as? [[String: Any]])
        #expect(offTranscoding.first?["EnableSubtitlesInManifest"] as? Bool == false)

        let defaultReq = try JellyfinPlayback.playbackInfoRequest(
            server: jfServer, token: "token-abc", identity: jfIdentity,
            itemId: "movie-1", userId: "user-1", maxStreamingBitrate: 8_000_000,
            subtitleStreamIndex: 3)
        let defaultBody = try bodyJSON(defaultReq)
        let defaultProfile = try #require(defaultBody["DeviceProfile"] as? [String: Any])
        let defaultTranscoding = try #require(defaultProfile["TranscodingProfiles"] as? [[String: Any]])
        #expect(defaultTranscoding.first?["EnableSubtitlesInManifest"] as? Bool == true)
    }
}
