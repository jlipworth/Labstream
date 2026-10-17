#if !os(tvOS)
import Foundation
import PMSKit
import Testing
import Synchronization
@testable import Labstream

@Suite("P7 offline availability pins", .serialized)
@MainActor
struct P7OfflineAvailabilityTests {
    @Test func repeatedGateReadsDoNotStatAgain() async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        let stats = Mutex(0)
        f.manager.offlineFileExists = { _ in stats.withLock { $0 += 1 }; return true }
        f.manager.refreshOfflineAvailability(force: true)
        await f.manager.offlineAvailabilityCache.worker?.value
        #expect(f.manager.hasPlayableOfflineContent)
        let afterScan = stats.withLock { $0 }
        for _ in 0..<20 { #expect(f.manager.hasPlayableOfflineContent) }
        f.manager.refreshRecords() // A publication with unchanged terminal candidate identity.
        _ = f.manager.hasPlayableOfflineContent
        #expect(stats.withLock { $0 } == afterScan)
        await f.finish()
    }

    @Test func delayedPositiveScanCannotReviveDeletedCandidate() async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        let cache = OfflinePlayableAvailabilityCache()
        let entered = P6Acknowledgement<Bool>()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        cache.refresh(records: [f.record], access: .readable, fileExists: { _ in
            entered.signal(true)
            release.wait()
            return true
        })
        let staleScan = cache.worker
        _ = await entered.wait()
        cache.refresh(records: [], access: .readable, fileExists: { _ in true })
        #expect(!cache.hasPlayableFile)
        release.signal()
        await staleScan?.value
        #expect(!cache.hasPlayableFile)
        #expect(cache.value.scan == .resolved(hasPlayableFile: false))
        await f.finish()
    }

    @Test func progressDoesNotRescanButForegroundDoes() async throws {
        let f = try await P7PlaybackFixture(status: .complete)
        await f.manager.offlineAvailabilityCache.worker?.value
        let count = Mutex(0)
        f.manager.offlineFileExists = { _ in count.withLock { $0 += 1 }; return true }
        f.manager.refreshOfflineAvailability(force: true)
        await f.manager.offlineAvailabilityCache.worker?.value
        let controller = try await f.launchController()
        controller.recordLocalPlaybackPosition(70_000)
        await f.manager.drainManagerOperationsForTesting()
        #expect(count.withLock { $0 } == 1)
        f.manager.refreshOfflineAvailability(force: true)
        await f.manager.offlineAvailabilityCache.worker?.value
        #expect(count.withLock { $0 } == 2)
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
        f.manager.refreshOfflineAvailability()
        await f.manager.offlineAvailabilityCache.worker?.value
        // A readable admission block is not a playback gate or mutation authority.
        let blockedLaunch = try await f.launch()
        blockedLaunch.events.progress(positionMs: 80_000, durationMs: 600_000)
        blockedLaunch.events.playbackObserved()
        await f.manager.drainManagerOperationsForTesting()
        #expect(f.store.record(for: f.key)?.metadata?.localPlaybackPositionMs == 30_000)
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
