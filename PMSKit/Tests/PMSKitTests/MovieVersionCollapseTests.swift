import Foundation
import Testing
@testable import PMSKit

/// GH #108 rework: robust movie-version identity, the incremental collapse algorithm
/// (`collapsingMovieVersions`), the `MediaItem.with(versions:)` copy helper, the
/// collapsed-space alphabet rail (`AlphabetBucket.buckets(fromTitles:)`), and the
/// backward-compatible `providerIds` decode.
@Suite("Movie version collapse (#108)")
struct MovieVersionCollapseTests {

    private func movie(_ ratingKey: String,
                       title: String,
                       year: Int? = nil,
                       providerIds: [String: String]? = nil) -> MediaItem {
        MediaItem(ratingKey: ratingKey, title: title, type: "movie",
                  year: year, providerIds: providerIds)
    }

    // MARK: - Identity logic (finding 4)

    @Test func tmdbIdentityWinsOverTitleAndYear() {
        // Two differently-titled editions of the same film (different years even) collapse
        // by their shared Tmdb id.
        let a = movie("a", title: "Blade Runner", year: 1982, providerIds: ["Tmdb": "78"])
        let b = movie("b", title: "Blade Runner: Final Cut", year: 2007, providerIds: ["Tmdb": "78"])
        #expect(a.movieVersionIdentity == "tmdb:78")
        #expect(a.movieVersionIdentity == b.movieVersionIdentity)
    }

    @Test func imdbIdentityUsedWhenNoTmdb() {
        let a = movie("a", title: "Heat", year: 1995, providerIds: ["Imdb": "tt0113277"])
        #expect(a.movieVersionIdentity == "imdb:tt0113277")
    }

    @Test func providerKeyNameMatchedCaseInsensitively() {
        let lower = movie("a", title: "X", year: 2000, providerIds: ["tmdb": "5"])
        let upper = movie("b", title: "X", year: 2000, providerIds: ["TMDB": "5"])
        #expect(lower.movieVersionIdentity == "tmdb:5")
        #expect(lower.movieVersionIdentity == upper.movieVersionIdentity)
    }

    @Test func titleYearIdentityWhenNoProviderId() {
        let a = movie("a", title: "The Thing", year: 1982)
        let b = movie("b", title: "the thing ", year: 1982) // case/whitespace normalized
        #expect(a.movieVersionIdentity == "title:the thing|1982")
        #expect(a.movieVersionIdentity == b.movieVersionIdentity)
    }

    @Test func differentYearsDoNotMergeWithoutProviderId() {
        let a = movie("a", title: "The Thing", year: 1982)
        let b = movie("b", title: "The Thing", year: 2011)
        #expect(a.movieVersionIdentity != b.movieVersionIdentity)
    }

    @Test func yearlessIdlessItemsNeverMerge() {
        // The old "title|?" token mass-collapsed these into one tile — the bug. Each must
        // now get a unique key so distinct year-less same-title items stay separate.
        let a = movie("a", title: "Untitled")
        let b = movie("b", title: "Untitled")
        #expect(a.movieVersionIdentity == "uid:a")
        #expect(b.movieVersionIdentity == "uid:b")
        #expect(a.movieVersionIdentity != b.movieVersionIdentity)
    }

    @Test func emptyProviderValueFallsThroughToTitleYear() {
        let a = movie("a", title: "Gattaca", year: 1997, providerIds: ["Tmdb": "  "])
        #expect(a.movieVersionIdentity == "title:gattaca|1997")
    }

    // MARK: - collapsingMovieVersions algorithm

    @Test func collapsesDuplicatesIntoOneRepresentativeWithVersions() {
        let items = [
            movie("4k", title: "Dune", year: 2021, providerIds: ["Tmdb": "438631"]),
            movie("1080", title: "Dune", year: 2021, providerIds: ["Tmdb": "438631"]),
            movie("other", title: "Arrival", year: 2016, providerIds: ["Tmdb": "329865"]),
        ]
        let collapsed = items.collapsingMovieVersions()
        #expect(collapsed.count == 2)
        // First-seen representative wins; carries the full ordered group on `versions`.
        let dune = collapsed[0]
        #expect(dune.ratingKey == "4k")
        #expect(dune.versions?.map(\.ratingKey) == ["4k", "1080"])
        // Single-member group keeps versions nil.
        #expect(collapsed[1].versions == nil)
    }

    @Test func preservesFirstAppearanceOrder() {
        let items = [
            movie("b", title: "Beta", year: 2000),
            movie("a", title: "Alpha", year: 2001),
            movie("b2", title: "Beta", year: 2000),
        ]
        let collapsed = items.collapsingMovieVersions()
        #expect(collapsed.map(\.ratingKey) == ["b", "a"])
    }

