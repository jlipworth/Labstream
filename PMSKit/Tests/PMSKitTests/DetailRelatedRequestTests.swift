import Foundation
import Testing
@testable import PMSKit

@Suite("Detail More Like This and show episode request builders")
struct DetailRelatedRequestTests {
    @Test func plexSimilarAndAllLeavesAreReadEndpoints() {
        let similar = PlexBrowseRequest.similar(server: TestFixtures.plexServer, token: "tok",
                                                identity: TestFixtures.plexIdentity,
                                                ratingKey: "42", count: 12)
        #expect(similar.url.path == "/library/metadata/42/similar")
        #expect(similar.method == "GET")
        #expect(queryValue(similar, "count") == "12")
        #expect(similar.headers["X-Plex-Token"] == "tok")

        let leaves = PlexBrowseRequest.allLeaves(server: TestFixtures.plexServer, token: "tok",
                                                 identity: TestFixtures.plexIdentity, ratingKey: "7")
        #expect(leaves.url.path == "/library/metadata/7/allLeaves")
        #expect(leaves.method == "GET")
    }

    @Test func jellyfinSimilarUsesItemsSimilar() throws {
        let request = try JellyfinLibrary.similarItemsRequest(server: TestFixtures.jellyfinServer,
                                                              token: "jf-token",
                                                              identity: TestFixtures.jellyfinIdentity,
                                                              userId: "user-1", itemId: "item-1",
                                                              limit: 12)
        let url = try #require(request.url)
        #expect(url.path == "/base/Items/item-1/Similar")
        #expect(try queryValue(request, "userId") == "user-1")
        #expect(try queryValue(request, "limit") == "12")
        #expect(try queryValue(request, "fields") == JellyfinLibrary.gridItemFields)
        _ = try assertAuthHeaderContainsTokenNotInURL(request, token: "jf-token")
    }

    @Test func embySimilarUsesItemsSimilar() throws {
        let request = try EmbyLibrary.similarItemsRequest(server: TestFixtures.embyServer,
                                                          token: "emby-token",
                                                          identity: TestFixtures.embyIdentity,
                                                          userId: "user-1", itemId: "item-1")
        let url = try #require(request.url)
        #expect(url.path == "/emby/Items/item-1/Similar")
        #expect(try queryValue(request, "UserId") == "user-1")
        #expect(try queryValue(request, "Limit") == "20")
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "emby-token")
        #expect(!url.absoluteString.contains("emby-token"))
    }
}
