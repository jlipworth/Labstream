import Foundation
import Testing
@testable import PMSKit

@Suite("Download forward-only stall tracker")
struct DownloadForwardOnlyStallTrackerTests {
    private func record(ratingKey: String = "jellyfin:1",
                        lane: DownloadLane = .optimize,
                        resumeMode: DownloadResumeMode? = nil,
                        status: DownloadStatus = .downloading,
                        bytes: Int = 10_000) -> DownloadRecord {
        DownloadRecord(ratingKey: ratingKey,
                       title: "Fixture",
                       localURL: URL(fileURLWithPath: "/tmp/fixture.mp4"),
                       bytes: bytes,
                       progress: 0,
                       status: status,
                       metadata: OfflineMetadata(ratingKey: ratingKey,
                                                 title: "Fixture",
                                                 type: "movie",
                                                 downloadLane: lane,
                                                 resumeMode: resumeMode))
    }

    @Test("A skipped restart below the high-water mark leaves a restart available")
    func skippedRestartDoesNotSpendBudget() {
        var tracker = DownloadForwardOnlyStallTracker()
        let start = Date(timeIntervalSince1970: 1_000)
        tracker.seedRestartAttempts("jellyfin:1", attempts: 1, highWaterBytes: 10_000)
        func observe(_ bytes: Int, _ seconds: Double) -> DownloadForwardOnlyStallRestart? {
            tracker.detectRestarts(records: [record(bytes: bytes)], now: start.addingTimeInterval(seconds)) { _ in true }.first
        }
        _ = observe(100, 0)
        #expect(observe(100, 120)?.attempt == 2)
        _ = observe(101, 121)
        #expect(observe(101, 250)?.verdict == .restart)
    }

    @Test("First observation does not immediately restart")
    func firstObservationDoesNotRestart() {
        var tracker = DownloadForwardOnlyStallTracker()
        let now = Date(timeIntervalSince1970: 1_000)
        let restarts = tracker.detectRestarts(records: [record()], now: now) { _ in true }
        #expect(restarts.isEmpty)
        #expect(tracker.trackedCount == 1)
        #expect(tracker.observation(for: "jellyfin:1")?.bytes == 10_000)
    }

    @Test("Stalled active streams propose the next restart without spending it")
    func stalledActiveStreamRestarts() {
        var tracker = DownloadForwardOnlyStallTracker()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = tracker.detectRestarts(records: [record()], now: start) { _ in true }
        let later = start.addingTimeInterval(120)
        let restarts = tracker.detectRestarts(records: [record()], now: later) { _ in true }
        #expect(restarts.count == 1)
        #expect(restarts.first?.record.ratingKey == "jellyfin:1")
        #expect(restarts.first?.attempt == 1)
        #expect(Int(restarts.first?.stalledFor ?? 0) == 120)
        #expect(tracker.restartAttemptCount(for: "jellyfin:1") == 0)
    }

    @Test("Byte progress resets the restart attempt budget")
    func byteProgressResetsAttempts() {
        var tracker = DownloadForwardOnlyStallTracker()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = tracker.detectRestarts(records: [record(bytes: 10_000)], now: start) { _ in true }
        _ = tracker.detectRestarts(records: [record(bytes: 10_000)], now: start.addingTimeInterval(120)) { _ in true }
        tracker.seedRestartAttempts("jellyfin:1", attempts: 1, highWaterBytes: 10_000)
        #expect(tracker.restartAttemptCount(for: "jellyfin:1") == 1)

        let progress = start.addingTimeInterval(130)
        let restarts = tracker.detectRestarts(records: [record(bytes: 20_000)], now: progress) { _ in true }
        #expect(restarts.isEmpty)
        #expect(tracker.restartAttemptCount(for: "jellyfin:1") == 0)
        #expect(tracker.observation(for: "jellyfin:1")?.bytes == 20_000)
        #expect(tracker.observation(for: "jellyfin:1")?.lastForwardProgressAt == progress)
    }

    @Test("Inactive streams and static rows do not restart")
    func inactiveAndStaticRowsDoNotRestart() {
        var tracker = DownloadForwardOnlyStallTracker()
        let start = Date(timeIntervalSince1970: 1_000)
        let staticRow = record(ratingKey: "jellyfin:static", lane: .original, resumeMode: .staticByteRange)
        let inactive = record(ratingKey: "emby:inactive", lane: .optimize)
        _ = tracker.detectRestarts(records: [staticRow, inactive], now: start) { _ in false }
        let restarts = tracker.detectRestarts(records: [staticRow, inactive], now: start.addingTimeInterval(120)) { _ in false }
        #expect(restarts.isEmpty)
        #expect(tracker.trackedCount == 1)
        #expect(tracker.observation(for: "emby:inactive") != nil)
        #expect(tracker.observation(for: "jellyfin:static") == nil)
    }

