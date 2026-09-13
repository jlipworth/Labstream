import Testing
@testable import PMSKit

struct PlaybackProbeSelectionTests {
    @Test func requiresUniqueExactMatch() {
        #expect(PlaybackProbeSelection.uniqueExactIndex(titles: ["Other", "Episode 42"], query: "episode 42") == 1)
        #expect(PlaybackProbeSelection.uniqueExactIndex(titles: ["Other"], query: "Episode 42") == nil)
        #expect(PlaybackProbeSelection.uniqueExactIndex(titles: ["Episode 42", "EPISODE 42"], query: "Episode 42") == nil)
        #expect(PlaybackProbeSelection.uniqueExactIndex(titles: [], query: "Episode 42") == nil)
    }
}
