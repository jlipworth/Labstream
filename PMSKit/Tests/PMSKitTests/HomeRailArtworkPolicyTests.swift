import Testing
@testable import PMSKit

@Suite("Home rail artwork policy")
struct HomeRailArtworkPolicyTests {
    @Test("Home episodes prefer season art over show art, stills, and backdrops")
    func episodePrefersSeasonArtwork() {
        let item = MediaItem(ratingKey: "e1", title: "Pilot", type: "episode",
                             thumb: "episode-still",
                             art: "episode-backdrop",
                             grandparentThumb: "show-poster",
                             parentThumb: "season-poster")

        #expect(HomeRailArtworkPolicy.selection(for: item)
            == .init(path: "season-poster", presentation: .poster))
    }

    @Test("Home episodes fall back to show poster before episode still when season art is missing")
    func episodeUsesShowPosterBeforeStillWhenSeasonMissing() {
        let item = MediaItem(ratingKey: "e2", title: "Episode", type: "episode",
                             thumb: "episode-still",
                             art: "episode-backdrop",
                             grandparentThumb: "show-poster")

        #expect(HomeRailArtworkPolicy.selection(for: item)
            == .init(path: "show-poster", presentation: .poster))
    }

    @Test("Home episodes use landscape presentation only for still/backdrop fallback")
    func episodeStillAndBackdropRemainLandscape() {
        let withStill = MediaItem(ratingKey: "e3", title: "Episode", type: "episode",
                                  thumb: "episode-still",
                                  art: "episode-backdrop")
        let backdropOnly = MediaItem(ratingKey: "e4", title: "Episode", type: "episode",
                                     art: "episode-backdrop")

        #expect(HomeRailArtworkPolicy.selection(for: withStill)
            == .init(path: "episode-still", presentation: .landscape))
        #expect(HomeRailArtworkPolicy.selection(for: backdropOnly)
            == .init(path: "episode-backdrop", presentation: .landscape))
    }

    @Test("Non-episode Home items keep existing thumb-only poster behavior")
    func nonEpisodeItemsAreUnchanged() {
        let movie = MediaItem(ratingKey: "m1", title: "Movie", type: "movie",
                              thumb: "movie-poster",
                              art: "movie-backdrop")
        let movieWithoutThumb = MediaItem(ratingKey: "m2", title: "Movie", type: "movie",
                                          art: "movie-backdrop")
        let season = MediaItem(ratingKey: "s1", title: "Season 1", type: "season",
                               thumb: "season-poster",
                               grandparentThumb: "show-poster")
        let track = MediaItem(ratingKey: "t1", title: "Track", type: "track",
                              thumb: "track-art",
                              parentThumb: "album-art")

        #expect(HomeRailArtworkPolicy.selection(for: movie)
            == .init(path: "movie-poster", presentation: .poster))
        #expect(HomeRailArtworkPolicy.selection(for: movieWithoutThumb)
            == .init(path: nil, presentation: .poster))
        #expect(HomeRailArtworkPolicy.selection(for: season)
            == .init(path: "season-poster", presentation: .poster))
        #expect(HomeRailArtworkPolicy.selection(for: track)
            == .init(path: "track-art", presentation: .poster))
    }

    @Test("Empty season art is skipped so the Home tile does not become a placeholder")
    func emptyEpisodeArtworkIsSkipped() {
        let item = MediaItem(ratingKey: "e5", title: "Episode", type: "episode",
                             thumb: "episode-still",
                             grandparentThumb: "show-poster",
                             parentThumb: "")

        #expect(HomeRailArtworkPolicy.selection(for: item)
            == .init(path: "show-poster", presentation: .poster))
    }
}
