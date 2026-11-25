import Foundation
import Testing
@testable import PMSKit

/// Orderings the TLA+ model of the downloads session core found on the current design
/// (`specs/downloads/session/Finding-*.cfg`, `docs/plans/2026-11-24-downloads-tla-model.md`).
///
/// Each test states the behaviour the design wants and is wrapped in `withKnownIssue`, so the
/// suite stays green while the finding is open. When a fix lands the expectations hold, no issue
/// is recorded, and `withKnownIssue` fails the test: delete the wrapper then, and flip the
/// matching `Finding-*.cfg` to `EXPECT: pass`.
///
/// These pin the pure decisions only. The session glue that feeds them (the stash claim, the
/// live-key snapshot) is app code and needs a `LabstreamTests` pin with the fix. F3 and F4 have
/// no pure decision for their main ordering, so they also pin the shape of the app source.
/// F3's static-lane ordering is pinned as R3 in `DownloadsFormalModelRangeTrainTests`.
///
/// The `Model rule` tests are not findings: they tie two things the model assumes (Faithful-B12-off,
/// Faithful-Replay-off) to the code, and fail if the code stops doing them.
@Suite("Downloads formal-model findings")
struct DownloadsFormalModelFindingsTests {
    private typealias R = DownloadLifecycleReducer

    /// F1. A forward-only transfer finishes; the delegate moves the body into a `tmp/` stash and
    /// queues its publication to the working path; the process dies before that hop runs.
    /// On relaunch the task is no longer live, so the stash sweep deletes the only copy, and the
    /// reducer fails the row. The whole body is lost and the stream restarts from zero.
    @Test("F1: a finished forward-only body in the stash survives relaunch")
    func finishedForwardOnlyBodyInStashSurvivesRelaunch() {
        withKnownIssue("TLA+ finding F1 (#472): crash between stash and working path loses the body") {
            // The stash of finished task 7. After the crash no task is live.
            let stash = BackgroundTempFileCleanupPolicy.rangeBodyStashPrefix + "7-o0"
            let swept = BackgroundTempFileCleanupPolicy.shouldDeleteRangeBodyStash(
                fileName: stash, liveTaskIdentifiers: [])
            #expect(!swept, "the relaunch sweep deletes the only copy of a finished body")

            // The reducer already names this fact (`Body.captured`), but nothing reports it and
            // a transferring row does not act on it.
            let relaunch = R.reduce(
                DownloadLifecycleState(lifecycle: .transferring), .relaunchObserved,
                facts: DownloadRowFacts(route: .forwardOnly, body: .captured))
            #expect(relaunch.state?.lifecycle == .finalizing)
            #expect(relaunch.effects.contains(.requestFinalization))
            #expect(!relaunch.effects.contains(.deleteWorkingBody))
        }
    }

    /// F2. The app returns to the foreground and reattach snapshots its live tasks; the user
    /// pauses a row in that snapshot; reconcile then runs `relaunchObserved` with the stale
    /// "live task" fact. The reducer used to promote the paused row to transferring, with no
    /// task left. Fixed: a live-task fact never promotes a paused row, for any pause cause
    /// (every cause cancels its task, and reattach never adopts a paused row's task, B02).
    @Test("F2: relaunchObserved never promotes a paused row")
    func userPausedRowIsNotPromotedByLiveTaskFact() {
        let causes: [DownloadPauseCause?] = [.user, .queuePaused, .systemInterrupted,
                                             .awaitingSession, .storage, .deferredResume, nil]
        let routes: [DownloadRowFacts.Route] = [.staticRange, .forwardOnly, .plexPrep,
                                                .embyConvert(hasJobOrIdentity: true),
                                                .embyConvert(hasJobOrIdentity: false)]
        for route in routes {
            for cause in causes {
                let paused = DownloadLifecycleState(
                    lifecycle: .paused, history: DownloadAttemptHistory(pauseCause: cause))
                let next = R.reduce(paused, .relaunchObserved,
                                    facts: DownloadRowFacts(route: route, liveTask: true))
                #expect(next.state == paused, "\(route) \(String(describing: cause))")
                #expect(next.effects.isEmpty)
            }
        }
        // A live task still keeps a transferring static row transferring.
        let transferring = R.reduce(DownloadLifecycleState(lifecycle: .transferring), .relaunchObserved,
                                    facts: DownloadRowFacts(route: .staticRange, liveTask: true))
        #expect(transferring.state?.lifecycle == .transferring)
    }

