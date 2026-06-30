import Foundation
import Testing
@testable import PMSKit

@Suite("Download terminal release policy")
struct DownloadTerminalReleasePolicyTests {
    private let url = URL(fileURLWithPath: "/tmp/visionplay-terminal-release.mp4")

    private func record(_ status: DownloadStatus, key: String = "item") -> DownloadRecord {
        let ratingKey = DownloadRecordIdentity.recordKey(for: key, backend: .jellyfin)
        return DownloadRecord(ratingKey: ratingKey,
                              title: "Title",
                              localURL: url,
                              bytes: 0,
                              progress: 0,
                              status: status)
    }

    @Test("Terminal and paused rows release in-flight protection")
    func terminalRowsRelease() {
        for status in [DownloadStatus.complete, .unverified, .failed, .paused] {
            #expect(DownloadTerminalReleasePolicy.shouldReleaseInFlight(record: record(status),
                                                                       retryHandoffKeys: [],
                                                                       retryingKeys: []))
        }
        for status in [DownloadStatus.queued, .preparing, .downloading] {
            #expect(!DownloadTerminalReleasePolicy.shouldReleaseInFlight(record: record(status),
                                                                        retryHandoffKeys: [],
                                                                        retryingKeys: []))
        }
    }

    @Test("Internal retry failed sentinel does not release")
    func retryHandoffFailedSentinelDoesNotRelease() {
        let failed = record(.failed, key: "failed")
        #expect(!DownloadTerminalReleasePolicy.shouldReleaseInFlight(record: failed,
                                                                    retryHandoffKeys: [failed.ratingKey],
                                                                    retryingKeys: [failed.ratingKey]))
        #expect(DownloadTerminalReleasePolicy.shouldReleaseInFlight(record: failed,
                                                                   retryHandoffKeys: [failed.ratingKey],
                                                                   retryingKeys: []))
        #expect(DownloadTerminalReleasePolicy.shouldReleaseInFlight(record: failed,
                                                                   retryHandoffKeys: [],
                                                                   retryingKeys: [failed.ratingKey]))
    }

    @Test("Terminal release keys filters a collection")
    func terminalReleaseKeys() {
        let complete = record(.complete, key: "complete")
        let paused = record(.paused, key: "paused")
        let active = record(.downloading, key: "active")
        let sentinel = record(.failed, key: "sentinel")
        let keys = DownloadTerminalReleasePolicy.terminalReleaseKeys(records: [complete, paused, active, sentinel],
                                                                     retryHandoffKeys: [sentinel.ratingKey],
                                                                     retryingKeys: [sentinel.ratingKey])
        #expect(keys == [complete.ratingKey, paused.ratingKey])
    }
}
