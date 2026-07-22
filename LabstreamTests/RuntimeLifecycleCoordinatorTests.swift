#if !os(tvOS)
import Testing
@testable import Labstream

@Suite("Runtime lifecycle coordinator")
@MainActor
struct RuntimeLifecycleCoordinatorTests {
    @Test
    func duplicateAggregateEventsProduceOneTypedRecoveryEdge() {
        var reasons: [DownloadRecoveryReason] = []
        var flushCount = 0
        let coordinator = RuntimeLifecycleCoordinator(
            requestDownloadRecovery: { reasons.append($0) },
            flushBestEffortState: { flushCount += 1 }
        )

        coordinator.aggregateSceneActivityChanged(isActive: true)
        coordinator.aggregateSceneActivityChanged(isActive: true)
        coordinator.aggregateSceneActivityChanged(isActive: false)
        coordinator.aggregateSceneActivityChanged(isActive: false)

        #expect(reasons == [.aggregateSceneBecameActive, .aggregateSceneBecameInactive])
        #expect(flushCount == 1)
    }

    @Test
    func typedReasonsPreserveManagerScenePhaseLabels() {
        #expect(DownloadRecoveryReason.aggregateSceneBecameActive.scenePhaseLabel == "active")
        #expect(DownloadRecoveryReason.aggregateSceneBecameInactive.scenePhaseLabel == "inactive")
    }
}
#endif
