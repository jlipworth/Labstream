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
}
#endif
