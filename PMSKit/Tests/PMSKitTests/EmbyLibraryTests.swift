import Foundation
import Testing
@testable import PMSKit

@Suite("Emby library")
struct EmbyLibraryTests {
    private let server = URL(string: "https://emby.example.test/emby")!
    private let identity = EmbyClientIdentity(
        client: "VisionPlay",
        device: "Apple Vision Pro",
        deviceId: "device-123",
        version: "0.1.0")

    private func query(_ request: URLRequest) throws -> [String: String] {
        let url = try #require(request.url)
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test func userViewsRequestUsesPathStyleAndPreservesBasePath() throws {
        let request = try EmbyLibrary.userViewsRequest(server: server, token: "token-abc", identity: identity, userId: "user-9")
        let url = try #require(request.url)
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(request.httpMethod == "GET")
        #expect(comps.path == "/emby/path/to/user/Views")
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "token-abc")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("UserId=\"user-9\"") == true)
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
        #expect(comps.path == "/emby/path/to/user/Items")
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

        #expect(comps.path == "/emby/path/to/user/Items/item-1")
    }

    @Test func markPlayedRequestUsesPostAndUnplayedUsesDelete() throws {
        let played = try EmbyLibrary.markPlayedRequest(server: server, token: "token-abc", identity: identity, userId: "user-9", itemId: "item-1", played: true)
        let unplayed = try EmbyLibrary.markPlayedRequest(server: server, token: "token-abc", identity: identity, userId: "user-9", itemId: "item-1", played: false)

        let playedURL = try #require(played.url)
        #expect(URLComponents(url: playedURL, resolvingAgainstBaseURL: false)?.path == "/emby/path/to/user/PlayedItems/item-1")
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
}
