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
        withKnownIssue("P6 red pin: P6.3 — clone lock prevents a competing exact-owner fence") {
            #expect(fencedBeforeCopyRelease)
        }
        hold.release.signal()
        try #require(await p6Signal(cloneDone))
        if !fencedBeforeCopyRelease { try #require(await p6Signal(competitorDone)) }
        let row = try #require(store.record(for: owner.ratingKey))
        withKnownIssue("P6 red pin: P6.3 — obsolete clone installs before the competing fence can linearize") {
            if delete { #expect(row.attemptID == owner.attemptID && store.isDeletionPending(for: owner)) }
            else { #expect(row.attemptID == replacement.attemptID) }
        }
    }

    enum IOCase: String, CaseIterable, Sendable { case blobRead, lifecycleStat, sidePublication, condemnRename, condemnFallback, stagingEnumeration, stagingRemoval }

    @Test("P6-pin-04 real filesystem operations do not hold the row lock", arguments: IOCase.allCases)
    func filesystemLookup(_ scenario: IOCase) async throws {
        let fixture = try P6Fixture()
        let initial = fixture.store()
        let owner = try fixture.seed(initial)
        let working = try fixture.working(initial, owner)
        #expect(initial.setResumeData(for: owner, Data([8])) == .applied)
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
}
#endif
