import Foundation
import Testing
@testable import PMSKit

@Suite("Download lifecycle reducer")
struct DownloadLifecycleReducerTests {
    private typealias R = DownloadLifecycleReducer
    private let staticFacts = DownloadRowFacts(route: .staticRange)
    private let source = DownloadSourceKey(server: "server-1", account: "user-1", backend: "jellyfin",
                                           item: "item-1", source: "source-1", profile: "1080p")

    private func state(_ lifecycle: DownloadLifecycle,
                       _ history: DownloadAttemptHistory = .empty) -> DownloadLifecycleState {
        DownloadLifecycleState(lifecycle: lifecycle, history: history)
    }

    // MARK: - Derivation

    @Test func statusIsDerivedFromLifecycle() {
        let expected: [DownloadLifecycle: DownloadStatus] = [
            .planned: .queued, .admitted: .queued, .serverPrep: .preparing,
            .transferring: .downloading, .finalizing: .downloading, .complete: .complete,
            .unverified: .unverified, .paused: .paused, .failed: .failed,
        ]
        for lifecycle in DownloadLifecycle.allCases {
            #expect(lifecycle.derivedStatus == expected[lifecycle])
        }
    }

    @Test func legacyRowsDeriveStructurallyWithoutEffects() {
        #expect(DownloadLifecycle.structural(from: .failed, admissionPending: true,
                                             finalizingEvidence: false) == .planned)
        #expect(DownloadLifecycle.structural(from: .failed, admissionPending: false,
                                             finalizingEvidence: false) == .failed)
        #expect(DownloadLifecycle.structural(from: .downloading, admissionPending: false,
                                             finalizingEvidence: true) == .finalizing)
        #expect(DownloadLifecycle.structural(from: .queued, admissionPending: false,
                                             finalizingEvidence: false) == .admitted)
    }

    // MARK: - B09: progress never promotes

    @Test func progressPromotesOnlyAdmittedOrTransferring() {
        #expect(R.reduce(state(.admitted), .transferProgress, facts: staticFacts).state?.lifecycle
                == .transferring)
        for lifecycle: DownloadLifecycle in [.paused, .failed, .finalizing, .complete, .planned] {
            #expect(R.reduce(state(lifecycle), .transferProgress, facts: staticFacts)
                    == .rejected(.illegal))
            // Bytes still advance through the checkpoint event, without a lifecycle change.
            #expect(R.reduce(state(lifecycle), .checkpointAdvanced, facts: staticFacts).state?
                .lifecycle == lifecycle)
        }
    }

    // MARK: - Pause causes

    @Test func pauseRecordsItsCauseAndSystemCancelParks() {
        let paused = R.reduce(state(.transferring), .pause(.user), facts: staticFacts).state
        #expect(paused?.lifecycle == .paused)
        #expect(paused?.history.pauseCause == .user)
        let interrupted = R.reduce(state(.transferring), .transferInterrupted(.cancelledBySystem),
                                   facts: staticFacts).state
        #expect(interrupted?.history.pauseCause == .systemInterrupted)
        let storage = R.reduce(state(.transferring), .transferInterrupted(.storage),
                               facts: staticFacts).state
        #expect(storage?.history.pauseCause == .storage)
        #expect(storage?.history.storagePark != nil)
        // A finalizing body is finished: pause is accepted but changes nothing.
        #expect(R.reduce(state(.finalizing), .pause(.user), facts: staticFacts).state?.lifecycle
                == .finalizing)
    }

    // MARK: - B54: truncation strikes survive attempts and relaunch

    @Test func truncationStrikesSpanAttemptsAndParkAtTheBudget() throws {
        // Strike 1 on attempt A: fail and delete the working body.
        let first = R.reduce(state(.finalizing),
                             .finalizeOutcome(id: "A-1", outcome: .truncated, source: source),
                             facts: staticFacts)
        #expect(first.state?.lifecycle == .failed)
        #expect(first.effects == [.deleteWorkingBody])
        let afterFirst = try #require(first.state)

        // Retry mints attempt B, which inherits the strike for the same source (R2-5).
        let inherited = afterFirst.history.inherited(by: source)
        #expect(inherited.truncation?.strikes == 1)

        // Strike 2 on attempt B: park unverified and publish (B54), never delete.
        let second = R.reduce(state(.finalizing, inherited),
                              .finalizeOutcome(id: "B-1", outcome: .truncated, source: source),
                              facts: staticFacts)
        #expect(second.state?.lifecycle == .finalizing)
        #expect(second.effects == [.publish(.unverified)])
        #expect(second.state?.history.unverifiedReason == .truncatedRepeated)
        let committed = R.reduce(try #require(second.state), .promotionCommitted(.unverified),
                                 facts: staticFacts)
        #expect(committed.state?.lifecycle == .unverified)
        #expect(committed.state?.history.unverifiedReason == .truncatedRepeated)
    }

    @Test func replayedFinalizeOutcomeIsNotCountedTwice() throws {
        let first = try #require(R.reduce(state(.finalizing),
                                          .finalizeOutcome(id: "A-1", outcome: .truncated,
                                                           source: source),
                                          facts: staticFacts).state)
        // The same outcome delivered again (a replayed finalizer) is rejected, not a second strike.
        var replayState = first
        replayState.lifecycle = .finalizing
        #expect(R.reduce(replayState,
                         .finalizeOutcome(id: "A-1", outcome: .truncated, source: source),
                         facts: staticFacts) == .rejected(.replayed))
    }

    @Test func strikesResetOnlyOnProvenSourceChange() throws {
        let struck = DownloadAttemptHistory(truncation: DownloadTruncationHistory(
            strikes: 1, sourceKey: source))
        var unknownPart = source
        unknownPart.source = nil
        #expect(struck.inherited(by: unknownPart).truncation?.strikes == 1)
        var otherProfile = source
        otherProfile.profile = "720p"
        #expect(struck.inherited(by: otherProfile).truncation == nil)
        var otherServer = source
        otherServer.server = "server-2"
        #expect(struck.inherited(by: otherServer).truncation == nil)
    }

    @Test func revalidatingAPublishedBodyNeverDeletesItForTruncation() {
        let kept = R.reduce(state(.unverified),
                            .publishedBodyRevalidated(id: "R-1", outcome: .truncated),
                            facts: staticFacts)
        #expect(kept.state?.lifecycle == .unverified)
        #expect(kept.effects.isEmpty)
        let empty = R.reduce(state(.unverified),
                             .publishedBodyRevalidated(id: "R-2", outcome: .emptyFile),
                             facts: staticFacts)
        #expect(empty.state?.lifecycle == .failed)
        #expect(empty.effects == [.deletePublishedBody])
        #expect(R.reduce(state(.unverified),
                         .publishedBodyRevalidated(id: "R-3", outcome: .complete),
                         facts: staticFacts).state?.lifecycle == .complete)
    }

    // MARK: - Finalization (B10, R2-2)

    @Test func capturedBodyEntersFinalizingAndPublicationCommitsTheTerminal() throws {
        let captured = R.reduce(state(.transferring), .bodyCaptured, facts: staticFacts)
        #expect(captured.state?.lifecycle == .finalizing)
        let atWorking = R.reduce(try #require(captured.state), .bodyAtWorking, facts: staticFacts)
        #expect(atWorking.effects == [.requestFinalization])
        let outcome = R.reduce(try #require(atWorking.state),
                               .finalizeOutcome(id: "A-1", outcome: .complete, source: source),
                               facts: staticFacts)
        #expect(outcome.state?.lifecycle == .finalizing, "stays finalizing until publication commits")
        #expect(outcome.effects == [.publish(.complete)])
        #expect(R.reduce(try #require(outcome.state), .promotionCommitted(.complete),
                         facts: staticFacts).state?.lifecycle == .complete)
        #expect(R.reduce(state(.finalizing), .finalizeOutcome(
            id: "A-2", outcome: .incompleteBytes, source: source), facts: staticFacts).effects
                == [.resetBytesToDurableCheckpoint])
    }

    @Test func aCompleteBodyOnAParkedRowReentersFinalizing() {
        for lifecycle: DownloadLifecycle in [.paused, .failed] {
            #expect(R.reduce(state(lifecycle), .bodyAtWorking, facts: staticFacts).state?.lifecycle
                    == .finalizing)
        }
        #expect(R.reduce(state(.complete), .bodyAtWorking, facts: staticFacts)
                == .rejected(.illegal))
    }

    // MARK: - Retry modes and admission

    @Test func retryModesChooseTheirDestination() {
        #expect(R.reduce(state(.failed), .retry(.convertResume), facts: staticFacts).state?
            .lifecycle == .serverPrep)
        #expect(R.reduce(state(.paused), .retry(.prepReattach), facts: staticFacts).state?
            .lifecycle == .admitted, "Plex prep is persisted queued")
        // A planned season row retries like a failed one.
        #expect(R.reduce(state(.planned), .retry(.convertResume), facts: staticFacts).state?
            .lifecycle == .serverPrep)
        #expect(R.reduce(state(.planned), .backendUnavailable(.awaitingSession),
                         facts: staticFacts).state?.lifecycle == .paused)
        // A deferred resume keeps or restores the queued intent.
        for lifecycle: DownloadLifecycle in [.paused, .failed, .admitted, .transferring, .planned] {
            #expect(R.reduce(state(lifecycle), .requeued, facts: staticFacts).state?.lifecycle
                    == .admitted)
        }
        #expect(R.reduce(state(.finalizing), .requeued, facts: staticFacts) == .rejected(.illegal))
        #expect(R.reduce(state(.complete), .requeued, facts: staticFacts) == .rejected(.illegal))
        #expect(R.reduce(state(.paused), .retry(.resumeBlob), facts: staticFacts).state?
            .lifecycle == .transferring)
        #expect(R.reduce(state(.failed), .retry(.staticCheckpoint), facts: staticFacts).state?
            .lifecycle == .admitted)
        #expect(R.reduce(state(.transferring), .retry(.freshAttempt), facts: staticFacts)
                == .rejected(.illegal))
    }

    @Test func seasonAdmissionMovesPlannedToAdmitted() {
        let planned = state(.planned, DownloadAttemptHistory(admissionIntent: .seasonPlanned))
        let admitted = R.reduce(planned, .admissionGranted, facts: staticFacts).state
        #expect(admitted?.lifecycle == .admitted)
        #expect(admitted?.history.admissionIntent == nil)
        #expect(R.reduce(state(.admitted), .admissionGranted, facts: staticFacts)
                == .rejected(.illegal))
    }

    @Test func prepHandoffKeepsTheAttemptAndAdmitsTheStaticTransfer() {
        #expect(R.reduce(state(.serverPrep), .prepHandoff, facts: staticFacts).state?.lifecycle
                == .admitted)
    }

    // MARK: - Terminal states

    @Test func terminalRowsAcceptOnlyTheirRecoveryEvents() {
        #expect(R.reduce(state(.unverified), .localPlaybackProgressed, facts: staticFacts).state?
            .lifecycle == .complete)
        #expect(R.reduce(state(.complete), .sizeAuditFailed, facts: staticFacts).state?
            .lifecycle == .failed)
        #expect(R.reduce(state(.complete), .transferProgress, facts: staticFacts)
                == .rejected(.illegal))
        #expect(R.reduce(state(.complete), .transferStarted, facts: staticFacts)
                == .rejected(.illegal))
    }

    @Test func stallFailsOnlyTransferringRows() {
        #expect(R.reduce(state(.transferring), .stallDetected, facts: staticFacts).state?
            .history.lastFailure == .stalled)
        #expect(R.reduce(state(.paused), .stallDetected, facts: staticFacts) == .rejected(.illegal))
    }

    // MARK: - Relaunch (Appendix C.5)

    @Test func relaunchReproducesTheReconcileTable() {
        func relaunch(_ lifecycle: DownloadLifecycle, _ facts: DownloadRowFacts)
            -> DownloadLifecycleTransition {
            R.reduce(state(lifecycle), .relaunchObserved, facts: facts)
        }
        // Finalizing with a body re-requests finalization; the body is never deleted (B10).
        let finalizing = relaunch(.finalizing, DownloadRowFacts(route: .forwardOnly, body: .captured))
        #expect(finalizing.state?.lifecycle == .finalizing)
        #expect(finalizing.effects == [.requestFinalization])
        // A live static task keeps transferring.
        #expect(relaunch(.transferring, DownloadRowFacts(route: .staticRange, liveTask: true)).state?
            .lifecycle == .transferring)
        // A static partial without a task parks at its durable checkpoint.
        let parked = relaunch(.transferring, DownloadRowFacts(
            route: .staticRange, checkpoint: .durablePartial(bytes: 10)))
        #expect(parked.state?.lifecycle == .paused)
        #expect(parked.effects == [.resetBytesToDurableCheckpoint])
        // A resume blob keeps any route paused.
        #expect(relaunch(.paused, DownloadRowFacts(route: .forwardOnly, checkpoint: .resumeBlob))
            .state?.lifecycle == .paused)
        // A Plex prep row without a task goes back to queued (admitted) with bytes reset.
        let prep = relaunch(.transferring, DownloadRowFacts(route: .plexPrep))
        #expect(prep.state?.lifecycle == .admitted)
        #expect(prep.effects == [.resetBytesToZero])
        // A preparing (Emby Convert) row is unchanged.
        #expect(relaunch(.serverPrep, DownloadRowFacts(route: .embyConvert(hasJobOrIdentity: false)))
            .state?.lifecycle == .serverPrep)
        // A paused static row with no bytes stays restartable.
        #expect(relaunch(.paused, DownloadRowFacts(route: .staticRange)).state?.lifecycle == .paused)
        // A queued forward-only row with a blob but no task fails, as today.
        #expect(relaunch(.admitted, DownloadRowFacts(route: .forwardOnly, checkpoint: .resumeBlob))
            .state?.lifecycle == .failed)
        // A finished forward-only body becomes finalizing (B10).
        #expect(relaunch(.transferring, DownloadRowFacts(route: .forwardOnly, body: .workingComplete))
            .effects == [.requestFinalization])
        // Nothing resumable: fail and clean up, as effects (executed outside the lock).
        let lost = relaunch(.transferring, DownloadRowFacts(route: .forwardOnly))
        #expect(lost.state?.lifecycle == .failed)
        #expect(lost.effects == [.deleteWorkingBody, .clearResumeBlob])
        // A terminal row whose published body is gone fails.
        #expect(relaunch(.complete, DownloadRowFacts(route: .staticRange, body: .none)).state?
            .lifecycle == .failed)
        #expect(relaunch(.complete, DownloadRowFacts(route: .staticRange, body: .published)).state?
            .lifecycle == .complete)
        // Rows behind a pending artifact head or a deletion are left alone.
        #expect(relaunch(.transferring, DownloadRowFacts(route: .forwardOnly, pendingArtifactHead: true))
            .effects.isEmpty)
        #expect(relaunch(.planned, DownloadRowFacts(route: .staticRange)).state?.lifecycle == .planned)
    }

    // MARK: - Persistence

    @Test func historyRoundTrips() throws {
        let history = DownloadAttemptHistory(
            truncation: DownloadTruncationHistory(strikes: 2, sourceKey: source,
                                                  countedOutcomeIDs: ["A-1", "B-1"]),
            unverifiedReason: .probeMiss("duration_unconfirmed"), lastFailure: .network,
            storagePark: DownloadStoragePark(requiredBytes: 1_000, measuredAtEpochSeconds: 5),
            pauseCause: .storage, admissionIntent: .seasonPlanned)
        let decoded = try JSONDecoder().decode(
            DownloadAttemptHistory.self, from: JSONEncoder().encode(history))
        #expect(decoded == history)
        #expect(try JSONDecoder().decode(DownloadLifecycle.self,
                                         from: JSONEncoder().encode(DownloadLifecycle.finalizing))
                == .finalizing)
    }
}
