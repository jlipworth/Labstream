#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("Published download row I/O", .serialized)
@MainActor
struct DownloadRowIOPerformanceTests {
    @Test func repeatedPresentationAndProgressReadsDoNotStat() async throws {
        let filesystem = DownloadPerformanceFileManager()
        let f = try await P7PlaybackFixture(status: .paused, fileManager: filesystem)
        #expect(await f.store.resolve(f.store.submitResumeData(for: f.key, Data([1]), displayBytes: 600), deadline: .after(5)) == .applied)
        _ = await f.store.updateMetadataAsync(for: f.key) { $0.sourcePartSize = 1_000 }
        f.manager.refreshRecords()
        for task in f.manager.resumePresenceWorkers.values { await task.value }
        let record = try #require(f.store.record(for: f.key))
        let expected = DownloadProgressDisplay.fraction(for: record, displayBytes: 600,
            staticExpectedBytes: 1_000, estimatedTotalBytes: nil)
        let row = try #require(f.manager.offlineLibrarySnapshot.rows.first)
        #expect(row.displayFraction == expected)
        #expect(row.phase == .paused)
        let before = filesystem.stats.value
        for _ in 0..<30 {
            #expect(f.manager.rowPhase(for: row) == row.phase)
            #expect(f.manager.displayFraction(for: record) == expected)
            #expect(OfflineLibraryView.rowPresentation(row) == DownloadOptionsSheet.existingPresentation(record, library: f.manager.offlineLibrarySnapshot))
        }
        #expect(filesystem.stats.value == before)
        let mainBefore = filesystem.mainStats.value
        f.manager.refreshRecords()
        #expect(filesystem.mainStats.value == mainBefore)
        await f.finish()
    }

    @Test func blobReplaceAndDeleteInvalidateExactGeneration() async throws {
        let f = try await P7PlaybackFixture(status: .paused)
        #expect(await f.store.resolve(f.store.submitResumeData(for: f.key, Data([1]), displayBytes: 600), deadline: .after(5)) == .applied)
        f.manager.refreshRecords()
        for task in f.manager.resumePresenceWorkers.values { await task.value }
        let first = try #require(f.store.resumePresenceIdentity(for: f.key))
        #expect(f.manager.cachedResumePresence(for: f.key))
        #expect(await f.store.resolve(f.store.submitResumeData(for: f.key, Data([2]), displayBytes: 700), deadline: .after(5)) == .applied)
        #expect(f.store.resumePresenceIdentity(for: f.key) != first)
        #expect(!f.manager.cachedResumePresence(for: f.key))
        f.manager.refreshRecords()
        for task in f.manager.resumePresenceWorkers.values { await task.value }
        #expect(f.manager.cachedResumePresence(for: f.key))
        _ = await f.store.clearResumeDataAsync(for: f.key)
        #expect(!f.manager.cachedResumePresence(for: f.key))
        await f.finish()
    }

    @Test func heldResumeObservationCannotPublishForReplacement() async throws {
        let filesystem = DownloadPerformanceFileManager()
        let f = try await P7PlaybackFixture(status: .paused, fileManager: filesystem)
        #expect(await f.store.resolve(f.store.submitResumeData(for: f.key, Data([1]), displayBytes: 600), deadline: .after(5)) == .applied)
        filesystem.hold.arm()
        f.manager.refreshRecords()
        _ = await filesystem.hold.acknowledgement.wait()
        let workers = Array(f.manager.resumePresenceWorkers.values)
        let replacement = f.files.record("b", status: .paused, filename: "replacement.mp4")
        _ = await f.store.createAttemptOwnedRecordAsync(replacement, attemptID: replacement.attemptID!, replacing: f.key.attemptID)
        f.manager.refreshRecords()
        filesystem.hold.release.signal()
        for worker in workers { await worker.value }
        #expect(!f.manager.cachedResumePresence(for: f.key))
        #expect(f.manager.offlineLibrarySnapshot.rows.first?.attemptID == replacement.attemptID)
        await f.finish()
    }

    @Test(arguments: DownloadLifecycle.allCases)
    func phaseAndFractionPreservePolicy(lifecycle: DownloadLifecycle) async throws {
        let f = try await P7PlaybackFixture(status: .paused)
        var record = f.record
        record.lifecycle = lifecycle
        record.status = lifecycle.derivedStatus
        record.bytes = 250
        record.progress = lifecycle == .finalizing ? 1 : 0.25
        let fraction = f.manager.displayFraction(for: record)
        let expectedPhase = DownloadRowStatusCaptionPolicy.phase(.init(record: record,
            displayFraction: fraction, isActive: record.status == .downloading,
            isBackendConfigured: false, isTranscodeLimited: false,
            serverPrepState: nil, serverPrepProgress: nil, serverPrepETA: nil,
            downloadETA: nil, downloadSpeedBytesPerSecond: nil,
            isRetrying: false, failureCaption: nil))
        let snapshot = f.manager.makeOfflineLibrarySnapshot(from: [record])
        let row = try #require(snapshot.rows.first)
        #expect(row.phase == expectedPhase)
        #expect(row.displayFraction == fraction)
        #expect(row.presentation.phase == expectedPhase)
        await f.finish()
    }
}

final class DownloadPerformanceFileManager: FileManager, @unchecked Sendable {
    let stats = TestLockedBox(0)
    let mainStats = TestLockedBox(0)
    let hold = P6Hold()
    let attributeHold = P6Hold()
    override func fileExists(atPath path: String) -> Bool {
        stats.withValue { $0 += 1 }
        if Thread.isMainThread { mainStats.withValue { $0 += 1 } }
        if path.contains(".resume-") { hold.hit() }
        return super.fileExists(atPath: path)
    }
    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        stats.withValue { $0 += 1 }
        if Thread.isMainThread { mainStats.withValue { $0 += 1 } }
        attributeHold.hit()
        return try super.attributesOfItem(atPath: path)
    }
}
#endif
