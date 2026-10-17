#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("P6 lead store I/O pins", .serialized)
struct P6StoreIOTests {
    @Test("P6-pin-03 Retry clone does not hold the row lock", arguments: [false, true])
    func retryCloneLookup(failedCommit: Bool) async throws {
        let fixture = try P6Fixture()
        let initial = fixture.store()
        let owner = try fixture.seed(initial, status: .failed)
        let original = try fixture.working(initial, owner)
        let hold = P6Hold()
        let store = fixture.store(filesystem: .init(before: { operation, _ in
            if operation == .copy { hold.hit() }
        }), index: .init { data, url in
            if failedCommit { throw CocoaError(.fileWriteUnknown) }
            try DownloadIndexFileCommitter().commit(data, to: url)
        })
        let replacement = fixture.record("b", status: .failed)
        let finished = DispatchSemaphore(value: 0)
        defer { hold.release.signal() }
        hold.arm()
        Thread.detachNewThread {
            _ = store.createAttemptOwnedRecord(replacement, attemptID: replacement.attemptID!,
                                               replacing: owner.attemptID)
            finished.signal()
        }
        try #require(await p6Signal(hold.entered))
        try await p6ExpectReadableWhileHeld(store, key: owner, hold: hold)
        try #require(await p6Signal(finished))
        #expect(store.record(for: "plex:fixture")?.attemptID == replacement.attemptID)
        #expect(FileManager.default.fileExists(atPath: original.path) == failedCommit)
        if failedCommit { #expect(try Data(contentsOf: original) == Data([1, 2, 3])) }
    }

    @Test("P6-pin-03 Delete/replacement can fence an obsolete clone before it publishes", arguments: [false, true])
    func obsoleteClone(delete: Bool) async throws {
        let fixture = try P6Fixture()
        let initial = fixture.store()
        let owner = try fixture.seed(initial, status: .failed)
        _ = try fixture.working(initial, owner)
        let hold = P6Hold()
        let store = fixture.store(filesystem: .init(before: { operation, _ in
            if operation == .copy { hold.hit() }
        }))
        let clone = fixture.record("b", status: .failed)
        let replacement = fixture.record("c", status: .failed, mode: .liveForwardOnly, filename: "replacement.mp4")
        let cloneDone = DispatchSemaphore(value: 0)
        let competitorDone = DispatchSemaphore(value: 0)
        let server = try #require(DurableDownloadCleanupIntent.ServerIdentity(
            baseURL: URL(string: "https://media.example.invalid")!, serverID: "fixture", userID: "fixture"))
        let cleanup = try #require(DurableDownloadCleanupIntent(
            id: UUID(), attemptKey: owner, backend: .emby, server: server,
            operation: .activeEncoding(playSessionID: "fixture")))
        defer { hold.release.signal() }
        hold.arm()
        Thread.detachNewThread {
            _ = store.createAttemptOwnedRecord(clone, attemptID: clone.attemptID!, replacing: owner.attemptID)
            cloneDone.signal()
        }
        try #require(await p6Signal(hold.entered))
        Thread.detachNewThread {
            if delete {
                _ = store.submitDeletionPending(for: owner, cleanupIntents: [cleanup])
            } else {
                _ = store.createAttemptOwnedRecord(replacement, attemptID: replacement.attemptID!, replacing: owner.attemptID)
            }
            competitorDone.signal()
        }
        let fencedBeforeCopyRelease = await p6Signal(competitorDone)
        #expect(fencedBeforeCopyRelease)

        hold.release.signal()
        try #require(await p6Signal(cloneDone))
        if !fencedBeforeCopyRelease { try #require(await p6Signal(competitorDone)) }
        let row = try #require(store.record(for: owner.ratingKey))
        if delete { #expect(row.attemptID == owner.attemptID && store.isDeletionPending(for: owner)) }
        else { #expect(row.attemptID == replacement.attemptID) }

    }

    enum IOCase: String, CaseIterable, Sendable { case blobRead, lifecycleStat, sidePublication, condemnRename, condemnFallback, stagingEnumeration, stagingRemoval }

    @Test("P6-pin-04 real filesystem operations do not hold the row lock", arguments: IOCase.allCases)
    func filesystemLookup(_ scenario: IOCase) async throws {
        let fixture = try P6Fixture()
        let initial = fixture.store()
        let owner = try fixture.seed(initial)
        let working = try fixture.working(initial, owner)
        #expect(await initial.resolve(initial.submitResumeData(for: owner, Data([8])), deadline: .after(30)) == .applied)
        let hold = P6Hold()
        let operation: DownloadStoreFilesystem.Operation = switch scenario {
        case .blobRead: .read
        case .lifecycleStat: .stat
        case .sidePublication, .condemnRename: .rename
        case .condemnFallback, .stagingRemoval: .remove
        case .stagingEnumeration: .enumerate
        }
        var filesystem = DownloadStoreFilesystem(before: { op, _ in if op == operation { hold.hit() } })
        if scenario == .condemnFallback { filesystem.rename = { _, _ in -1 } }
        let orphan = fixture.directory.appendingPathComponent(".attempt-stage-v1-" + String(repeating: "a", count: 64) + ".stage")
        try Data([6]).write(to: orphan)
        let store = fixture.store(filesystem: filesystem)
        let side = fixture.directory.appendingPathComponent("fixture.poster.jpg")
        let staged = try #require(store.attemptStagingURL(for: owner, stableURL: side))
        try Data([9]).write(to: staged)
        // Startup staging cleanup is reachable through a fresh Store; this seam observes its
        // actual enumeration/removal rather than using an invented scan loop.
        let finished = DispatchSemaphore(value: 0)
        defer { hold.release.signal() }
        hold.arm()
        Thread.detachNewThread {
            switch scenario {
            case .blobRead: _ = store.resumeData(for: owner)
            case .lifecycleStat: _ = store.lifecycleFacts(for: owner)
            case .sidePublication: _ = store.promoteAttemptStagingFile(for: owner, stagingURL: staged, to: side)
            case .condemnRename, .condemnFallback: _ = store.condemnWorkingBody(at: working, for: owner)
            case .stagingEnumeration, .stagingRemoval: _ = store.sweepUnreferencedAttemptStaging()
            }
            finished.signal()
        }
        try #require(await p6Signal(hold.entered))
        try await p6ExpectReadableWhileHeld(store, key: owner, hold: hold)
        try #require(await p6Signal(finished))
        #expect(store.record(for: owner) != nil)
    }
    @Test("st-02: unsafe persisted read paths never touch an outside-root sentinel")
    func unsafePersistedReadPaths() throws {
        let fixture = try P6Fixture()
        let initial = fixture.store()
        let key = try fixture.seed(initial, status: .complete)
        let sentinel = fixture.directory.deletingLastPathComponent().appendingPathComponent("p6-sentinel-\(UUID()).resume")
        try Data([7, 8, 9]).write(to: sentinel)
        defer { try? FileManager.default.removeItem(at: sentinel) }
        let unsafe = "../" + sentinel.lastPathComponent
        #expect(initial.updateMetadata(for: key) { $0.resumeDataRelativePath = unsafe } == .staleOrMissing)
        let index = fixture.directory.appendingPathComponent("index.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        var rows = try #require(object["rows"] as? [[String: Any]])
        rows[0]["relativePath"] = unsafe
        var metadata = try #require(rows[0]["metadata"] as? [String: Any])
        metadata["resumeDataRelativePath"] = unsafe
        rows[0]["metadata"] = metadata
        object["rows"] = rows
        try JSONSerialization.data(withJSONObject: object).write(to: index)
        let store = fixture.store(filesystem: .init(before: { _, url in
            #expect(url.standardizedFileURL != sentinel.standardizedFileURL)
        }))
        #expect(store.localURL(for: key.ratingKey) == nil)
        #expect(store.resumeData(for: key) == nil)
        #expect(store.resumeData(ratingKey: key.ratingKey) == nil)
        #expect(!store.hasResumeData(for: key))
        #expect(!store.hasResumeData(ratingKey: key.ratingKey))
        #expect(try Data(contentsOf: sentinel) == Data([7, 8, 9]))
    }

    @Test("st-23: startup sweep preserves new files, replaced identities and live writers")
    func startupInventoryAndWriterProtection() throws {
        let fixture = try P6Fixture()
        let initial = fixture.store()
        let key = try fixture.seed(initial)
        func path(_ digit: String) -> URL {
            fixture.directory.appendingPathComponent(".attempt-stage-v1-" + String(repeating: digit, count: 64) + ".stage")
        }
        let replaced = path("c")
        let claimed = path("d")
        try Data([1]).write(to: replaced)
        try Data([2]).write(to: claimed)
        let store = fixture.store()
        let new = path("e")
        try Data([3]).write(to: new)
        try Data([4]).write(to: replaced, options: .atomic)
        guard case .acquired(let lease) = store.tryAcquirePathLease(for: key,
            relativePaths: [claimed.lastPathComponent], purpose: .sideCacheWrite) else {
            Issue.record("writer lease rejected"); return
        }
        defer { store.releasePathLease(lease) }
        #expect(store.sweepUnreferencedAttemptStaging().removedRelativePaths.isEmpty)
        #expect(try Data(contentsOf: replaced) == Data([4]))
        #expect(try Data(contentsOf: claimed) == Data([2]))
        #expect(try Data(contentsOf: new) == Data([3]))
        store.releasePathLease(lease)
        #expect(store.sweepUnreferencedAttemptStaging().removedRelativePaths == [claimed.lastPathComponent])
    }

    @Test("a stale same-attempt side-cache tail cannot remove a new source's staging")
    func staleSideCacheCleanupPreservesSuccessorStaging() throws {
        let fixture = try P6Fixture()
        let store = fixture.store()
        let key = try fixture.seed(store, status: .paused)
        let oldSource = try #require(store.sideAssetSourceIdentity(for: key))
        let destination = store.posterDestinationURL(ratingKey: key.ratingKey)
        let staging = try #require(store.attemptStagingURL(for: key, stableURL: destination))
        try Data([1]).write(to: staging)
        #expect(store.updateMetadata(for: key) { $0.sourcePartID = 2 } == .applied)
        try Data([2]).write(to: staging, options: .atomic)
        #expect(store.promoteSideAssetStagingFile(for: key, expectedSource: oldSource,
            stagingURL: staging, to: destination) == .staleOrMissingOwner)
        store.discardSideAssetStaging(at: staging, for: key)
        #expect(try Data(contentsOf: staging) == Data([2]))
    }

    @Test("delayed side-cache retirement protects a new rename awaiting metadata publication")
    func retirementPreservesUnpublishedCurrentSource() async throws {
        let fixture = try P6Fixture()
        let initial = fixture.store()
        let key = try fixture.seed(initial, status: .paused)
        let destination = initial.posterDestinationURL(ratingKey: key.ratingKey)
        try Data([1]).write(to: destination)
        #expect(initial.updateMetadata(for: key) { $0.recordCachedPoster(relativePath: destination.lastPathComponent) } == .applied)
        let hold = P6Hold()
        let store = fixture.store(index: .init { data, url in
            hold.hit()
            try DownloadIndexFileCommitter().commit(data, to: url)
        })
        defer { hold.release.signal() }
        hold.arm()
        let change = Task { await store.updateMetadataAsync(for: key) { $0.sourcePartID = 2 } }
        try #require(await p6Signal(hold.entered))
        let source = try #require(store.sideAssetSourceIdentity(for: key))
        let staging = try #require(store.attemptStagingURL(for: key, stableURL: destination))
        try Data([2]).write(to: staging)
        #expect(store.promoteSideAssetStagingFile(for: key, expectedSource: source,
            stagingURL: staging, to: destination) == .promoted)
        hold.release.signal()
        #expect(await change.value == .applied)
        #expect(try Data(contentsOf: destination) == Data([2]))
        #expect(store.storageAudit().referencedRelativePaths.contains(destination.lastPathComponent))
        #expect(await store.updateMetadataAsync(for: key, expectedSideAssetSource: source) {
            $0.recordCachedPoster(relativePath: destination.lastPathComponent)
        } == .applied)
        #expect(try Data(contentsOf: destination) == Data([2]))
    }

}
#endif