    @Test func incrementalIngestMatchesSinglePassCollapse() {
        // Simulates the collapser ingesting pages incrementally: the deduped result over the
        // concatenation must equal a single-pass collapse, regardless of page boundaries.
        let page1 = [
            movie("4k", title: "Dune", year: 2021, providerIds: ["Tmdb": "438631"]),
            movie("a", title: "Arrival", year: 2016),
        ]
        let page2 = [
            movie("1080", title: "Dune", year: 2021, providerIds: ["Tmdb": "438631"]),
            movie("c", title: "Contact", year: 1997),
        ]
        let incremental = (page1 + page2).collapsingMovieVersions()
        #expect(incremental.map(\.ratingKey) == ["4k", "a", "c"])
        #expect(incremental[0].versions?.map(\.ratingKey) == ["4k", "1080"])
    }

    // MARK: - MediaItem.with(versions:) (finding 9)

    @Test func withVersionsPreservesEveryFieldAndSetsVersions() {
        let original = MediaItem(ratingKey: "rk", key: "/k", title: "T", type: "movie",
                                 duration: 1000, year: 1999, summary: "s",
                                 primaryImageAspectRatio: 1.5,
                                 providerIds: ["Tmdb": "1"])
        let group = [original, movie("rk2", title: "T", year: 1999)]
        let copy = original.with(versions: group)
        #expect(copy.versions?.map(\.ratingKey) == ["rk", "rk2"])
        // Untouched fields survive verbatim.
        #expect(copy.ratingKey == "rk")
        #expect(copy.key == "/k")
        #expect(copy.duration == 1000)
        #expect(copy.summary == "s")
        #expect(copy.primaryImageAspectRatio == 1.5)
        #expect(copy.providerIds == ["Tmdb": "1"])
    }

    @Test func withVersionsCanClearVersions() {
        let original = movie("rk", title: "T", year: 1999).with(versions: [movie("x", title: "T", year: 1999)])
        #expect(original.with(versions: nil).versions == nil)
    }

    // MARK: - Collapsed-space alphabet rail (finding 1 / F1)

    @Test func bucketsFromTitlesIndexIntoTheDisplayedList() {
        // Offsets are list indices (not server offsets), so they line up with the grid's
        // .id(index) scroll targets.
        let titles = ["Alpha", "Apple", "Beta", "Zeta"]
        let buckets = AlphabetBucket.buckets(fromTitles: titles)
        #expect(buckets.map(\.display) == ["A", "B", "Z"])
        #expect(buckets.map(\.offset) == [0, 2, 3])
        #expect(buckets.map(\.count) == [2, 1, 1])
    }

    @Test func bucketsFromTitlesGroupNonAlphabeticUnderHash() {
        let titles = ["1917", "300", "Avatar"]
        let buckets = AlphabetBucket.buckets(fromTitles: titles)
        #expect(buckets.map(\.display) == ["#", "A"])
        #expect(buckets.first?.count == 2)
        #expect(buckets.first?.offset == 0)
    }

    @Test func bucketsFromTitlesEmptyForEmptyList() {
        #expect(AlphabetBucket.buckets(fromTitles: []).isEmpty)
    }

    // MARK: - providerIds backward-compatible decode

    @Test func providerIdsDecodeNilWhenAbsent() throws {
        // A Plex-style payload (and every pre-existing fixture) omits providerIds → nil.
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(#"""
        { "ratingKey": "1", "title": "Movie", "type": "movie", "year": 2000 }
        """#.utf8))
        #expect(item.providerIds == nil)
        // Year-bearing item still collapses by title|year.
        #expect(item.movieVersionIdentity == "title:movie|2000")
    }

    @Test func jellyfinDtoDecodesProviderIds() throws {
        let dto = try JSONDecoder().decode(JellyfinBaseItemDto.self, from: Data(#"""
        {
          "Id": "movie-1", "Name": "Dune", "Type": "Movie", "ProductionYear": 2021,
          "ProviderIds": { "Tmdb": "438631", "Imdb": "tt1160419" }
        }
        """#.utf8))
        let item = try #require(dto.toMediaItem())
        #expect(item.providerIds?["Tmdb"] == "438631")
        #expect(item.movieVersionIdentity == "tmdb:438631")
    }

    @Test func jellyfinDtoLeavesProviderIdsNilWhenAbsent() throws {
        let dto = try JSONDecoder().decode(JellyfinBaseItemDto.self, from: Data(#"""
        { "Id": "movie-2", "Name": "Arrival", "Type": "Movie", "ProductionYear": 2016 }
        """#.utf8))
        let item = try #require(dto.toMediaItem())
        #expect(item.providerIds == nil)
    }
}
