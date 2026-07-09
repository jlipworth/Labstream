import Testing
@testable import PMSKit

private func searchItem(_ key: String, _ type: String,
                        section: String? = nil) -> MediaItem {
    MediaItem(ratingKey: key, title: "\(type)-\(key)", type: type,
              librarySectionKey: section)
}

@Test func searchProjectionKeepsLibrariesAndVideoBeforeMusic() throws {
    let first = try #require(SearchResultGroup.mediaBrowserLibrary(
        backendID: .jellyfin, libraryID: "music", title: "Music",
        items: [searchItem("t", "track"), searchItem("a", "artist")]))
    let second = try #require(SearchResultGroup.mediaBrowserLibrary(
        backendID: .jellyfin, libraryID: "mixed", title: "Mixed",
        items: [searchItem("album", "album"), searchItem("movie", "movie"),
                searchItem("song", "track"), searchItem("show", "show")]))

    let projected = SearchResults(groups: [first, second]).presentationGroups
    #expect(projected.map(\.libraryID) == ["music", "mixed"])
    #expect(projected[0].sections.map(\.kind) == [.artists, .songs])
    #expect(projected[1].sections.map(\.kind) == [.standard, .standard, .albums, .songs])
    #expect(projected[1].sections.map(\.title) == ["Movies", "Shows", "Albums", "Songs"])
}

@Test func searchProjectionPreservesCollectionsAndExtrasBeforeMusic() throws {
    let group = try #require(SearchResultGroup.mediaBrowserLibrary(
        backendID: .emby, libraryID: "mixed", title: "Mixed",
        items: [searchItem("song", "track"), searchItem("collection", "collection"),
                searchItem("trailer", "trailer"), searchItem("extra", "extra"),
                searchItem("movie", "movie")]))

    let sections = SearchResults(groups: [group]).presentationGroups[0].sections
    #expect(sections.map(\.title) == ["Movies", "Collections", "Trailers & Extras", "Songs"])
    #expect(sections.map(\.kind) == [.standard, .standard, .standard, .songs])
    #expect(sections[2].items.map(\.ratingKey) == ["trailer", "extra"])
}

@Test func searchProjectionKeepsMultipleMusicLibrariesSeparate() throws {
    let jazz = try #require(SearchResultGroup.mediaBrowserLibrary(
        backendID: .emby, libraryID: "jazz", title: "Jazz",
        items: [searchItem("1", "artist"), searchItem("2", "album")]))
    let classical = try #require(SearchResultGroup.mediaBrowserLibrary(
        backendID: .emby, libraryID: "classical", title: "Classical",
        items: [searchItem("1", "artist"), searchItem("3", "track")]))

    let projected = SearchResults(groups: [jazz, classical]).presentationGroups
    #expect(projected.map(\.title) == ["Jazz", "Classical"])
    #expect(projected[0].sections.flatMap(\.items).map(\.ratingKey) == ["1", "2"])
    // The same backend id in another source library is intentionally retained.
    #expect(projected[1].sections.flatMap(\.items).map(\.ratingKey) == ["1", "3"])
}

@Test func searchGroupingDeduplicatesWithinTypeAndDropsEmptyGroups() throws {
    let group = try #require(SearchResultGroup.mediaBrowserLibrary(
        backendID: .plex, libraryID: "5", title: "Music",
        items: [searchItem("artist", "artist"), searchItem("artist", "artist"),
                searchItem("track", "track")]))
    let empty = SearchResultGroup(id: "empty", libraryID: "empty", title: "Empty",
                                  hubs: [Hub(title: "Songs")])

    let results = SearchResults(groups: [empty, group])
    #expect(results.presentationGroups.count == 1)
    #expect(results.presentationGroups[0].sections[0].items.count == 1)
    #expect(results.presentationGroups[0].sections.map(\.kind) == [.artists, .songs])
}

@Test func plexSearchKeepsFirstEncounterLibraryOrderAndExplicitIdentity() {
    let hubs = [Hub(title: "Native", metadata: [
        searchItem("m2", "movie", section: "/library/sections/2"),
        searchItem("a5", "artist", section: "5"),
        searchItem("m2b", "show", section: "2"),
    ])]
    let sections = [Section(key: "5", title: "Music", type: "artist"),
                    Section(key: "2", title: "Video", type: "movie")]

    let results = SearchResults.plexNativeHubs(hubs, sections: sections)
    #expect(results.presentationGroups.map(\.libraryID) == ["2", "5"])
    #expect(results.presentationGroups.map(\.title) == ["Video", "Music"])
}

@Test func plexUnattributedResultsDoNotInventALibraryIdentity() {
    let hubs = [Hub(title: "Native", metadata: [searchItem("a", "artist")])]
    let results = SearchResults.plexNativeHubs(hubs, sections: [])

    #expect(results.presentationGroups.count == 1)
    #expect(results.presentationGroups[0].libraryID == nil)
    #expect(results.presentationGroups[0].title == "All Plex Libraries")
}
