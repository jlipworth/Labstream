#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

/// Delegate lane: this file moves with session append; lead consumes the frozen lease API.
@Suite("P6 delegate path exclusion pins", .serialized)
struct P6PathLeaseTests {
    /// Synchronous cleanup bridge; the test runs off MainActor and never leaves a held worker.
    private func drainWorkers(_ workers: DispatchGroup) -> Bool {
        workers.wait(timeout: .now() + 2) == .success
    }

    @Test("P6 amendment 3: held append excludes Retry/reconcile through the actual syscall", arguments: [false, true])
    func appendExclusion(reconcile: Bool) async throws {
        let fixture = try P6Fixture()
        let store = fixture.store()
        let key = try fixture.seed(store, mode: reconcile ? .liveForwardOnly : .staticByteRange)
        let working = try fixture.working(store, key)
        let body = fixture.directory.appendingPathComponent("append.part")
        try Data([4]).write(to: body)
        let hold = P6Hold()
        let session = BackgroundDownloadSession(store: store, protocolClasses: [],
            appendWillPerformIO: { _, _ in hold.hit() })
        let workers = DispatchGroup()
        defer {
            hold.release.signal()
            #expect(drainWorkers(workers))
            session.invalidateInjectedSessionForTesting()
        }
        let appendFinished = DispatchSemaphore(value: 0)
        hold.arm()
        workers.enter()
        Thread.detachNewThread {
            defer { workers.leave() }
            _ = try? session.appendFileForP6Testing(at: body, onto: working)
            appendFinished.signal()
        }
        try #require(await p6Signal(hold.entered))
        // Deadline expiry is a waiter outcome, never permission to release the active append.
        let attempted = await store.acquirePathLease(for: key, relativePaths: [working.lastPathComponent],
                                                     purpose: .reconcile, deadline: .after(0))
        #expect(attempted == .timedOut)
        if case .acquired(let unintended) = attempted { store.releasePathLease(unintended) }
        if reconcile {
            guard case .accepted(_, let ticket) = store.submitLifecycleEvent(.pause(.user), for: key) else {
                Issue.record("pause fence rejected"); return
            }
            #expect(await store.resolve(DownloadStore.AttemptMutationSubmission.accepted(change: .applied, ticket: ticket),
                                        deadline: .after(2)) == .applied)
        }
        let competitorFinished = DispatchSemaphore(value: 0)
        let competitorAdmitted = DispatchSemaphore(value: 0)
        store.pathLeaseAdmissionForP6Testing = { admittedKey, purpose in
            if admittedKey == key && purpose == (reconcile ? .reconcile : .checkpointHandoff) {
                competitorAdmitted.signal()
            }
        }
        let successor = fixture.record("b", status: .failed)
        workers.enter()
        Thread.detachNewThread {
            defer { workers.leave() }
            if reconcile {
                store.reconcile(liveRatingKeys: [], snapshotRatingKeys: [key.ratingKey])
            } else {
                _ = store.createAttemptOwnedRecord(successor, attemptID: successor.attemptID!, replacing: key.attemptID)
            }
            competitorFinished.signal()
        }
        // Observe the actual lease-admission boundary before releasing the physical writer.
        // A scheduler delay can no longer turn this overlap assertion into a sequential test.
        try #require(await p6Signal(competitorAdmitted))
        #expect(FileManager.default.fileExists(atPath: working.path))
        if !reconcile { #expect(store.record(for: key.ratingKey)?.attemptID == key.attemptID) }
        hold.release.signal()
        try #require(await p6Signal(appendFinished))
        try #require(await p6Signal(competitorFinished))
        if !reconcile, store.record(for: key.ratingKey)?.attemptID == successor.attemptID {
            let successorKey = DownloadAttemptKey(ratingKey: successor.ratingKey, attemptID: successor.attemptID!)
            let copied = try #require(store.attemptWorkingFileURL(for: successorKey))
            let bytes = try Data(contentsOf: copied)
            #expect(bytes == Data([1, 2, 3, 4]))
        }
    }
    // Lead-owned half: exercise the store with an actual lease, independent of whether the
    // delegate's session append integration has landed in this checkout yet.
    @Test("P6 lead: physical path lease excludes Retry and reconcile", arguments: [false, true])
    func storePathLeaseExclusion(reconcile: Bool) throws {
        let fixture = try P6Fixture()
        let store = fixture.store()
        let key = try fixture.seed(store, mode: reconcile ? .liveForwardOnly : .staticByteRange)
        let working = try fixture.working(store, key)
        guard case .acquired(let lease) = store.tryAcquirePathLease(for: key,
            relativePaths: [working.lastPathComponent], purpose: .append) else {
            Issue.record("writer lease rejected"); return
        }
        defer { store.releasePathLease(lease) }
        if reconcile {
            _ = store.submitLifecycleEvent(.pause(.user), for: key)
            store.reconcile(liveRatingKeys: [], snapshotRatingKeys: [key.ratingKey])
            #expect(try Data(contentsOf: working) == Data([1, 2, 3]))
        } else {
            let successor = fixture.record("b", status: .failed)
            let result = store.createAttemptOwnedRecord(successor, attemptID: successor.attemptID!, replacing: key.attemptID)
            guard case .rejectedOwnership = result else { Issue.record("Retry bypassed live writer"); return }
            #expect(store.record(for: key) != nil)
            try Data([1, 2, 3, 4]).write(to: working)
            store.releasePathLease(lease)
            let next = DownloadAttemptKey(ratingKey: successor.ratingKey, attemptID: successor.attemptID!)
            #expect(store.createAttemptOwnedRecord(successor, attemptID: next.attemptID, replacing: key.attemptID) == .committed(next))
            let copied = try #require(store.attemptWorkingFileURL(for: next))
            #expect(try Data(contentsOf: copied) == Data([1, 2, 3, 4]))
        }
    }

}
#endif
