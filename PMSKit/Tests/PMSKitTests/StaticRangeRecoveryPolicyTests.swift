import Foundation
import Testing
@testable import PMSKit

@Suite("Static range recovery policy")
struct StaticRangeRecoveryPolicyTests {
    private let url = URL(fileURLWithPath: "/tmp/labstream-static-range-policy.mp4")

    private func record(status: DownloadStatus = .paused,
                        progress: Double = 0.25,
                        backend: DownloadBackendKind = .plex,
                        lane: DownloadLane = .original,
                        resumeMode: DownloadResumeMode? = .staticByteRange,
                        bytes: Int = 100) -> DownloadRecord {
        let key = DownloadRecordIdentity.recordKey(for: "item", backend: backend)
        let metadata = OfflineMetadata(ratingKey: key,
                                       title: "Title",
                                       type: "movie",
                                       backendKind: backend,
                                       downloadLane: lane,
                                       resumeMode: resumeMode)
        return DownloadRecord(ratingKey: key,
                              title: "Title",
                              localURL: url,
                              bytes: bytes,
                              progress: progress,
                              status: status,
                              metadata: metadata)
    }

    @Test("Static range detection respects explicit and inferred resume mode")
    func staticRangeDetection() {
        #expect(StaticRangeRecoveryPolicy.isStaticRangeRecord(record()))
        #expect(!StaticRangeRecoveryPolicy.isStaticRangeRecord(
            record(lane: .optimize, resumeMode: .liveForwardOnly)
        ))

        let inferredPlexOriginal = record(resumeMode: nil)
        #expect(StaticRangeRecoveryPolicy.isStaticRangeRecord(inferredPlexOriginal))

        let inferredEmbyOptimize = record(backend: .emby, lane: .optimize, resumeMode: nil)
        #expect(!StaticRangeRecoveryPolicy.isStaticRangeRecord(inferredEmbyOptimize))
    }

    @Test("Only non-terminal complete static checkpoints start finalization")
    func finalizeDecision() {
        let completeCheckpoint = record(status: .downloading, progress: 1.0)
        #expect(StaticRangeRecoveryPolicy.finalizeDecision(for: completeCheckpoint,
                                                           checkpointBytes: 42,
                                                           isAlreadyFinalizing: false)
                == .start(checkpointBytes: 42))
        #expect(StaticRangeRecoveryPolicy.finalizeDecision(for: completeCheckpoint,
                                                           checkpointBytes: 42,
                                                           isAlreadyFinalizing: true)
                == .alreadyFinalizing)
        #expect(StaticRangeRecoveryPolicy.finalizeDecision(for: completeCheckpoint,
                                                           checkpointBytes: 0,
                                                           isAlreadyFinalizing: false)
                == .ignore)
        #expect(StaticRangeRecoveryPolicy.finalizeDecision(for: record(status: .complete, progress: 1.0),
                                                           checkpointBytes: 42,
                                                           isAlreadyFinalizing: false)
                == .ignore)
        #expect(StaticRangeRecoveryPolicy.finalizeDecision(
            for: record(status: .downloading, progress: 1.0, resumeMode: .liveForwardOnly),
            checkpointBytes: 42,
            isAlreadyFinalizing: false
        ) == .ignore)
    }

    @Test("Deferred resume visible state is derived from active intent and durable bytes")
    func deferredResumeDisposition() {
        #expect(StaticRangeRecoveryPolicy.deferredResumeDisposition(checkpointBytes: 0,
                                                                    preserveActiveIntent: true)
                == .queuedActiveIntent)
        #expect(StaticRangeRecoveryPolicy.deferredResumeDisposition(checkpointBytes: 10,
                                                                    preserveActiveIntent: false)
                == .pausedAtCheckpoint)
        #expect(StaticRangeRecoveryPolicy.deferredResumeDisposition(checkpointBytes: 0,
                                                                    preserveActiveIntent: false)
                == .failedNoCheckpoint)
    }

    @Test("Queue pause waits for explicit per-row resume")
    func queuePauseManualGate() {
        #expect(StaticRangeRecoveryPolicy.shouldWaitForManualResume(isQueuePaused: true,
                                                                    wasManuallyResumedWhileQueuePaused: false))
        #expect(!StaticRangeRecoveryPolicy.shouldWaitForManualResume(isQueuePaused: true,
                                                                     wasManuallyResumedWhileQueuePaused: true))
        #expect(!StaticRangeRecoveryPolicy.shouldWaitForManualResume(isQueuePaused: false,
                                                                     wasManuallyResumedWhileQueuePaused: false))
    }

    @Test("Retry handoff demotes only static rows in the relevant transient states")
    func retryHandoffDemotion() {
        #expect(StaticRangeRecoveryPolicy.shouldMarkPausedRowInactiveBeforeBackendRetry(
            record(status: .paused)
        ))
        #expect(!StaticRangeRecoveryPolicy.shouldMarkPausedRowInactiveBeforeBackendRetry(
            record(status: .paused, resumeMode: .liveForwardOnly)
        ))
        #expect(!StaticRangeRecoveryPolicy.shouldMarkPausedRowInactiveBeforeBackendRetry(
            record(status: .failed)
        ))

        #expect(StaticRangeRecoveryPolicy.shouldMarkSystemResumeInactiveBeforeRetry(
            record(status: .queued)
        ))
        #expect(StaticRangeRecoveryPolicy.shouldMarkSystemResumeInactiveBeforeRetry(
            record(status: .downloading)
        ))
        #expect(!StaticRangeRecoveryPolicy.shouldMarkSystemResumeInactiveBeforeRetry(
            record(status: .downloading, resumeMode: .liveForwardOnly)
        ))
        #expect(!StaticRangeRecoveryPolicy.shouldMarkSystemResumeInactiveBeforeRetry(
            record(status: .paused)
        ))
    }

    @Test("Only no-progress request rebuild reasons preserve retry counters")
    func preserveRestartCounterReasons() {
        #expect(StaticRangeRecoveryPolicy.shouldPreserveRangeRestartCounters(reason: "validatorChanged"))
        #expect(StaticRangeRecoveryPolicy.shouldPreserveRangeRestartCounters(reason: "requestRebuildNeeded"))
        #expect(StaticRangeRecoveryPolicy.shouldPreserveRangeRestartCounters(reason: "serverAuthorizationRejected"))
        #expect(!StaticRangeRecoveryPolicy.shouldPreserveRangeRestartCounters(reason: "unownedRangeRejected"))
        #expect(!StaticRangeRecoveryPolicy.shouldPreserveRangeRestartCounters(reason: "backend_ready"))
    }

    @Test("Storage-full rows park automatic resume until space would fit the remainder")
    func storageFullParksAutoResume() {
        // Only a storage-full last failure parks; other failures keep normal auto-resume.
        #expect(!StaticRangeRecoveryPolicy.shouldParkAutoResumeAfterStorageFull(
            lastFailureWasStorageFull: false,
            freeBytes: 0,
            remainingBytes: 10_000_000_000))
        // Unmeasurable free space is treated as still-full: never auto-redrive blind.
        #expect(StaticRangeRecoveryPolicy.shouldParkAutoResumeAfterStorageFull(
            lastFailureWasStorageFull: true,
            freeBytes: nil,
            remainingBytes: 1))
        // The observed defect shape: ~8.6 GB free vs a ~8.9 GB remainder + headroom.
        #expect(StaticRangeRecoveryPolicy.shouldParkAutoResumeAfterStorageFull(
            lastFailureWasStorageFull: true,
            freeBytes: 8_586_698_752,
            remainingBytes: 8_880_317_413))
        // Enough space for remainder + headroom releases the row back to auto-resume.
        #expect(!StaticRangeRecoveryPolicy.shouldParkAutoResumeAfterStorageFull(
            lastFailureWasStorageFull: true,
            freeBytes: 9_380_317_413,
            remainingBytes: 8_880_317_413))
        // A zero/unknown remainder still requires the headroom floor, matching the preflight.
        #expect(StaticRangeRecoveryPolicy.shouldParkAutoResumeAfterStorageFull(
            lastFailureWasStorageFull: true,
            freeBytes: 499_999_999,
            remainingBytes: 0))
        #expect(!StaticRangeRecoveryPolicy.shouldParkAutoResumeAfterStorageFull(
            lastFailureWasStorageFull: true,
            freeBytes: 500_000_000,
            remainingBytes: 0))
    }
}
