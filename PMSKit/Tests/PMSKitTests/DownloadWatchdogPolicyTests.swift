import Foundation
import Testing
@testable import PMSKit

@Suite("Download watchdog policy")
struct DownloadWatchdogPolicyTests {
    private let url = URL(fileURLWithPath: "/tmp/labstream-watchdog-policy.mp4")

    private func record(status: DownloadStatus,
                        backend: DownloadBackendKind = .jellyfin,
                        lane: DownloadLane = .compatibleRemux,
                        resumeMode: DownloadResumeMode = .liveForwardOnly) -> DownloadRecord {
        let ratingKey = DownloadRecordIdentity.recordKey(for: "item", backend: backend)
        let metadata = OfflineMetadata(ratingKey: ratingKey,
                                       title: "Title",
                                       type: "movie",
                                       backendKind: backend,
                                       downloadLane: lane,
                                       resumeMode: resumeMode)
        return DownloadRecord(ratingKey: ratingKey,
                              title: "Title",
                              localURL: url,
                              bytes: 0,
                              progress: 0,
                              status: status,
                              metadata: metadata)
    }

    @Test("Watchdog cadence remains stable")
    func cadence() {
        #expect(DownloadWatchdogPolicy.refreshIntervalSeconds == 15.0)
    }

    @Test("Preparing rows always need watchdog refreshes")
    func preparingRowsNeedWatchdog() {
        #expect(DownloadWatchdogPolicy.requiresWatchdog(record(status: .preparing,
                                                              backend: .emby,
                                                              lane: .optimize,
                                                              resumeMode: .serverPrepThenStatic)))
    }

    @Test("Forward-only MediaBrowser streams need watchdog refreshes")
    func forwardOnlyRowsNeedWatchdog() {
        #expect(DownloadWatchdogPolicy.requiresWatchdog(record(status: .downloading)))
        #expect(!DownloadWatchdogPolicy.requiresWatchdog(record(status: .downloading,
                                                               backend: .plex,
                                                               lane: .original,
                                                               resumeMode: .staticByteRange)))
    }

    @Test("A transferring static row does not keep the polling loop alive (#488 review)")
    func transferringStaticRowsDoNotPoll() {
        var staticRow = record(status: .downloading, backend: .plex, lane: .original, resumeMode: .staticByteRange)
        for lifecycle: DownloadLifecycle in [.transferring, .admitted, .paused, .failed, .finalizing, .complete] {
            staticRow.lifecycle = lifecycle
            #expect(!DownloadWatchdogPolicy.requiresWatchdog(staticRow), "\(lifecycle)")
        }
    }

    @Test("The rate expiry is the earliest stale deadline still ahead, plus the slack")
    func rateEvidenceExpiry() {
        let now = Date(timeIntervalSince1970: 1_000)
        let slack = DownloadWatchdogPolicy.rateExpirySlackSeconds
        #expect(DownloadWatchdogPolicy.nextRateEvidenceExpiry(staleDeadlines: [Date](), now: now) == nil)
        #expect(DownloadWatchdogPolicy.nextRateEvidenceExpiry(
            staleDeadlines: [now, now.addingTimeInterval(-3)], now: now) == nil)
        #expect(DownloadWatchdogPolicy.nextRateEvidenceExpiry(
            staleDeadlines: [now.addingTimeInterval(5), now.addingTimeInterval(2), now.addingTimeInterval(-1)],
            now: now) == now.addingTimeInterval(2 + slack))
    }

    /// #488 review: one silent static row used to keep a main-actor `refreshRecords()` running
    /// every 15 s for as long as it stayed transferring. Drive the owner's loop (refresh, sample
    /// the row, show its speed and ETA, arm the next expiry) on a fake clock: the row's speed and
    /// ETA are gone one stall timeout after its last byte, and an hour of silence costs a bounded
    /// number of refreshes.
    @Test("One silent static row produces a bounded number of refreshes and loses its speed and ETA")
    func silentStaticRowRefreshesAreBounded() {
        var staticRow = record(status: .downloading, backend: .plex, lane: .original, resumeMode: .staticByteRange)
        staticRow.lifecycle = .transferring
        let start = Date(timeIntervalSince1970: 0)
        var estimator = DownloadRateEstimator(rebaselineSuppressWindow: 4.0)
        var bytes = 0
        var showsSpeed = false
        var showsETA = false
        var refreshes: [Double] = []
        var expiry: Date?
        func refresh(at t: Double) {
            refreshes.append(t)
            let now = start.addingTimeInterval(t)
            let rate = estimator.sample(bytes: bytes, at: now)
            showsSpeed = (rate ?? 0) > 0
            showsETA = estimator.eta(expectedTotal: 1_000_000_000) != nil
            #expect(!DownloadWatchdogPolicy.requiresWatchdog(records: [staticRow]))
            let deadlines = (showsSpeed || showsETA) ? [estimator.staleDeadline].compactMap { $0 } : []
            expiry = DownloadWatchdogPolicy.nextRateEvidenceExpiry(staleDeadlines: deadlines, now: now)
        }
        // Ten seconds of callbacks, each scheduling the 1 s range-progress refresh.
        var t = 0.0
        while t < 10 {
            bytes += 250_000
            refresh(at: t + 1)
            t += 1
        }
        #expect(showsSpeed)
        let lastByte = refreshes.last ?? 0
        let callbackRefreshes = refreshes.count
        // Then silence for an hour: only the armed one-shot refreshes run.
        let horizon = 3_600.0
        while let next = expiry, next.timeIntervalSince(start) <= horizon {
            refresh(at: next.timeIntervalSince(start))
        }
        #expect(!showsSpeed && !showsETA)
        #expect(refreshes.count - callbackRefreshes <= 2, "\(refreshes.count - callbackRefreshes) expiry refreshes")
        #expect((refreshes.last ?? 0) <= lastByte + estimator.stallTimeout + 1)
    }

    @Test("Collections require watchdog when any row does")
    func collectionPredicate() {
        let complete = record(status: .complete, backend: .plex, lane: .original, resumeMode: .staticByteRange)
        let prep = record(status: .preparing, backend: .emby, lane: .optimize, resumeMode: .serverPrepThenStatic)
        #expect(!DownloadWatchdogPolicy.requiresWatchdog(records: [complete]))
        #expect(DownloadWatchdogPolicy.requiresWatchdog(records: [complete, prep]))
    }
}
