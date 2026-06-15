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
            maxStreamingBitrate: 8_000_000,
            audioStreamIndex: 3,
            subtitleStreamIndex: 7)

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
        #expect(object["AudioStreamIndex"] as? Int == 3)
        #expect(object["SubtitleStreamIndex"] as? Int == 7)
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
            "Bitrate": 8200000,
            "ETag": "tag-1",
            "MediaStreams": [
              { "Index": 0, "Type": "Video", "Codec": "hevc", "Width": 3840, "Height": 2160 },
              { "Index": 1, "Type": "Audio", "Codec": "eac3", "DisplayTitle": "English EAC3 5.1", "Channels": 6 }
            ],
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
            itemId: "movie-1",
            maxWidth: 1280,
            maxHeight: 720,
            audioBitrate: 256_000)

        #expect(result.url == URL(string: "https://jellyfin.example.test/base/Videos/movie-1/master.m3u8?mediaSourceId=source-1&playSessionId=play-1&api_key=server-token&MaxWidth=1280&MaxHeight=720&AudioBitrate=256000"))
        #expect(result.playSessionId == "play-1")
        #expect(result.mediaSourceId == "source-1")
        #expect(result.playMethod == .transcode)
        // Jellyfin HLS needs the server-generated URL token to flow into child playlists/segments;
        // AVFoundation does not reliably apply custom headers to every HLS subresource.
        #expect(result.url.query()?.contains("api_key=server-token") == true)
        #expect(result.url.query()?.contains("MaxWidth=1280") == true)
        #expect(result.url.query()?.contains("MaxHeight=720") == true)
        #expect(result.url.query()?.contains("AudioBitrate=256000") == true)
        #expect(result.requiredHTTPHeaders["Authorization"]?.contains("Token=\"token-abc\"") == true)
        #expect(result.sourceMetadata.container == "mkv")
        #expect(result.sourceMetadata.width == 3840)
        #expect(result.sourceMetadata.height == 2160)
        #expect(result.sourceMetadata.videoCodec == "hevc")
        #expect(result.sourceMetadata.audioCodec == "eac3")
        #expect(result.sourceMetadata.bitrate == 8200)
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
