import Foundation
import Testing
@testable import PMSKit

@Suite("Collections and related-media request builders")
struct CollectionExtrasRequestTests {
    @Test func plexCollectionsAndChildrenUseReadEndpointsWithPaging() {
        let list = CollectionRequest.plexCollections(server: TestFixtures.plexServer,
                                                     token: "tok",
                                                     identity: TestFixtures.plexIdentity,
                                                     sectionKey: "1",
                                                     containerStart: 100,
                                                     containerSize: 50)
        #expect(list.url.path == "/library/sections/1/collections")
        #expect(list.method == "GET")
        #expect(queryValue(list, "X-Plex-Container-Start") == "100")
        #expect(queryValue(list, "X-Plex-Container-Size") == "50")
        #expect(list.headers["X-Plex-Token"] == "tok")

        let children = CollectionRequest.plexCollectionItems(server: TestFixtures.plexServer,
                                                            token: "tok",
                                                            identity: TestFixtures.plexIdentity,
                                                            collectionId: "collection-1",
                                                            containerStart: 0,
                                                            containerSize: 200)
        #expect(children.url.path == "/library/collections/collection-1/items")
        // No sort param: the server's curated collection order must come back verbatim.
        #expect(queryValue(children, "sort") == nil)
        #expect(queryValue(children, "X-Plex-Container-Size") == "200")
    }

    @Test func jellyfinCollectionsUseGenericItemsNotCollectionManagementEndpoint() throws {
        let list = try JellyfinLibrary.collectionsRequest(server: TestFixtures.jellyfinServer,
                                                          token: "jf-token",
                                                          identity: TestFixtures.jellyfinIdentity,
                                                          userId: "user-1",
                                                          parentId: "library-1",
                                                          startIndex: 0,
                                                          limit: 25)
        let listURL = try #require(list.url)
        #expect(listURL.path == "/base/Items")
        #expect(!listURL.path.contains("/Collections"))
        #expect(try queryValue(list, "parentId") == "library-1")
        #expect(try queryValue(list, "includeItemTypes") == "BoxSet")
        #expect(try queryValue(list, "recursive") == "true")
        _ = try assertAuthHeaderContainsTokenNotInURL(list, token: "jf-token")

        let children = try JellyfinLibrary.collectionItemsRequest(server: TestFixtures.jellyfinServer,
                                                                  token: "jf-token",
                                                                  identity: TestFixtures.jellyfinIdentity,
                                                                  userId: "user-1",
                                                                  collectionId: "boxset-1")
        let childURL = try #require(children.url)
        #expect(childURL.path == "/base/Items")
        #expect(!childURL.path.contains("/Collections"))
        #expect(try queryValue(children, "parentId") == "boxset-1")
        #expect(try queryValue(children, "recursive") == "false")
        // Nested collections stay browsable as containers.
        #expect(try queryValue(children, "includeItemTypes")?.contains("BoxSet") == true)
        // No sort params: preserve the box set's curated child order.
        #expect(try queryValue(children, "sortBy") == nil)
        #expect(try queryValue(children, "sortOrder") == nil)
        #expect(try queryValue(children, "fields") == JellyfinLibrary.gridItemFields)
    }

