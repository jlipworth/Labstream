import Foundation
import Testing
@testable import PMSKit

/// Orderings the TLA+ model of the downloads session core found on the current design
/// (`specs/downloads/session/Finding-*.cfg`, `docs/archive/plans/2026-11-24-downloads-tla-model.md`).
///
/// Each test states the behaviour the design wants. A test for an open finding is wrapped in
/// `withKnownIssue`, so the suite stays green while the finding is open. When a fix lands the
/// expectations hold, no issue is recorded, and `withKnownIssue` fails the test: delete the
/// wrapper then, and turn the matching `Finding-*.cfg` into a `Faithful-*-off.cfg`. F1 and F3
/// are fixed and their tests are plain regression tests.
///
/// These pin the pure decisions. The session glue that feeds them (the capture, the live-key
/// snapshot) is app code, held here as source text until a `LabstreamTests` case runs it. F4
/// has no pure decision for its ordering, so it pins the shape of the app source.
/// F3's static-lane ordering is pinned as R3 in `DownloadsFormalModelRangeTrainTests`.
///
/// The `Model rule` tests are not findings: they tie two things the model assumes (Faithful-B12-off,
/// Faithful-Replay-off) to the code, and fail if the code stops doing them.
@Suite("Downloads formal-model findings")
struct DownloadsFormalModelFindingsTests {
    private typealias R = DownloadLifecycleReducer

