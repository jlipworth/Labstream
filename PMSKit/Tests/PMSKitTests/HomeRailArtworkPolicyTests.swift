import Foundation
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

    @Test("Emby Home prefers a series Primary poster over a landscape parent Thumb")
    func embySeriesPrimaryBeatsParentThumb() {
        let item = MediaItem(
            ratingKey: "e-emby-primary", title: "Episode", type: "episode",
            thumb: "emby://item/episode-1/Thumb?tag=episode-still",
            grandparentThumb: "emby://item/series-1/Primary?tag=series-poster",
            parentThumb: "emby://item/season-1/Thumb?tag=season-landscape"
        )

        let selection = HomeRailArtworkPolicy.selection(for: item)
        #expect(selection == .init(
            path: "emby://item/series-1/Primary?tag=series-poster",
            presentation: .poster
        ))
        #expect(selection.presentation.pixelHeight(forPixelWidth: 304) == 456)
    }

    @Test("Emby parent Thumb stays landscape when no Primary poster exists")
    func embyParentThumbWithoutPrimaryStaysLandscape() throws {
        let item = MediaItem(
            ratingKey: "e-emby-thumb", title: "Episode", type: "episode",
            thumb: "emby://item/episode-1/Thumb?tag=episode-still",
            parentThumb: "emby://item/season-1/Thumb?tag=season-landscape"
        )

        let selection = HomeRailArtworkPolicy.selection(for: item)
        #expect(selection == .init(
            path: "emby://item/season-1/Thumb?tag=season-landscape",
            presentation: .landscape
        ))

        let width = 304
        let height = selection.presentation.pixelHeight(forPixelWidth: width)
        #expect(height == 171)
        let request = try #require(try EmbyLibrary.posterRequest(
            syntheticRef: selection.path,
            server: URL(string: "https://emby.example.test/emby")!,
            token: "token",
            identity: .init(client: "Labstream", device: "Test", deviceId: "device", version: "1"),
            userId: "user",
            width: width,
            height: height
        ))
        let query = Dictionary(uniqueKeysWithValues:
            (URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .compactMap { item in item.value.map { (item.name, $0) } })
        #expect(query["width"] == "304")
        #expect(query["height"] == "171")
        #expect(query["height"] != "456")
    }

    @Test("Emby episode fallbacks retain explicit Primary and Thumb shapes")
    func embyMissingParentFallbacks() {
        let seriesOnly = MediaItem(
            ratingKey: "e-series", title: "Episode", type: "episode",
            thumb: "emby://item/episode-1/Thumb?tag=episode-still",
            grandparentThumb: "emby://item/series-1/Primary?tag=series-poster"
        )
        let stillOnly = MediaItem(
            ratingKey: "e-still", title: "Episode", type: "episode",
            thumb: "emby://item/episode-1/Thumb?tag=episode-still"
        )
        let backdropOnly = MediaItem(
            ratingKey: "e-backdrop", title: "Episode", type: "episode",
            art: "emby://item/series-1/Backdrop?tag=backdrop"
        )

        #expect(HomeRailArtworkPolicy.selection(for: seriesOnly).presentation == .poster)
        #expect(HomeRailArtworkPolicy.selection(for: stillOnly).presentation == .landscape)
        #expect(HomeRailArtworkPolicy.selection(for: backdropOnly).presentation == .landscape)
    }

    @Test("Emby movie Primary remains an unaffected poster")
    func embyMoviePrimaryRemainsPoster() {
        let movie = MediaItem(
            ratingKey: "m-emby", title: "Movie", type: "movie",
            thumb: "emby://item/movie-1/Primary?tag=movie-poster",
            art: "emby://item/movie-1/Backdrop?tag=movie-backdrop",
            primaryImageAspectRatio: MediaItem.defaultPosterAspect
        )

        #expect(HomeRailArtworkPolicy.selection(for: movie) == .init(
            path: "emby://item/movie-1/Primary?tag=movie-poster",
            presentation: .poster
        ))
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
