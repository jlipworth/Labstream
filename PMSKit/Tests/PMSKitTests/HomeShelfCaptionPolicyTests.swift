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

    @Test func anyProgressMakesEveryCardShowTimeLeft() {
        let items = [movie("a", offset: 4_620_000), movie("b"), episode("c")]
        let kind = HomeShelfCaptionPolicy.kind(for: items)
        #expect(kind == .timeLeft)
        #expect(HomeShelfCaptionPolicy.caption(for: items[0], kind: kind) == "23m left")
        // An unstarted sibling still reads as time left, never as a bare runtime.
        #expect(HomeShelfCaptionPolicy.caption(for: items[1], kind: kind) == "1h 40m left")
        #expect(HomeShelfCaptionPolicy.caption(for: items[2], kind: kind) == "45m left")
    }

    @Test func episodeOnlyShelvesUseTheEpisodeCode() {
        let items = [episode("a"), episode("b", season: 2, number: 1)]
        let kind = HomeShelfCaptionPolicy.kind(for: items)
        #expect(kind == .episode)
        #expect(HomeShelfCaptionPolicy.caption(for: items[1], kind: kind) == "S2E1 · Pilot")
    }

    @Test func yearOnlyWhenEverySiblingHasOne() {
        #expect(HomeShelfCaptionPolicy.kind(for: [movie("a"), movie("b")]) == .year)
        #expect(HomeShelfCaptionPolicy.kind(for: [movie("a"), movie("b", year: nil)]) == .none)
        #expect(HomeShelfCaptionPolicy.kind(for: []) == .none)
    }

    @Test(arguments: [
        (0, "1m left"),
        (29_000, "1m left"),
        (1_380_000, "23m left"),
        (3_600_000, "1h left"),
        (3_720_000, "1h 2m left"),
    ])
    func timeLeftFormat(milliseconds: Int, expected: String) {
        #expect(HomeShelfCaptionPolicy.timeLeft(milliseconds: milliseconds) == expected)
    }
}
