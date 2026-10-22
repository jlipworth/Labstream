#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

/// Green seam/contract coverage is deliberately separate from behavioral red pins.
@Suite(.downloadTestFiles)
struct P6ContractTests {
    @Test func pathLeaseLifetimeAndExactRelease() async throws {
        let fixture = try P6Fixture()
        let store = fixture.store()
        let key = try fixture.seed(store)
        let paths: Set<String> = ["body.part", "publication.mp4"]
        guard case .acquired(let first) = store.tryAcquirePathLease(for: key, relativePaths: paths, purpose: .append) else {
            Issue.record("first lease rejected"); return
        }
        #expect(await store.acquirePathLease(for: key, relativePaths: paths, purpose: .reconcile,
                                             deadline: .after(0)) == .timedOut)
        #expect(store.tryAcquirePathLease(for: key, relativePaths: paths, purpose: .artifact) == .busy)
        store.releasePathLease(first)
        guard case .acquired(let second) = store.tryAcquirePathLease(for: key, relativePaths: paths, purpose: .artifact) else {
            Issue.record("successor lease rejected"); return
        }
        store.releasePathLease(first) // stale completion must not release successor ownership
        #expect(store.tryAcquirePathLease(for: key, relativePaths: paths, purpose: .append) == .busy)
        #expect(store.tryAcquirePathLease(for: key, relativePaths: ["../unsafe"], purpose: .artifact) == .invalidPath)
        store.releasePathLease(second)
    }

}
#endif
