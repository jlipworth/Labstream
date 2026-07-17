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
                expected: "GET https://jellyfin.example.test/root-base/Items?userId=u&fields=Overview,Genres,MediaSources,People,Studios,ProviderIds,ParentId,PrimaryImageAspectRatio,UserData,OfficialRating,CommunityRating,CriticRating,Taglines,Chapters,ExtraIds,LocalTrailerCount,SpecialFeatureCount,RemoteTrailers,ParentThumbItemId,ParentThumbImageTag,ParentBackdropItemId,ParentBackdropImageTags,ParentPrimaryImageItemId,ParentPrimaryImageTag,SeriesPrimaryImageTag&enableUserData=true&recursive=false&includeItemTypes=Movie,Series,Season,Episode,Video&sortBy=SortName&sortOrder=Ascending [Accept:application/json|Authorization:MediaBrowser Client=\"Lab stream\", Device=\"Vision/Pro\", DeviceId=\"device+1\", Version=\"1.2.3\", Token=\"t\"] body=nil"
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
                expected: "GET https://emby.example.test/emby-base/path/to/user/Items?Fields=Overview,Genres,MediaSources,People,Studios,ProviderIds,ParentId,PrimaryImageAspectRatio,UserData,OfficialRating,CommunityRating,CriticRating,Taglines,Chapters,ExtraIds,LocalTrailerCount,SpecialFeatureCount,RemoteTrailers,ParentThumbItemId,ParentThumbImageTag,ParentBackdropItemId,ParentBackdropImageTags,ParentPrimaryImageItemId,ParentPrimaryImageTag,SeriesPrimaryImageTag&EnableUserData=true&Recursive=false&IncludeItemTypes=Movie,Series,Season,Episode,Video&SortBy=SortName&SortOrder=Ascending [Accept:application/json|Authorization:Emby UserId=\"u\", Client=\"Lab stream\", Device=\"Vision/Pro\", DeviceId=\"device+1\", Version=\"1.2.3\", Token=\"t\"|X-Emby-Token:t] body=nil"
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

    @Test func remainingConceptsPreserveOrderedDialectGoldens() {
        struct ShapeGolden {
            let name: String
            let shape: MediaBrowserLibraryRequestShape
            let expected: String
        }

        let jf = MediaBrowserLibraryRequestFactory(dialect: .jellyfin)
        let emby = MediaBrowserLibraryRequestFactory(dialect: .emby)
        let cases = [
            ShapeGolden(
                name: "Jellyfin resume reserved values",
                shape: jf.resumeItems(userId: "u &/1", parentId: "p +&/x", limit: -2, fields: "F"),
                expected: "GET /UserItems/Resume?userId=u &/1&limit=-2&includeItemTypes=Movie,Episode,Video&fields=F&enableUserData=true&enableImages=true&excludeActiveSessions=false&parentId=p +&/x accept=nil"
            ),
            ShapeGolden(
                name: "Emby resume nil parent",
                shape: emby.resumeItems(userId: "u &/1", parentId: nil, limit: 0, fields: "F"),
                expected: "GET /path/to/user &/1/Items/Resume?Limit=0&IncludeItemTypes=Movie,Episode,Video&Fields=F&EnableUserData=true&EnableImages=true accept=nil"
            ),
            ShapeGolden(
                name: "Jellyfin next up nil parent",
                shape: jf.nextUp(userId: "u", parentId: nil, limit: 1, fields: "F"),
                expected: "GET /Shows/NextUp?userId=u&limit=1&fields=F&enableUserData=true&enableImages=true&enableResumable=true accept=nil"
            ),
            ShapeGolden(
                name: "Emby next up reserved parent",
                shape: emby.nextUp(userId: "u", parentId: "p &+", limit: 1, fields: "F"),
                expected: "GET /Shows/NextUp?UserId=u&Limit=1&Fields=F&EnableUserData=true&EnableImages=true&ParentId=p &+ accept=nil"
            ),
            ShapeGolden(
                name: "Jellyfin latest empty item types",
                shape: jf.latestItems(userId: "u", parentId: nil, includeItemTypes: "", limit: 0, fields: "F"),
                expected: "GET /Items/Latest?userId=u&limit=0&includeItemTypes=&fields=F&enableUserData=true&enableImages=true&groupItems=false accept=nil"
            ),
            ShapeGolden(
                name: "Emby latest reserved item types",
                shape: emby.latestItems(userId: "u", parentId: "p/1", includeItemTypes: "Movie,Video & X", limit: 2, fields: "F"),
                expected: "GET /path/to/user/Items/Latest?Limit=2&IncludeItemTypes=Movie,Video & X&Fields=F&EnableUserData=true&EnableImages=true&GroupItems=false&ParentId=p/1 accept=nil"
            ),
            ShapeGolden(
                name: "Jellyfin metadata",
                shape: jf.item(userId: "u/1", itemId: "i &+", fields: "F"),
                expected: "GET /path/to/user/1/Items/i &+?fields=F accept=nil"
            ),
            ShapeGolden(
                name: "Emby metadata",
                shape: emby.item(userId: "u/1", itemId: "i &+", fields: "F"),
                expected: "GET /path/to/user/1/Items/i &+?Fields=F accept=nil"
            ),
            ShapeGolden(
                name: "Jellyfin mark played",
                shape: jf.markPlayed(userId: "u", itemId: "i", played: true),
                expected: "POST /path/to/user/PlayedItems/i accept=nil"
            ),
            ShapeGolden(
                name: "Emby mark unplayed",
                shape: emby.markPlayed(userId: "u", itemId: "i", played: false),
                expected: "DELETE /path/to/user/PlayedItems/i accept=nil"
            ),
            ShapeGolden(
                name: "Jellyfin subtitle normalizes reserved format",
                shape: jf.textSubtitle(itemId: "i/1", mediaSourceId: "s &+", streamIndex: -1, format: "..SRT.."),
                expected: "GET /Videos/i/1/s &+/Subtitles/-1/Stream.srt accept=application/x-subrip,text/plain,*/*"
            ),
            ShapeGolden(
                name: "Emby subtitle empty format falls back",
                shape: emby.textSubtitle(itemId: "i", mediaSourceId: "s", streamIndex: 0, format: ""),
                expected: "GET /Videos/i/s/Subtitles/0/Stream.vtt accept=text/vtt,text/plain,*/*"
            ),
            ShapeGolden(
                name: "Jellyfin audio ordered title-case query",
                shape: jf.audioStream(userId: "u &+", deviceId: "d/1", itemId: "i", maxStreamingBitrate: -1, containers: ""),
                expected: "GET /Audio/i/universal?UserId=u &+&DeviceId=d/1&MaxStreamingBitrate=-1&Container=&TranscodingContainer=ts&TranscodingProtocol=hls&AudioCodec=aac accept=nil"
            ),
            ShapeGolden(
                name: "Emby audio ordered title-case query",
                shape: emby.audioStream(userId: "u", deviceId: "d", itemId: "i", maxStreamingBitrate: 1, containers: "mp3,aac"),
                expected: "GET /Audio/i/universal?UserId=u&DeviceId=d&MaxStreamingBitrate=1&Container=mp3,aac&TranscodingContainer=ts&TranscodingProtocol=hls&AudioCodec=aac accept=nil"
            ),
            ShapeGolden(
                name: "Jellyfin image omits empty and nil options",
                shape: jf.image(itemId: "i", imageType: "Primary", tag: "", width: nil, height: nil),
                expected: "GET /Items/i/Images/Primary accept=nil"
            ),
            ShapeGolden(
                name: "Emby image preserves reserved tag order",
                shape: emby.image(itemId: "i", imageType: "Backdrop", tag: "t &+", width: 0, height: -1),
                expected: "GET /Items/i/Images/Backdrop?tag=t &+&width=0&height=-1 accept=nil"
            ),
            ShapeGolden(
                name: "Jellyfin chapter image",
                shape: jf.chapterImage(itemId: "i", chapterIndex: -2, tag: nil, width: 0, height: nil),
                expected: "GET /Items/i/Images/Chapter/-2?fillWidth=0 accept=nil"
            ),
            ShapeGolden(
                name: "Emby chapter image",
                shape: emby.chapterImage(itemId: "i", chapterIndex: 2, tag: "", width: nil, height: 0),
                expected: "GET /Items/i/Images/Chapter/2?fillHeight=0 accept=nil"
            ),
            ShapeGolden(
                name: "Jellyfin active encoding stop casing",
                shape: jf.activeEncodingStop(deviceId: "d &+", playSessionId: "p/1"),
                expected: "DELETE /Videos/ActiveEncodings?deviceId=d &+&playSessionId=p/1 accept=nil"
            ),
            ShapeGolden(
                name: "Emby active encoding stop casing",
                shape: emby.activeEncodingStop(deviceId: "d &+", playSessionId: "p/1"),
                expected: "DELETE /Videos/ActiveEncodings?DeviceId=d &+&PlaySessionId=p/1 accept=nil"
            ),
        ]

        for golden in cases {
            #expect(shapeSnapshot(golden.shape) == golden.expected, Comment(rawValue: golden.name))
        }
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

    private func shapeSnapshot(_ shape: MediaBrowserLibraryRequestShape) -> String {
        let query = shape.queryItems
            .map { "\($0.name)=\($0.value ?? "nil")" }
            .joined(separator: "&")
        let suffix = query.isEmpty ? "" : "?\(query)"
        return "\(shape.httpMethod) \(shape.path)\(suffix) accept=\(shape.accept ?? "nil")"
    }
}