    /// F1 (#472, fixed). A forward-only transfer finishes; the delegate used to move the body into
    /// a `tmp/` stash under an in-memory claim and queue its publication to the working path. A
    /// crash before that hop left a transferring row with no task: the stash sweep deleted the
    /// only copy and the reducer failed the row. Now the body goes to the attempt's capture
    /// path, which the row references, `bodyCaptured` is recorded with it, and relaunch reports
    /// `Body.captured` (`session/Faithful-F1-off.cfg` is the old behaviour).
    @Test("F1: a finished forward-only body at its capture path survives relaunch")
    func finishedForwardOnlyBodyInStashSurvivesRelaunch() throws {
        // Only a media response is captured durably: after a relaunch the response is gone, so
        // a captured body is published without the HTTP checks.
        typealias Body = ForwardOnlyFinishedBodyPolicy
        #expect(Body.custody(responseRejection: Body.responseRejection(
            httpStatus: 200, mimeType: "video/mp4")) == .durableCapture)
        #expect(Body.custody(responseRejection: Body.responseRejection(
            httpStatus: nil, mimeType: nil)) == .durableCapture)
        #expect(Body.responseRejection(httpStatus: 404, mimeType: "video/mp4") == .httpStatus(404))
        #expect(Body.responseRejection(httpStatus: 200, mimeType: "Text/HTML") == .nonMediaMIME("text/html"))
        #expect(Body.responseRejection(httpStatus: 200, mimeType: "application/json") != nil)
        #expect(Body.custody(responseRejection: .httpStatus(500)) == .volatileStash)

        // The capture: the row is `finalizing` from the moment the delegate holds the body,
        // from a transferring row or from one the user just paused.
        for lifecycle in [DownloadLifecycle.transferring, .admitted, .paused] {
            let captured = R.reduce(DownloadLifecycleState(lifecycle: lifecycle), .bodyCaptured,
                                    facts: DownloadRowFacts(route: .forwardOnly))
            #expect(captured.state?.lifecycle == .finalizing)
        }

        // Relaunch. A finalizing row keeps its captured body and asks for its publication.
        let recorded = R.reduce(
            DownloadLifecycleState(lifecycle: .finalizing), .relaunchObserved,
            facts: DownloadRowFacts(route: .forwardOnly, body: .captured))
        #expect(recorded.state?.lifecycle == .finalizing)
        #expect(recorded.effects == [.requestFinalization])
        // The process may also die after the rename and before `bodyCaptured` is durable: the
        // row is still transferring (or paused), and the captured body decides.
        for lifecycle in [DownloadLifecycle.transferring, .admitted, .paused] {
            let relaunch = R.reduce(
                DownloadLifecycleState(lifecycle: lifecycle), .relaunchObserved,
                facts: DownloadRowFacts(route: .forwardOnly, body: .captured))
            #expect(relaunch.state?.lifecycle == .finalizing)
            #expect(relaunch.effects.contains(.requestFinalization))
            #expect(!relaunch.effects.contains(.deleteWorkingBody))
        }
        // A live task means the transfer is not finished; the row is left to it.
        let live = R.reduce(
            DownloadLifecycleState(lifecycle: .transferring), .relaunchObserved,
            facts: DownloadRowFacts(route: .forwardOnly, body: .captured, liveTask: true))
        #expect(live.state?.lifecycle == .transferring)

        // The session glue, as source: the delegate captures and records, the store references
        // the capture path and reports it, and launch recovery requeues the publication.
        let session = try #require(Self.appSource(
            "Labstream/Capabilities/Downloads/Core/BackgroundDownloadSession.swift"))
        #expect(session.contains("store.forwardOnlyCapturedBodyURL(for: entry.attemptKey)"))
        #expect(session.contains(".bodyCaptured, for: entry.attemptKey"))
        #expect(session.contains("requeueCapturedForwardOnlyBody(attemptKey: attemptKey, destination: destination)"))
        let store = try #require(Self.appSource(
            "Labstream/Capabilities/Downloads/Core/DownloadStore.swift"))
        #expect(store.contains("if let captured = capturedBodyRelativePath(for: row) { result.insert(captured) }"))
        #expect(store.contains("body = .captured"))
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

    /// F3 (#474, fixed). A finished body must survive a user pause on either lane. The static
    /// lane writes it (`StaticRangeFinishedBodyPolicy`: `.pause` is `writeThenPause`; its pause
    /// sweep is R3 in `DownloadsFormalModelRangeTrainTests`). The forward-only lane dropped it,
    /// in two orderings:
    ///
    /// 1. The transfer finishes while a pause is landing. The delegate stashes the body and
    ///    queues `finishOpaqueBody`, which required that the attempt had no halt at all, so the
    ///    pause halt made it release the claim and return.
    /// 2. The body is already at the working path when the user pauses, and the process dies
    ///    before `bodyAtWorking` is persisted. On relaunch the reducer failed the paused row and
    ///    deleted the body.
    ///
    /// `session/Faithful-F3-off.cfg` is the old behaviour.
    @Test("F3: a finished forward-only body survives a user pause")
    func finishedForwardOnlyBodySurvivesUserPause() throws {
        typealias Body = ForwardOnlyFinishedBodyPolicy
        func publication(_ halt: StaticRangeHaltKind?, generationCurrent: Bool = true,
                         admits: Bool = true, trainCurrent: Bool = true) -> Body.Publication {
            Body.publication(attemptAdmitsWork: admits, trainEpochIsCurrent: trainCurrent,
                             retryGenerationIsCurrent: generationCurrent, haltKind: halt)
        }
        // 1. The queued publication accepts a pause halt and still rejects a cancel. Installing
        // a pause halt advances the retry generation, which must not discard the body either.
        #expect(publication(nil) == .publish)
        #expect(publication(.pause) == .publish)
        #expect(publication(.pause, generationCurrent: false) == .publish)
        #expect(publication(.cancel) == .discard)
        #expect(publication(nil, generationCurrent: false) == .discard)
        #expect(publication(.pause, admits: false) == .discard)
        #expect(publication(.pause, trainCurrent: false) == .discard)
        // The same decision the static lane makes, and the reducer allows.
        #expect(StaticRangeFinishedBodyPolicy.disposition(haltKind: .pause) == .writeThenPause)
        let paused = DownloadLifecycleState(
            lifecycle: .paused, history: DownloadAttemptHistory(pauseCause: .user))
        #expect(R.reduce(paused, .bodyAtWorking, facts: DownloadRowFacts(route: .forwardOnly))
            .state?.lifecycle == .finalizing)
        // A finalizing row is not paused at all.
        let finalizing = DownloadLifecycleState(lifecycle: .finalizing)
        #expect(R.reduce(finalizing, .pause(.user), facts: DownloadRowFacts(route: .forwardOnly))
            .state?.lifecycle == .finalizing)

        // The app asks the policy, and no longer requires an unhalted attempt.
        let finishOpaqueBody = try #require(Self.appFunctionSource(
            named: "finishOpaqueBody",
            in: "Labstream/Capabilities/Downloads/Core/BackgroundDownloadSession.swift"))
        #expect(finishOpaqueBody.contains("opaquePublication(for: currency) == .publish"))
        #expect(!finishOpaqueBody.contains("checkpointIsCurrent(currency, halt: nil)"))

        // 2. Relaunch with the whole body at the working path of a user-paused row.
        let relaunch = R.reduce(paused, .relaunchObserved,
                                facts: DownloadRowFacts(route: .forwardOnly, body: .workingComplete))
        #expect(relaunch.state?.lifecycle == .finalizing)
        #expect(relaunch.state?.history.pauseCause == nil)
        #expect(relaunch.effects == [.requestFinalization])
        // Without a body a user-paused forward-only row stays paused (Admission-A1, #475).
        let empty = R.reduce(paused, .relaunchObserved, facts: DownloadRowFacts(route: .forwardOnly))
        #expect(empty.state?.lifecycle == .paused)
        #expect(empty.effects.isEmpty)
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

    /// The text of an app source file. Nil when it is missing.
    private static func appSource(_ relativePath: String) -> String? {
        // PMSKit/Tests/PMSKitTests/<this file> -> repository root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The text of one function in an app source file, from its declaration to the next
    /// declaration at the same indentation. Nil when the file or the function is missing.
    private static func appFunctionSource(named name: String, in relativePath: String) -> String? {
        guard let source = appSource(relativePath),
              let start = source.range(of: "    private func \(name)(") else { return nil }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func ")?.lowerBound ?? rest.endIndex
        return String(source[start.lowerBound..<end])
    }
}
