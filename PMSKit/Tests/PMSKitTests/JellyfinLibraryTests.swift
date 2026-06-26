import Foundation
import Testing
@testable import PMSKit

@Suite("Jellyfin library")
struct JellyfinLibraryTests {
    private let server = URL(string: "https://jellyfin.example.test/base")!
    private let identity = JellyfinClientIdentity(client: "VisionPlay", device: "Apple Vision Pro", deviceId: "device-123", version: "0.1.0")

    @Test func decodesAuthenticationResult() throws {
        let result = try JSONDecoder().decode(JellyfinAuthenticationResult.self, from: Data(#"""
        {
          "User": { "Id": "user-1", "Name": "viewer" },
          "AccessToken": "token-abc",
          "ServerId": "server-1"
        }
        """#.utf8))

        #expect(result.user?.id == "user-1")
        #expect(result.user?.name == "viewer")
        #expect(result.accessToken == "token-abc")
        #expect(result.serverId == "server-1")
    }

    @Test func userViewsRequestCarriesUserAndAuth() throws {
        let request = try JellyfinLibrary.userViewsRequest(server: server, token: "token-abc", identity: identity, userId: "user-1")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(request.httpMethod == "GET")
        #expect(components.scheme == "https")
        #expect(components.host == "jellyfin.example.test")
        #expect(components.path == "/base/UserViews")
        #expect(query["userId"] == "user-1")
        #expect(query["includeExternalContent"] == "false")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"token-abc\"") == true)
    }

    @Test func itemsRequestCarriesVideoQueryShape() throws {
        let request = try JellyfinLibrary.itemsRequest(server: server, token: "token-abc", identity: identity, userId: "user-1", parentId: "view-1", recursive: false)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.path == "/base/Items")
        #expect(query["userId"] == "user-1")
        #expect(query["parentId"] == "view-1")
        #expect(query["recursive"] == "false")
        #expect(query["includeItemTypes"] == "Movie,Series,Season,Episode,Video")
        #expect(query["enableUserData"] == "true")
        #expect(query["fields"]?.contains("MediaSources") == true)
        #expect(query["fields"]?.contains("OfficialRating") == true)
        #expect(query["fields"]?.contains("CommunityRating") == true)
        #expect(query["fields"]?.contains("Genres") == true)
        #expect(query["fields"]?.contains("Chapters") == true)
    }

    @Test func itemsRequestCarriesSearchTerm() throws {
        let request = try JellyfinLibrary.itemsRequest(server: server,
                                                       token: "token-abc",
                                                       identity: identity,
                                                       userId: "user-1",
                                                       recursive: true,
                                                       startIndex: 25,
                                                       limit: 50,
                                                       searchTerm: "pilot",
                                                       nameStartsWith: "P",
                                                       includeItemTypes: "Movie",
                                                       fields: JellyfinLibrary.gridItemFields)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.path == "/base/Items")
        #expect(query["recursive"] == "true")
        #expect(query["startIndex"] == "25")
        #expect(query["limit"] == "50")
        #expect(query["searchTerm"] == "pilot")
        #expect(query["nameStartsWith"] == "P")
        #expect(query["includeItemTypes"] == "Movie")
        #expect(query["fields"] == JellyfinLibrary.gridItemFields)
    }

    @Test func audioStreamURLTargetsUniversalEndpointTokenless() throws {
        let url = try JellyfinLibrary.audioStreamURL(server: server,
                                                     identity: identity,
                                                     userId: "user-1",
                                                     itemId: "track-9")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.path == "/base/Audio/track-9/universal")
        #expect(query["UserId"] == "user-1")
        #expect(query["DeviceId"] == "device-123")
        // Default bitrate keeps lossless sources direct-playing.
        #expect(query["MaxStreamingBitrate"] == "140000000")
        #expect(query["AudioCodec"] == "aac")
        #expect(query["TranscodingProtocol"] == "hls")
        #expect(query["Container"]?.contains("flac") == true)
        #expect(query["Container"]?.contains("mp3") == true)
        // Token must NOT be baked into the stream URL — auth rides in the asset header.
        #expect(url.absoluteString.contains("token") == false)
        #expect(query["api_key"] == nil)
    }

    @Test func albumArtistsRequestTargetsDedicatedEndpoint() throws {
        // The folder-derived `MusicArtist` items browse is wrong for an Artists list (#111);
        // album artists must come from `/Artists/AlbumArtists`.
        let request = try JellyfinLibrary.albumArtistsRequest(server: server,
                                                              token: "token-abc",
                                                              identity: identity,
                                                              userId: "user-1",
                                                              parentId: "music-lib",
                                                              startIndex: 120,
                                                              limit: 60)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.path == "/base/Artists/AlbumArtists")
        #expect(query["parentId"] == "music-lib")
        #expect(query["userId"] == "user-1")
        #expect(query["startIndex"] == "120")
        #expect(query["limit"] == "60")
        #expect(query["recursive"] == "true")
        #expect(query["enableImages"] == "true")
        // No letter probe → no NameStartsWith on the plain page request.
        #expect(query["nameStartsWith"] == nil)
    }

    @Test func albumArtistsRequestEmitsNameStartsWithForRailProbe() throws {
        // The Artists A–Z rail probes each letter's count with `NameStartsWith=X`,
        // `Limit=1` and reads `TotalRecordCount` (#111).
        let request = try JellyfinLibrary.albumArtistsRequest(server: server,
                                                              token: "token-abc",
                                                              identity: identity,
                                                              userId: "user-1",
                                                              parentId: "music-lib",
                                                              limit: 1,
                                                              nameStartsWith: "B")
        let query = try queryMap(request)
        #expect(query["nameStartsWith"] == "B")
        #expect(query["limit"] == "1")
        #expect(query["parentId"] == "music-lib")
    }

    @Test func playlistItemsRequestPreservesPlaylistOrder() throws {
        // Playlist tracks must come from `/Playlists/{id}/Items` (playlist order), not a
        // `ParentId` items browse (which sorts) (#111).
        let request = try JellyfinLibrary.playlistItemsRequest(server: server,
                                                               token: "token-abc",
                                                               identity: identity,
                                                               userId: "user-1",
                                                               playlistId: "playlist-5",
                                                               startIndex: 0,
                                                               limit: 200)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.path == "/base/Playlists/playlist-5/Items")
        #expect(query["userId"] == "user-1")
        #expect(query["startIndex"] == "0")
        #expect(query["limit"] == "200")
        #expect(query["enableImages"] == "true")
        // No SortBy override — the endpoint returns the user's playlist order verbatim.
        #expect(query["sortBy"] == nil)
    }

    @Test func itemsRequestCarriesAlbumArtistAndArtistFilters() throws {
        // An album artist's albums (AlbumArtistIds) and full discography (ArtistIds) are
        // reached by filter, not by `parentId` — those entities are tag aggregates (#111).
        let albums = try JellyfinLibrary.itemsRequest(server: server, token: "t", identity: identity,
                                                      userId: "user-1", recursive: true,
                                                      includeItemTypes: "MusicAlbum",
                                                      albumArtistIds: "artist-7")
        let albumQuery = try queryMap(albums)
        #expect(albumQuery["albumArtistIds"] == "artist-7")
        #expect(albumQuery["artistIds"] == nil)

        let tracks = try JellyfinLibrary.itemsRequest(server: server, token: "t", identity: identity,
                                                      userId: "user-1", recursive: true,
                                                      includeItemTypes: "Audio",
                                                      artistIds: "artist-7")
        let trackQuery = try queryMap(tracks)
        #expect(trackQuery["artistIds"] == "artist-7")
        #expect(trackQuery["albumArtistIds"] == nil)
    }

    private func queryMap(_ request: URLRequest) throws -> [String: String] {
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test func audioStreamURLHonorsBitrateCap() throws {
        let url = try JellyfinLibrary.audioStreamURL(server: server,
                                                     identity: identity,
                                                     userId: "user-1",
                                                     itemId: "track-9",
                                                     maxStreamingBitrate: 256_000)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["MaxStreamingBitrate"] == "256000")
    }

    @Test func resumeItemsRequestTargetsContinueWatching() throws {
        let request = try JellyfinLibrary.resumeItemsRequest(server: server,
                                                             token: "token-abc",
                                                             identity: identity,
                                                             userId: "user-1",
                                                             parentId: "view-1",
                                                             limit: 12)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.path == "/base/UserItems/Resume")
        #expect(query["userId"] == "user-1")
        #expect(query["parentId"] == "view-1")
        #expect(query["limit"] == "12")
        #expect(query["includeItemTypes"] == "Movie,Episode,Video")
        #expect(query["enableUserData"] == "true")
        #expect(query["excludeActiveSessions"] == "false")
    }

    @Test func nextUpRequestTargetsShowsNextUp() throws {
        let request = try JellyfinLibrary.nextUpRequest(server: server,
                                                        token: "token-abc",
                                                        identity: identity,
                                                        userId: "user-1",
                                                        limit: 10)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.path == "/base/Shows/NextUp")
        #expect(query["userId"] == "user-1")
        #expect(query["limit"] == "10")
        #expect(query["enableResumable"] == "true")
        #expect(query["enableUserData"] == "true")
    }

    @Test func latestItemsRequestTargetsLatestMedia() throws {
        let request = try JellyfinLibrary.latestItemsRequest(server: server,
                                                             token: "token-abc",
                                                             identity: identity,
                                                             userId: "user-1",
                                                             parentId: "view-1",
                                                             includeItemTypes: "Movie",
                                                             limit: 8)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.path == "/base/Items/Latest")
        #expect(query["userId"] == "user-1")
        #expect(query["parentId"] == "view-1")
        #expect(query["includeItemTypes"] == "Movie")
        #expect(query["groupItems"] == "false")
        #expect(query["enableUserData"] == "true")
    }

    @Test func itemRequestTargetsSingleItem() throws {
        let request = try JellyfinLibrary.itemRequest(server: server, token: "token-abc", identity: identity, userId: "user-1", itemId: "item-1")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.path == "/base/path/to/user/Items/item-1")
        #expect(query["userId"] == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"token-abc\"") == true)
    }

    @Test func imageURLPreservesBasePathAndOptions() throws {
        let url = try JellyfinLibrary.imageURL(server: server, itemId: "item-1", imageType: .primary, tag: "tag-1", width: 400, height: 600)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.path == "/base/Items/item-1/Images/Primary")
        #expect(query["tag"] == "tag-1")
        #expect(query["width"] == "400")
        #expect(query["height"] == "600")
    }

    @Test func itemRequestAsksForFullMetadataFields() throws {
        let request = try JellyfinLibrary.itemRequest(server: server, token: "token-abc", identity: identity, userId: "user-1", itemId: "item-1")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.path == "/base/path/to/user/Items/item-1")
        #expect(query["userId"] == nil)
        #expect(query["fields"]?.contains("MediaSources") == true)
        #expect(query["fields"]?.contains("Chapters") == true)
    }

    @Test func chapterImageURLPreservesBasePathAndUsesChapterEndpoint() throws {
        let url = try JellyfinLibrary.chapterImageURL(server: server, itemId: "item-1", chapterIndex: 2, tag: "chapter-tag", width: 480, height: 270)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.path == "/base/Items/item-1/Images/Chapter/2")
        #expect(query["tag"] == "chapter-tag")
        #expect(query["fillWidth"] == "480")
        #expect(query["fillHeight"] == "270")
    }


    @Test func trickPlayPlaylistRequestUsesHeaderAuthAndMediaSource() throws {
        let request = try JellyfinLibrary.trickPlayPlaylistRequest(server: server,
                                                                   token: "token-abc",
                                                                   identity: identity,
                                                                   itemId: "item-1",
                                                                   mediaSourceId: "source-1",
                                                                   width: 320)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.path == "/base/Videos/item-1/Trickplay/320/tiles.m3u8")
        #expect(query["MediaSourceId"] == "source-1")
        #expect(query["ApiKey"] == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"token-abc\"") == true)
        #expect(request.value(forHTTPHeaderField: "Accept")?.contains("mpegURL") == true)
    }

    @Test func trickPlayTileRequestStripsPlaylistApiKeyAndKeepsMediaSource() throws {
        let request = try JellyfinLibrary.trickPlayTileRequest(server: server,
                                                               token: "token-abc",
                                                               identity: identity,
                                                               itemId: "item-1",
                                                               mediaSourceId: "source-1",
                                                               width: 320,
                                                               tileURI: "4.jpg?MediaSourceId=source-1&ApiKey=secret")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.path == "/base/Videos/item-1/Trickplay/320/4.jpg")
        #expect(query["MediaSourceId"] == "source-1")
        #expect(query["ApiKey"] == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"token-abc\"") == true)
        #expect(request.value(forHTTPHeaderField: "Accept")?.contains("image/jpeg") == true)
    }

    @Test func parsesJellyfinTrickPlayPlaylistAndFindsFrame() throws {
        let playlist = try JellyfinTrickPlayPlaylistParser.parse(#"""
        #EXTM3U
        #EXT-X-IMAGES-ONLY
        #EXTINF:1000,
        #EXT-X-TILES:RESOLUTION=320x180,LAYOUT=10x10,DURATION=10
        0.jpg?MediaSourceId=source-1&ApiKey=secret
        #EXTINF:50,
        #EXT-X-TILES:RESOLUTION=320x180,LAYOUT=10x10,DURATION=10
        1.jpg?MediaSourceId=source-1&ApiKey=secret
        #EXT-X-ENDLIST
        """#)

        #expect(playlist.tiles.count == 2)
        #expect(playlist.tiles[0].startMs == 0)
        #expect(playlist.tiles[0].durationMs == 1_000_000)
        #expect(playlist.tiles[0].tileDurationMs == 10_000)
        #expect(playlist.tiles[0].columns == 10)
        #expect(playlist.tiles[0].rows == 10)
        let frame = try #require(playlist.frame(nearMs: 125_000))
        #expect(frame.tile.uri.hasPrefix("0.jpg"))
        #expect(frame.frameIndex == 12)
        #expect(frame.column == 2)
        #expect(frame.row == 1)
        #expect(frame.timeMs == 120_000)
        let final = try #require(playlist.frame(nearMs: 1_020_000))
        #expect(final.tile.uri.hasPrefix("1.jpg"))
        #expect(final.frameIndex == 2)
    }

    @Test func activeEncodingStopTargetsDeviceAndSession() throws {
        let request = try JellyfinLibrary.activeEncodingStopRequest(server: server, token: "token-abc", identity: identity, deviceId: "device-123", playSessionId: "play-1")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(request.httpMethod == "DELETE")
        #expect(components.path == "/base/Videos/ActiveEncodings")
        #expect(query["deviceId"] == "device-123")
        #expect(query["playSessionId"] == "play-1")
    }

    @Test func markPlayedUsesUserDataEndpoint() throws {
        let played = try JellyfinLibrary.markPlayedRequest(server: server,
                                                           token: "token-abc",
                                                           identity: identity,
                                                           userId: "user-1",
                                                           itemId: "item-1",
                                                           played: true)
        let unplayed = try JellyfinLibrary.markPlayedRequest(server: server,
                                                             token: "token-abc",
                                                             identity: identity,
                                                             userId: "user-1",
                                                             itemId: "item-1",
                                                             played: false)

        #expect(played.httpMethod == "POST")
        #expect(unplayed.httpMethod == "DELETE")
        #expect(played.url?.path == "/base/path/to/user/PlayedItems/item-1")
        #expect(played.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"token-abc\"") == true)
    }

    @Test func downloadRequestUsesHeadersNotURLToken() throws {
        let request = try JellyfinLibrary.downloadRequest(server: server,
                                                          token: "token-abc",
                                                          identity: identity,
                                                          itemId: "item-1",
                                                          mediaSourceId: "source-1",
                                                          container: "mp4")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(request.httpMethod == nil || request.httpMethod == "GET")
        #expect(components.path == "/base/Videos/item-1/stream.mp4")
        #expect(query["api_key"] == nil)
        #expect(query["static"] == "true")
        #expect(query["mediaSourceId"] == "source-1")
        #expect(request.value(forHTTPHeaderField: "Accept") == "*/*")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"token-abc\"") == true)
    }

    @Test func transcodedDownloadRequestUsesHeaderAuthAndMp4Stream() throws {
        let request = try JellyfinLibrary.transcodedDownloadRequest(server: server,
                                                                    token: "token-abc",
                                                                    identity: identity,
                                                                    itemId: "item-1",
                                                                    mediaSourceId: "source-1",
                                                                    playSessionId: "download-session-1",
                                                                    maxVideoBitrate: 4_000_000,
                                                                    maxWidth: 1280,
                                                                    maxHeight: 720)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query: [String: String] = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(request.httpMethod == nil || request.httpMethod == "GET")
        #expect(components.path == "/base/Videos/item-1/stream.mp4")
        #expect(query["api_key"] == nil)
        #expect(query["static"] == "false")
        #expect(query["container"] == "mp4")
        #expect(query["videoCodec"] == "h264")
        #expect(query["audioCodec"] == "aac")
        #expect(query["videoBitRate"] == "4000000")
        #expect(query["maxWidth"] == "1280")
        #expect(query["maxHeight"] == "720")
        #expect(query["playSessionId"] == "download-session-1")
        #expect(query["allowVideoStreamCopy"] == "false")
        #expect(request.value(forHTTPHeaderField: "Accept") == "*/*")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"token-abc\"") == true)
    }

    @Test func mapsMovieDtoToMediaItem() throws {
        let response = try JSONDecoder().decode(JellyfinItemsResponse.self, from: Data(#"""
        {
          "Items": [{
            "Id": "movie-1",
            "Name": "A Movie",
            "Type": "Movie",
            "Overview": "Movie summary",
            "ProductionYear": 2020,
            "RunTimeTicks": 72000000000,
            "CommunityRating": 7.8,
            "OfficialRating": "PG-13",
            "Taglines": ["One dream can change everything"],
            "Genres": ["Adventure", "Drama"],
            "Chapters": [
              { "StartPositionTicks": 0, "Name": "Chapter 01", "ImageTag": "chapter-tag-1" },
              { "StartPositionTicks": 3003420000, "Name": "Chapter 02", "ImageTag": "chapter-tag-2" }
            ],
            "ImageTags": { "Primary": "poster-tag" },
            "BackdropImageTags": ["backdrop-tag"],
            "MediaSources": [{
              "Id": "source-1",
              "Container": "mkv",
              "Bitrate": 8200000,
              "Width": 1920,
              "Height": 1080,
              "VideoCodec": "hevc",
              "AudioCodec": "aac",
              "MediaStreams": [
                { "Index": 0, "Type": "Video", "Codec": "hevc", "Width": 1920, "Height": 1080 },
                { "Index": 1, "Type": "Audio", "Codec": "aac", "Language": "English", "DisplayTitle": "English AAC Stereo", "IsDefault": true, "Channels": 2 },
                { "Index": 2, "Type": "Subtitle", "Codec": "srt", "Language": "English", "DisplayTitle": "English", "IsForced": false }
              ]
            }],
            "UserData": { "PlaybackPositionTicks": 1200000000, "Played": true }
          }],
          "TotalRecordCount": 1
        }
        """#.utf8))

        let item = try #require(response.items.first?.toMediaItem())
        #expect(item.ratingKey == "movie-1")
        #expect(item.title == "A Movie")
        #expect(item.type == "movie")
        #expect(item.summary == "Movie summary")
        #expect(item.year == 2020)
        #expect(item.duration == 7_200_000)
        #expect(item.viewOffset == 120_000)
        #expect(item.viewCount == 1)
        #expect(item.thumb == "jellyfin://item/movie-1/Primary?tag=poster-tag")
        #expect(item.art == "jellyfin://item/movie-1/Backdrop?tag=backdrop-tag")
        #expect(item.rating == 7.8)
        #expect(item.contentRating == "PG-13")
        #expect(item.tagline == "One dream can change everything")
        #expect(item.genres?.map(\.tag) == ["Adventure", "Drama"])
        #expect(item.chapters?.map(\.tag) == ["Chapter 01", "Chapter 02"])
        #expect(item.chapters?[0].thumb == "jellyfin://item/movie-1/Chapter/0?tag=chapter-tag-1")
        #expect(item.chapters?[1].thumb == "jellyfin://item/movie-1/Chapter/1?tag=chapter-tag-2")
        #expect(item.chapters?[1].startTimeOffset == 300_342)
        let media = try #require(item.media?.first)
        #expect(media.container == "mkv")
        #expect(media.bitrate == 8200)
        #expect(media.width == 1920)
        #expect(media.height == 1080)
        #expect(media.videoCodec == "hevc")
        #expect(media.audioCodec == "aac")
        let part = try #require(media.part.first)
        #expect(part.key == "jellyfin://item/movie-1/media/source-1")
        #expect(part.container == "mkv")
        #expect(part.videoStreams.first?.codec == "hevc")
        #expect(part.audioStreams.first?.displayTitle == "English AAC Stereo")
        #expect(part.subtitleStreams.first?.displayTitle == "English")
    }

    @Test func mapsResolutionAndCodecsFromMediaStreamsWhenSourceOmitsThem() throws {
        // Real Jellyfin carries resolution & codecs on the per-stream `MediaStreams`, NOT on the
        // MediaSource top level (which only has Bitrate/Container). The mapper must fall back to
        // the video/audio streams so resolution & codec badges populate (GH #108).
        let response = try JSONDecoder().decode(JellyfinItemsResponse.self, from: Data(#"""
        {
          "Items": [{
            "Id": "movie-2",
            "Name": "Another Movie",
            "Type": "Movie",
            "ProductionYear": 2023,
            "MediaSources": [{
              "Id": "source-2",
              "Container": "mkv",
              "Bitrate": 26600000,
              "MediaStreams": [
                { "Index": 0, "Type": "Video", "Codec": "hevc", "Width": 3840, "Height": 2160 },
                { "Index": 1, "Type": "Audio", "Codec": "truehd", "Channels": 8 }
              ]
            }]
          }],
          "TotalRecordCount": 1
        }
        """#.utf8))

        let media = try #require(response.items.first?.toMediaItem()?.media?.first)
        #expect(media.container == "mkv")
        #expect(media.bitrate == 26600)
        #expect(media.width == 3840)
        #expect(media.height == 2160)        // → resolutionLabel reads "4K"
        #expect(media.videoCodec == "hevc")
        #expect(media.audioCodec == "truehd")
    }

    @Test func mapsEpisodeHierarchyToMediaItem() throws {
        let dto = try JSONDecoder().decode(JellyfinBaseItemDto.self, from: Data(#"""
        {
          "Id": "episode-1",
          "Name": "Pilot",
          "Type": "Episode",
          "CommunityRating": 1.0,
          "SeriesId": "series-1",
          "SeriesName": "A Show",
          "ParentId": "season-1",
          "ParentIndexNumber": 1,
          "IndexNumber": 2,
          "ImageTags": { "Primary": "episode-tag" }
        }
        """#.utf8))

        let item = try #require(dto.toMediaItem())
        #expect(item.type == "episode")
        #expect(item.rating == nil)
        #expect(item.grandparentRatingKey == "series-1")
        #expect(item.grandparentTitle == "A Show")
        #expect(item.parentRatingKey == "season-1")
        #expect(item.parentIndex == 1)
        #expect(item.index == 2)
    }

    @Test func mapsStandaloneVideoDtoToPlayableMediaItem() throws {
        let dto = try JSONDecoder().decode(JellyfinBaseItemDto.self, from: Data(#"""
        {
          "Id": "video-1",
          "Name": "A Recording",
          "Type": "Video",
          "RunTimeTicks": 12000000000,
          "ImageTags": { "Primary": "video-tag" },
          "MediaSources": [{
            "Id": "source-1",
            "Container": "mp4",
            "MediaStreams": [
              { "Index": 0, "Type": "Video", "Codec": "h264" },
              { "Index": 1, "Type": "Audio", "Codec": "aac" }
            ]
          }]
        }
        """#.utf8))

        let item = try #require(dto.toMediaItem())
        #expect(item.ratingKey == "video-1")
        #expect(item.title == "A Recording")
        #expect(item.type == "video")
        #expect(item.duration == 1_200_000)
        #expect(item.thumb == "jellyfin://item/video-1/Primary?tag=video-tag")
        #expect(item.media?.first?.part.first?.key == "jellyfin://item/video-1/media/source-1")
        #expect(item.isPlayableLeaf)
    }

    @Test func textSubtitleRequestUsesHeaderAuthAndPathStyle() throws {
        let req = try JellyfinLibrary.textSubtitleRequest(server: URL(string: "https://jf.example/base")!,
                                                          token: "secret",
                                                          identity: identity,
                                                          itemId: "item-1",
                                                          mediaSourceId: "source-1",
                                                          streamIndex: 3,
                                                          format: "srt")
        #expect(req.url?.path == "/base/Videos/item-1/source-1/Subtitles/3/Stream.srt")
        #expect(req.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"secret\"") == true)
        #expect(URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?.isEmpty ?? true)
    }

}
