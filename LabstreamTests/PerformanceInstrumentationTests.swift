import Foundation
import Testing
@testable import Labstream

#if DEBUG || PERFORMANCE_AUDIT
@Suite("Performance instrumentation")
struct PerformanceInstrumentationTests {
    @Test("Browse measurement phases have stable closed names")
    func browsePhaseNames() {
        #expect(PerformanceInstrumentation.Phase.homeFirstContent.rawValue == "home.first_content")
        #expect(PerformanceInstrumentation.Phase.searchLoad.rawValue == "search.load")
        #expect(PerformanceInstrumentation.Phase.libraryGridFirstContent.rawValue
                == "library_grid.first_content")
        #expect(PerformanceInstrumentation.Phase.libraryGridComplete.rawValue
                == "library_grid.complete")
        #expect(ArtworkDeliveryProvenance.allCases.map(\.rawValue) == [
            "network_decode", "compressed_cache_decode", "decoded_cache", "inflight_join", "local_file",
        ])
    }

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

    @Test("Cold first-poster measurement target can be claimed exactly once")
    func artworkMeasurementTargetIsProcessSafeExactlyOnce() {
        let gate = ArtworkMeasurementTargetGate()
        let successfulClaims = TestLockedBox(0)

        DispatchQueue.concurrentPerform(iterations: 128) { _ in
            guard gate.claim() else { return }
            successfulClaims.withValue { $0 += 1 }
        }

        #expect(successfulClaims.value == 1)
        #expect(!gate.claim())
    }

    @Test("Span result and fields are evaluated only by the winning end")
    func spanEndPayloadsAreLazy() {
        let evaluations = TestLockedBox(0)
        let span = PerformanceInstrumentation.begin(.homeFirstContent, backend: "Plex")

        for _ in 0..<2 {
            span.end(result: {
                evaluations.withValue { $0 += 1 }
                return "success"
            }(), fields: {
                evaluations.withValue { $0 += 1 }
                return ["rail_count": 1, "item_count": 1] as [String: Any]
            }())
        }

        #expect(evaluations.value == 2)
    }

    @Test("Browse measurement policy treats empty publication and cancellation semantically")
    func browseMeasurementPolicy() {
        let counts = BrowsePerformanceMeasurementPolicy.aggregateCounts([2, 0, 3])
        #expect(counts.containerCount == 3)
        #expect(counts.itemCount == 5)
        #expect(BrowsePerformanceMeasurementPolicy.aggregateCounts([]).itemCount == 0)
        #expect(BrowsePerformanceMeasurementPolicy.firstContentResult(itemCount: 1) == "success")
        #expect(BrowsePerformanceMeasurementPolicy.firstContentResult(itemCount: 0) == "partial")
        #expect(BrowsePerformanceMeasurementPolicy.caughtErrorResult(
            isCurrentIdentity: true, taskIsCancelled: false, errorIsCancellation: true) == "cancelled")
        #expect(BrowsePerformanceMeasurementPolicy.caughtErrorResult(
            isCurrentIdentity: true, taskIsCancelled: true, errorIsCancellation: false) == "cancelled")
        #expect(BrowsePerformanceMeasurementPolicy.caughtErrorResult(
            isCurrentIdentity: true, taskIsCancelled: false, errorIsCancellation: false) == "failure")
        #expect(BrowsePerformanceMeasurementPolicy.caughtErrorResult(
            isCurrentIdentity: false, taskIsCancelled: false, errorIsCancellation: false) == "superseded")
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
