#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("P6 session append leases", .serialized)
struct P6SessionPathLeaseTests {
    @Test("Append owns source and destination until handles close, including after waiter expiry")
    func physicalAppendLease() async throws {
        let fixture = try P6Fixture()
        let store = fixture.store()
        let key = try fixture.seed(store)
        let destination = try fixture.working(store, key)
        let source = fixture.directory.appendingPathComponent("session-body.part")
        try Data([4]).write(to: source)
        let hold = P6Hold()
        let session = BackgroundDownloadSession(store: store, protocolClasses: [],
            appendWillPerformIO: { _, _ in hold.hit() })
        defer { hold.release.signal(); session.invalidateInjectedSessionForTesting() }
        hold.arm()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = try? session.appendFileForP6Testing(at: source, onto: destination)
            done.signal()
        }
        try #require(await p6Signal(hold.entered))
        for path in [source.lastPathComponent, destination.lastPathComponent] {
            #expect(await store.acquirePathLease(for: key, relativePaths: [path],
                purpose: .reconcile, deadline: .after(0)) == .timedOut)
            #expect(store.tryAcquirePathLease(for: key, relativePaths: [path], purpose: .checkpointHandoff) == .busy)
        }
        hold.release.signal()
        try #require(await p6Signal(done))
        #expect(try Data(contentsOf: destination) == Data([1, 2, 3, 4]))
        guard case .acquired(let successor) = store.tryAcquirePathLease(for: key,
            relativePaths: [destination.lastPathComponent], purpose: .reconcile) else {
            Issue.record("Physical append did not release its lease"); return
        }
        store.releasePathLease(successor)
    }
    @Test("Whole replacement and resource restart defer while a real Retry copy owns the path", arguments: [false, true])
    func retryExcludesWorkingMutation(replaceWhole: Bool) async throws {
        let fixture = try P6Fixture()
        let initial = fixture.store()
        let key = try fixture.seed(initial)
        let working = try fixture.working(initial, key)
        #expect(initial.resetStaticRangeProgressToDurableCheckpoint(for: key, expectedBytes: 10) == .applied(bytes: 3))
        let hold = P6Hold()
        let live = DownloadStaticCheckpointFilesystem.live
        let store = fixture.store(checkpoint: .init(exists: live.exists, size: live.size,
            durableCopy: { source, destination, temporary in
                hold.hit()
                try live.durableCopy(source, destination, temporary)
            }))
        let session = BackgroundDownloadSession(store: store, protocolClasses: [],
            playbackValidator: { _, _ in .init(played: true, reason: "fixture", durationMs: nil, detail: nil) })
        defer { hold.release.signal(); session.invalidateInjectedSessionForTesting() }
        let retryDone = DispatchSemaphore(value: 0)
        let successor = fixture.record("retry")
        hold.arm()
        Thread.detachNewThread {
            _ = store.createAttemptOwnedRecord(successor, attemptID: successor.attemptID!, replacing: key.attemptID)
            retryDone.signal()
        }
        try #require(await p6Signal(hold.entered))
        let stash = fixture.directory.appendingPathComponent("replacement.part")
        try Data([7, 7, 7, 7]).write(to: stash)
        let submitted = DispatchSemaphore(value: 0)
        session.mutateWorkingPathForP6Testing(key, stash: replaceWhole ? stash : nil) { submitted.signal() }
        try #require(await p6Signal(submitted))
        #expect((try? Data(contentsOf: working)) == Data([1, 2, 3]))
        if replaceWhole {
            #expect((try? Data(contentsOf: stash)) == Data([7, 7, 7, 7]))
            #expect(session.claimedRangeBodiesForTesting().contains(stash.standardizedFileURL))
        }
        hold.release.signal()
        try #require(await p6Signal(retryDone))
        let nextKey = DownloadAttemptKey(ratingKey: key.ratingKey, attemptID: successor.attemptID!)
        let nextWorking = try #require(store.attemptWorkingFileURL(for: nextKey))
        #expect(try Data(contentsOf: nextWorking) == Data([1, 2, 3]))
    }

}
#endif
