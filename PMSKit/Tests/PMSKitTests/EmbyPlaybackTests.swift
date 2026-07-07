import Foundation
import Testing
@testable import PMSKit

@Suite("Emby playback")
struct EmbyPlaybackTests {
    private let server = URL(string: "https://emby.example.test/emby")!
    private let identity = EmbyClientIdentity(client: "Labstream", device: "Apple Vision Pro", deviceId: "device-123", version: "0.1.0")

    @Test func playbackInfoIsPostWithUserIdInQueryAndBodyPlusDeviceProfile() throws {
        let request = try EmbyPlayback.playbackInfoRequest(
            server: server,
            token: "token-abc",
            identity: identity,
            userId: "user-9",
            itemId: "movie-1",
            mediaSourceId: "mediasource_abc",
            startTimeTicks: 12_300_000_000,
            maxStreamingBitrate: 8_000_000,
            audioStreamIndex: 3,
            subtitleStreamIndex: 7)

        let url = try #require(request.url)
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(request.httpMethod == "POST")
        #expect(comps.path == "/emby/Items/movie-1/PlaybackInfo")
        // UserId in query.
        #expect(q["UserId"] == "user-9")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "token-abc")

        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        // UserId in body too.
        #expect(object["UserId"] as? String == "user-9")
        #expect(object["MediaSourceId"] as? String == "mediasource_abc")
        #expect(object["StartTimeTicks"] as? Int == 12_300_000_000)
        #expect(object["MaxStreamingBitrate"] as? Int == 8_000_000)
        #expect(object["AudioStreamIndex"] as? Int == 3)
        #expect(object["SubtitleStreamIndex"] as? Int == 7)
        #expect(object["EnableDirectPlay"] as? Bool == true)
        #expect(object["EnableDirectStream"] as? Bool == true)
        #expect(object["EnableTranscoding"] as? Bool == true)
        #expect(object["AllowVideoStreamCopy"] as? Bool == true)
        #expect(object["AllowAudioStreamCopy"] as? Bool == true)
        // DIVERGENCE FROM JELLYFIN: AutoOpenLiveStream is false.
        #expect(object["AutoOpenLiveStream"] as? Bool == false)
        let profile = try #require(object["DeviceProfile"] as? [String: Any])
        #expect(profile["Name"] as? String == "Labstream")
        #expect(profile["MaxStreamingBitrate"] as? Int == 8_000_000)
        let transcodeProfiles = try #require(profile["TranscodingProfiles"] as? [[String: Any]])
        let hlsProfile = try #require(transcodeProfiles.first)
        // h264 first (encode target); hevc enables MKV HEVC video-copy remux (GH #196).
        #expect(hlsProfile["VideoCodec"] as? String == "h264,hevc")
    }

