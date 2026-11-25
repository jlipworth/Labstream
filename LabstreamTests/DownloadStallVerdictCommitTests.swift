#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

/// Review of PR #505 (#501 follow-up). A queued forward-only stall verdict used to be checked
/// against a manager read of the row and then cancel the session work and overwrite the row's error
/// before the reducer saw `stallDetected`. `.finalizing` also shows as `.downloading`, so a body
/// that finished while the verdict waited passed the read; and the delegate could advance the bytes
/// between the read and the cancel. `DownloadStore.submitStallVerdict` now checks the exact attempt,
/// the `.transferring` lifecycle and the observed bytes in the same lock hold as the commit, and the
/// manager cancels only after it accepted. These tests drive the store through both interleavings.
@Suite("Download stall verdict commit", .downloadTestFiles, .serialized)
struct DownloadStallVerdictCommitTests {
    @Test("A body that finished while the verdict was queued rejects it and stays finalizing")
    func finalizingBodyRejectsTheVerdict() throws {
        try withDirectory { directory in
            let store = DownloadTestFiles.store(baseDirectory: directory)
            let key = try seedTransferring("jellyfin:finishing", bytes: 1_000, in: store)
            // The watchdog's observation that queued the verdict.
            let observed = try #require(store.record(for: key))
            // Before the queued operation runs, the body finishes with no further bytes.
            guard case .accepted = store.submitLifecycleEvent(
                .bodyCaptured, for: key, facts: DownloadRowFacts(route: .forwardOnly)) else {
                Issue.record("Expected the finished body to enter finalizing"); return
            }
            let current = try #require(store.record(for: key))
            // The trap: a finalizing row is still a `.downloading` forward-only stream with the
            // same bytes, which is all the old manager-side check looked at.
            #expect(current.status == .downloading)
            #expect(current.bytes == observed.bytes)
            #expect(DownloadStallRecoveryPolicy.isForwardOnlyMediaBrowserStream(current))
            #expect(!DownloadStallRecoveryPolicy.queuedStallVerdictStillWarranted(
                observed: observed, current: current))

            #expect(store.submitStallVerdict(for: key, observedBytes: observed.bytes) == .rejected(.illegal))
            #expect(store.lifecycleState(for: key)?.lifecycle == .finalizing)
            #expect(store.lifecycleState(for: key)?.history.lastFailure == nil)
        }
    }

    @Test("Bytes the delegate advanced after the manager's read reject the verdict")
    func bytesAdvancedAfterTheReadRejectTheVerdict() throws {
        try withDirectory { directory in
            let store = DownloadTestFiles.store(baseDirectory: directory)
            let key = try seedTransferring("jellyfin:moving", bytes: 1_000, in: store)
            let observed = try #require(store.record(for: key))
            // The manager's early read: still stalled, so it goes on towards the commit.
            let read = try #require(store.record(for: key))
            #expect(DownloadStallRecoveryPolicy.queuedStallVerdictStillWarranted(observed: observed, current: read))
            // A delegate callback lands between that read and the commit.
            _ = store.submitProgress(for: key, bytes: 1_001, progress: 0)

            #expect(store.submitStallVerdict(for: key, observedBytes: observed.bytes) == .rejected(.illegal))
            #expect(store.lifecycleState(for: key)?.lifecycle == .transferring)
            #expect(store.record(for: key)?.bytes == 1_001)
        }
    }

    @Test("A still-stalled transferring attempt fails as stalled; a later callback does not revive it")
    func stalledAttemptCommitsAndStaysFailed() throws {
        try withDirectory { directory in
            let store = DownloadTestFiles.store(baseDirectory: directory)
            let key = try seedTransferring("jellyfin:stalled", bytes: 1_000, in: store)
            let observed = try #require(store.record(for: key))
            guard case .accepted = store.submitStallVerdict(for: key, observedBytes: observed.bytes) else {
                Issue.record("Expected the stall verdict to commit"); return
            }
            #expect(store.lifecycleState(for: key)?.lifecycle == .failed)
            #expect(store.lifecycleState(for: key)?.history.lastFailure == .stalled)
            // The delegate advances the bytes after the commit, before the manager's cancel lands.
            _ = store.submitProgress(for: key, bytes: 1_100, progress: 0)
            #expect(store.lifecycleState(for: key)?.lifecycle == .failed)
            // Replaying the verdict is not a second commit.
            #expect(store.submitStallVerdict(for: key, observedBytes: 1_100) == .rejected(.illegal))
        }
    }

    @Test("A verdict for another attempt of the same key is stale")
    func anotherAttemptIsStale() throws {
        try withDirectory { directory in
            let store = DownloadTestFiles.store(baseDirectory: directory)
            let key = try seedTransferring("jellyfin:replaced", bytes: 1_000, in: store)
            let other = DownloadAttemptKey(ratingKey: key.ratingKey, attemptID: DownloadAttemptID(uuid: UUID()))
            #expect(store.submitStallVerdict(for: other, observedBytes: 1_000) == .staleOrMissing)
            #expect(store.lifecycleState(for: key)?.lifecycle == .transferring)
        }
    }

    // MARK: - Fixtures

    private func seedTransferring(_ ratingKey: String, bytes: Int,
                                  in store: DownloadStore) throws -> DownloadAttemptKey {
        let id = DownloadAttemptID(uuid: UUID())
        let key = DownloadAttemptKey(ratingKey: ratingKey, attemptID: id)
        let url = store.destinationURL(ratingKey: ratingKey, ext: "mp4")
        let record = DownloadRecord(
            ratingKey: ratingKey, attemptID: id, title: "Item", localURL: url,
            bytes: 0, progress: 0, status: .queued,
            metadata: OfflineMetadata(ratingKey: ratingKey, title: "Item", type: "movie",
                                      backendKind: .jellyfin, downloadLane: .optimize,
                                      resumeMode: .liveForwardOnly))
        #expect(store.createAttemptOwnedRecord(record, attemptID: id) == .committed(key))
        // The first progress sample moves the admitted row to transferring.
        _ = store.submitProgress(for: key, bytes: bytes, progress: 0)
        #expect(store.lifecycleState(for: key)?.lifecycle == .transferring)
        return key
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let parent = DownloadTestFiles.temporaryDirectory
            .appendingPathComponent("stall-verdict-\(UUID().uuidString)", isDirectory: true)
        let directory = parent.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try body(directory)
    }
}
#endif
