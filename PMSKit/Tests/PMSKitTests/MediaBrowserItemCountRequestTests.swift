import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PMSKit

@Suite("MediaBrowser count-only items request")
struct MediaBrowserItemCountRequestTests {
    private static func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
    }

    @Test func jellyfinCountRequestAsksForNoRowsFieldsImagesOrUserData() throws {
        let request = try JellyfinLibrary.itemCountRequest(
            server: URL(string: "https://jellyfin.example.test")!, token: "t",
            identity: JellyfinClientIdentity(client: "c", device: "d", deviceId: "i", version: "1"),
            userId: "user-one", parentId: "lib", recursive: true,
            nameStartsWith: "B", includeItemTypes: "Series")
        let q = Self.query(request)
        #expect(request.url?.path == "/Items")
        #expect(q["limit"] == "0")
        #expect(q["fields"] == nil)
        #expect(q["sortBy"] == nil && q["sortOrder"] == nil)
        #expect(q["enableImages"] == "false")
        #expect(q["enableUserData"] == "false")
        // Same scope as the grid's items request.
        #expect(q["parentId"] == "lib")
        #expect(q["recursive"] == "true")
        #expect(q["nameStartsWith"] == "B")
        #expect(q["includeItemTypes"] == "Series")
        #expect(q["userId"] == "user-one")
    }

    @Test func embyCountRequestAsksForNoRowsFieldsImagesOrUserData() throws {
        let request = try EmbyLibrary.itemCountRequest(
            server: URL(string: "https://emby.example.test")!, token: "t",
            identity: EmbyClientIdentity(client: "c", device: "d", deviceId: "i", version: "1"),
            userId: "user-one", parentId: "lib", recursive: false,
            nameStartsWith: "Z", includeItemTypes: "Movie")
        let q = Self.query(request)
        #expect(request.url?.path == "/Users/user-one/Items")
        #expect(q["Limit"] == "0")
        #expect(q["Fields"] == nil)
        #expect(q["SortBy"] == nil && q["SortOrder"] == nil)
        #expect(q["EnableImages"] == "false")
        #expect(q["EnableUserData"] == "false")
        #expect(q["ParentId"] == "lib")
        #expect(q["Recursive"] == "false")
        #expect(q["NameStartsWith"] == "Z")
        #expect(q["IncludeItemTypes"] == "Movie")
    }
}