    @Test func resolveStreamPrefersTranscodingURLPrependsBaseAndKeepsApiKeyWithNoAuthHeader() throws {
        let response = try EmbyPlaybackInfoResponse.decode(from: Data(#"""
        {
          "PlaySessionId": "play-1",
          "MediaSources": [{
            "Id": "mediasource_abc",
            "Name": "Main",
            "Container": "mkv",
            "Bitrate": 8200000,
            "Width": 3840,
            "Height": 2160,
            "VideoCodec": "hevc",
            "AudioCodec": "ac3",
            "MediaStreams": [
              { "Index": 0, "Type": "Video", "Codec": "hevc", "Width": 3840, "Height": 2160 },
              { "Index": 1, "Type": "Audio", "Codec": "ac3", "Language": "eng", "IsDefault": true, "Channels": 6 }
            ],
            "SupportsDirectPlay": false,
            "SupportsDirectStream": false,
            "SupportsTranscoding": true,
            "TranscodingUrl": "/videos/movie-1/master.m3u8?DeviceId=device-123&MediaSourceId=mediasource_abc&PlaySessionId=play-1&api_key=server-token&VideoCodec=h264&AudioCodec=aac,ac3&TranscodeReasons=ContainerNotSupported",
            "TranscodingSubProtocol": "hls",
            "TranscodingContainer": "ts"
          }]
        }
        """#.utf8))

        let result = try EmbyPlayback.resolveStream(
            response: response,
            server: server,
            identity: identity,
            token: "token-abc",
            userId: "user-9",
            itemId: "movie-1")

        let comps = try #require(URLComponents(url: result.url, resolvingAgainstBaseURL: false))
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(result.url.scheme == "https")
        #expect(result.url.host == "emby.example.test")
        // Lowercase /videos/, with the server base path /emby preserved.
        #expect(comps.path == "/emby/videos/movie-1/master.m3u8")
        #expect(q["MediaSourceId"] == "mediasource_abc")
        #expect(q["PlaySessionId"] == "play-1")
        // Token rides in api_key query; HLS children inherit it.
        #expect(q["api_key"] == "server-token")
        #expect(result.playSessionId == "play-1")
        #expect(result.mediaSourceId == "mediasource_abc")
        #expect(result.playMethod == .transcode)
        #expect(result.usesServerEncoding == true)
        // DIVERGENCE FROM JELLYFIN: no Authorization header injected for HLS.
        #expect(result.requiredHTTPHeaders["Authorization"] == nil)
        #expect(result.sourceMetadata.container == "mkv")
        #expect(result.sourceMetadata.width == 3840)
        #expect(result.sourceMetadata.height == 2160)
        #expect(result.sourceMetadata.videoCodec == "hevc")
        #expect(result.sourceMetadata.bitrate == 8200)
    }

    @Test func cappedTranscodeSteersCompatibleAudioOntoTranscodingURL() throws {
        // Default track is high-risk (TrueHD 7.1); a compatible AC3 5.1 alternate exists.
        // The server minted its URL against the default — the client-side steering must pin
        // the compatible track on the master URL (the Emby twin of Jellyfin's overrides).
        let response = try EmbyPlaybackInfoResponse.decode(from: Data(#"""
        {
          "PlaySessionId": "play-1",
          "MediaSources": [{
            "Id": "mediasource_abc",
            "Name": "Main",
            "Container": "mkv",
            "MediaStreams": [
              { "Index": 0, "Type": "Video", "Codec": "hevc", "Width": 3840, "Height": 2160 },
              { "Index": 2, "Type": "Audio", "Codec": "truehd", "Language": "eng", "DisplayTitle": "English TrueHD Atmos 7.1", "IsDefault": true, "Channels": 8 },
              { "Index": 4, "Type": "Audio", "Codec": "ac3", "Language": "eng", "DisplayTitle": "English AC3 5.1", "Channels": 6 }
            ],
            "SupportsDirectPlay": false,
            "SupportsDirectStream": false,
            "SupportsTranscoding": true,
            "TranscodingUrl": "/videos/movie-1/master.m3u8?DeviceId=device-123&MediaSourceId=mediasource_abc&PlaySessionId=play-1&api_key=server-token&AudioStreamIndex=2",
            "TranscodingSubProtocol": "hls",
            "TranscodingContainer": "ts"
          }]
        }
        """#.utf8))

        let result = try EmbyPlayback.resolveStream(
            response: response,
            server: server,
            identity: identity,
            token: "token-abc",
            userId: "user-9",
            itemId: "movie-1",
            audioBitrate: 256_000)

        let comps = try #require(URLComponents(url: result.url, resolvingAgainstBaseURL: false))
        let queryItems = comps.queryItems ?? []
        let q = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
        #expect(q["AudioStreamIndex"] == "4")
        #expect(queryItems.filter { $0.name.caseInsensitiveCompare("AudioStreamIndex") == .orderedSame }.count == 1)
        // The reported metadata matches the steered track, not the server default.
        #expect(result.sourceMetadata.audioCodec == "ac3")
    }

    @Test func uncappedTranscodeLeavesServerMintedAudioSelectionAlone() throws {
        let response = try EmbyPlaybackInfoResponse.decode(from: Data(#"""
        {
          "PlaySessionId": "play-1",
          "MediaSources": [{
            "Id": "mediasource_abc",
            "MediaStreams": [
              { "Index": 0, "Type": "Video", "Codec": "hevc" },
              { "Index": 2, "Type": "Audio", "Codec": "truehd", "IsDefault": true, "Channels": 8 },
              { "Index": 4, "Type": "Audio", "Codec": "ac3", "Channels": 6 }
            ],
            "SupportsDirectPlay": false,
            "SupportsDirectStream": false,
            "SupportsTranscoding": true,
            "TranscodingUrl": "/videos/movie-1/master.m3u8?PlaySessionId=play-1&api_key=server-token&AudioStreamIndex=2",
            "TranscodingSubProtocol": "hls",
            "TranscodingContainer": "ts"
          }]
        }
        """#.utf8))

        let result = try EmbyPlayback.resolveStream(
            response: response,
            server: server,
            identity: identity,
            token: "token-abc",
            userId: "user-9",
            itemId: "movie-1")

        let comps = try #require(URLComponents(url: result.url, resolvingAgainstBaseURL: false))
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        // No cap → no steering; the server's own selection stands untouched.
        #expect(q["AudioStreamIndex"] == "2")
    }

    @Test func resolveStreamClassifiesTranscodingURLAsTranscodeEvenWhenDirectStreamSupported() throws {
        let response = try EmbyPlaybackInfoResponse.decode(from: Data(#"""
        {
          "PlaySessionId": "play-hls-direct-stream",
          "MediaSources": [{
            "Id": "mediasource_hls",
            "Container": "mkv",
            "SupportsDirectPlay": false,
            "SupportsDirectStream": true,
            "SupportsTranscoding": true,
            "TranscodingUrl": "/videos/movie-hls/master.m3u8?DeviceId=device-123&MediaSourceId=mediasource_hls&PlaySessionId=play-hls-direct-stream&api_key=server-token",
            "TranscodingSubProtocol": "hls",
            "TranscodingContainer": "ts"
          }]
        }
        """#.utf8))

        let result = try EmbyPlayback.resolveStream(
            response: response,
            server: server,
            identity: identity,
            token: "token-abc",
            userId: "user-9",
            itemId: "movie-hls")

        #expect(result.playMethod == .transcode)
        #expect(result.usesServerEncoding)
    }

    @Test func resolveStreamFallsBackToDirectStreamURLAndAddsApiKeyWhenRequested() throws {
        let response = try EmbyPlaybackInfoResponse.decode(from: Data(#"""
        {
          "PlaySessionId": "play-2",
          "MediaSources": [{
            "Id": "mediasource_def",
            "Container": "mp4",
            "SupportsDirectPlay": false,
            "SupportsDirectStream": true,
            "SupportsTranscoding": true,
            "DirectStreamUrl": "/videos/movie-2/stream.mp4?MediaSourceId=mediasource_def&PlaySessionId=play-2",
            "AddApiKeyToDirectStreamUrl": true
          }]
        }
        """#.utf8))

        let result = try EmbyPlayback.resolveStream(
            response: response,
            server: server,
            identity: identity,
            token: "token-abc",
            userId: "user-9",
            itemId: "movie-2")

        let comps = try #require(URLComponents(url: result.url, resolvingAgainstBaseURL: false))
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(comps.path == "/emby/videos/movie-2/stream.mp4")
        #expect(result.playMethod == .directStream)
        #expect(result.usesServerEncoding == false)
        // AddApiKeyToDirectStreamUrl=true -> api_key present, no header token.
        #expect(q["api_key"] == "token-abc")
        #expect(result.requiredHTTPHeaders["X-Emby-Token"] == nil)
    }

    @Test func resolveStreamRejectsCrossOriginDirectStreamURLBeforeAppendingApiKey() throws {
        let response = try EmbyPlaybackInfoResponse.decode(from: Data(#"""
        {
          "PlaySessionId": "play-evil",
          "MediaSources": [{
            "Id": "mediasource_evil",
            "SupportsDirectPlay": false,
            "SupportsDirectStream": true,
            "SupportsTranscoding": true,
            "DirectStreamUrl": "https://evil.example.test/videos/movie-2/stream.mp4",
            "AddApiKeyToDirectStreamUrl": true
          }]
        }
        """#.utf8))

        #expect(throws: EmbyPlaybackError.invalidURL) {
            _ = try EmbyPlayback.resolveStream(
                response: response,
                server: server,
                identity: identity,
                token: "token-abc",
                userId: "user-9",
                itemId: "movie-2")
        }
    }

    @Test func resolveStreamSynthesizesDirectPlayURLWhenNoServerURLs() throws {
        let response = try EmbyPlaybackInfoResponse.decode(from: Data(#"""
        {
          "PlaySessionId": "play-3",
          "MediaSources": [{
            "Id": "mediasource_ghi",
            "Container": "mp4",
            "ETag": "tag-1",
            "SupportsDirectPlay": true,
            "SupportsDirectStream": true,
            "SupportsTranscoding": true
          }]
        }
        """#.utf8))

        let result = try EmbyPlayback.resolveStream(
            response: response,
            server: server,
            identity: identity,
            token: "token-abc",
            userId: "user-9",
            itemId: "movie-3")

        let comps = try #require(URLComponents(url: result.url, resolvingAgainstBaseURL: false))
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(comps.path == "/emby/videos/movie-3/stream.mp4")
        #expect(q["Static"] == "true")
        #expect(q["MediaSourceId"] == "mediasource_ghi")
        #expect(q["PlaySessionId"] == "play-3")
        #expect(q["api_key"] == "token-abc")
        #expect(q["Tag"] == "tag-1")
        #expect(result.playMethod == .directPlay)
        #expect(result.usesServerEncoding == false)
    }

    @Test func resolveStreamThrowsWhenPlaySessionIdMissing() throws {
        let response = try EmbyPlaybackInfoResponse.decode(from: Data(#"""
        { "MediaSources": [{ "Id": "mediasource_abc", "SupportsDirectPlay": true }] }
        """#.utf8))

        #expect(throws: EmbyPlaybackError.missingPlaySessionId) {
            _ = try EmbyPlayback.resolveStream(
                response: response, server: server, identity: identity,
                token: "token-abc", userId: "user-9", itemId: "movie-1")
        }
    }

    @Test func resolveStreamThrowsWhenNoMediaSources() throws {
        let response = try EmbyPlaybackInfoResponse.decode(from: Data(#"""
        { "PlaySessionId": "play-1", "MediaSources": [] }
        """#.utf8))

        #expect(throws: EmbyPlaybackError.noMediaSources) {
            _ = try EmbyPlayback.resolveStream(
                response: response, server: server, identity: identity,
                token: "token-abc", userId: "user-9", itemId: "movie-1")
        }
    }

    @Test func activeEncodingStopRequestShapeViaLibrary() throws {
        // Cleanup invariant: stop must DELETE /Videos/ActiveEncodings for encoded sources.
        let request = try EmbyLibrary.activeEncodingStopRequest(
            server: server, token: "token-abc", identity: identity,
            userId: "user-9", deviceId: "device-123", playSessionId: "play-1")

        #expect(request.httpMethod == "DELETE")
        let url = try #require(request.url)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.path == "/emby/Videos/ActiveEncodings")
    }

    @Test func progressRequestsBuildExpectedBodies() throws {
        let stopped = try EmbyPlayback.stoppedRequest(
            server: server, token: "token-abc", identity: identity, userId: "user-9",
            itemId: "movie-1", mediaSourceId: "mediasource_abc", playSessionId: "play-1",
            playMethod: .transcode, positionTicks: 50_000_000)

        let url = try #require(stopped.url)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.path == "/emby/Sessions/Playing/Stopped")
        #expect(stopped.httpMethod == "POST")
        let body = try #require(stopped.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["ItemId"] as? String == "movie-1")
        #expect(object["PlaySessionId"] as? String == "play-1")
        #expect(object["PositionTicks"] as? Int == 50_000_000)
        #expect(object["PlayMethod"] as? String == "Transcode")

        let ping = try EmbyPlayback.pingRequest(
            server: server, token: "token-abc", identity: identity, userId: "user-9", playSessionId: "play-1")
        let pingURL = try #require(ping.url)
        let pingComps = try #require(URLComponents(url: pingURL, resolvingAgainstBaseURL: false))
        #expect(pingComps.path == "/emby/Sessions/Playing/Ping")
        #expect(pingComps.queryItems?.first(where: { $0.name == "PlaySessionId" })?.value == "play-1")
    }
}

@Suite("Emby models")
struct EmbyModelsTests {
    @Test func movieBaseItemDtoMapsTicksToMillisecondsAndSyntheticImageRefs() throws {
        let data = Data(#"""
        {
          "Id": "movie-1",
          "Name": "The Matrix",
          "Type": "Movie",
          "ProductionYear": 1999,
          "Overview": "A hacker learns the truth.",
          "RunTimeTicks": 81600000000,
          "OfficialRating": "R",
          "CommunityRating": 8.7,
          "Genres": ["Action", "Sci-Fi"],
          "UserData": { "PlaybackPositionTicks": 6000000000, "Played": false, "PlayCount": 0, "IsFavorite": true },
          "ImageTags": { "Primary": "primary-tag" },
          "BackdropImageTags": ["backdrop-tag"],
          "MediaSources": [{
            "Id": "mediasource_abc",
            "Container": "mkv",
            "Bitrate": 8200000,
            "Width": 3840,
            "Height": 2160,
            "VideoCodec": "hevc",
            "AudioCodec": "ac3",
            "MediaStreams": [
              { "Index": 0, "Type": "Video", "Codec": "hevc" },
              { "Index": 1, "Type": "Audio", "Codec": "ac3", "Channels": 6, "IsDefault": true }
            ]
          }]
        }
        """#.utf8)

        let dto = try JSONDecoder().decode(EmbyBaseItemDto.self, from: data)
        let item = try #require(dto.toMediaItem())

        #expect(item.type == "movie")
        #expect(item.title == "The Matrix")
        #expect(item.year == 1999)
        // RunTimeTicks 81_600_000_000 / 10_000 = 8_160_000 ms.
        #expect(item.duration == 8_160_000)
        // PlaybackPositionTicks 6_000_000_000 / 10_000 = 600_000 ms.
        #expect(item.viewOffset == 600_000)
        #expect(item.rating == 8.7)
        #expect(item.contentRating == "R")
        #expect(item.thumb == "emby://item/movie-1/Primary?tag=primary-tag")
        #expect(item.art == "emby://item/movie-1/Backdrop?tag=backdrop-tag")
        // MediaSource Id carried verbatim (mediasource_<id>) into the part key.
        let part = try #require(item.media?.first?.part.first)
        #expect(part.key == "emby://item/movie-1/media/mediasource_abc")
        // Bitrate kbps conversion.
        #expect(item.media?.first?.bitrate == 8200)
    }

    @Test func episodeBaseItemDtoCarriesSeriesAndIndexFields() throws {
        let data = Data(#"""
        {
          "Id": "ep-1",
          "Name": "Pilot",
          "Type": "Episode",
          "RunTimeTicks": 25000000000,
          "SeriesId": "series-1",
          "SeriesName": "Example Show",
          "SeasonId": "season-1",
          "SeasonName": "Season 1",
          "ParentIndexNumber": 1,
          "IndexNumber": 1,
          "ImageTags": { "Primary": "ep-tag" }
        }
        """#.utf8)

        let dto = try JSONDecoder().decode(EmbyBaseItemDto.self, from: data)
        let item = try #require(dto.toMediaItem())

        #expect(item.type == "episode")
        #expect(item.grandparentTitle == "Example Show")
        #expect(item.grandparentRatingKey == "series-1")
        #expect(item.parentIndex == 1)
        #expect(item.index == 1)
        #expect(dto.seasonId == "season-1")
        #expect(dto.seasonName == "Season 1")
    }

    @Test func unknownItemTypeMapsToNil() throws {
        let data = Data(#"{ "Id": "x", "Name": "Folder", "Type": "Folder" }"#.utf8)
        let dto = try JSONDecoder().decode(EmbyBaseItemDto.self, from: data)
        #expect(dto.toMediaItem() == nil)
    }

    @Test func itemsResponseDecodesItemsAndTotal() throws {
        let data = Data(#"""
        {
          "Items": [
            { "Id": "movie-1", "Name": "A", "Type": "Movie" },
            { "Id": "movie-2", "Name": "B", "Type": "Movie" }
          ],
          "TotalRecordCount": 2
        }
        """#.utf8)

        let response = try EmbyItemsResponse.decode(from: data)
        #expect(response.items.count == 2)
        #expect(response.totalRecordCount == 2)
        #expect(response.items.compactMap { $0.toMediaItem()?.ratingKey } == ["movie-1", "movie-2"])
    }
}
