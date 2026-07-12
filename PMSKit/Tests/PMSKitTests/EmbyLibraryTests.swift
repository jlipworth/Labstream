import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PMSKit

@Suite("Emby library")
struct EmbyLibraryTests {
    private let server = URL(string: "https://emby.example.test/emby")!
    private let identity = EmbyClientIdentity(
        client: "Labstream",
        device: "Apple Vision Pro",
        deviceId: "device-123",
        version: "0.1.0")

    private func query(_ request: URLRequest) throws -> [String: String] {
        let url = try #require(request.url)
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test func resumeAndNextUpRequestsCarryExplicitBounds() throws {
        let resume = try EmbyLibrary.resumeItemsRequest(server: server,
                                                        token: "token-abc",
                                                        identity: identity,
                                                        userId: "user-9",
                                                        parentId: "view-1",
                                                        startIndex: 60,
                                                        limit: 30)
        let next = try EmbyLibrary.nextUpRequest(server: server,
                                                token: "token-abc",
                                                identity: identity,
                                                userId: "user-9",
                                                startIndex: 90,
                                                limit: 30)
        let resumeQuery = try query(resume)
        let nextQuery = try query(next)
        #expect(resumeQuery["StartIndex"] == "60")
        #expect(resumeQuery["Limit"] == "30")
        #expect(resumeQuery["ParentId"] == "view-1")
        #expect(nextQuery["StartIndex"] == "90")
        #expect(nextQuery["Limit"] == "30")
    }

    @Test func userViewsRequestUsesPathStyleAndPreservesBasePath() throws {
        let request = try EmbyLibrary.userViewsRequest(server: server, token: "token-abc", identity: identity, userId: "user-9")
        let url = try #require(request.url)
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(request.httpMethod == "GET")
        #expect(comps.path == "/emby/Users/user-9/Views")
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "token-abc")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("UserId=\"user-9\"") == true)
    }

    @Test func audioStreamURLTargetsUniversalEndpointTokenless() throws {
        let url = try EmbyLibrary.audioStreamURL(server: server,
                                                 identity: identity,
                                                 userId: "user-9",
                                                 itemId: "track-9")
        let expectedURL = "https://emby.example.test/emby/Audio/track-9/universal"
            + "?UserId=user-9&DeviceId=device-123&MaxStreamingBitrate=140000000"
            + "&Container=mp3,aac,m4a,m4b,flac,alac,wav,ogg,oga,opus,webma"
            + "&TranscodingContainer=ts&TranscodingProtocol=hls&AudioCodec=aac"
        #expect(url.absoluteString == expectedURL)
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        // Path-style endpoint preserving the /emby base path.
        #expect(comps.path == "/emby/Audio/track-9/universal")
        #expect(q["UserId"] == "user-9")
        #expect(q["DeviceId"] == "device-123")
        #expect(q["MaxStreamingBitrate"] == "140000000")
        #expect(q["AudioCodec"] == "aac")
        #expect(q["Container"] == MediaBrowserAudioStreamFacts.directPlayContainers)
        // No token / api_key baked into the stream URL — auth rides in the asset header.
        #expect(q["api_key"] == nil)
        #expect(url.absoluteString.lowercased().contains("token") == false)
    }

    @Test func albumArtistsRequestTargetsDedicatedEndpoint() throws {
        let request = try EmbyLibrary.albumArtistsRequest(server: server,
                                                          token: "token-abc",
                                                          identity: identity,
                                                          userId: "user-9",
                                                          parentId: "music-lib",
                                                          startIndex: 120,
                                                          limit: 60)
        let url = try #require(request.url)
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let q = try query(request)
        #expect(comps.path == "/emby/Artists/AlbumArtists")
        #expect(q["ParentId"] == "music-lib")
        #expect(q["UserId"] == "user-9")
        #expect(q["StartIndex"] == "120")
        #expect(q["Limit"] == "60")
        #expect(q["Recursive"] == "true")
        #expect(q["EnableImages"] == "true")
        #expect(q["NameStartsWith"] == nil)
    }

    @Test func albumArtistsRequestEmitsNameStartsWithForRailProbe() throws {
        // The Artists A–Z rail probes each letter's count with `NameStartsWith=X`,
        // `Limit=1` and reads `TotalRecordCount` (#111).
        let request = try EmbyLibrary.albumArtistsRequest(server: server,
                                                          token: "token-abc",
                                                          identity: identity,
                                                          userId: "user-9",
                                                          parentId: "music-lib",
                                                          limit: 1,
                                                          nameStartsWith: "B")
        let q = try query(request)
        #expect(q["NameStartsWith"] == "B")
        #expect(q["Limit"] == "1")
        #expect(q["ParentId"] == "music-lib")
    }

    @Test func playlistItemsRequestPreservesPlaylistOrder() throws {
        let request = try EmbyLibrary.playlistItemsRequest(server: server,
                                                           token: "token-abc",
                                                           identity: identity,
                                                           userId: "user-9",
                                                           playlistId: "playlist-5",
                                                           startIndex: 0,
                                                           limit: 200)
        let url = try #require(request.url)
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let q = try query(request)
        #expect(comps.path == "/emby/Playlists/playlist-5/Items")
        #expect(q["UserId"] == "user-9")
        #expect(q["StartIndex"] == "0")
        #expect(q["Limit"] == "200")
        #expect(q["EnableImages"] == "true")
        // No SortBy override — the endpoint returns the user's playlist order verbatim.
        #expect(q["SortBy"] == nil)
    }

    @Test func itemsRequestCarriesAlbumArtistAndArtistFilters() throws {
        let albums = try EmbyLibrary.itemsRequest(server: server, token: "t", identity: identity,
                                                  userId: "user-9", recursive: true,
                                                  includeItemTypes: "MusicAlbum",
                                                  albumArtistIds: "artist-7")
        #expect(try query(albums)["AlbumArtistIds"] == "artist-7")
        let tracks = try EmbyLibrary.itemsRequest(server: server, token: "t", identity: identity,
                                                  userId: "user-9", recursive: true,
                                                  includeItemTypes: "Audio",
                                                  artistIds: "artist-7")
        #expect(try query(tracks)["ArtistIds"] == "artist-7")
    }

    @Test func itemsRequestCarriesRecursiveIncludeItemTypesAndFields() throws {
        let request = try EmbyLibrary.itemsRequest(
            server: server,
            token: "token-abc",
            identity: identity,
            userId: "user-9",
            recursive: true,
            includeItemTypes: "Movie",
            fields: "MediaSources,Overview,Chapters,Genres")

        let url = try #require(request.url)
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let q = try query(request)

        // Canonical Emby browse path is /Users/{UserId}/Items, base path preserved.
        #expect(comps.path == "/emby/Users/user-9/Items")
        #expect(q["Recursive"] == "true")
        #expect(q["IncludeItemTypes"] == "Movie")
        #expect(q["Fields"] == "MediaSources,Overview,Chapters,Genres")
        #expect(q["SortBy"] == "SortName")
        #expect(q["SortOrder"] == "Ascending")
    }

    @Test func itemsRequestAppliesPagingAndSearch() throws {
        let request = try EmbyLibrary.itemsRequest(
            server: server,
            token: "token-abc",
            identity: identity,
            userId: "user-9",
            recursive: true,
            startIndex: 40,
            limit: 20,
            searchTerm: "matrix")

        let q = try query(request)
        #expect(q["StartIndex"] == "40")
        #expect(q["Limit"] == "20")
        #expect(q["SearchTerm"] == "matrix")
    }

    @Test func itemRequestUsesUserScopedPath() throws {
        let request = try EmbyLibrary.itemRequest(server: server, token: "token-abc", identity: identity, userId: "user-9", itemId: "item-1")
        let url = try #require(request.url)
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(comps.path == "/emby/Users/user-9/Items/item-1")
    }

    @Test func markPlayedRequestUsesPostAndUnplayedUsesDelete() throws {
        let played = try EmbyLibrary.markPlayedRequest(server: server, token: "token-abc", identity: identity, userId: "user-9", itemId: "item-1", played: true)
        let unplayed = try EmbyLibrary.markPlayedRequest(server: server, token: "token-abc", identity: identity, userId: "user-9", itemId: "item-1", played: false)

        let playedURL = try #require(played.url)
        #expect(URLComponents(url: playedURL, resolvingAgainstBaseURL: false)?.path == "/emby/Users/user-9/PlayedItems/item-1")
        #expect(played.httpMethod == "POST")
        #expect(unplayed.httpMethod == "DELETE")
    }

    @Test func imageURLOmitsTokenFromStoredURL() throws {
        let url = try EmbyLibrary.imageURL(server: server, itemId: "item-1", imageType: .primary, tag: "tag-xyz", width: 400)
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(comps.path == "/emby/Items/item-1/Images/Primary")
        #expect(q["tag"] == "tag-xyz")
        #expect(q["width"] == "400")
        // No token baked into the stored image URL.
        #expect(q["api_key"] == nil)
        #expect(q["X-Emby-Token"] == nil)
    }

    @Test func activeEncodingStopRequestUsesUppercaseVideosAndDelete() throws {
        let request = try EmbyLibrary.activeEncodingStopRequest(
            server: server,
            token: "token-abc",
            identity: identity,
            userId: "user-9",
            deviceId: "device-123",
            playSessionId: "play-1")

        let url = try #require(request.url)
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let q = try query(request)

        #expect(request.httpMethod == "DELETE")
        // Admin endpoint is uppercase /Videos/, base path preserved.
        #expect(comps.path == "/emby/Videos/ActiveEncodings")
        #expect(q["DeviceId"] == "device-123")
        #expect(q["PlaySessionId"] == "play-1")
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "token-abc")
    }

    @Test func textSubtitleRequestUsesHeaderAuthAndPathStyle() throws {
        let request = try EmbyLibrary.textSubtitleRequest(server: server,
                                                          token: "token-abc",
                                                          identity: identity,
                                                          userId: "user-9",
                                                          itemId: "item-1",
                                                          mediaSourceId: "source-1",
                                                          streamIndex: 4,
                                                          format: "srt")
        let url = try #require(request.url)
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(comps.path == "/emby/Videos/item-1/source-1/Subtitles/4/Stream.srt")
        #expect(comps.queryItems?.isEmpty ?? true)
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "token-abc")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("UserId=\"user-9\"") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"token-abc\"") == true)
        #expect(request.value(forHTTPHeaderField: "Accept")?.contains("subrip") == true)
    }
}
