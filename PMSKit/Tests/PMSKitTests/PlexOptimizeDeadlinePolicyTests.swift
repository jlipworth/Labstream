import Foundation
import Testing
@testable import PMSKit

@Suite("Plex optimize deadline policy")
struct PlexOptimizeDeadlinePolicyTests {
    @Test("Deadline expires exactly at 24 hours and survives arbitrary relaunch checks")
    func deadlineBoundary() {
        let start: TimeInterval = 1_000
        #expect(!PlexOptimizeDeadlinePolicy.isExpired(
            startedAtEpochSeconds: start,
            nowEpochSeconds: start + PlexOptimizeDeadlinePolicy.maximumDurationSeconds - 1))
        #expect(PlexOptimizeDeadlinePolicy.isExpired(
            startedAtEpochSeconds: start,
            nowEpochSeconds: start + PlexOptimizeDeadlinePolicy.maximumDurationSeconds))
    }

    @Test("Future clock corrections do not immediately expire; invalid timestamps fail closed")
    func clockEdges() {
        #expect(!PlexOptimizeDeadlinePolicy.isExpired(
            startedAtEpochSeconds: 2_000, nowEpochSeconds: 1_000))
        #expect(PlexOptimizeDeadlinePolicy.isExpired(
            startedAtEpochSeconds: .nan, nowEpochSeconds: 1_000))
    }
}
