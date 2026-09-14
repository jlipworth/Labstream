import Testing
@testable import PMSKit

struct PlaybackProbeSelectionTests {
    @Test func identityAssertionsFailClosed() {
        #expect(PlaybackProbeSelection.matchesExpectedIdentity("source-A", actual: "source-A"))
        #expect(!PlaybackProbeSelection.matchesExpectedIdentity("source-A", actual: "source-a"))
        #expect(!PlaybackProbeSelection.matchesExpectedIdentity("source-A", actual: nil))
        #expect(!PlaybackProbeSelection.matchesExpectedIdentity(nil, actual: "source-A"))
        #expect(!PlaybackProbeSelection.matchesExpectedIdentity("", actual: ""))
    }

    @Test func requiresUniqueExactMatch() {
        #expect(PlaybackProbeSelection.uniqueExactIndex(titles: ["Other", "Episode 42"], query: "episode 42") == 1)
        #expect(PlaybackProbeSelection.uniqueExactIndex(titles: ["Other"], query: "Episode 42") == nil)
        #expect(PlaybackProbeSelection.uniqueExactIndex(titles: ["Episode 42", "EPISODE 42"], query: "Episode 42") == nil)
        #expect(PlaybackProbeSelection.uniqueExactIndex(titles: [], query: "Episode 42") == nil)
    }
    @Test func explicitMediaBrowserIdentityDisambiguatesOnlyExactTitles() {
        let first = MediaItem(ratingKey: "A", title: "Fixture", type: "movie")
        let second = MediaItem(ratingKey: "B", title: "Fixture", type: "movie")
        func select(_ items: [MediaItem], _ id: String?) -> Int? {
            PlaybackProbeSelection.mediaBrowserItemIndex(items: items, query: "fixture", expectedItemID: id)
        }
        #expect(select([first, second], "B") == 1)
        #expect(select([second, first], "B") == 0)
        #expect(select([first, second], nil) == nil)
        #expect(select([first], nil) == 0)
        #expect(select([first, second], "") == nil)
        #expect(select([first, second], "b") == nil)
        #expect(select([first, second], "C") == nil)
        #expect(select([second, second], "B") == nil)
        #expect(select([MediaItem(ratingKey: "B", title: "Fixture Extended", type: "movie")], "B") == nil)
        #expect(select([MediaItem(ratingKey: "B", title: "Fixture", type: "show")], "B") == nil)
    }

    @Test func plexBindsExactItemAndVersionRatherThanFirstEncode() {
        let first = Media(id: 10, part: [Part(id: 100, key: "/fixture/first")])
        let intended = Media(id: 20, part: [Part(id: 200, key: "/fixture/intended")])
        func select(_ media: [Media]?, title: String = "Fixture", key: String = "42",
                    type: String = "movie") -> Int? {
            PlaybackProbeSelection.plexMediaIndex(
                item: MediaItem(ratingKey: key, title: title, type: type, media: media),
                query: "Fixture", ratingKey: "42", mediaID: 20, partID: 200)
        }
        #expect(select([first, intended]) == 1)
        #expect(select([intended, first]) == 0)
        #expect(select([first]) == nil)
        #expect(select([intended], title: "Fixture Extended") == nil)
        #expect(select([intended], key: "43") == nil)
        #expect(select([intended], type: "clip") == nil)
        #expect(select(nil) == nil)
        #expect(select([intended, intended]) == nil)
        #expect(select([Media(id: 20, part: [])]) == nil)
        #expect(select([Media(id: 20, part: first.part)]) == nil)
        #expect(select([Media(id: 20, part: intended.part + first.part)]) == nil)
    }
}
