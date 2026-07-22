import Testing
@testable import PMSKit

@Suite("Video Now Playing snapshot")
struct VideoNowPlayingSnapshotTests {
    @Test func movieUsesCanonicalDynamicValuesAndYearContext() {
        let item = MediaItem(ratingKey: "movie", title: "Film", type: "movie",
                             duration: 120_000, year: 2024)

        let snapshot = VideoNowPlayingSnapshot(
            mediaItem: item,
            durationMilliseconds: 125_000,
            elapsedMilliseconds: 12_345,
            playbackRate: 1,
            defaultPlaybackRate: 1.25)

        #expect(snapshot.title == "Film")
        #expect(snapshot.context == "2024")
        #expect(snapshot.releaseYear == 2024)
        #expect(snapshot.durationMilliseconds == 125_000)
        #expect(snapshot.elapsedMilliseconds == 12_345)
        #expect(snapshot.playbackRate == 1)
        #expect(snapshot.defaultPlaybackRate == 1.25)
    }

    @Test func episodeContextUsesShowAndCode() {
        let item = MediaItem(ratingKey: "episode", title: "Pilot", type: "episode",
                             grandparentTitle: "Example Show", parentTitle: "Season One",
                             parentIndex: 1, index: 3)

        let snapshot = makeSnapshot(item)

        #expect(snapshot.context == "Example Show · S1E3")
        #expect(snapshot.releaseYear == nil)
    }

    @Test func episodeContextFallsBackToSeasonAndDropsEmptyComponents() {
        let item = MediaItem(ratingKey: "episode", title: "Pilot", type: "episode",
                             grandparentTitle: "", parentTitle: "Season One")

        #expect(makeSnapshot(item).context == "Season One")
    }

    @Test func invalidDurationFallsBackToItemAndElapsedClampsAtZero() {
        let item = MediaItem(ratingKey: "movie", title: "Film", type: "movie",
                             duration: 90_000)

        let zeroDuration = VideoNowPlayingSnapshot(
            mediaItem: item,
            durationMilliseconds: 0,
            elapsedMilliseconds: -500,
            playbackRate: 0,
            defaultPlaybackRate: 1)
        let noDuration = makeSnapshot(MediaItem(ratingKey: "bare", title: "Bare", type: "movie"))

        #expect(zeroDuration.durationMilliseconds == 90_000)
        #expect(zeroDuration.elapsedMilliseconds == 0)
        #expect(noDuration.durationMilliseconds == nil)
        #expect(noDuration.context == nil)
    }

    private func makeSnapshot(_ item: MediaItem) -> VideoNowPlayingSnapshot {
        VideoNowPlayingSnapshot(mediaItem: item,
                                durationMilliseconds: nil,
                                elapsedMilliseconds: 0,
                                playbackRate: 0,
                                defaultPlaybackRate: 1)
    }
}
