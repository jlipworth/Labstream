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
}