    @Test func embyCollectionsUseGenericUserItemsNotCollectionManagementEndpoint() throws {
        let list = try EmbyLibrary.collectionsRequest(server: TestFixtures.embyServer,
                                                      token: "emby-token",
                                                      identity: TestFixtures.embyIdentity,
                                                      userId: "user-1",
                                                      parentId: "library-1")
        let listURL = try #require(list.url)
        #expect(listURL.path == "/emby/Users/user-1/Items")
        #expect(!listURL.path.contains("/Collections"))
        #expect(try queryValue(list, "ParentId") == "library-1")
        #expect(try queryValue(list, "IncludeItemTypes") == "BoxSet")
        #expect(try queryValue(list, "Recursive") == "true")
        #expect(list.value(forHTTPHeaderField: "X-Emby-Token") == "emby-token")
        #expect(!listURL.absoluteString.contains("emby-token"))

        let children = try EmbyLibrary.collectionItemsRequest(server: TestFixtures.embyServer,
                                                              token: "emby-token",
                                                              identity: TestFixtures.embyIdentity,
                                                              userId: "user-1",
                                                              collectionId: "boxset-1")
        let childURL = try #require(children.url)
        #expect(childURL.path == "/emby/Users/user-1/Items")
        #expect(!childURL.path.contains("/Collections"))
        #expect(try queryValue(children, "ParentId") == "boxset-1")
        #expect(try queryValue(children, "Recursive") == "false")
        // Nested collections stay browsable as containers.
        #expect(try queryValue(children, "IncludeItemTypes")?.contains("BoxSet") == true)
        // No sort params: preserve the box set's curated child order.
        #expect(try queryValue(children, "SortBy") == nil)
        #expect(try queryValue(children, "SortOrder") == nil)
        #expect(try queryValue(children, "Fields") == EmbyLibrary.gridItemFields)
    }

    @Test func jellyfinRelatedMediaHelpersTargetReadOnlyItemEndpoints() throws {
        let trailers = try JellyfinLibrary.localTrailersRequest(server: TestFixtures.jellyfinServer,
                                                                token: "jf-token",
                                                                identity: TestFixtures.jellyfinIdentity,
                                                                userId: "user-1",
                                                                itemId: "movie-1")
        #expect(try #require(trailers.url).path == "/base/Items/movie-1/LocalTrailers")
        #expect(try queryValue(trailers, "userId") == "user-1")
        #expect(try queryValue(trailers, "fields") == JellyfinLibrary.fullItemFields)

        let features = try JellyfinLibrary.specialFeaturesRequest(server: TestFixtures.jellyfinServer,
                                                                  token: "jf-token",
                                                                  identity: TestFixtures.jellyfinIdentity,
                                                                  userId: "user-1",
                                                                  itemId: "movie-1")
        #expect(try #require(features.url).path == "/base/Items/movie-1/SpecialFeatures")

        let intros = try JellyfinLibrary.introsRequest(server: TestFixtures.jellyfinServer,
                                                       token: "jf-token",
                                                       identity: TestFixtures.jellyfinIdentity,
                                                       userId: "user-1",
                                                       itemId: "movie-1")
        #expect(try #require(intros.url).path == "/base/Items/movie-1/Intros")
    }

    @Test func embyRelatedMediaHelpersTargetReadOnlyUserItemEndpoints() throws {
        let trailers = try EmbyLibrary.localTrailersRequest(server: TestFixtures.embyServer,
                                                            token: "emby-token",
                                                            identity: TestFixtures.embyIdentity,
                                                            userId: "user-1",
                                                            itemId: "movie-1")
        #expect(try #require(trailers.url).path == "/emby/Users/user-1/Items/movie-1/LocalTrailers")
        #expect(try queryValue(trailers, "Fields") == EmbyLibrary.fullItemFields)
        #expect(trailers.value(forHTTPHeaderField: "X-Emby-Token") == "emby-token")
        #expect(!(try #require(trailers.url).absoluteString.contains("emby-token")))

        let features = try EmbyLibrary.specialFeaturesRequest(server: TestFixtures.embyServer,
                                                              token: "emby-token",
                                                              identity: TestFixtures.embyIdentity,
                                                              userId: "user-1",
                                                              itemId: "movie-1")
        #expect(try #require(features.url).path == "/emby/Users/user-1/Items/movie-1/SpecialFeatures")

        let intros = try EmbyLibrary.introsRequest(server: TestFixtures.embyServer,
                                                   token: "emby-token",
                                                   identity: TestFixtures.embyIdentity,
                                                   userId: "user-1",
                                                   itemId: "movie-1")
        #expect(try #require(intros.url).path == "/emby/Users/user-1/Items/movie-1/Intros")
    }
}
