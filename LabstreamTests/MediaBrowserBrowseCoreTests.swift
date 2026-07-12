import Foundation
import Testing
@testable import Labstream
@testable import PMSKit

@Suite("Shared MediaBrowser browse core")
@MainActor
struct MediaBrowserBrowseCoreTests {
    @Test func jellyfinCorePreservesBasePathPagingTotalsAndSyntheticURIs() async throws {
        let transport = BrowseCoreScriptedTransport { request in
            switch request.url?.path {
            case "/root/UserViews":
                return Data(#"{"Items":[{"Id":"lib","Name":"Movies","CollectionType":"movies"}]}"#.utf8)
            case "/root/Items":
                return Data(#"{"Items":[{"Id":"m1","Name":"One","Type":"Movie","ImageTags":{"Primary":"tag"}}],"TotalRecordCount":42}"#.utf8)
            case "/root/Artists/AlbumArtists":
                return Data(#"{"Items":[{"Id":"artist","Name":"Artist","Type":"MusicArtist"}],"TotalRecordCount":7}"#.utf8)
            default:
                throw BrowseCoreTestFailure.unexpectedRequest
            }
        }
        let core = MediaBrowserBrowseCore(
            context: MediaBrowserBrowseContext(
                server: URL(string: "https://media.example/root")!,
                token: "token",
                userID: "user",
                identity: JellyfinClientIdentity(client: "Labstream", device: "Mac", deviceId: "device", version: "1")
            ),
            adapter: JellyfinBrowseCoreAdapter(),
            send: { try await transport.send($0) }
        )

        let links = try await core.userViewLinks()
        let page = try await core.itemsPage(MediaBrowserItemsQuery(
            parentID: "lib", recursive: true, startIndex: 20, limit: 10,
            searchTerm: "A & B", fields: JellyfinLibrary.fullItemFields
        ))
        let artists = try await core.albumArtistsPage(parentID: "lib", startIndex: 0, limit: 5,
                                                      nameStartsWith: "A", sortBy: "SortName",
                                                      sortOrder: "Ascending")

        #expect(links == [MediaBrowserLibraryLink(id: "lib", title: "Movies", collectionType: "movies")])
        #expect(page.total == 42)
        #expect(page.items.map(\.ratingKey) == ["m1"])
        #expect(page.items.first?.thumb?.hasPrefix("jellyfin://") == true)
        #expect(artists.total == 7)
        #expect(artists.items.map(\.ratingKey) == ["artist"])

        let requests = await transport.requests
        #expect(requests.map { $0.url?.path } == ["/root/UserViews", "/root/Items", "/root/Artists/AlbumArtists"])
        #expect(requests[1].url?.query?.contains("startIndex=20") == true)
        #expect(requests[1].url?.query?.contains("searchTerm=A%20%26%20B") == true)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("MediaBrowser ") == true })
    }

    @Test func embyCorePreservesPlaylistOrderAndCommonCapabilityShapes() async throws {
        let transport = BrowseCoreScriptedTransport { request in
            let path = request.url?.path ?? ""
            if path == "/emby/Playlists/playlist/Items" {
                return Self.itemsJSON(ids: ["second", "first"])
            }
            if path.hasSuffix("/Items/Resume") { return Self.itemsJSON(ids: ["resume"]) }
            if path == "/emby/Shows/NextUp" { return Self.itemsJSON(ids: ["next"]) }
            if path.hasSuffix("/Items/Latest") { return Self.arrayJSON(ids: ["latest"]) }
            if path.hasSuffix("/Items/meta") { return Self.itemJSON(id: "meta") }
            if path.hasSuffix("/PlayedItems/meta") { return Data() }
            throw BrowseCoreTestFailure.unexpectedRequest
        }
        let core = MediaBrowserBrowseCore(
            context: MediaBrowserBrowseContext(
                server: URL(string: "https://media.example/emby")!,
                token: "token",
                userID: "user",
                identity: EmbyClientIdentity(client: "Labstream", device: "Mac", deviceId: "device", version: "1")
            ),
            adapter: EmbyBrowseCoreAdapter(),
            send: { try await transport.send($0) }
        )

        #expect(try await core.playlistItems(playlistID: "playlist").map(\.ratingKey) == ["second", "first"])
        #expect(try await core.resumeItems(limit: 3).map(\.ratingKey) == ["resume"])
        #expect(try await core.nextUp(limit: 3).map(\.ratingKey) == ["next"])
        let latest = try await core.latestItems(parentID: nil, includeItemTypes: "Movie", limit: 3)
        #expect(latest.map(\.ratingKey) == ["latest"])
        #expect(latest.first?.thumb?.hasPrefix("emby://") == true)
        #expect(try await core.metadata(itemID: "meta")?.ratingKey == "meta")
        try await core.setPlayed(itemID: "meta", played: false)

        let requests = await transport.requests
        #expect(requests.last?.httpMethod == "DELETE")
        #expect(requests.allSatisfy { $0.url?.path.hasPrefix("/emby/") == true })
    }

    @Test func corePropagatesTransportAndDecodeErrorsWithoutRewritingThem() async throws {
        let context = MediaBrowserBrowseContext(
            server: URL(string: "https://media.example/root")!, token: "t", userID: "u",
            identity: JellyfinClientIdentity(client: "c", device: "d", deviceId: "id", version: "v")
        )
        let transportFailure = MediaBrowserBrowseCore(
            context: context,
            adapter: JellyfinBrowseCoreAdapter(),
            send: { _ in throw BrowseCoreTestFailure.transport }
        )
        await #expect(throws: BrowseCoreTestFailure.transport) {
            _ = try await transportFailure.userViews()
        }

        let decodeFailure = MediaBrowserBrowseCore(
            context: context,
            adapter: JellyfinBrowseCoreAdapter(),
            send: { _ in Data("not-json".utf8) }
        )
        await #expect(throws: (any Error).self) {
            _ = try await decodeFailure.userViews()
        }
    }

    nonisolated private static func itemJSON(id: String) -> Data {
        Data(#"{"Id":"\#(id)","Name":"\#(id)","Type":"Movie","ImageTags":{"Primary":"tag"}}"#.utf8)
    }

    nonisolated private static func itemsJSON(ids: [String]) -> Data {
        let rows = ids.map { String(data: itemJSON(id: $0), encoding: .utf8)! }.joined(separator: ",")
        return Data("{\"Items\":[\(rows)],\"TotalRecordCount\":\(ids.count)}".utf8)
    }

    nonisolated private static func arrayJSON(ids: [String]) -> Data {
        let rows = ids.map { String(data: itemJSON(id: $0), encoding: .utf8)! }.joined(separator: ",")
        return Data("[\(rows)]".utf8)
    }
}

private enum BrowseCoreTestFailure: Error, Equatable {
    case unexpectedRequest
    case transport
}

private actor BrowseCoreScriptedTransport {
    private(set) var requests: [URLRequest] = []
    private let response: @Sendable (URLRequest) throws -> Data

    init(response: @escaping @Sendable (URLRequest) throws -> Data) {
        self.response = response
    }

    func send(_ request: URLRequest) throws -> Data {
        requests.append(request)
        return try response(request)
    }
}
