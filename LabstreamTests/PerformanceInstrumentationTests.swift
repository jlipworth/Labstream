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
}
#endif
