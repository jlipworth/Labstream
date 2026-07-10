import Foundation
import Testing
@testable import PMSKit

@Suite("Library browse query")
struct LibraryBrowseQueryTests {
    private let server = URL(string: "https://plex.example.test")!
    private let identity = ClientIdentity(clientIdentifier: "CID", product: "Labstream", version: "0.1.0", deviceName: "AVP")

    @Test func plexSectionItemsCarriesSortFilterAndPaging() throws {
        let request = PlexLibraryBrowseRequest.sectionItems(
            server: server,
            token: "tok",
            identity: identity,
            sectionKey: "7",
            containerStart: 40,
            containerSize: 20,
            browseQuery: LibraryBrowseQuery(sort: .recentlyAdded, filter: .unwatched))
        let query = try queryMap(request.urlRequest())

        #expect(request.url.path == "/library/sections/7/all")
        #expect(query["sort"] == "addedAt:desc")
        #expect(query["unwatched"] == "1")
        #expect(query["X-Plex-Container-Start"] == "40")
        #expect(query["X-Plex-Container-Size"] == "20")
    }

    @Test func plexWatchedFilterEmitsNegatedUnwatchedOperator() throws {
        let request = PlexLibraryBrowseRequest.sectionItems(
            server: server,
            token: "tok",
            identity: identity,
            sectionKey: "7",
            containerStart: 0,
            containerSize: 20,
            browseQuery: LibraryBrowseQuery(sort: .titleAscending, filter: .watched))
        // The `!` operator is percent-encoded on the wire (`unwatched%21=1`); PMS decodes it
        // back to the `unwatched!=1` negation, so the decoded query name carries the operator.
        let query = try queryMap(request.urlRequest())
        #expect(query["unwatched!"] == "1")
        #expect(query["unwatched"] == nil)
    }

    @Test func plexFilterMappingsUseBooleanMediaQueryFields() {
        #expect(LibraryBrowseQuery(sort: .titleAscending, filter: .all).plexQueryItems.map(\.name) == ["sort"])
        #expect(LibraryBrowseFilter.unwatched.plexQueryItems == [URLQueryItem(name: "unwatched", value: "1")])
        #expect(LibraryBrowseFilter.watched.plexQueryItems == [URLQueryItem(name: "unwatched!", value: "1")])
        #expect(LibraryBrowseFilter.inProgress.plexQueryItems == [URLQueryItem(name: "inProgress", value: "1")])
    }

    @Test func mediaBrowserSortAndFilterMappingsAreCrossBackend() {
        let release = LibraryBrowseQuery(sort: .releaseDate, filter: .inProgress)
        #expect(release.mediaBrowserSortBy == "PremiereDate")
        #expect(release.mediaBrowserSortOrder == "Descending")
        #expect(release.mediaBrowserFilters == ["IsResumable"])

        #expect(LibraryBrowseQuery(sort: .titleDescending, filter: .watched).mediaBrowserSortBy == "SortName")
        #expect(LibraryBrowseQuery(sort: .titleDescending, filter: .watched).mediaBrowserSortOrder == "Descending")
        #expect(LibraryBrowseFilter.unwatched.mediaBrowserFilters == ["IsUnplayed"])
        #expect(LibraryBrowseFilter.watched.mediaBrowserFilters == ["IsPlayed"])
    }

    @Test func alphabetRailOnlyAppliesToUnfilteredTitleAscending() {
        #expect(LibraryBrowseQuery(sort: .titleAscending, filter: .all).supportsAlphabetRail)
        #expect(!LibraryBrowseQuery(sort: .titleDescending, filter: .all).supportsAlphabetRail)
        #expect(!LibraryBrowseQuery(sort: .titleAscending, filter: .unwatched).supportsAlphabetRail)
        #expect(!LibraryBrowseQuery(sort: .recentlyAdded, filter: .all).supportsAlphabetRail)
    }


    @Test func plexCapabilityDiscoveryRequestsUseSectionEndpoints() throws {
        let filters = PlexLibraryBrowseRequest.sectionFilters(server: server,
                                                             token: "tok",
                                                             identity: identity,
                                                             sectionKey: "7")
        let sorts = PlexLibraryBrowseRequest.sectionSorts(server: server,
                                                          token: "tok",
                                                          identity: identity,
                                                          sectionKey: "7")

        #expect(try #require(filters.urlRequest().url).path == "/library/sections/7/filters")
        #expect(try #require(sorts.urlRequest().url).path == "/library/sections/7/sorts")
    }

    @Test func plexCapabilityDiscoveryMapsOnlyAdvertisedControls() throws {
        let filters = try JSONDecoder().decode(PlexLibrarySectionFiltersResponse.self, from: Data(#"""
        {
          "MediaContainer": {
            "Directory": [
              { "filter": "genre", "filterType": "string", "title": "Genre" },
              { "filter": "unwatched", "filterType": "boolean", "title": "Unwatched" },
              { "filter": "inProgress", "filterType": "boolean", "title": "In Progress" }
            ]
          }
        }
        """#.utf8))
        let sorts = try JSONDecoder().decode(PlexLibrarySectionSortsResponse.self, from: Data(#"""
        {
          "MediaContainer": {
            "Directory": [
              { "key": "titleSort", "descKey": "titleSort:desc", "firstCharacterKey": "/library/sections/1/firstCharacter", "title": "Title" },
              { "key": "originallyAvailableAt", "descKey": "originallyAvailableAt:desc", "title": "Release Date" },
              { "key": "rating", "descKey": "rating:desc", "title": "Critic Rating" },
              { "key": "addedAt", "descKey": "addedAt:desc", "title": "Date Added" },
              { "key": "random", "descKey": "random:desc", "title": "Randomly" }
            ]
          }
        }
        """#.utf8))

        let capabilities = LibraryBrowseCapabilities.plex(filters: filters, sorts: sorts)

        #expect(capabilities.sorts == [.titleAscending, .titleDescending, .recentlyAdded, .releaseDate, .rating])
        #expect(capabilities.filters == [.all, .unwatched, .watched, .inProgress])
    }

    @Test func plexCapabilityDiscoveryOmitsUnsupportedFacetControls() throws {
        let filters = PlexLibrarySectionFiltersResponse(mediaContainer: .init(directory: [
            PlexLibraryFilterDescriptor(filter: "unwatched", filterType: "boolean")
        ]))
        let sorts = PlexLibrarySectionSortsResponse(mediaContainer: .init(directory: [
            PlexLibrarySortDescriptor(key: "titleSort", descKey: "titleSort:desc"),
            PlexLibrarySortDescriptor(key: "addedAt", descKey: "addedAt:desc")
        ]))

        let capabilities = LibraryBrowseCapabilities.plex(filters: filters, sorts: sorts)

        #expect(capabilities.sorts == [.titleAscending, .titleDescending, .recentlyAdded])
        #expect(!capabilities.sorts.contains(.rating))
        #expect(!capabilities.sorts.contains(.releaseDate))
        #expect(capabilities.filters == [.all, .unwatched, .watched])
        #expect(!capabilities.filters.contains(.inProgress))
    }

    private func queryMap(_ request: URLRequest) throws -> [String: String] {
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
}
