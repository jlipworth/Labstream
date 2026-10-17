#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("P6 lead reconcile pins", .serialized)
struct P6ReconcileCleanupTests {
    @Test("P6-pin-05 interrupted forward-only cleanup retires durable resume authority")
    func clearResumeAuthority() throws {
        let fixture = try P6Fixture()
        let store = fixture.store()
        let key = try fixture.seed(store, mode: .liveForwardOnly)
        // A legacy/non-resumable row may still have a blob left by an earlier transport.
        let blob = fixture.directory.appendingPathComponent("fixture.resume")
        try Data([7, 8]).write(to: blob)
        #expect(store.updateMetadata(for: key) { $0.resumeDataRelativePath = blob.lastPathComponent } == .applied)
        store.reconcile(liveRatingKeys: [], snapshotRatingKeys: [key.ratingKey])
        #expect(!FileManager.default.fileExists(atPath: blob.path))
        let reloaded = fixture.store()
        #expect(reloaded.record(for: key)?.metadata?.resumeDataRelativePath == nil)

    }

    @Test("P6-pin-05 cleanup failure conserves authority and cleanup does not lock unrelated lookups")
    func heldCleanupAndFailure() async throws {
        let fixture = try P6Fixture()
        let initial = fixture.store()
        let key = try fixture.seed(initial, mode: .liveForwardOnly)
        let blob = fixture.directory.appendingPathComponent("fixture.resume")
        try Data([7]).write(to: blob)
        #expect(initial.updateMetadata(for: key) { $0.resumeDataRelativePath = blob.lastPathComponent } == .applied)
        let hold = P6Hold()
        let store = fixture.store(filesystem: .init(
            before: { operation, _ in if operation == .remove { hold.hit() } },
            remove: { _, _ in throw CocoaError(.fileWriteUnknown) }))
        let done = DispatchSemaphore(value: 0)
        defer { hold.release.signal() }
        hold.arm()
        Thread.detachNewThread { store.reconcile(liveRatingKeys: [], snapshotRatingKeys: [key.ratingKey]); done.signal() }
        try #require(await p6Signal(hold.entered))
        try await p6ExpectReadableWhileHeld(store, key: key, hold: hold)
        try #require(await p6Signal(done))
        #expect(store.record(for: key)?.metadata?.resumeDataRelativePath == blob.lastPathComponent)
        #expect(try Data(contentsOf: blob) == Data([7]))
    }

    @Test("P6-pin-05 a second row's reference prevents resume cleanup")
    func crossRowReference() throws {
        let fixture = try P6Fixture()
        let store = fixture.store()
        let key = try fixture.seed(store, mode: .liveForwardOnly)
        let blob = fixture.directory.appendingPathComponent("shared.resume")
        try Data([3]).write(to: blob)
        #expect(store.updateMetadata(for: key) { $0.resumeDataRelativePath = blob.lastPathComponent } == .applied)
        var second = fixture.record("other", status: .paused, ratingKey: "plex:other")
        second.metadata?.resumeDataRelativePath = blob.lastPathComponent
        #expect(store.createAttemptOwnedRecord(second, attemptID: second.attemptID!)
                == .committed(.init(ratingKey: second.ratingKey, attemptID: second.attemptID!)))
        store.reconcile(liveRatingKeys: [], snapshotRatingKeys: [key.ratingKey])
        #expect(FileManager.default.fileExists(atPath: blob.path))

    }
}
#endif
