import Foundation
import Testing
@testable import PMSKit

private struct BrowseRequestGolden {
    let name: String
    let request: PlexRequest
    let path: String
    let queryItems: [(String, String)]
}

@Test func plexBrowseRequestsMatchWireGoldens() {
    let server = TestFixtures.plexServer
    let identity = TestFixtures.plexIdentity
    let token = "browse-token"

    let goldens = [
        BrowseRequestGolden(
            name: "sections",
            request: PlexBrowseRequest.sections(server: server, token: token, identity: identity),
            path: "/library/sections",
            queryItems: []
        ),
        BrowseRequestGolden(
            name: "section items",
            request: PlexBrowseRequest.sectionItems(
                server: server,
                token: token,
                identity: identity,
                sectionKey: "7",
                containerStart: 40,
                containerSize: 20,
                sort: "titleSort:asc",
                firstCharacter: "#"
            ),
            path: "/library/sections/7/all",
            queryItems: [
                ("sort", "titleSort:asc"),
                ("firstCharacter", "#"),
                ("X-Plex-Container-Start", "40"),
                ("X-Plex-Container-Size", "20"),
            ]
        ),
        BrowseRequestGolden(
            name: "first characters",
            request: PlexBrowseRequest.firstCharacters(
                server: server, token: token, identity: identity, sectionKey: "7", type: 9
            ),
            path: "/library/sections/7/firstCharacter",
            queryItems: [("type", "9")]
        ),
        BrowseRequestGolden(
            name: "hubs",
            request: PlexBrowseRequest.hubs(server: server, token: token, identity: identity),
            path: "/hubs",
            queryItems: [("count", "20")]
        ),
        BrowseRequestGolden(
            name: "on deck",
            request: PlexBrowseRequest.onDeck(server: server, token: token, identity: identity),
            path: "/library/onDeck",
            queryItems: []
        ),
        BrowseRequestGolden(
            name: "search",
            request: PlexBrowseRequest.search(
                server: server, token: token, identity: identity, query: "film & tv"
            ),
            path: "/hubs/search",
            queryItems: [("query", "film & tv"), ("limit", "30")]
        ),
        BrowseRequestGolden(
            name: "children",
            request: PlexBrowseRequest.children(
                server: server, token: token, identity: identity, ratingKey: "123"
            ),
            path: "/library/metadata/123/children",
            queryItems: [("includeChapters", "1"), ("includeMarkers", "1")]
        ),
        BrowseRequestGolden(
            name: "metadata",
            request: PlexBrowseRequest.metadata(
                server: server, token: token, identity: identity, ratingKey: "123"
            ),
            path: "/library/metadata/123",
            queryItems: [
                ("includeChapters", "1"),
                ("includeMarkers", "1"),
                ("includeExtras", "1"),
            ]
        ),
    ]

    let expectedHeaders = [
        "X-Plex-Client-Identifier": "CID",
        "X-Plex-Product": "Labstream",
        "X-Plex-Version": "0.1.0",
        "X-Plex-Platform": "visionOS",
        "X-Plex-Device": "AVP",
        "X-Plex-Device-Name": "AVP",
        "X-Plex-Token": token,
        "Accept": "application/json",
    ]

    for golden in goldens {
        #expect(golden.request.method == "GET", Comment(rawValue: golden.name))
        #expect(golden.request.url.scheme == "https", Comment(rawValue: golden.name))
        #expect(golden.request.url.host == "192.0.2.10", Comment(rawValue: golden.name))
        #expect(golden.request.url.port == 32400, Comment(rawValue: golden.name))
        #expect(golden.request.url.path == golden.path, Comment(rawValue: golden.name))
        #expect(golden.request.queryItems.map { ($0.name, $0.value ?? "") }
                .elementsEqual(golden.queryItems, by: ==), Comment(rawValue: golden.name))
        #expect(golden.request.headers == expectedHeaders, Comment(rawValue: golden.name))
        #expect(golden.request.body == nil, Comment(rawValue: golden.name))
    }
}

@Test func plexBrowseOptionalQueriesPreserveLegacyEmissionRules() {
    let server = TestFixtures.plexServer
    let identity = TestFixtures.plexIdentity

    let empty = PlexBrowseRequest.sectionItems(
        server: server, token: "tok", identity: identity, sectionKey: "1"
    )
    #expect(empty.queryItems.isEmpty)

    let startOnly = PlexBrowseRequest.sectionItems(
        server: server, token: "tok", identity: identity,
        sectionKey: "1", containerStart: 20
    )
    let sizeOnly = PlexBrowseRequest.sectionItems(
        server: server, token: "tok", identity: identity,
        sectionKey: "1", containerSize: 20
    )
    #expect(startOnly.queryItems.isEmpty)
    #expect(sizeOnly.queryItems.isEmpty)

    let untypedInitials = PlexBrowseRequest.firstCharacters(
        server: server, token: "tok", identity: identity, sectionKey: "1"
    )
    #expect(untypedInitials.queryItems.isEmpty)
}

@Test func plexBrowseChildrenDelegatesToAuthoritativeBuilder() {
    let server = TestFixtures.plexServer
    let identity = TestFixtures.plexIdentity
    let forwarded = PlexBrowseRequest.children(
        server: server, token: "tok", identity: identity, ratingKey: "42"
    )
    let authoritative = ChildrenRequest.children(
        server: server, token: "tok", identity: identity, ratingKey: "42"
    )
    #expect(forwarded == authoritative)
}

@Test func plexBrowseBuilderPreservesBasePathAndOrderedEncodedQuery() throws {
    let server = try #require(URL(string: "https://plex.example.test/proxy/root"))
    let request = PlexBrowseRequest.sectionItems(
        server: server,
        token: "tok",
        identity: TestFixtures.plexIdentity,
        sectionKey: "7",
        containerStart: 0,
        containerSize: 30,
        sort: "titleSort:asc",
        firstCharacter: "#"
    ).urlRequest()

    #expect(request.url?.absoluteString ==
            "https://plex.example.test/proxy/root/library/sections/7/all" +
            "?sort=titleSort%3Aasc&firstCharacter=%23" +
            "&X-Plex-Container-Start=0&X-Plex-Container-Size=30")
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "X-Plex-Token") == "tok")
}
