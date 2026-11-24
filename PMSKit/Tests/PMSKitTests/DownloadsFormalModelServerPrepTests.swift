import Foundation
import Testing
@testable import PMSKit

/// The pure decisions behind the TLA+ model of server preparation
/// (`specs/downloads/DownloadsServerPrep.tla`, notes in `specs/downloads/DownloadsServerPrep.md`).
///
/// The first tests hold today: each one ties a branch of the model to the policy that decides it,
/// so a policy change that the model does not follow fails here as well as in the drift guard.
///
/// The last test is finding S1. It states the behaviour the design wants and is wrapped in
/// `withKnownIssue`, so the suite stays green while the finding is open. When a fix lands the
/// expectation holds, no issue is recorded, and `withKnownIssue` fails the test: delete the
/// wrapper then, and flip the `ServerPrep-Finding-S1-*.cfg` configs to `EXPECT: pass`.
@Suite("Downloads formal model: server preparation")
struct DownloadsFormalModelServerPrepTests {
    private typealias R = DownloadLifecycleReducer
    private typealias Recovery = EmbyConvertRecoveryPolicy

    private static let queueTitle = "Fixture [Labstream 00000000]"

    private func attempt(_ id: String) -> DownloadAttemptKey {
        DownloadAttemptKey(ratingKey: "101", attemptID: DownloadAttemptID(rawValue: id)!)
    }

    private func plexPrepRecord(status: DownloadStatus,
                                resumeMode: DownloadResumeMode = .serverPrepThenStatic) -> DownloadRecord {
        let metadata = OfflineMetadata(ratingKey: "101", title: "Fixture", type: "movie",
                                       optimizeTargetName: "Medium",
                                       optimizeQueueTitle: Self.queueTitle,
                                       backendKind: .plex,
                                       downloadLane: .optimize,
                                       resumeMode: resumeMode)
        return DownloadRecord(ratingKey: "101", title: "Fixture",
                              localURL: URL(fileURLWithPath: "/tmp/labstream-server-prep-model.mp4"),
                              bytes: 0, progress: 0, status: status, metadata: metadata)
    }

    // MARK: - Model conformance

