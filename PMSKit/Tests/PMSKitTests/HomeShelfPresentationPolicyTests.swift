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

    @Test("Episode shelves keep landscape geometry even with poster-only fallback")
    func mixedEpisodes() {
        let poster = MediaItem(ratingKey: "poster", title: "Episode", type: "episode",
                               grandparentThumb: "emby://item/show/Primary")
        let still = MediaItem(ratingKey: "still", title: "Episode", type: "episode",
                              thumb: "emby://item/episode/Thumb",
                              grandparentThumb: "emby://item/show/Primary")
        for item in [poster, still] {
            let shape = HomeShelfPresentationPolicy.presentation(for: Hub(title: "Shelf", metadata: [item]))
            #expect(shape == .landscape)
            #expect(shape?.pixelHeight(forPixelWidth: 320) == 180)
            let artwork = HomeShelfPresentationPolicy.artwork(for: item, presentation: .landscape)
            #expect(artwork.path == (item.thumb ?? item.grandparentThumb))
            #expect(HomeShelfPresentationPolicy.sourceAspect(for: item, artwork: artwork)
                    == (item.thumb == nil ? 2.0 / 3.0 : 16.0 / 9.0))
            // Expanded related/search policy is deliberately unaffected.
            #expect(HomeRailArtworkPolicy.selection(for: item).presentation == .poster)
        }
    }

    @Test("Declared shelf type wins and non-video shelves retain their own policy")
    func shelfSemantics() {
        let episode = MediaItem(ratingKey: "e", title: "Episode", type: "episode")
        #expect(HomeShelfPresentationPolicy.presentation(for: Hub(title: "Movies", type: "movie",
                                                                  metadata: [episode])) == .poster)
        #expect(HomeShelfPresentationPolicy.presentation(for: Hub(title: "Episodes", type: "episode")) == .landscape)
        let album = MediaItem(ratingKey: "a", title: "Album", type: "album")
        #expect(HomeShelfPresentationPolicy.presentation(for: Hub(title: "Music", metadata: [album])) == nil)
    }

    @Test("Empty stills fall through to contextual artwork without changing its request aspect")
    func emptyStill() {
        let item = MediaItem(ratingKey: "e", title: "Episode", type: "episode", thumb: "",
                             parentThumb: "season-poster")
        let artwork = HomeShelfPresentationPolicy.artwork(for: item, presentation: .landscape)
        #expect(artwork.path == "season-poster")
        #expect(HomeShelfPresentationPolicy.sourceAspect(for: item, artwork: artwork) == 2.0 / 3.0)
    }
}
