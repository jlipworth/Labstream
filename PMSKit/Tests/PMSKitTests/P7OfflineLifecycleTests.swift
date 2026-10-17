import Foundation
import Testing
@testable import PMSKit

struct P7OfflineLifecycleTests {
    @Test func actualPlayingCannotEraseRepeatedTruncation() throws {
        let initial = DownloadLifecycleState(lifecycle: .unverified,
            history: .init(unverifiedReason: .truncatedRepeated))
        let transition = DownloadLifecycleReducer.reduce(initial, .localPlaybackProgressed,
            facts: .init(route: .forwardOnly, body: .published))
        let after = transition.state ?? initial
        // Simulate persisted history decoding as well as the immediate reducer result.
        let reloaded = try JSONDecoder().decode(DownloadAttemptHistory.self,
            from: JSONEncoder().encode(after.history))
        withKnownIssue("P7 red pin: 04") {
            #expect(after.lifecycle == .unverified)
            #expect(reloaded.unverifiedReason == .truncatedRepeated)
        }
    }
}
