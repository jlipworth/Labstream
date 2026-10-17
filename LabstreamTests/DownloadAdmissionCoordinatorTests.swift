#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

@MainActor
@Suite("Download admission coordinator (P4)")
struct DownloadAdmissionCoordinatorTests {
    /// A stale continuation can never settle its successor's supervised start.
    @Test func aStaleGenerationCannotEndItsSuccessor() {
        let coordinator = DownloadAdmissionCoordinator()
        let old = coordinator.beginSupervision("row", lane: .staticFile, origin: .user)
        let new = coordinator.beginSupervision("row", lane: .staticFile, origin: .user)
        #expect(!coordinator.endSupervision("row", generation: old))
        #expect(!coordinator.switchLane("row", generation: old, to: .serverPreparation))
        #expect(coordinator.isCurrent("row", generation: new))
        #expect(coordinator.endSupervision("row", generation: new))
        #expect(coordinator.supervised.isEmpty)
    }

    @Test func pauseOrDeleteInvalidatesTheStartAndItsRequest() {
        let coordinator = DownloadAdmissionCoordinator()
        let generation = coordinator.beginSupervision("row", lane: .liveForward, origin: .automatic)
        coordinator.noteRequest("row", origin: .automatic)
        coordinator.invalidate("row")
        #expect(!coordinator.endSupervision("row", generation: generation))
        #expect(coordinator.requestStates["row"] == nil)
    }

    @Test func deferralBacksOffAndAUserRequestJumpsTheQueue() {
        let coordinator = DownloadAdmissionCoordinator()
        var clock: TimeInterval = 100
        coordinator.now = { clock }
        coordinator.noteRequest("row", origin: .automatic)
        coordinator.recordDeferral("row")
        #expect(coordinator.request(for: "row", lane: .staticFile).eligibleAt == 101)
        clock = 101
        coordinator.recordDeferral("row")
        #expect(coordinator.request(for: "row", lane: .staticFile).eligibleAt == 106)
        coordinator.noteRequest("row", origin: .user)
        let request = coordinator.request(for: "row", lane: .staticFile)
        #expect(request.origin == .user)
        #expect(request.eligibleAt == 101)
        #expect(request.requestedAt == 100, "a repeated request keeps its place")
    }

    @Test func exemptionsAreRowScopedAndRevokedTogether() {
        let coordinator = DownloadAdmissionCoordinator()
        coordinator.exempt("a")
        coordinator.exempt("b")
        coordinator.revokeExemption("a")
        #expect(!coordinator.isExempt("a"))
        #expect(coordinator.isExempt("b"))
        coordinator.revokeAllExemptions()
        #expect(coordinator.pauseExemptions.isEmpty)
    }
}
#endif
