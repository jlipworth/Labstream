import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PMSKit

@Suite("MediaBrowser library request factory")
struct MediaBrowserLibraryRequestFactoryTests {
    private struct GoldenCase {
        let name: String
        let request: URLRequest
        let expected: String
    }

    @Test func backendWrappersPreserveGoldenWireBytes() throws {
        let jellyfinServer = URL(string: "https://jellyfin.example.test/root-base")!
        let embyServer = URL(string: "https://emby.example.test/emby-base")!
        let jellyfinIdentity = JellyfinClientIdentity(
            client: "Lab stream",
            device: "Vision/Pro",
            deviceId: "device+1",
            version: "1.2.3"
        )
        let embyIdentity = EmbyClientIdentity(
            client: "Lab stream",
            device: "Vision/Pro",
            deviceId: "device+1",
            version: "1.2.3"
        )

        let cases = try [
            GoldenCase(
                name: "Jellyfin views",
                request: JellyfinLibrary.userViewsRequest(
                    server: jellyfinServer,
                    token: "tok\"en",
                    identity: jellyfinIdentity,
                    userId: "user-one"
                ),
                expected: "GET https://jellyfin.example.test/root-base/UserViews?userId=user-one&includeExternalContent=false [Accept:application/json|Authorization:MediaBrowser Client=\"Lab stream\", Device=\"Vision/Pro\", DeviceId=\"device+1\", Version=\"1.2.3\", Token=\"tok\\\"en\"] body=nil"
            ),
            GoldenCase(
                name: "Emby views",
                request: EmbyLibrary.userViewsRequest(
                    server: embyServer,
                    token: "tok\"en",
                    identity: embyIdentity,
                    userId: "user-one"
                ),
                expected: "GET https://emby.example.test/emby-base/path/to/user/Views?IncludeExternalContent=false [Accept:application/json|Authorization:Emby UserId=\"user-one\", Client=\"Lab stream\", Device=\"Vision/Pro\", DeviceId=\"device+1\", Version=\"1.2.3\", Token=\"tok\\\"en\"|X-Emby-Token:tok\"en] body=nil"
            ),
            GoldenCase(
                name: "Jellyfin items paging/search",
                request: JellyfinLibrary.itemsRequest(
                    server: jellyfinServer,
                    token: "tok\"en",
                    identity: jellyfinIdentity,
                    userId: "user-one",
                    parentId: "parent/one",
                    recursive: true,
                    startIndex: 20,
                    limit: 10,
                    searchTerm: "A+B & C",
                    nameStartsWith: "A",
                    sortBy: "DateCreated,SortName",
                    sortOrder: "Descending",
                    includeItemTypes: "Movie,Episode",
                    fields: "Overview,Genres",
                    albumArtistIds: "aa,bb",
                    artistIds: "cc/dd",
                    filters: ["IsPlayed", "Likes"]
                ),
                expected: "GET https://jellyfin.example.test/root-base/Items?userId=user-one&fields=Overview,Genres&enableUserData=true&parentId=parent/one&recursive=true&startIndex=20&limit=10&searchTerm=A+B%20%26%20C&nameStartsWith=A&albumArtistIds=aa,bb&artistIds=cc/dd&includeItemTypes=Movie,Episode&filters=IsPlayed,Likes&sortBy=DateCreated,SortName&sortOrder=Descending [Accept:application/json|Authorization:MediaBrowser Client=\"Lab stream\", Device=\"Vision/Pro\", DeviceId=\"device+1\", Version=\"1.2.3\", Token=\"tok\\\"en\"] body=nil"
            ),
            GoldenCase(
                name: "Emby items paging/search",
                request: EmbyLibrary.itemsRequest(
                    server: embyServer,
                    token: "tok\"en",
                    identity: embyIdentity,
                    userId: "user-one",
                    parentId: "parent/one",
                    recursive: true,
                    startIndex: 20,
                    limit: 10,
                    searchTerm: "A+B & C",
                    nameStartsWith: "A",
                    sortBy: "DateCreated,SortName",
                    sortOrder: "Descending",
                    includeItemTypes: "Movie,Episode",
                    fields: "Overview,Genres",
                    albumArtistIds: "aa,bb",
                    artistIds: "cc/dd",
                    filters: ["IsPlayed", "Likes"]
                ),
                expected: "GET https://emby.example.test/emby-base/path/to/user/Items?Fields=Overview,Genres&EnableUserData=true&ParentId=parent/one&Recursive=true&StartIndex=20&Limit=10&SearchTerm=A+B%20%26%20C&NameStartsWith=A&AlbumArtistIds=aa,bb&ArtistIds=cc/dd&IncludeItemTypes=Movie,Episode&Filters=IsPlayed,Likes&SortBy=DateCreated,SortName&SortOrder=Descending [Accept:application/json|Authorization:Emby UserId=\"user-one\", Client=\"Lab stream\", Device=\"Vision/Pro\", DeviceId=\"device+1\", Version=\"1.2.3\", Token=\"tok\\\"en\"|X-Emby-Token:tok\"en] body=nil"
            ),
            GoldenCase(
                name: "Jellyfin items omit empty optionals",
                request: JellyfinLibrary.itemsRequest(
                    server: jellyfinServer,
                    token: "t",
                    identity: jellyfinIdentity,
                    userId: "u",
                    searchTerm: "",
                    nameStartsWith: "",
                    albumArtistIds: "",
                    artistIds: "",
                    filters: []
                ),
                expected: "GET https://jellyfin.example.test/root-base/Items?userId=u&fields=Overview,Genres,MediaSources,People,Studios,ProviderIds,ParentId,PrimaryImageAspectRatio,UserData,OfficialRating,CommunityRating,CriticRating,Taglines,Chapters,ParentThumbItemId,ParentThumbImageTag,ParentBackdropItemId,ParentBackdropImageTags,ParentPrimaryImageItemId,ParentPrimaryImageTag,SeriesPrimaryImageTag&enableUserData=true&recursive=false&includeItemTypes=Movie,Series,Season,Episode,Video&sortBy=SortName&sortOrder=Ascending [Accept:application/json|Authorization:MediaBrowser Client=\"Lab stream\", Device=\"Vision/Pro\", DeviceId=\"device+1\", Version=\"1.2.3\", Token=\"t\"] body=nil"
            ),
            GoldenCase(
                name: "Emby items omit empty optionals",
                request: EmbyLibrary.itemsRequest(
                    server: embyServer,
                    token: "t",
                    identity: embyIdentity,
                    userId: "u",
                    searchTerm: "",
                    nameStartsWith: "",
                    albumArtistIds: "",
                    artistIds: "",
                    filters: []
                ),
                expected: "GET https://emby.example.test/emby-base/path/to/user/Items?Fields=Overview,Genres,MediaSources,People,Studios,ProviderIds,ParentId,PrimaryImageAspectRatio,UserData,OfficialRating,CommunityRating,CriticRating,Taglines,Chapters,ParentThumbItemId,ParentThumbImageTag,ParentBackdropItemId,ParentBackdropImageTags,ParentPrimaryImageItemId,ParentPrimaryImageTag,SeriesPrimaryImageTag&EnableUserData=true&Recursive=false&IncludeItemTypes=Movie,Series,Season,Episode,Video&SortBy=SortName&SortOrder=Ascending [Accept:application/json|Authorization:Emby UserId=\"u\", Client=\"Lab stream\", Device=\"Vision/Pro\", DeviceId=\"device+1\", Version=\"1.2.3\", Token=\"t\"|X-Emby-Token:t] body=nil"
            ),
            GoldenCase(
                name: "Jellyfin album artists",
                request: JellyfinLibrary.albumArtistsRequest(
                    server: jellyfinServer,
                    token: "t",
                    identity: jellyfinIdentity,
                    userId: "u & 1",
                    parentId: nil,
                    limit: 1,
                    nameStartsWith: "Ä & B",
                    fields: "Overview,Genres"
                ),
                expected: "GET https://jellyfin.example.test/root-base/Artists/AlbumArtists?userId=u%20%26%201&fields=Overview,Genres&enableUserData=true&enableImages=true&recursive=true&sortBy=SortName&sortOrder=Ascending&limit=1&nameStartsWith=%C3%84%20%26%20B [Accept:application/json|Authorization:MediaBrowser Client=\"Lab stream\", Device=\"Vision/Pro\", DeviceId=\"device+1\", Version=\"1.2.3\", Token=\"t\"] body=nil"
            ),
            GoldenCase(
                name: "Emby album artists",
                request: EmbyLibrary.albumArtistsRequest(
                    server: embyServer,
                    token: "t",
                    identity: embyIdentity,
                    userId: "u & 1",
                    parentId: nil,
                    limit: 1,
                    nameStartsWith: "Ä & B",
                    fields: "Overview,Genres"
                ),
                expected: "GET https://emby.example.test/emby-base/Artists/AlbumArtists?UserId=u%20%26%201&Fields=Overview,Genres&EnableUserData=true&EnableImages=true&Recursive=true&SortBy=SortName&SortOrder=Ascending&Limit=1&NameStartsWith=%C3%84%20%26%20B [Accept:application/json|Authorization:Emby UserId=\"u & 1\", Client=\"Lab stream\", Device=\"Vision/Pro\", DeviceId=\"device+1\", Version=\"1.2.3\", Token=\"t\"|X-Emby-Token:t] body=nil"
            ),
            GoldenCase(
                name: "Jellyfin playlist items",
                request: JellyfinLibrary.playlistItemsRequest(
                    server: jellyfinServer,
                    token: "t",
                    identity: jellyfinIdentity,
                    userId: "u & 1",
                    playlistId: "playlist/id",
                    startIndex: 0,
                    fields: "Overview,Genres"
                ),
                expected: "GET https://jellyfin.example.test/root-base/Playlists/playlist/id/Items?userId=u%20%26%201&fields=Overview,Genres&enableUserData=true&enableImages=true&startIndex=0 [Accept:application/json|Authorization:MediaBrowser Client=\"Lab stream\", Device=\"Vision/Pro\", DeviceId=\"device+1\", Version=\"1.2.3\", Token=\"t\"] body=nil"
            ),
            GoldenCase(
                name: "Emby playlist items",
                request: EmbyLibrary.playlistItemsRequest(
                    server: embyServer,
                    token: "t",
                    identity: embyIdentity,
                    userId: "u & 1",
                    playlistId: "playlist/id",
                    startIndex: 0,
                    fields: "Overview,Genres"
                ),
                expected: "GET https://emby.example.test/emby-base/Playlists/playlist/id/Items?UserId=u%20%26%201&Fields=Overview,Genres&EnableUserData=true&EnableImages=true&StartIndex=0 [Accept:application/json|Authorization:Emby UserId=\"u & 1\", Client=\"Lab stream\", Device=\"Vision/Pro\", DeviceId=\"device+1\", Version=\"1.2.3\", Token=\"t\"|X-Emby-Token:t] body=nil"
            ),
        ]

        for golden in cases {
            let actual = try wireSnapshot(golden.request)
            #expect(actual == golden.expected, Comment(rawValue: golden.name))
        }
    }

    @Test func requestShapeRetainsOrderedDuplicateQueryItems() {
        let shape = MediaBrowserLibraryRequestShape(path: "/Items", queryItems: [
            URLQueryItem(name: "Filter", value: "first"),
            URLQueryItem(name: "Filter", value: "second"),
        ])

        #expect(shape.queryItems.map(\.name) == ["Filter", "Filter"])
        #expect(shape.queryItems.map(\.value) == ["first", "second"])
    }

    private func wireSnapshot(_ request: URLRequest) throws -> String {
        let url = try #require(request.url)
        let headers = (request.allHTTPHeaderFields ?? [:])
            .sorted { lhs, rhs in lhs.key < rhs.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: "|")
        let body = request.httpBody?.base64EncodedString() ?? "nil"
        return "\(request.httpMethod ?? "nil") \(url.absoluteString) [\(headers)] body=\(body)"
    }
}
