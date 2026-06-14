import Foundation
import Testing
@testable import PMSKit

@Suite("Jellyfin playback")
struct JellyfinPlaybackTests {
    private let server = URL(string: "https://jellyfin.example.test/base")!
    private let identity = JellyfinClientIdentity(client: "VisionPlex", device: "Apple Vision Pro", deviceId: "device-123", version: "0.1.0")

    @Test func playbackInfoRequestPostsDeviceProfileAndPlaybackOptions() throws {
        let request = try JellyfinPlayback.playbackInfoRequest(
            server: server,
            token: "token-abc",
            identity: identity,
            itemId: "movie-1",
            userId: "user-1",
            mediaSourceId: "source-1",
            startTimeTicks: 12_300_000_000,
            maxStreamingBitrate: 8_000_000)

        #expect(request.url == URL(string: "https://jellyfin.example.test/base/Items/movie-1/PlaybackInfo"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"token-abc\"") == true)

        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["UserId"] as? String == "user-1")
        #expect(object["MediaSourceId"] as? String == "source-1")
        #expect(object["StartTimeTicks"] as? Int == 12_300_000_000)
        #expect(object["MaxStreamingBitrate"] as? Int == 8_000_000)
        #expect(object["EnableDirectPlay"] as? Bool == true)
        #expect(object["EnableDirectStream"] as? Bool == true)
        #expect(object["EnableTranscoding"] as? Bool == true)
        let profile = try #require(object["DeviceProfile"] as? [String: Any])
        #expect(profile["Name"] as? String == "VisionPlex")
        #expect(profile["MaxStreamingBitrate"] as? Int == 8_000_000)
    }

    @Test func resolvesServerRelativeTranscodingURLFromPlaybackInfo() throws {
        let response = try JellyfinPlaybackInfoResponse.decode(from: Data(#"""
        {
          "PlaySessionId": "play-1",
          "MediaSources": [{
            "Id": "source-1",
            "Name": "Main",
            "Container": "mkv",
            "ETag": "tag-1",
            "SupportsDirectPlay": false,
            "SupportsDirectStream": false,
            "SupportsTranscoding": true,
            "TranscodingUrl": "/Videos/movie-1/master.m3u8?mediaSourceId=source-1&playSessionId=play-1&api_key=server-token",
            "TranscodingSubProtocol": "hls",
            "TranscodingContainer": "ts"
          }]
        }
        """#.utf8))

        let result = try JellyfinPlayback.resolveStream(
            response: response,
            server: server,
            identity: identity,
            token: "token-abc",
            itemId: "movie-1")

        #expect(result.url == URL(string: "https://jellyfin.example.test/base/Videos/movie-1/master.m3u8?mediaSourceId=source-1&playSessionId=play-1"))
        #expect(result.playSessionId == "play-1")
        #expect(result.mediaSourceId == "source-1")
        #expect(result.playMethod == .transcode)
        #expect(result.requiredHTTPHeaders["Authorization"]?.contains("Token=\"token-abc\"") == true)
    }

    @Test func buildsStaticVideoStreamURLWhenNoTranscodingURLIsNeeded() throws {
        let response = try JellyfinPlaybackInfoResponse.decode(from: Data(#"""
        {
          "PlaySessionId": "play-1",
          "MediaSources": [{
            "Id": "source-1",
            "Container": "mp4",
            "ETag": "tag-1",
            "SupportsDirectPlay": true,
            "SupportsDirectStream": true,
            "SupportsTranscoding": true
          }]
        }
        """#.utf8))

        let result = try JellyfinPlayback.resolveStream(
            response: response,
            server: server,
            identity: identity,
            token: "token-abc",
            itemId: "movie-1")

        let components = try #require(URLComponents(url: result.url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "jellyfin.example.test")
        #expect(components.path == "/base/Videos/movie-1/stream.mp4")
        let queryItems: [URLQueryItem] = components.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
        #expect(query["Static"] == "true")
        #expect(query["mediaSourceId"] == "source-1")
        #expect(query["PlaySessionId"] == "play-1")
        #expect(query["Tag"] == "tag-1")
        #expect(query["api_key"] == nil)
        #expect(query["apiKey"] == nil)
        #expect(result.requiredHTTPHeaders["Authorization"]?.contains("Token=\"token-abc\"") == true)
        #expect(result.playMethod == .directPlay)
    }
}
