import Foundation
import Testing
@testable import PMSKit

struct HomeShelfCaptionPolicyTests {
    private func movie(_ id: String, year: Int? = 2024, duration: Int? = 6_000_000,
                       offset: Int? = nil) -> MediaItem {
        MediaItem(ratingKey: id, title: "Movie \(id)", type: "movie",
                  duration: duration, viewOffset: offset, year: year)
    }

    private func episode(_ id: String, season: Int = 1, number: Int = 3) -> MediaItem {
        MediaItem(ratingKey: id, title: "Pilot", type: "episode", duration: 2_700_000, year: 2024,
                  grandparentTitle: "Show", parentIndex: season, index: number)
    }

    @Test func resumeShelvesShowTimeLeftOnEveryCard() {
        let items = [movie("a", offset: 4_620_000), movie("b"), episode("c")]
        let kind = HomeShelfCaptionPolicy.kind(for: items, shelfIdentifier: "home.continue")
        #expect(kind == .timeLeft)
        #expect(HomeShelfCaptionPolicy.caption(for: items[0], kind: kind) == "23m left")
        // An unstarted sibling still reads as time left, never as a bare runtime.
        #expect(HomeShelfCaptionPolicy.caption(for: items[1], kind: kind) == "100m left")
        #expect(HomeShelfCaptionPolicy.caption(for: items[2], kind: kind) == "45m left")
    }

    @Test func episodeOnlyShelvesUseTheEpisodeCode() {
        let items = [episode("a"), episode("b", season: 2, number: 1)]
        let kind = HomeShelfCaptionPolicy.kind(for: items, shelfIdentifier: "home.recentlyadded")
        #expect(kind == .episode)
        #expect(HomeShelfCaptionPolicy.caption(for: items[1], kind: kind) == "S2E1 · Pilot")
    }

    @Test func yearOnlyWhenEverySiblingHasOne() {
        #expect(HomeShelfCaptionPolicy.kind(for: [movie("a"), movie("b")], shelfIdentifier: nil) == .year)
        #expect(HomeShelfCaptionPolicy.kind(for: [movie("a"), movie("b", year: nil)], shelfIdentifier: nil) == .none)
        #expect(HomeShelfCaptionPolicy.kind(for: [], shelfIdentifier: "home.continue") == .none)
    }

    @Test(arguments: ["home.continue", "home.ondeck", "jellyfin-continue-watching", "emby-next-up",
                      "fixture-resume"])
    func resumeIdentifiers(identifier: String) {
        #expect(HomeShelfCaptionPolicy.isResumeShelf(identifier: identifier))
    }

    /// A resume shelf where one card has no duration falls back to a shared field instead of
    /// leaving that card's line empty among "Nm left" siblings.
    @Test func aResumeShelfWithAMissingDurationFallsBack() {
        let items = [movie("a", offset: 600_000), movie("b", duration: nil)]
        let kind = HomeShelfCaptionPolicy.kind(for: items, shelfIdentifier: "home.continue")
        #expect(kind == .year)
        #expect(items.allSatisfy { HomeShelfCaptionPolicy.caption(for: $0, kind: kind) != nil })
    }

    @Test func timeLeftIsAlwaysTwoWords() {
        for ms in [0, 1_380_000, 4_980_000, 9_000_000] {
            #expect(HomeShelfCaptionPolicy.timeLeft(milliseconds: ms).split(separator: " ").count == 2)
        }
    }

    @Test func aStartedItemInRecentlyAddedKeepsTheShelfField() {
        let items = [movie("a", offset: 600_000), movie("b")]
        #expect(HomeShelfCaptionPolicy.kind(for: items, shelfIdentifier: "home.movies.recent") == .year)
    }

    @Test(arguments: [
        (0, "1m left"),
        (29_000, "1m left"),
        (1_380_000, "23m left"),
        (3_600_000, "60m left"),
        (4_980_000, "83m left"),
    ])
    func timeLeftFormat(milliseconds: Int, expected: String) {
        #expect(HomeShelfCaptionPolicy.timeLeft(milliseconds: milliseconds) == expected)
    }
}
