import Testing
@testable import Labstream
@testable import PMSKit

@Suite("Incremental movie version collapser")
@MainActor
struct MovieVersionCollapserTests {
    @Test func pageDeltasPreserveRepresentativesOrderAndCompleteVersionGroups() {
        let alpha4K = Self.movie("alpha-4k", title: "Alpha", year: 2020)
        let bravo = Self.movie("bravo", title: "Bravo", year: 2021)
        let alphaHD = Self.movie("alpha-hd", title: "Alpha", year: 2020)
        let charlie = Self.movie("charlie", title: "Charlie", year: 2022)
        let alphaSD = Self.movie("alpha-sd", title: "Alpha", year: 2020)

        var collapser = MovieVersionCollapser()
        let first = collapser.ingest([alpha4K, bravo])
        #expect(first.count == 2)
        #expect(first.updates.map(\.index) == [0, 1])
        #expect(collapser.collapsedItems().map(\.ratingKey) == ["alpha-4k", "bravo"])
        #expect(collapser.collapsedItems()[0].versions == nil)
        #expect(collapser.collapsedItems()[1].versions == nil)

        // One page both grows a prior group and encounters the same group again after a new
        // representative. The delta contains each touched projection index exactly once.
        let second = collapser.ingest([alphaHD, charlie, alphaSD])
        #expect(second.count == 3)
        #expect(second.updates.map(\.index) == [0, 2])

        let collapsed = collapser.collapsedItems()
        #expect(collapsed.map(\.ratingKey) == ["alpha-4k", "bravo", "charlie"])
        #expect(collapsed[0].versions?.map(\.ratingKey) == ["alpha-4k", "alpha-hd", "alpha-sd"])
        #expect(collapsed[1].versions == nil)
        #expect(collapsed[2].versions == nil)
    }

    @Test func incrementalProjectionMatchesSinglePassAcrossEveryPageBoundary() {
        let items = [
            Self.movie("a1", title: "Alpha", year: 2020),
            Self.movie("b1", title: "Bravo", year: 2021),
            Self.movie("a2", title: "Alpha", year: 2020),
            Self.movie("c1", title: "Charlie", year: 2022),
            Self.movie("b2", title: "Bravo", year: 2021),
            Self.movie("a3", title: "Alpha", year: 2020),
        ]
        let expected = items.collapsingMovieVersions()

        for split1 in 0...items.count {
            for split2 in split1...items.count {
                var collapser = MovieVersionCollapser()
                collapser.ingest(Array(items[..<split1]))
                collapser.ingest(Array(items[split1..<split2]))
                collapser.ingest(Array(items[split2...]))

                let actual = collapser.collapsedItems()
                #expect(actual.map(\.ratingKey) == expected.map(\.ratingKey))
                #expect(actual.map { $0.versions?.map(\.ratingKey) }
                    == expected.map { $0.versions?.map(\.ratingKey) })
            }
        }
    }

#if DEBUG
    @Test func pageWorkDoesNotRevisitUnrelatedHistory() {
        var collapser = MovieVersionCollapser()
        let largeFirstPage = (0..<500).map { item in
            Self.movie("first-\(item)", title: "Movie \(item)", year: 2000 + item)
        }
        collapser.ingest(largeFirstPage)
        #expect(collapser.groupedItemCountForTesting == 500)
        #expect(collapser.projectedVersionMemberCountForTesting == 0)

        // Growing one existing group performs one identity visit and republishes only that
        // two-member versions snapshot; the other 499 representatives are not revisited.
        collapser.ingest([Self.movie("second-0", title: "Movie 0", year: 2000)])
        #expect(collapser.groupedItemCountForTesting == 501)
        #expect(collapser.projectedVersionMemberCountForTesting == 2)
        #expect(collapser.collapsedItems().count == 500)
    }

    @Test func growingVersionSnapshotCostIsExplicitAcrossPageBoundaries() {
        var collapser = MovieVersionCollapser()
        for page in 1...40 {
            collapser.ingest([Self.movie("version-\(page)", title: "One Movie", year: 2020)])
        }

        #expect(collapser.groupedItemCountForTesting == 40)
        // Singleton projection is free; each later page publishes the full group discovered so
        // far. This is the immutable output contract, not a hidden full-history recollapse.
        #expect(collapser.projectedVersionMemberCountForTesting == (2...40).reduce(0, +))
        #expect(collapser.collapsedItems()[0].versions?.count == 40)
    }
#endif

    private static func movie(_ ratingKey: String, title: String, year: Int) -> MediaItem {
        MediaItem(ratingKey: ratingKey, title: title, type: "movie", year: year)
    }
}
