#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

/// Delegate lane: this file moves with session append; lead consumes the frozen lease API.
@Suite("P6 delegate path exclusion pins", .serialized)
struct P6PathLeaseTests {
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
        defer { hold.release.signal(); session.invalidateInjectedSessionForTesting() }
        let appendFinished = DispatchSemaphore(value: 0)
        hold.arm()
        Thread.detachNewThread {
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
        let successor = fixture.record("b", status: .failed)
        Thread.detachNewThread {
            if reconcile {
                store.reconcile(liveRatingKeys: [], snapshotRatingKeys: [key.ratingKey])
            } else {
                _ = store.createAttemptOwnedRecord(successor, attemptID: successor.attemptID!, replacing: key.attemptID)
            }
            competitorFinished.signal()
        }
        let competedWhileAppendHeld = await p6Signal(competitorFinished, seconds: 0.3)
        withKnownIssue("P6 red pin: P6.3/P6.4 — \(reconcile ? "reconcile" : "Retry clone") ignores the physically active append") {
            #expect(FileManager.default.fileExists(atPath: working.path))
            if !reconcile { #expect(store.record(for: key.ratingKey)?.attemptID == key.attemptID) }
        }
        hold.release.signal()
        try #require(await p6Signal(appendFinished))
        if !competedWhileAppendHeld { try #require(await p6Signal(competitorFinished)) }
        if !reconcile, store.record(for: key.ratingKey)?.attemptID == successor.attemptID {
            let successorKey = DownloadAttemptKey(ratingKey: successor.ratingKey, attemptID: successor.attemptID!)
            let copied = try #require(store.attemptWorkingFileURL(for: successorKey))
            let bytes = try Data(contentsOf: copied)
            withKnownIssue("P6 red pin: P6.3/P6.4 — Retry clones before the held append syscall completes") {
                #expect(bytes == Data([1, 2, 3, 4]))
            }
        }
    }
}
#endif