    // The manager's stall-restart path funnels through releaseInFlight → remove(), which used to
    // erase the attempt just counted, so the 2-restart cap never bound and a persistent wedge
    // restarted the encoder from byte 0 forever. seedRestartAttempts restores the budget.
    @Test("Restart budget survives the stall-restart teardown and the cap binds")
    func budgetSurvivesTeardownReseed() {
        var tracker = DownloadForwardOnlyStallTracker()
        var now = Date(timeIntervalSince1970: 1_000)
        _ = tracker.detectRestarts(records: [record()], now: now) { _ in true }

        // First stall → restart attempt 1, then the manager teardown + re-seed cycle.
        now = now.addingTimeInterval(120)
        #expect(tracker.detectRestarts(records: [record()], now: now) { _ in true }.first?.attempt == 1)
        tracker.remove("jellyfin:1")
        tracker.seedRestartAttempts("jellyfin:1", attempts: 1, highWaterBytes: 10_000)
        // The interim failed-row pass (refreshRecords before retry) keeps the budget.
        _ = tracker.detectRestarts(records: [record(status: .failed)], now: now) { _ in false }
        #expect(tracker.restartAttemptCount(for: "jellyfin:1") == 1)

        // Stream restarts, wedges again → attempt 2 (still within the cap), same cycle.
        _ = tracker.detectRestarts(records: [record()], now: now) { _ in true }
        now = now.addingTimeInterval(120)
        #expect(tracker.detectRestarts(records: [record()], now: now) { _ in true }.first?.attempt == 2)
        tracker.remove("jellyfin:1")
        tracker.seedRestartAttempts("jellyfin:1", attempts: 2, highWaterBytes: 10_000)

        // Third wedge: the cap binds — no further automatic restart. The stall still gets a
        // verdict (#497): the row fails and waits for the user.
        _ = tracker.detectRestarts(records: [record()], now: now) { _ in true }
        now = now.addingTimeInterval(120)
        let capped = tracker.detectRestarts(records: [record()], now: now) { _ in true }
        #expect(capped.count == 1)
        #expect(capped.first?.verdict == .fail)
        #expect(capped.first?.attempt == 2)
        #expect(tracker.restartAttemptCount(for: "jellyfin:1") == 2)
        // Reported once: the refreshes before the failure lands do not repeat it.
        #expect(tracker.detectRestarts(records: [record()], now: now.addingTimeInterval(15)) { _ in true }.isEmpty)
    }

