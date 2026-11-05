import Testing
@testable import PMSKit

@Suite("Uniform Home shelf presentation")
struct HomeShelfPresentationPolicyTests {
    @Test("Movie/show shelf shape ignores mixed source aspects and their order")
    func mixedPosters() {
        for kind in ["movie", "show"] {
            let items = [16.0 / 9.0, 2.0 / 3.0, 1.0].enumerated().map { index, aspect in
                MediaItem(ratingKey: "\(index)", title: "Item", type: kind,
                          primaryImageAspectRatio: aspect)
            }
            for rows in [items, Array(items.reversed())] {
                let shape = HomeShelfPresentationPolicy.presentation(for: Hub(title: "Shelf", metadata: rows))
                #expect(shape == .poster)
                #expect(shape?.pixelHeight(forPixelWidth: 120) == 180)
                // Source aspect survives so a crop never becomes a stretch.
                for item in rows {
                    let artwork = HomeShelfPresentationPolicy.artwork(for: item, presentation: .poster)
                    #expect(HomeShelfPresentationPolicy.sourceAspect(for: item, artwork: artwork)
                            == item.primaryImageAspectRatio)
                }
            }
        }
    }

    @Test("Episode shelves use season/show posters, falling back to a cropped still")
    func episodePosters() {
        let seasonPoster = MediaItem(ratingKey: "season", title: "Episode", type: "episode",
                                     thumb: "emby://item/episode/Thumb",
                                     grandparentThumb: "emby://item/show/Primary",
                                     parentThumb: "emby://item/season/Primary")
        let showPoster = MediaItem(ratingKey: "show", title: "Episode", type: "episode",
                                   thumb: "emby://item/episode/Thumb",
                                   grandparentThumb: "emby://item/show/Primary",
                                   parentThumb: "emby://item/season/Thumb")
        let stillOnly = MediaItem(ratingKey: "still", title: "Episode", type: "episode",
                                  thumb: "emby://item/episode/Thumb")
        let plex = MediaItem(ratingKey: "plex", title: "Episode", type: "episode",
                             thumb: "/library/metadata/3/thumb", grandparentThumb: "/library/metadata/1/thumb",
                             parentThumb: "/library/metadata/2/thumb")
        let expected: [(MediaItem, String, Double)] = [
            (seasonPoster, "emby://item/season/Primary", 2.0 / 3.0),
            (showPoster, "emby://item/show/Primary", 2.0 / 3.0),
            (stillOnly, "emby://item/episode/Thumb", 16.0 / 9.0),
            (plex, "/library/metadata/2/thumb", 2.0 / 3.0),
        ]
        for (item, path, sourceAspect) in expected {
            let shape = HomeShelfPresentationPolicy.presentation(for: Hub(title: "Shelf", metadata: [item]))
            #expect(shape == .poster)
            let artwork = HomeShelfPresentationPolicy.artwork(for: item, presentation: .poster)
            #expect(artwork.path == path)
            // A still-only fallback is requested at 16:9 and cropped, never stretched.
            #expect(HomeShelfPresentationPolicy.sourceAspect(for: item, artwork: artwork) == sourceAspect)
        }
    }

    @Test("Mixed Continue Watching shape does not depend on which item sorts first")
    func mixedContinueWatching() {
        let movie = MediaItem(ratingKey: "m", title: "Movie", type: "movie", thumb: "movie-poster")
        let episode = MediaItem(ratingKey: "e", title: "Episode", type: "episode",
                                thumb: "episode-still", parentThumb: "season-poster")
        for rows in [[movie, episode], [episode, movie]] {
            for type in ["mixed", nil] as [String?] {
                let hub = Hub(title: "Continue Watching", type: type, metadata: rows)
                #expect(HomeShelfPresentationPolicy.presentation(for: hub) == .poster)
            }
        }
        #expect(HomeShelfPresentationPolicy.artwork(for: episode, presentation: .poster).path == "season-poster")
        #expect(HomeShelfPresentationPolicy.artwork(for: movie, presentation: .poster).path == "movie-poster")
    }

    @Test("Declared video shelves are posters and non-video shelves retain their own policy")
    func shelfSemantics() {
        let episode = MediaItem(ratingKey: "e", title: "Episode", type: "episode")
        #expect(HomeShelfPresentationPolicy.presentation(for: Hub(title: "Movies", type: "movie",
                                                                  metadata: [episode])) == .poster)
        #expect(HomeShelfPresentationPolicy.presentation(for: Hub(title: "On Deck", type: "episode")) == .poster)
        let album = MediaItem(ratingKey: "a", title: "Album", type: "album")
        #expect(HomeShelfPresentationPolicy.presentation(for: Hub(title: "Music", metadata: [album])) == nil)
        #expect(HomeShelfPresentationPolicy.presentation(for: Hub(title: "Music", type: "mixed",
                                                                  metadata: [album])) == nil)
    }

    @Test("Empty contextual paths fall through without changing the request aspect")
    func emptyContext() {
        let item = MediaItem(ratingKey: "e", title: "Episode", type: "episode", thumb: "episode-still",
                             grandparentThumb: "show-poster", parentThumb: "")
        let artwork = HomeShelfPresentationPolicy.artwork(for: item, presentation: .poster)
        #expect(artwork.path == "show-poster")
        #expect(HomeShelfPresentationPolicy.sourceAspect(for: item, artwork: artwork) == 2.0 / 3.0)
    }
}
