import Testing
@testable import PMSKit

private func titled(_ title: String, key: String? = nil) -> MediaItem {
    MediaItem(ratingKey: key ?? title, title: title, type: "movie")
}

@Test func searchTitleNormalizationHandlesCaseDiacriticsWidthAndPunctuation() {
    #expect(SearchTitleRanking.normalized("  CAFÉ—Moon: Ａ  ") == "cafe moon a")
    let items = [titled("Café—Moon: Return"), titled("CAFE Moon"), titled("Moon Café")]
    #expect(SearchTitleRanking.ranked(items, query: " café moon ").map(\.title)
            == ["CAFE Moon", "Café—Moon: Return", "Moon Café"])
}

@Test func searchTitleRanksExactThenPrefixThenMultiwordThenTypoAndMetadata() {
    let items = ["Unrelated metadata hit", "Paper Moin", "The Moon of Paper", "Paper Moon Rising", "Paper Moon"].map { titled($0) }
    #expect(SearchTitleRanking.ranked(items, query: "paper moon").map(\.title)
            == ["Paper Moon", "Paper Moon Rising", "The Moon of Paper", "Paper Moin", "Unrelated metadata hit"])
    #expect(SearchTitleRanking.ranked([titled("Paper Mountain"), titled("Moon Paper")], query: "pap moo")
        .map(\.title) == ["Moon Paper", "Paper Mountain"])
}

@Test func searchTitleToleratesOneEditButDoesNotFuzzShortWords() {
    for query in ["horizno", "horizn", "horizonn", "horixon"] {
        #expect(SearchTitleRanking.ranked([titled("Other"), titled("Horizon")], query: query).first?.title == "Horizon")
    }
    // Short and two-edit misses retain server relevance, including non-title hits.
    for query in ["sun", "hxxizon"] {
        #expect(SearchTitleRanking.ranked([titled("Other"), titled("Son Horizon")], query: query).first?.title == "Other")
    }
}

@Test func searchTitleOrderingIsStableAndDoesNotDropServerHits() {
    let a = titled("Moon", key: "a"), b = titled("MOON", key: "b")
    #expect(SearchTitleRanking.ranked([b, a], query: "moon").map(\.ratingKey) == ["a", "b"])
    #expect(SearchTitleRanking.ranked([a, b], query: "moon").map(\.ratingKey) == ["a", "b"])
    #expect(SearchTitleRanking.ranked([b, a], query: "   ").map(\.ratingKey) == ["b", "a"])
}

@Test func rankedProjectionKeepsBackendLibraryAndTypeBoundaries() throws {
    for backend in [MediaBackendID.plex, .jellyfin, .emby] {
        let first = try #require(SearchResultGroup.mediaBrowserLibrary(backendID: backend,
            libraryID: "first", title: "First", items: [titled("Moon Return"), titled("Moon")]))
        let second = try #require(SearchResultGroup.mediaBrowserLibrary(backendID: backend,
            libraryID: "second", title: "Second", items: [titled("Moon", key: "other-library"),
                MediaItem(ratingKey: "song", title: "Moon", type: "track")]))
        let groups = SearchResults(groups: [first, second]).presentationGroups(query: "moon")
        #expect(groups.map(\.libraryID) == ["first", "second"])
        #expect(groups[0].sections[0].items.map(\.title) == ["Moon", "Moon Return"])
        #expect(groups[1].sections.map(\.kind) == [.standard, .songs])
        #expect(groups[1].sections[0].items[0].ratingKey == "other-library")
    }
}

@Test func multiwordPrefixesConsumeDistinctWordsMostSpecificFirst() {
    let items = [titled("Other"), titled("Stars Starship")]
    #expect(SearchTitleRanking.ranked(items, query: "star stars").first?.title == "Stars Starship")
    #expect(SearchTitleRanking.ranked(items, query: "starship starship").first?.title == "Other")
}

@Test func fuzzyWordsDoNotStealAnotherTokensOnlyMatch() {
    let items = [titled("Other"), titled("Cast Fast")]
    #expect(SearchTitleRanking.ranked(items, query: "east cant").first?.title == "Cast Fast")
}
