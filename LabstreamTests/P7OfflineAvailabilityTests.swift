#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("P7 offline availability pins", .serialized)
@MainActor
struct P7OfflineAvailabilityTests {
    @Test func repeatedGateReadsDoNotStatAgain() async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        var stats = 0
        f.manager.offlineFileExists = { _ in stats += 1; return true }
        #expect(f.manager.hasPlayableOfflineContent)
        let afterScan = stats
        for _ in 0..<20 { #expect(f.manager.hasPlayableOfflineContent) }
        f.manager.refreshRecords() // A publication with unchanged terminal candidate identity.
        _ = f.manager.hasPlayableOfflineContent
        withKnownIssue("P7 red pin: 11") { #expect(stats == afterScan) }
        await f.finish()
    }

    @Test func blockedReadableAdmissionRetainsPlaybackButOpaqueIndexDoesNot() async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        // The real block pauses the queue durably. Restore its shared preference synchronously,
        // before another MainActor test can construct a manager; this fixture keeps its own gate.
        let defaults = UserDefaults.standard
        let savedPause = defaults.object(forKey: "downloads.queuePaused")
        f.manager.blockAfterIndeterminateSeasonPersistence()
        if let savedPause { defaults.set(savedPause, forKey: "downloads.queuePaused") }
        else { defaults.removeObject(forKey: "downloads.queuePaused") }
        guard case .blocked = f.manager.startupRecoveryState else {
            Issue.record("Expected the production admission block")
            await f.finish()
            return
        }
        // Amendment 1 is already green on this head: a block is not used as a playback gate.
        #expect(OfflineLaunchAvailability.admitsOfflineLaunch(restoreOutcome: .temporarilyUnavailable,
            hasPlayableDownload: f.manager.hasPlayableOfflineContent))
        #expect(!f.store.records.isEmpty)
        await f.finish()

        let opaque = try P6Fixture()
        try Data("unreadable index".utf8).write(to: opaque.directory.appendingPathComponent("index.json"))
        let store = opaque.store()
        #expect(!OfflineLaunchAvailability.hasPlayableDownload(records: store.records))
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 99, "rows": []])
            .write(to: opaque.directory.appendingPathComponent("index.json"))
        #expect(!OfflineLaunchAvailability.hasPlayableDownload(records: opaque.store().records))
    }
}
#endif