    @Test("Past the cap a stall fails the row only after the stall timeout, and progress restores the budget (#497)")
    func cappedStallFailsAfterTimeout() {
        var tracker = DownloadForwardOnlyStallTracker()
        let start = Date(timeIntervalSince1970: 1_000)
        tracker.seedRestartAttempts("jellyfin:1", attempts: 2, highWaterBytes: 10_000)
        _ = tracker.detectRestarts(records: [record()], now: start) { _ in true }
        #expect(tracker.detectRestarts(records: [record()], now: start.addingTimeInterval(60)) { _ in true }.isEmpty)
        // An inactive row (no job, no tracked task) is not judged.
        #expect(tracker.detectRestarts(records: [record()], now: start.addingTimeInterval(95)) { _ in false }.isEmpty)
        // Forward progress resets the budget: the next stall is a restart again, not a failure.
        _ = tracker.detectRestarts(records: [record(bytes: 20_000)], now: start.addingTimeInterval(100)) { _ in true }
        #expect(tracker.restartAttemptCount(for: "jellyfin:1") == 0)
        let next = tracker.detectRestarts(records: [record(bytes: 20_000)], now: start.addingTimeInterval(200)) { _ in true }
        #expect(next.map(\.verdict) == [.restart])
        #expect(DownloadStallRecoveryPolicy.shouldFailForwardOnlyStream(
            record: record(), active: true, lastForwardProgressAt: start, now: start.addingTimeInterval(90),
            restartAttempts: 2))
        #expect(!DownloadStallRecoveryPolicy.shouldFailForwardOnlyStream(
            record: record(), active: true, lastForwardProgressAt: start, now: start.addingTimeInterval(90),
            restartAttempts: 1))
    }

    /// Review of PR #505 (#497): drive the manager's restart cycle (verdict, `remove` in the
    /// teardown, seed back, the replacement replays from byte 0) against a stream that reaches
    /// 1 MiB and wedges there every time. Before the high-water mark the replayed bytes cleared
    /// the count, so every stall was attempt 1 and the row restarted for ever.
    @Test("Replacements that replay up to the old high-water mark do not refill the restart budget")
    func replayedBytesDoNotRefillTheBudget() {
        let mib = 1_048_576
        var tracker = DownloadForwardOnlyStallTracker()
        var now = Date(timeIntervalSince1970: 1_000)
        func refresh(bytes: Int, status: DownloadStatus = .downloading) -> [DownloadForwardOnlyStallRestart] {
            tracker.detectRestarts(records: [record(status: status, bytes: bytes)], now: now) { _ in true }
        }
        var verdicts: [(DownloadForwardOnlyStallVerdict, Int)] = []
        // The first attempt streams to 1 MiB.
        for bytes in stride(from: 0, through: mib, by: mib / 4) {
            _ = refresh(bytes: bytes); now = now.addingTimeInterval(15)
        }
        for _ in 0..<10 where verdicts.last?.0 != .fail {
            // Wedged at 1 MiB until the stall timeout passes.
            var found: [DownloadForwardOnlyStallRestart] = []
            while found.isEmpty {
                found = refresh(bytes: mib); now = now.addingTimeInterval(15)
            }
            let verdict = found[0]
            verdicts.append((verdict.verdict, verdict.attempt))
            #expect(verdict.highWaterBytes == mib)
            // restartStalledForwardOnlyStreamAsync / failStalledForwardOnlyStreamAsync.
            let high = tracker.highWaterMark(for: "jellyfin:1") ?? 0
            tracker.remove("jellyfin:1")
            guard verdict.verdict == .restart else { break }
            tracker.seedRestartAttempts("jellyfin:1", attempts: verdict.attempt,
                                        highWaterBytes: max(verdict.highWaterBytes, high))
            _ = refresh(bytes: mib, status: .failed)
            // The replacement replays the stream from byte 0 up to the old high-water mark.
            for bytes in stride(from: 0, through: mib, by: mib / 4) {
                _ = refresh(bytes: bytes); now = now.addingTimeInterval(15)
            }
            #expect(tracker.restartAttemptCount(for: "jellyfin:1") == verdict.attempt)
        }
        #expect(verdicts.map(\.0) == [.restart, .restart, .fail])
        #expect(verdicts.map(\.1) == [1, 2, 2])
    }

    @Test("A replacement that passes the high-water mark, or a user Retry, refills the budget")
    func passingTheHighWaterMarkOrRetryRefills() {
        var tracker = DownloadForwardOnlyStallTracker()
        let now = Date(timeIntervalSince1970: 1_000)
        tracker.seedRestartAttempts("jellyfin:1", attempts: 2, highWaterBytes: 10_000)
        _ = tracker.detectRestarts(records: [record(bytes: 0)], now: now) { _ in true }
        _ = tracker.detectRestarts(records: [record(bytes: 10_000)], now: now.addingTimeInterval(1)) { _ in true }
        #expect(tracker.restartAttemptCount(for: "jellyfin:1") == 2)
        _ = tracker.detectRestarts(records: [record(bytes: 10_001)], now: now.addingTimeInterval(2)) { _ in true }
        #expect(tracker.restartAttemptCount(for: "jellyfin:1") == 0)
        #expect(tracker.highWaterMark(for: "jellyfin:1") == 10_001)

        tracker.seedRestartAttempts("jellyfin:2", attempts: 2, highWaterBytes: 50_000)
        tracker.refillRestartBudget("jellyfin:2")
        #expect(tracker.restartAttemptCount(for: "jellyfin:2") == 0)
        #expect(tracker.highWaterMark(for: "jellyfin:2") == nil)
    }

    @Test("Removed and terminal rows prune tracker state")
    func prunesState() {
        var tracker = DownloadForwardOnlyStallTracker()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = tracker.detectRestarts(records: [record()], now: start) { _ in true }
        #expect(tracker.trackedCount == 1)

        _ = tracker.detectRestarts(records: [], now: start.addingTimeInterval(10)) { _ in false }
        #expect(tracker.trackedCount == 0)

        _ = tracker.detectRestarts(records: [record()], now: start.addingTimeInterval(20)) { _ in true }
        tracker.remove("jellyfin:1")
        #expect(tracker.trackedCount == 0)
    }
}