    /// `PlexPoll`: create only on proven absence with no dispatch on record (B35 puts adoption
    /// first); a dispatched create is never sent again and fails after the grace (B37).
    @Test("Plex: one create per identity, and a missing create fails after the grace")
    func plexCreateDecision() {
        typealias P = PlexOptimizePrepPolicy
        #expect(P.action(queue: .inspectedAbsent, metadataInspected: true,
                         dispatchedAt: nil, now: 1_000) == .create)
        // `disp` set: never `.create` again, whatever the queue says.
        for queue in [P.QueueLookup.present, .inspectedAbsent, .unavailable] {
            for now in [100.0, 100 + P.createVisibilityGraceSeconds, 1_000_000] {
                #expect(P.action(queue: queue, metadataInspected: true,
                                 dispatchedAt: 100, now: now) != .create)
            }
        }
        // `grace` elapsed and the item is proven absent: `failMissingCreate`.
        #expect(P.action(queue: .inspectedAbsent, metadataInspected: true, dispatchedAt: 100,
                         now: 100 + P.createVisibilityGraceSeconds) == .failMissingCreate)
        #expect(P.action(queue: .inspectedAbsent, metadataInspected: true, dispatchedAt: 100,
                         now: 100 + P.createVisibilityGraceSeconds - 1) == .keepInspecting)
    }

    /// `Current(r, p)`: a chain acts only while it is the attached poller. Pause and Delete run
    /// `releaseAll`; the poller a quick Resume attaches has a different ID.
    @Test("A released poller is no longer current, and its successor is a different poller")
    func pollerCurrency() {
        var tracker = ServerPrepAttemptTracker()
        let key = attempt("a1")
        let first = UUID(), second = UUID()

        let attached = tracker.beginPlexPoller(for: key, id: first)
        let refused = tracker.beginPlexPoller(for: key, id: second)
        #expect(attached == first)
        #expect(refused == nil, "Attach needs poller = NoPoller")
        tracker.releaseAll(for: key)
        #expect(!tracker.isCurrentPlexPoller(for: key, id: first))
        let successor = tracker.beginPlexPoller(for: key, id: second)
        #expect(successor == second)
        #expect(!tracker.isCurrentPlexPoller(for: key, id: first))
        let staleDetach = tracker.endPlexPoller(for: key, id: first)
        #expect(!staleDetach, "a stale chain's detach is a no-op")
        #expect(tracker.isCurrentPlexPoller(for: key, id: second))

        let embyAttached = tracker.beginEmbyConvertPoller(for: key, id: first)
        let embyRefused = tracker.beginEmbyConvertPoller(for: key, id: second)
        #expect(embyAttached == first)
        #expect(embyRefused == nil)
        // The hand-off's compare-and-remove: only the attached poller hands off, once.
        let strangerHandsOff = tracker.endEmbyConvertPoller(for: key, id: second)
        let ownerHandsOff = tracker.endEmbyConvertPoller(for: key, id: first)
        let ownerHandsOffAgain = tracker.endEmbyConvertPoller(for: key, id: first)
        #expect(!strangerHandsOff)
        #expect(ownerHandsOff)
        #expect(!ownerHandsOffAgain)
    }

    /// `Attach` for an Emby row after a relaunch, and `Respond` for a create that lands on a row
    /// the chain no longer owns (B47).
    @Test("Emby: relaunch polls, recovers, expires or fails by the identity the row kept")
    func embyRecoveryDecisions() {
        let fingerprint = Recovery.Fingerprint(itemId: "item", quality: "q", profile: "p", bitrate: nil)
        let start = 1_000.0
        // ident
        #expect(Recovery.relaunchAction(jobID: 7, baselineJobIDs: nil, fingerprint: nil) == .poll(jobID: 7))
        // disp, not ident, not expired
        #expect(Recovery.relaunchAction(
            jobID: nil, baselineJobIDs: [1], fingerprint: fingerprint,
            attemptStartedAtEpochSeconds: start, phase: .dispatchAmbiguous, nowEpochSeconds: start + 60)
            == .recover(baselineJobIDs: [1], fingerprint: fingerprint,
                        attemptStartedAtEpochSeconds: start, phase: .dispatchAmbiguous))
        // disp, expired
        #expect(Recovery.relaunchAction(
            jobID: nil, baselineJobIDs: [1], fingerprint: fingerprint,
            attemptStartedAtEpochSeconds: start, phase: .dispatchAmbiguous,
            nowEpochSeconds: start + Recovery.recoveryExpirySeconds + 1) == .expireRecovery)
        // neither: the process died before the create was dispatched
        #expect(Recovery.relaunchAction(
            jobID: nil, baselineJobIDs: [1], fingerprint: fingerprint,
            attemptStartedAtEpochSeconds: start, phase: .prepared, nowEpochSeconds: start + 60)
            == .failMissingIdentity)

        // Respond, current chain: only a definitive refusal clears `disp`.
        #expect(Recovery.createFailureDisposition(postWasDispatched: true, httpStatusCode: 400) == .clearRecovery)
        #expect(Recovery.createFailureDisposition(postWasDispatched: true, httpStatusCode: nil)
            == .preserveForRecovery)
        #expect(Recovery.createFailureDisposition(postWasDispatched: true, httpStatusCode: 503)
            == .preserveForRecovery)

        // Respond, stale chain.
        for parked in [DownloadStatus.paused, .failed] {
            #expect(Recovery.staleCreateDisposition(rowOwnedByAttempt: true, rowStatus: parked,
                                                    persistedJobID: nil, createdJobID: 7) == .adoptOntoParkedRow)
        }
        #expect(Recovery.staleCreateDisposition(rowOwnedByAttempt: true, rowStatus: .preparing,
                                                persistedJobID: nil, createdJobID: 7) == .leaveToCurrentOwner)
        #expect(Recovery.staleCreateDisposition(rowOwnedByAttempt: false, rowStatus: nil,
                                                persistedJobID: nil, createdJobID: 7) == .cancel)
    }

    /// `UserDelete` and `Claims`: every Plex prep row owes the cancel of its queue item, parked
    /// rows included (B28, D2); a handed-off row owes nothing.
    @Test("Delete owes the Plex optimize cancel for every prep status, and nothing after the hand-off")
    func deleteOwesPrepCancel() {
        for status in [DownloadStatus.queued, .preparing, .paused, .failed] {
            #expect(DownloadDeletePolicy.plexOptimizeCleanupQueueTitle(
                for: plexPrepRecord(status: status)) == Self.queueTitle)
        }
        #expect(DownloadDeletePolicy.plexOptimizeCleanupQueueTitle(
            for: plexPrepRecord(status: .queued, resumeMode: .staticByteRange)) == nil)
    }

    /// The reducer events the model submits, in the lifecycles it submits them from.
    @Test("The prep events the model uses are legal where it uses them")
    func prepEventsAreLegal() {
        func life(_ from: DownloadLifecycle, _ event: DownloadLifecycleEvent) -> DownloadLifecycle? {
            R.reduce(DownloadLifecycleState(lifecycle: from), event,
                     facts: DownloadRowFacts(route: .plexPrep)).state?.lifecycle
        }
        // Emby: the seed (admitted), a reattach (serverPrep) and a recovery of a failed row.
        for from in [DownloadLifecycle.admitted, .serverPrep, .failed] {
            #expect(life(from, .prepReattached) == .serverPrep)
        }
        for from in [DownloadLifecycle.admitted, .serverPrep, .failed] {
            #expect(life(from, .prepFailed(.server)) == .failed)
        }
        #expect(life(.admitted, .pause(.user)) == .paused)
        #expect(life(.serverPrep, .pause(.user)) == .paused)
        #expect(life(.paused, .retry(.prepReattach)) == .admitted)
        #expect(life(.paused, .retry(.convertResume)) == .serverPrep)
        #expect(life(.failed, .retry(.convertResume)) == .serverPrep)
        // Plex hand-off: the prep row is `admitted` and its transfer starts.
        #expect(life(.admitted, .transferStarted) == .transferring)

        // Relaunch leaves a Plex prep row queued for the scanner and keeps a user pause.
        #expect(life(.admitted, .relaunchObserved) == .admitted)
        let paused = DownloadLifecycleState(
            lifecycle: .paused, history: DownloadAttemptHistory(pauseCause: .user))
        let relaunched = R.reduce(paused, .relaunchObserved, facts: DownloadRowFacts(route: .plexPrep))
        #expect(relaunched.state?.lifecycle == .paused)
        #expect(relaunched.state?.history.pauseCause == .user)
        // An Emby row keeps `serverPrep`, with or without a job.
        for hasJob in [true, false] {
            #expect(R.reduce(DownloadLifecycleState(lifecycle: .serverPrep), .relaunchObserved,
                             facts: DownloadRowFacts(route: .embyConvert(hasJobOrIdentity: hasJob)))
                .state?.lifecycle == .serverPrep)
        }
    }

    // MARK: - Finding S1

    /// S1. A Plex optimize job is rendering. The prep row fails while the job runs on: three
    /// rejected credentials (`PlexOptimizePollHealthPolicy.failAuthDead`), or a create whose
    /// response was lost. The user signs in again and taps Retry. Retry removes the row
    /// (`retry_replace`) and starts a new attempt under a new queue title, and journals nothing
    /// for the old title. The new attempt finds no finished render and no item under its own
    /// title, so it creates a second job. The first job is cancelled only if that create's
    /// best-effort stale sweep lists the queue; until then it has no durable cancel, and if it
    /// finishes first the replacement adopts its render and leaves the second job rendering.
    ///
    /// The Emby lane already avoids this: a failed row that still names a job resumes polling it.
    @Test("S1: Retry of a failed Plex prep row does not abandon its running job without a durable cancel")
    func retryOfFailedPlexPrepKeepsOrCancelsItsJob() throws {
        let failed = plexPrepRecord(status: .failed)

        // Holds today: the failed row still owes the cancel of its queue item on Delete, the
        // Emby lane resumes a failed row's job, and once the row is gone its running item is
        // "stale" to the next create's sweep.
        #expect(DownloadDeletePolicy.plexOptimizeCleanupQueueTitle(for: failed) == Self.queueTitle)
        #expect(DownloadRetryPreparationPolicy.shouldResumePausedEmbyConvert(
            status: .failed, resumeMode: .serverPrepThenStatic, isEmbyRecord: true,
            hasEmbyConvertJobID: true))
        let queue = BackgroundProcessingItems(items: [
            .init(id: "1", title: Self.queueTitle, state: "processing"),
        ])
        #expect(queue.staleItemIDs(marker: "[Labstream ", protectedTitles: []) == ["1"])

        // The decision is inline in app code, with no PMSKit policy to call. Until the fix
        // extracts one, pin the shape of the Plex retry branch: everything between the choice
        // of the optimize target and the removal of the failed row.
        let branch = try #require(Self.appSource(
            in: "Labstream/Capabilities/Downloads/Core/DownloadManager.swift",
            from: "DownloadBackendRetryIntentPolicy.plexPersistedOptimizeTarget(for: record)",
            through: "context: \"retry_replace\""))

        withKnownIssue("TLA+ finding S1 (#478): Plex Retry orphans the failed attempt's running optimize job") {
            // Either remedy satisfies the model: reattach to the job the row still names, or
            // journal its cancel before the row and its queue title are removed.
            let reattaches = branch.contains(".prepReattach")
            let journalsCancel = branch.contains("makePlexOptimizeCleanupIntent")
                || branch.contains("journalCleanupAbandonment")
            #expect(reattaches || journalsCancel,
                    "the failed row is removed with nothing recorded for its optimize queue item")
        }
    }

    /// The text of an app source file from the first `from` marker through the next `through`
    /// marker. Nil when the file or either marker is missing.
    private static func appSource(in relativePath: String, from: String, through: String) -> String? {
        // PMSKit/Tests/PMSKitTests/<this file> -> repository root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let source = try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8),
              let start = source.range(of: from),
              let end = source.range(of: through, range: start.upperBound..<source.endIndex)
        else { return nil }
        return String(source[start.lowerBound..<end.upperBound])
    }
}
