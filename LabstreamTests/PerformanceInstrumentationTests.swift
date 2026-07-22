import Foundation
import Testing
@testable import Labstream

#if DEBUG || PERFORMANCE_AUDIT
@Suite("Performance instrumentation")
struct PerformanceInstrumentationTests {
    @Test("A span end gate can be claimed exactly once across concurrent callers")
    func endGateIsConcurrentExactlyOnce() {
        let gate = PerformanceSpanEndGate()
        let successfulClaims = TestLockedBox(0)

        DispatchQueue.concurrentPerform(iterations: 128) { _ in
            guard gate.claim() else { return }
            successfulClaims.withValue { $0 += 1 }
        }

        #expect(successfulClaims.value == 1)
        #expect(!gate.claim())
    }

    @Test("Session restore evidence distinguishes usable, retained-unavailable, and absent lanes")
    func sessionRestoreOutcomes() {
        let usable = SessionRestorePerformanceOutcome.resolve(
            reportedRestored: true, hasUsableSession: true)
        #expect(usable == .usable)
        #expect(usable.result == "success")
        #expect(usable.restoredField == 1)

        let retained = SessionRestorePerformanceOutcome.resolve(
            reportedRestored: true, hasUsableSession: false)
        #expect(retained == .credentialRetainedButUnavailable)
        #expect(retained.result == "partial")
        #expect(retained.restoredField == 0)

        let unavailable = SessionRestorePerformanceOutcome.resolve(
            reportedRestored: false, hasUsableSession: false)
        #expect(unavailable == .unavailable)
        #expect(unavailable.result == "failure")
        #expect(unavailable.restoredField == 0)

        // Runtime readiness is authoritative even if a helper reports a conservative false.
        #expect(SessionRestorePerformanceOutcome.resolve(
            reportedRestored: false, hasUsableSession: true) == .usable)
    }
}
#endif