    /// F3. A finished body must survive a user pause on either lane. The static lane keeps it
    /// (`StaticRangeFinishedBodyPolicy`: `.pause` is `writeThenPause`). The forward-only lane
    /// drops it, in two orderings:
    ///
    /// 1. The transfer finishes while a pause is landing. The delegate stashes the body and
    ///    queues `finishOpaqueBody`, which requires that the attempt has no halt at all, so the
    ///    pause halt makes it release the claim and return. The row stays paused, the stash is
    ///    orphaned, and Resume restarts the stream from zero.
    /// 2. The body is already at the working path when the user pauses, and the process dies
    ///    before `bodyAtWorking` is persisted. On relaunch the reducer fails the paused row and
    ///    deletes the body.
    @Test("F3: a finished forward-only body survives a user pause")
    func finishedForwardOnlyBodySurvivesUserPause() throws {
        // Ordering 1 is decided inline in app code, with no PMSKit policy to call. Until the fix
        // extracts one, pin the guard itself.
        let finishOpaqueBody = try #require(Self.appFunctionSource(
            named: "finishOpaqueBody",
            in: "Labstream/Capabilities/Downloads/Core/BackgroundDownloadSession.swift"))

        // The decision the static lane already makes, and the reducer already allows.
        #expect(StaticRangeFinishedBodyPolicy.disposition(haltKind: .pause) == .writeThenPause)
        let paused = DownloadLifecycleState(
            lifecycle: .paused, history: DownloadAttemptHistory(pauseCause: .user))
        #expect(R.reduce(paused, .bodyAtWorking, facts: DownloadRowFacts(route: .forwardOnly))
            .state?.lifecycle == .finalizing)

        withKnownIssue("TLA+ finding F3 (#474): a user pause discards a finished forward-only body") {
            // 1. `halt: nil` means "current only while nothing halted the attempt", which a
            // pause halt fails. The fixed guard accepts a pause halt and still rejects a cancel.
            let requiresNoHalt = finishOpaqueBody.contains("checkpointIsCurrent(currency, halt: nil)")
            #expect(!requiresNoHalt, "finishOpaqueBody drops the finished body of a paused attempt")

            // 2. Relaunch with the whole body at the working path of a user-paused row.
            let relaunch = R.reduce(paused, .relaunchObserved,
                                    facts: DownloadRowFacts(route: .forwardOnly, body: .workingComplete))
            #expect(!relaunch.effects.contains(.deleteWorkingBody))
            #expect(relaunch.state?.lifecycle != .failed)
        }
    }

    /// F4. A failing truncation verdict goes through the reducer, which condemns the body, counts
    /// the strike and fails the row in one revision. The finalizer applies it in memory, renames
    /// the body off the working path at once, and only then waits for the revision to commit. A
    /// crash in between leaves the durable row `finalizing` with no body, no strike and no
    /// `bodyCondemned`. On relaunch the reducer fails it as an internal error: the truncation
    /// strike is lost, so the source needs one more whole download before two strikes accept it
    /// as unverified, and the user is shown the wrong failure.
    @Test("F4: a truncation verdict is durable before its body leaves the working path")
    func truncationVerdictIsDurableBeforeTheBodyMoves() throws {
        // What a relaunch makes of the residue: a finalizing row with no body.
        let residue = R.reduce(DownloadLifecycleState(lifecycle: .finalizing), .relaunchObserved,
                               facts: DownloadRowFacts(route: .forwardOnly))
        #expect(residue.state?.lifecycle == .failed)
        #expect(residue.state?.history.lastFailure == .internalError)
        #expect(residue.state?.history.truncation == nil)
        // What the verdict would have recorded.
        let source = DownloadSourceKey(server: nil, account: nil, backend: nil, item: "item",
                                       source: nil, profile: nil)
        let verdict = R.reduce(DownloadLifecycleState(lifecycle: .finalizing),
                               .finalizeOutcome(id: "o1", outcome: .truncated, source: source),
                               facts: DownloadRowFacts(route: .forwardOnly))
        #expect(verdict.state?.history.lastFailure == .truncated)
        #expect(verdict.state?.history.truncation?.strikes == 1)
        #expect(verdict.state?.history.isBodyCondemned == true)

        let finalize = try #require(Self.appFunctionSource(
            named: "finalizeTransferredFile",
            in: "Labstream/Capabilities/Downloads/Core/BackgroundDownloadSession.swift"))
        let rename = try #require(finalize.range(of: "condemnBody(afterCommitOf: ticket)\n"))
        let commit = try #require(finalize.range(
            of: "verdict, key: attemptKey, phase: \"finalize_truncated_verdict\") else { return }"))
        withKnownIssue("TLA+ finding F4 (#491): a crash between the condemn rename and the verdict's commit") {
            #expect(commit.lowerBound < rename.lowerBound,
                    "the body is renamed away before the verdict that explains it is durable")
        }
    }

    /// Faithful-Replay-off. The model's `FixReplay = FALSE` is the counter before R2-5: one
    /// strike per truncated finalizer run, with nothing that names the body. Today two layers
    /// reject a replayed outcome ID, the reducer and `recordingTruncation`.
    @Test("Model rule: a replayed truncation outcome is ignored by the reducer and by the history")
    func replayedTruncationIsIgnoredTwice() {
        let source = DownloadSourceKey(server: nil, account: nil, backend: nil, item: "item",
                                       source: nil, profile: nil)
        let counted = DownloadAttemptHistory(
            truncation: DownloadTruncationHistory(strikes: 1, sourceKey: source, countedOutcomeIDs: ["o1"]))
        #expect(R.reduce(DownloadLifecycleState(lifecycle: .finalizing, history: counted),
                         .finalizeOutcome(id: "o1", outcome: .truncated, source: source),
                         facts: DownloadRowFacts(route: .forwardOnly)) == .rejected(.replayed))
        let again = counted.recordingTruncation(outcomeID: "o1", source: source)
        #expect(!again.recorded)
        #expect(again.history.truncation?.strikes == 1)
        #expect(counted.recordingTruncation(outcomeID: "o2", source: source).history.truncation?.strikes == 2)
    }

    /// Faithful-B12-off. B12 is the manager's side of a transfer-error handoff: the session
    /// hands an attempt's error to the main actor, and by the time it lands the user may have
    /// replaced that attempt. The handoff must be dropped unless its attempt still owns the row.
    @Test("Model rule: the manager's error handoffs act only for the attempt that raised them (B12)")
    func errorHandoffsAreFencedOnTheAttempt() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let manager = try String(
            contentsOf: root.appendingPathComponent(
                "Labstream/Capabilities/Downloads/Core/DownloadManager.swift"), encoding: .utf8)
        for handoff in ["self.session.onRangeRequestNeeded = ", "self.session.onRangeAuthHTTPFailure = "] {
            let start = try #require(manager.range(of: handoff))
            let body = manager[start.upperBound...].prefix(2_000)
            #expect(body.contains("self.store.ownsAttempt(attemptKey)"), "\(handoff) is not fenced")
        }
    }

    /// The text of one function in an app source file, from its declaration to the next
    /// declaration at the same indentation. Nil when the file or the function is missing.
    private static func appFunctionSource(named name: String, in relativePath: String) -> String? {
        // PMSKit/Tests/PMSKitTests/<this file> -> repository root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let source = try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8),
              let start = source.range(of: "    private func \(name)(") else { return nil }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func ")?.lowerBound ?? rest.endIndex
        return String(source[start.lowerBound..<end])
    }
}
