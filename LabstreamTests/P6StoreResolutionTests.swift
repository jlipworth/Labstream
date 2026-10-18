#if !os(tvOS)
import Foundation
import PMSKit
import Synchronization
import Testing
@testable import Labstream

@Suite("P6 lead exact resolution pins", .serialized)
struct P6StoreResolutionTests {
    enum Kind: String, CaseIterable, Sendable { case mutation, resume, artifact, promotion, checkpoint, deletion, seed, compareClear }

    @Test("P6-pin-02 supplied deadlines bound exact waiters without cancelling commits", arguments: Kind.allCases)
    func deadline(_ kind: Kind) async throws {
        let fixture = try P6Fixture()
        let initial = fixture.store()
        let key = try fixture.seed(initial)
        _ = try fixture.working(initial, key)
        let hold = P6Hold()
        let store = fixture.store(index: .init { data, url in
            hold.hit()
            try DownloadIndexFileCommitter().commit(data, to: url)
        })
        defer { hold.release.signal() }
        let completed = DispatchSemaphore(value: 0)
        let timedOut = Mutex(false)
        let deadline = DownloadStoreDeadline.after(0.05)
        hold.arm()
        let resolve: @Sendable () async -> Bool
        switch kind {
        case .mutation:
            let submission = store.submitProgress(for: key, bytes: 2, progress: 0.2)
            resolve = { if case .persistenceFailed(.timedOut) = await store.resolve(submission, deadline: deadline) { return true }; return false }
        case .resume:
            let submission = store.submitResumeData(for: key, Data([4]), displayBytes: 4)
            resolve = { if case .persistenceFailed(.timedOut) = await store.resolve(submission, deadline: deadline) { return true }; return false }
        case .artifact:
            let submission = store.submitResumeData(for: key, Data([4]), displayBytes: 4)
            guard case .accepted(let ticket) = submission else { Issue.record("resume rejected"); return }
            resolve = { if case .timedOut = await store.resolveArtifact(ticket, deadline: deadline) { return true }; return false }
        case .promotion:
            let submission = store.submitValidatedPromotion(for: key, terminalStatus: .complete)
            resolve = { if case .persistenceFailed(_, .timedOut) = await store.resolveValidatedPromotion(submission, deadline: deadline) { return true }; return false }
        case .checkpoint:
            let submission = store.submitStaticRangeCheckpointReset(for: key)
            resolve = { if case .persistenceFailed(_, .timedOut) = await store.resolveStaticCheckpoint(submission, deadline: deadline) { return true }; return false }
        case .deletion:
            let submission = store.submitRemove(for: key)
            resolve = { if case .persistenceFailed(_, .timedOut) = await store.resolveRowDeletion(submission, deadline: deadline) { return true }; return false }
        case .seed:
            let record = fixture.record("b")
            let submission = store.submitAttemptOwnedRecord(record, attemptID: record.attemptID!, replacing: key.attemptID)
            resolve = { if case .failed(_, .timedOut) = await store.resolve(submission, deadline: deadline) { return true }; return false }
        case .compareClear:
            let submission = store.submitClearPlaySessionID(for: key, expectedPlaySessionID: "expected")
            resolve = { if case .persistenceFailed(.timedOut) = await store.resolve(submission, deadline: deadline) { return true }; return false }
        }
        let task = Task {
            let value = await resolve()
            timedOut.withLock { $0 = value }
            completed.signal()
        }
        try #require(await p6Signal(hold.entered))
        let returnedBeforeRelease = await p6Signal(completed, seconds: 0.3)
        #expect(returnedBeforeRelease && timedOut.withLock { $0 })

        hold.release.signal()
        await task.value
        // Late physical work still reaches its original boundary; timeout is not cancellation.
        let proof = await store.flushLifecycleAndPersistence(
            through: store.currentPersistenceTicket(), artifactWatermark: store.currentArtifactLifecycleWatermark(), timeout: 5)
        guard case .committed = proof else { Issue.record("late original work failed to commit"); return }
        if kind == .checkpoint { #expect(store.staticCheckpointOutcomeCountForTests() == 0) }
    }

    @Test("P6-pin-02 amendment: retry B cannot overwrite delayed promotion A's typed failure")
    func promotionEpoch() async throws {
        let fixture = try P6Fixture()
        let initial = fixture.store()
        let key = try fixture.seed(initial)
        _ = try fixture.working(initial, key)
        let fail = Mutex(true)
        let live = DownloadPromotionFilesystem.live
        let store = fixture.store(promotion: .init(
            exists: live.exists, size: live.size, fullSyncSource: live.fullSyncSource,
            renameReplacing: { source, destination in
                if fail.withLock({ $0 }) { throw CocoaError(.fileWriteUnknown) }
                try live.renameReplacing(source, destination)
            }, syncParentDirectory: live.syncParentDirectory))
        let a = store.submitValidatedPromotion(for: key, terminalStatus: .complete)
        guard case .accepted(let ticketA) = a else { Issue.record("A rejected"); return }
        guard case .failed(.artifact) = await store.resolveArtifact(ticketA, deadline: .after(30)) else { Issue.record("A did not fail"); return }
        fail.withLock { $0 = false }
        let b = store.submitValidatedPromotion(for: key, terminalStatus: .complete)
        guard case .accepted(let ticketB) = b else { Issue.record("B rejected"); return }
        #expect(ticketA.sequence != ticketB.sequence)
        #expect(ticketA.intentID == ticketB.intentID)
        #expect(await store.resolveArtifact(ticketB, deadline: .after(30)) == .completed)
        let resultA = await store.resolveValidatedPromotion(a, deadline: .after(30))
        if case .renameFailed = resultA {} else { Issue.record("A inherited B's outcome: \(resultA)") }
        #expect(await store.resolveValidatedPromotion(b, deadline: .after(30)) == .promoted(key, bytes: 3, status: .complete))

    }

    @Test("P6-pin-02 amendment: checkpoint retry B cannot overwrite delayed A")
    func checkpointEpoch() async throws {
        let fixture = try P6Fixture()
        let initial = fixture.store()
        let key = try fixture.seed(initial)
        _ = try fixture.working(initial, key)
        let fail = Mutex(true)
        let store = fixture.store(index: .init { data, url in
            if fail.withLock({ $0 }) { throw CocoaError(.fileWriteUnknown) }
            try DownloadIndexFileCommitter().commit(data, to: url)
        })
        let a = store.submitStaticRangeCheckpointReset(for: key)
        guard case .accepted(let ticketA) = a else { Issue.record("A rejected"); return }
        guard case .failed(.persistence) = await store.resolveArtifact(ticketA, deadline: .after(30)) else { Issue.record("A did not fail"); return }
        fail.withLock { $0 = false }
        let ticketB = try #require(store.recoverArtifactTicketsForP6Testing().first { $0.intentID == ticketA.intentID })
        let b = DownloadStore.AttemptStaticCheckpointSubmission.accepted(ticket: ticketB)
        #expect(ticketA.intentID == ticketB.intentID)
        #expect(ticketA.sequence != ticketB.sequence)
        #expect(await store.resolveArtifact(ticketB, deadline: .after(30)) == .completed)
        let resultA = await store.resolveStaticCheckpoint(a, deadline: .after(30))
        if case .persistenceFailed = resultA {} else { Issue.record("A inherited B's outcome: \(resultA)") }
        #expect(await store.resolveStaticCheckpoint(b, deadline: .after(30)) == .unchanged(bytes: 3))

    }
}
#endif
