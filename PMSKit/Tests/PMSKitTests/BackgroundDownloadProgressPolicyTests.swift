import Foundation
import Testing
@testable import PMSKit

@Suite("Background download progress policy")
struct BackgroundDownloadProgressPolicyTests {

    @Test("Expected bytes are recovered from persisted bytes and progress")
    func derivesExpectedBytes() {
        let record = DownloadRecord(
            ratingKey: "movie",
            title: "Movie",
            localURL: URL(fileURLWithPath: "/tmp/movie.mp4"),
            bytes: 25,
            progress: 0.25
        )

        #expect(BackgroundDownloadProgressPolicy.derivedExpectedBytes(record) == 100)
        #expect(BackgroundDownloadProgressPolicy.derivedExpectedBytes(downloadedBytes: 101, progress: 1.5) == 101)
        #expect(BackgroundDownloadProgressPolicy.derivedExpectedBytes(downloadedBytes: 0, progress: 0.5) == nil)
        #expect(BackgroundDownloadProgressPolicy.derivedExpectedBytes(downloadedBytes: 10, progress: 0.00001) == nil)
    }

    @Test("Range diagnostics record first observations and then throttle by time or bytes")
    func rangeDiagnosticThrottle() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let last = BackgroundRangeProgressDiagnosticSnapshot(time: t0, bytes: 1_000)

        #expect(BackgroundDownloadProgressPolicy.shouldRecordRangeProgress(
            last: last,
            now: t0,
            totalBytes: 1_000,
            byteInterval: 64,
            isFirstCallback: true
        ))
        #expect(BackgroundDownloadProgressPolicy.shouldRecordRangeProgress(
            last: nil,
            now: t0,
            totalBytes: 1_000,
            byteInterval: 64,
            isFirstCallback: false
        ))
        #expect(!BackgroundDownloadProgressPolicy.shouldRecordRangeProgress(
            last: last,
            now: t0.addingTimeInterval(9.9),
            totalBytes: 1_063,
            byteInterval: 64,
            isFirstCallback: false
        ))
        #expect(BackgroundDownloadProgressPolicy.shouldRecordRangeProgress(
            last: last,
            now: t0.addingTimeInterval(10),
            totalBytes: 1_000,
            byteInterval: 64,
            isFirstCallback: false
        ))
        #expect(BackgroundDownloadProgressPolicy.shouldRecordRangeProgress(
            last: last,
            now: t0,
            totalBytes: 1_064,
            byteInterval: 64,
            isFirstCallback: false
        ))
    }

    @Test("UI progress publication throttles normal progress but always emits completion")
    func progressNotificationThrottle() {
        let t0 = Date(timeIntervalSince1970: 2_000)

        #expect(BackgroundDownloadProgressPolicy.shouldNotifyProgressChange(
            lastNotification: nil,
            now: t0,
            progress: 0.1,
            interval: 0.5
        ))
        #expect(!BackgroundDownloadProgressPolicy.shouldNotifyProgressChange(
            lastNotification: t0,
            now: t0.addingTimeInterval(0.49),
            progress: 0.9,
            interval: 0.5
        ))
        #expect(BackgroundDownloadProgressPolicy.shouldNotifyProgressChange(
            lastNotification: t0,
            now: t0.addingTimeInterval(0.5),
            progress: 0.9,
            interval: 0.5
        ))
        #expect(BackgroundDownloadProgressPolicy.shouldNotifyProgressChange(
            lastNotification: t0,
            now: t0.addingTimeInterval(0.01),
            progress: 1.0,
            interval: 0.5
        ))
    }
}
