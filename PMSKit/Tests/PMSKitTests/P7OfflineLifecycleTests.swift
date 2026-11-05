import Foundation
import Testing
@testable import PMSKit

struct P7OfflineLifecycleTests {
    @Test(arguments: [DownloadUnverifiedReason.probeMiss("fixture"), .backgroundProbeDeferred, .migratedUnknown])
    func actualPlayingVerifiesEligibleReasons(reason: DownloadUnverifiedReason) {
        let initial = DownloadLifecycleState(lifecycle: .unverified,
            history: .init(unverifiedReason: reason))
        let result = DownloadLifecycleReducer.reduce(initial, .localPlaybackProgressed,
            facts: .init(route: .forwardOnly, body: .published))
        #expect(result.state?.lifecycle == .complete)
        #expect(result.state?.history.unverifiedReason == nil)
    }

    @Test func actualPlayingCannotEraseRepeatedTruncation() throws {
        let initial = DownloadLifecycleState(lifecycle: .unverified,
            history: .init(unverifiedReason: .truncatedRepeated))
        let transition = DownloadLifecycleReducer.reduce(initial, .localPlaybackProgressed,
            facts: .init(route: .forwardOnly, body: .published))
        let after = transition.state ?? initial
        // Simulate persisted history decoding as well as the immediate reducer result.
        let reloaded = try JSONDecoder().decode(DownloadAttemptHistory.self,
            from: JSONEncoder().encode(after.history))
        #expect(after.lifecycle == .unverified)
        #expect(reloaded.unverifiedReason == .truncatedRepeated)
    }
}
