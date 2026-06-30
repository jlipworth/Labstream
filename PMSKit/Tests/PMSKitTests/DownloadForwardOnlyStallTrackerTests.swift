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

    @Test("First observation does not immediately restart")
    func firstObservationDoesNotRestart() {
        var tracker = DownloadForwardOnlyStallTracker()
        let now = Date(timeIntervalSince1970: 1_000)
        let restarts = tracker.detectRestarts(records: [record()], now: now) { _ in true }
        #expect(restarts.isEmpty)
        #expect(tracker.trackedCount == 1)
        #expect(tracker.observation(for: "jellyfin:1")?.bytes == 10_000)
    }

    @Test("Stalled active streams restart and increment bounded attempts")
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
        #expect(tracker.restartAttemptCount(for: "jellyfin:1") == 1)
    }

    @Test("Byte progress resets the restart attempt budget")
    func byteProgressResetsAttempts() {
        var tracker = DownloadForwardOnlyStallTracker()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = tracker.detectRestarts(records: [record(bytes: 10_000)], now: start) { _ in true }
        _ = tracker.detectRestarts(records: [record(bytes: 10_000)], now: start.addingTimeInterval(120)) { _ in true }
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
