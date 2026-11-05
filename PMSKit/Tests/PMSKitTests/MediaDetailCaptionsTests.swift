import Foundation
import Testing
@testable import PMSKit

struct MediaDetailCaptionsTests {
    private func episode(_ season: Int?, _ number: Int?, duration: Int? = 2_280_000,
                         offset: Int? = nil, viewCount: Int? = nil,
                         lastViewedAt: Int? = nil) -> MediaItem {
        MediaItem(ratingKey: "e-\(season ?? -1)-\(number ?? -1)", title: "Episode", type: "episode",
                  duration: duration, viewOffset: offset, viewCount: viewCount,
                  parentIndex: season, index: number, lastViewedAt: lastViewedAt)
    }

    @Test func runtimeReadsHoursAndMinutes() {
        #expect(MediaDetailCaptions.runtime(milliseconds: 7_140_000) == "1h 59m")
        #expect(MediaDetailCaptions.runtime(milliseconds: 2_280_000) == "38m")
        #expect(MediaDetailCaptions.runtime(milliseconds: 7_200_000) == "2h")
        #expect(MediaDetailCaptions.runtime(milliseconds: 10_000) == "1m")
        #expect(MediaDetailCaptions.runtime(milliseconds: 0) == nil)
        #expect(MediaDetailCaptions.runtime(milliseconds: nil) == nil)
    }

    @Test func movieContextIsYearRuntimeRating() {
        let movie = MediaItem(ratingKey: "m", title: "M", type: "movie", duration: 7_140_000,
                              year: 2026, contentRating: "PG-13")
        #expect(MediaDetailCaptions.movieContext(movie) == ["2026", "1h 59m", "PG-13"])
        let bare = MediaItem(ratingKey: "b", title: "B", type: "movie", contentRating: "  ")
        #expect(MediaDetailCaptions.movieContext(bare).isEmpty)
    }

    @Test func timeLeftOnlyForStartedUnfinishedItems() {
        #expect(MediaDetailCaptions.timeLeft(for: episode(1, 3, offset: 900_000)) == "23m left")
        #expect(MediaDetailCaptions.timeLeft(for: episode(1, 3)) == nil)
        #expect(MediaDetailCaptions.timeLeft(for: episode(1, 3, offset: 2_280_000)) == nil)
        #expect(MediaDetailCaptions.timeLeft(for: episode(1, 3, duration: nil, offset: 10)) == nil)
    }

    @Test func showAndSeasonContext() {
        #expect(MediaDetailCaptions.showContext(seasonCount: 3, contentRating: "TV-14", year: 2024)
                == ["3 seasons", "TV-14"])
        #expect(MediaDetailCaptions.showContext(seasonCount: 1, contentRating: nil, year: nil) == ["1 season"])
        #expect(MediaDetailCaptions.showContext(seasonCount: nil, contentRating: nil, year: 2024) == ["2024"])
        #expect(MediaDetailCaptions.episodeCount(8) == "8 episodes")
        #expect(MediaDetailCaptions.episodeCount(1) == "1 episode")
        #expect(MediaDetailCaptions.episodeCount(0) == nil)
    }

    @Test func episodeRowNamesOnlyTheEpisodeNumber() {
        #expect(MediaDetailCaptions.episodeRow(episode(1, 1)) == "E1 · 38m")
        #expect(MediaDetailCaptions.episodeRow(episode(1, 3, offset: 900_000)) == "E3 · 23m left")
        #expect(MediaDetailCaptions.episodeRow(episode(1, 4, duration: nil)) == "E4")
        #expect(MediaDetailCaptions.episodeRow(episode(1, nil)) == "38m")
    }

    @Test func resumeLabelAndTimeLeftForAStartedEpisode() throws {
        let episodes = [episode(1, 1, viewCount: 1), episode(1, 2, viewCount: 1),
                        episode(1, 3, offset: 900_000), episode(1, 4)]
        let plan = try #require(ShowResumePlan.plan(episodes: episodes))
        #expect(plan.action == .resume)
        #expect(plan.label == "Resume S1, E3")
        #expect(plan.timeLeft == "23m left")
    }

    @Test func mostRecentlyViewedStartedEpisodeWins() throws {
        let episodes = [episode(2, 1, offset: 600_000, lastViewedAt: 100),
                        episode(1, 5, offset: 600_000, lastViewedAt: 200)]
        let plan = try #require(ShowResumePlan.plan(episodes: episodes))
        #expect(plan.label == "Resume S1, E5")
    }

    @Test func nextUnwatchedAfterTheLastWatchedIsPlayed() throws {
        let episodes = [episode(2, 1), episode(1, 2, viewCount: 1), episode(1, 1, viewCount: 1),
                        episode(1, 3)]
        let plan = try #require(ShowResumePlan.plan(episodes: episodes))
        #expect(plan.action == .play)
        #expect(plan.label == "Play S1, E3")
        #expect(plan.timeLeft == nil)
    }

    @Test func freshOrFinishedShowPlaysTheFirstRegularEpisode() throws {
        let fresh = [episode(0, 1), episode(1, 1), episode(1, 2)]
        #expect(try #require(ShowResumePlan.plan(episodes: fresh)).label == "Play S1, E1")
        let finished = [episode(1, 1, viewCount: 1), episode(1, 2, viewCount: 1)]
        #expect(try #require(ShowResumePlan.plan(episodes: finished)).label == "Play S1, E1")
        #expect(ShowResumePlan.plan(episodes: []) == nil)
    }

    @Test func startedSpecialIsStillResumed() throws {
        let episodes = [episode(0, 2, offset: 600_000), episode(1, 1, viewCount: 1)]
        #expect(try #require(ShowResumePlan.plan(episodes: episodes)).label == "Resume S0, E2")
    }
}
