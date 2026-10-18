#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

/// #414: submitted server jobs keep their prep slot after rendering and take a static transfer
/// slot only when one is free, first come, first served, ahead of new transfer starts.
@Suite("Server-prep render handoff", .serialized)
@MainActor
struct ServerPrepHandoffTests {
    private func key(_ id: String) -> DownloadAttemptKey {
        DownloadAttemptKey(ratingKey: id, attemptID: DownloadAttemptID(rawValue: "attempt-\(id)")!)
    }

    /// Fills the static lane with supervised starts and puts `prep` rows in the prep lane.
    private func fixture(prep: [String]) async throws -> (P7PlaybackFixture, [String: UUID]) {
        let f = try await P7PlaybackFixture(status: .failed)
        f.manager.setQueuePausedForTesting(false)
        var generations: [String: UUID] = [:]
        let staticCap = try #require(f.manager.admission.limits.maximumByLane[.staticFile])
        for index in 0..<staticCap {
            generations["static-\(index)"] = f.manager.admission.beginSupervision(
                "static-\(index)", lane: .staticFile, origin: .user)
        }
        for id in prep {
            generations[id] = f.manager.admission.beginSupervision(id, lane: .serverPreparation, origin: .user)
        }
        return (f, generations)
    }

    private func wait(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test("Finished renders wait in order and never start past the static cap")
    func rendersWaitInOrder() async throws {
        let (f, generations) = try await fixture(prep: ["p1", "p2", "p3"])
        let manager = f.manager
        let first = Task { await manager.awaitStaticHandoffRoom(for: key("p1"), backend: "Plex") { true } }
        try #require(await wait { manager.staticHandoffWaiters["p1"] != nil })
        let second = Task { await manager.awaitStaticHandoffRoom(for: key("p2"), backend: "Plex") { true } }
        try #require(await wait { manager.staticHandoffWaiters["p2"] != nil })
        #expect(manager.optimizeState["p1"] == DownloadRowStatusCaptionPolicy.serverPrepReadyState)
        // More jobs can still be submitted while renders wait for transfers.
        #expect(manager.admissionHasRoom(for: "p4", lane: .serverPreparation))
        #expect(!manager.admissionHasRoom(for: "new-static", lane: .staticFile))

        // A transfer finishes: the first waiter takes the slot; the second keeps waiting.
        _ = manager.admission.endSupervision("static-0", generation: try #require(generations["static-0"]))
        let firstToken = try #require(await first.value)
        #expect(manager.staticHandoffReservations["p1"] == firstToken)
        #expect(manager.staticHandoffWaiters["p1"] == nil)
        #expect(manager.optimizeState["p1"] == nil)
        try? await Task.sleep(for: .milliseconds(1_500))
        #expect(manager.staticHandoffWaiters["p2"] != nil)
        #expect(manager.staticHandoffReservations["p2"] == nil)

        // Only the reserving wait can end its reservation.
        manager.endStaticHandoff("p1", token: UUID())
        #expect(manager.staticHandoffReservations["p1"] == firstToken)
        // p1's transfer is now observable in the static lane; the reservation ends.
        _ = manager.admission.endSupervision("p1", generation: try #require(generations["p1"]))
        _ = manager.admission.beginSupervision("p1", lane: .staticFile, origin: .user)
        manager.endStaticHandoff("p1", token: firstToken)
        #expect(manager.staticHandoffReservations["p1"] == nil)
        try? await Task.sleep(for: .milliseconds(1_500))
        #expect(manager.staticHandoffReservations["p2"] == nil)

        let staticCap = try #require(manager.admission.limits.maximumByLane[.staticFile])
        if staticCap > 1 {
            _ = manager.admission.endSupervision("static-1", generation: try #require(generations["static-1"]))
        } else {
            manager.admission.invalidate("p1")
        }
        let secondToken = try #require(await second.value)
        #expect(manager.staticHandoffReservations["p2"] == secondToken)
        #expect(manager.staticHandoffWaiters.isEmpty)
    }

    @Test("A cancelled or superseded wait leaves no waiter, caption or reservation")
    func cancelledWaitCleansUp() async throws {
        let (f, _) = try await fixture(prep: ["p1", "p2"])
        let manager = f.manager
        let cancelled = Task { await manager.awaitStaticHandoffRoom(for: key("p1"), backend: "Plex") { true } }
        try #require(await wait { manager.staticHandoffWaiters["p1"] != nil })
        cancelled.cancel()
        #expect(await cancelled.value == nil)
        #expect(manager.staticHandoffWaiters["p1"] == nil)
        #expect(manager.optimizeState["p1"] == nil)

        let current = TestLockedBox(true)
        let superseded = Task {
            await manager.awaitStaticHandoffRoom(for: key("p2"), backend: "Emby") { current.withValue { $0 } }
        }
        try #require(await wait { manager.staticHandoffWaiters["p2"] != nil })
        current.withValue { $0 = false }
        #expect(await superseded.value == nil)
        #expect(manager.staticHandoffWaiters.isEmpty)
        #expect(manager.staticHandoffReservations.isEmpty)
    }

    @Test("A render that can hand off now goes before new transfer starts, not before prep")
    func pendingHandoffHasPriority() async throws {
        let (f, generations) = try await fixture(prep: ["p1"])
        let manager = f.manager
        _ = manager.admission.endSupervision("static-0", generation: try #require(generations["static-0"]))
        #expect(manager.admissionHasRoom(for: "new-static", lane: .staticFile))
        manager.staticHandoffWaiters["p1"] = (UUID(), 1)
        let occupants = manager.admissionOccupants(f.store.records)
        #expect(manager.staticHandoffIsPending(occupants: occupants))
        #expect(!manager.admissionHasRoom(for: "new-static", lane: .staticFile))
        #expect(manager.admissionHasRoom(for: "p2", lane: .serverPreparation))
        manager.staticHandoffWaiters["p1"] = nil
        #expect(manager.admissionHasRoom(for: "new-static", lane: .staticFile))
    }
}
#endif
