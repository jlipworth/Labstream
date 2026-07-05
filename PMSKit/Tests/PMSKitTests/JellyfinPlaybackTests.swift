import Foundation
import Testing
@testable import PMSKit

@Suite("Jellyfin playback")
struct JellyfinPlaybackTests {
    private let server = URL(string: "https://jellyfin.example.test/base")!
    private let identity = JellyfinClientIdentity(client: "Labstream", device: "Apple Vision Pro", deviceId: "device-123", version: "0.1.0")

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
        #expect(profile["Name"] as? String == "Labstream")
        #expect(profile["MaxStreamingBitrate"] as? Int == 8_000_000)
        let directProfiles = try #require(profile["DirectPlayProfiles"] as? [[String: Any]])
        let mpegTSProfile = try #require(directProfiles.first { $0["Container"] as? String == "mpegts" })
        #expect(mpegTSProfile["VideoCodec"] as? String == "h264")
        let transcodeProfiles = try #require(profile["TranscodingProfiles"] as? [[String: Any]])
        let hlsProfile = try #require(transcodeProfiles.first)
        #expect(hlsProfile["Container"] as? String == "ts")
        #expect(hlsProfile["Protocol"] as? String == "hls")
        // h264 first (encode target); hevc enables MKV HEVC video-copy remux (GH #196).
        #expect(hlsProfile["VideoCodec"] as? String == "h264,hevc")
        #expect(hlsProfile["AudioCodec"] as? String == "aac")
        #expect(hlsProfile["BreakOnNonKeyFrames"] as? Bool == false)
    }

    @Test func downloadPlaybackInfoRequestPostsCompatibleStaticMp4Profile() throws {
        let request = try JellyfinPlayback.downloadPlaybackInfoRequest(
            server: server,
            token: "token-abc",
            identity: identity,
            itemId: "movie-1",
            userId: "user-1",
            mediaSourceId: "source-1",
            maxStaticBitrate: 200_000_000)

        #expect(request.url == URL(string: "https://jellyfin.example.test/base/Items/movie-1/PlaybackInfo"))
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["UserId"] as? String == "user-1")
        #expect(object["MediaSourceId"] as? String == "source-1")
        #expect(object["MaxStaticBitrate"] as? Int == 200_000_000)
        #expect(object["AllowVideoStreamCopy"] as? Bool == true)
        let profile = try #require(object["DeviceProfile"] as? [String: Any])
        #expect(profile["Name"] as? String == "Labstream-Compatible-Download")
        let transcoding = try #require(profile["TranscodingProfiles"] as? [[String: Any]])
        let first = try #require(transcoding.first)
        #expect(first["Container"] as? String == "mp4")
        #expect(first["Protocol"] as? String == "http")
        #expect(first["Context"] as? String == "Static")
        #expect(first["VideoCodec"] as? String == "h264,hevc")
    }

    @Test func downloadDecisionSurfacesDirectStreamAndCodecs() throws {
        let response = try JellyfinPlaybackInfoResponse.decode(from: Data(#"""
        {
          "PlaySessionId": "download-play-1",
          "MediaSources": [{
            "Id": "source-1",
            "Container": "mkv",
            "Size": 123456789,
            "Bitrate": 9000000,
            "SupportsDirectPlay": false,
            "SupportsDirectStream": true,
            "SupportsTranscoding": true,
            "TranscodeReasons": ["ContainerNotSupported"],
            "MediaStreams": [
              { "Index": 0, "Type": "Video", "Codec": "hevc" },
              { "Index": 1, "Type": "Audio", "Codec": "dts" }
            ]
          }]
        }
        """#.utf8))

        let decision = try JellyfinPlayback.downloadDecision(response: response,
                                                            preferredMediaSourceId: "source-1")
        #expect(decision.playSessionId == "download-play-1")
        #expect(decision.mediaSourceId == "source-1")
        #expect(decision.supportsDirectStream == true)
        #expect(decision.container == "mkv")
        #expect(decision.size == 123456789)
        #expect(decision.videoCodec == "hevc")
        #expect(decision.audioCodec == "dts")
        #expect(decision.transcodeReasons == ["ContainerNotSupported"])
    }

    @Test func resolvesServerRelativeTranscodingURLFromPlaybackInfoWithStableHLSOverrides() throws {
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
              { "Index": 2, "Type": "Audio", "Codec": "truehd", "Language": "eng", "DisplayTitle": "English TrueHD Atmos 7.1", "IsDefault": true, "Channels": 8 },
              { "Index": 4, "Type": "Audio", "Codec": "ac3", "Language": "eng", "DisplayTitle": "English AC3 5.1", "Channels": 6 }
            ],
            "SupportsDirectPlay": false,
            "SupportsDirectStream": false,
            "SupportsTranscoding": true,
            "TranscodingUrl": "/Videos/movie-1/master.m3u8?MediaSourceId=source-1&PlaySessionId=play-1&api_key=server-token&AudioStreamIndex=2&VideoBitrate=88000000&AudioCodec=ac3&AudioBitrate=448000&AllowAudioStreamCopy=true&SegmentContainer=ts&BreakOnNonKeyFrames=True",
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
            startTimeTicks: 27_000_000_000,
            maxVideoBitrate: 3_000_000,
            maxWidth: 1280,
            maxHeight: 720,
            audioBitrate: 256_000)

        let components = try #require(URLComponents(url: result.url, resolvingAgainstBaseURL: false))
        let queryItems = components.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
        #expect(result.url.scheme == "https")
        #expect(result.url.host == "jellyfin.example.test")
        #expect(components.path == "/base/Videos/movie-1/master.m3u8")
        #expect(query["MediaSourceId"] == "source-1")
        #expect(query["PlaySessionId"] == "play-1")
        #expect(query["api_key"] == "server-token")
        #expect(query["VideoBitrate"] == "3000000")
        #expect(query["MaxWidth"] == "1280")
        #expect(query["MaxHeight"] == "720")
        #expect(query["AudioCodec"] == "aac")
        #expect(query["AudioBitrate"] == "256000")
        #expect(query["TranscodingMaxAudioChannels"] == "6")
        #expect(query["AllowAudioStreamCopy"] == "false")
        #expect(query["AudioStreamIndex"] == "4")
        #expect(query["StartTimeTicks"] == nil)
        #expect(query["SegmentContainer"] == "ts")
        #expect(query["BreakOnNonKeyFrames"] == "false")
        #expect(queryItems.filter { $0.name.caseInsensitiveCompare("AudioStreamIndex") == .orderedSame }.count == 1)
        #expect(queryItems.filter { $0.name.caseInsensitiveCompare("VideoBitrate") == .orderedSame }.count == 1)
        #expect(queryItems.filter { $0.name.caseInsensitiveCompare("AudioCodec") == .orderedSame }.count == 1)
        #expect(queryItems.filter { $0.name.caseInsensitiveCompare("AudioBitrate") == .orderedSame }.count == 1)
        #expect(queryItems.filter { $0.name.caseInsensitiveCompare("AllowAudioStreamCopy") == .orderedSame }.count == 1)
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
        #expect(result.sourceMetadata.audioCodec == "ac3")
        #expect(result.sourceMetadata.bitrate == 8200)
    }

    @Test func resolveStreamRejectsCrossOriginTranscodingURLBeforeAuthHeaders() throws {
        let response = try JellyfinPlaybackInfoResponse.decode(from: Data(#"""
        {
          "PlaySessionId": "play-evil",
          "MediaSources": [{
            "Id": "source-evil",
            "SupportsDirectPlay": false,
            "SupportsDirectStream": false,
            "SupportsTranscoding": true,
            "TranscodingUrl": "https://evil.example.test/Videos/movie-1/master.m3u8?api_key=server-token",
            "RequiredHttpHeaders": { "X-Leak-Canary": "should-not-be-used" }
          }]
        }
        """#.utf8))

        #expect(throws: JellyfinPlaybackError.invalidURL) {
            _ = try JellyfinPlayback.resolveStream(
                response: response,
                server: server,
                identity: identity,
                token: "token-abc",
                itemId: "movie-1")
        }
    }

    @Test func explicitAudioStreamIndexWinsOverCompatibleAudioFallback() throws {
        let response = try JellyfinPlaybackInfoResponse.decode(from: Data(#"""
        {
          "PlaySessionId": "play-1",
          "MediaSources": [{
            "Id": "source-1",
            "Container": "mkv",
            "MediaStreams": [
              { "Index": 0, "Type": "Video", "Codec": "hevc", "Width": 3840, "Height": 2160 },
              { "Index": 2, "Type": "Audio", "Codec": "truehd", "Language": "eng", "DisplayTitle": "English TrueHD Atmos 7.1", "IsDefault": true, "Channels": 8 },
              { "Index": 4, "Type": "Audio", "Codec": "ac3", "Language": "eng", "DisplayTitle": "English AC3 5.1", "Channels": 6 }
            ],
            "SupportsDirectPlay": false,
            "SupportsDirectStream": false,
            "SupportsTranscoding": true,
            "TranscodingUrl": "/Videos/movie-1/master.m3u8?MediaSourceId=source-1&PlaySessionId=play-1&api_key=server-token&AudioStreamIndex=4",
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
            maxVideoBitrate: 3_000_000,
            maxWidth: 1280,
            maxHeight: 720,
            audioBitrate: 256_000,
            audioStreamIndex: 2)

        let components = try #require(URLComponents(url: result.url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["AudioStreamIndex"] == "2")
        #expect(result.sourceMetadata.audioCodec == "truehd")
    }

    @Test func transcodingURLAlwaysReportsTranscodeEvenWhenDirectStreamSupported() throws {
        let response = try JellyfinPlaybackInfoResponse.decode(from: Data(#"""
        {
          "PlaySessionId": "play-1",
          "MediaSources": [{
            "Id": "source-1",
            "Container": "mkv",
            "SupportsDirectPlay": false,
            "SupportsDirectStream": true,
            "SupportsTranscoding": true,
            "TranscodingUrl": "/Videos/movie-1/master.m3u8?MediaSourceId=source-1&PlaySessionId=play-1&api_key=server-token",
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

        #expect(result.playMethod == .transcode)
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


    @Test func progressRequestsBuildExpectedBodies() throws {
        let progress = try JellyfinPlayback.progressRequest(
            server: server,
            token: "token-abc",
            identity: identity,
            userId: "user-1",
            itemId: "movie-1",
            mediaSourceId: "source-1",
            playSessionId: "play-1",
            playMethod: .transcode,
            positionTicks: 50_000_000,
            isPaused: false)

        let url = try #require(progress.url)
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.path == "/base/Sessions/Playing/Progress")
        #expect(progress.httpMethod == "POST")
        #expect(progress.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"token-abc\"") == true)
        let body = try #require(progress.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["UserId"] as? String == "user-1")
        #expect(object["ItemId"] as? String == "movie-1")
        #expect(object["MediaSourceId"] as? String == "source-1")
        #expect(object["PlaySessionId"] as? String == "play-1")
        #expect(object["PositionTicks"] as? Int == 50_000_000)
        #expect(object["IsPaused"] as? Bool == false)
        #expect(object["PlayMethod"] as? String == "Transcode")

        let ping = try JellyfinPlayback.pingRequest(
            server: server, token: "token-abc", identity: identity, playSessionId: "play-1")
        let pingURL = try #require(ping.url)
        let pingComps = try #require(URLComponents(url: pingURL, resolvingAgainstBaseURL: false))
        #expect(pingComps.path == "/base/Sessions/Playing/Ping")
        #expect(pingComps.queryItems?.first(where: { $0.name == "PlaySessionId" })?.value == "play-1")
        #expect(ping.httpMethod == "POST")

        let stopped = try JellyfinPlayback.stoppedRequest(
            server: server,
            token: "token-abc",
            identity: identity,
            userId: "user-1",
            itemId: "movie-1",
            mediaSourceId: "source-1",
            playSessionId: "play-1",
            playMethod: .transcode,
            positionTicks: 60_000_000)
        #expect(stopped.url?.path == "/base/Sessions/Playing/Stopped")
        #expect(stopped.httpMethod == "POST")
        let stoppedBody = try #require(stopped.httpBody)
        let stoppedObject = try #require(JSONSerialization.jsonObject(with: stoppedBody) as? [String: Any])
        #expect(stoppedObject["ItemId"] as? String == "movie-1")
        #expect(stoppedObject["MediaSourceId"] as? String == "source-1")
        #expect(stoppedObject["PlaySessionId"] as? String == "play-1")
        #expect(stoppedObject["PositionTicks"] as? Int == 60_000_000)
        #expect(stoppedObject["IsPaused"] as? Bool == false)
        #expect(stoppedObject["PlayMethod"] as? String == "Transcode")
    }

}
