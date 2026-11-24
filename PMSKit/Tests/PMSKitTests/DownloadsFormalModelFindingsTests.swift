import Foundation
import Testing
@testable import PMSKit

/// Orderings the TLA+ model of the downloads session core found on the current design
/// (`specs/downloads/Finding-*.cfg`, `docs/plans/2026-11-24-downloads-tla-model.md`).
///
/// Each test states the behaviour the design wants and is wrapped in `withKnownIssue`, so the
/// suite stays green while the finding is open. When a fix lands the expectations hold, no issue
/// is recorded, and `withKnownIssue` fails the test: delete the wrapper then, and flip the
/// matching `Finding-*.cfg` to `EXPECT: pass`.
///
/// These pin the pure decisions only. The session glue that feeds them (the stash claim, the
/// live-key snapshot) is app code and needs a `LabstreamTests` pin with the fix.
@Suite("Downloads formal-model findings")
struct DownloadsFormalModelFindingsTests {
    private typealias R = DownloadLifecycleReducer

    /// F1. A forward-only transfer finishes; the delegate moves the body into a `tmp/` stash and
    /// queues its publication to the working path; the process dies before that hop runs.
    /// On relaunch the task is no longer live, so the stash sweep deletes the only copy, and the
    /// reducer fails the row. The whole body is lost and the stream restarts from zero.
    @Test("F1: a finished forward-only body in the stash survives relaunch")
    func finishedForwardOnlyBodyInStashSurvivesRelaunch() {
        withKnownIssue("TLA+ finding F1: crash between stash and working path loses the body") {
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
    /// "live task" fact and promotes the user-paused row to transferring, with no task left.
    @Test("F2: relaunchObserved never promotes a user-paused row")
    func userPausedRowIsNotPromotedByLiveTaskFact() {
        withKnownIssue("TLA+ finding F2: a stale live-task snapshot undoes a user pause") {
            for route in [DownloadRowFacts.Route.staticRange, .forwardOnly] {
                let paused = DownloadLifecycleState(
                    lifecycle: .paused, history: DownloadAttemptHistory(pauseCause: .user))
                let next = R.reduce(paused, .relaunchObserved,
                                    facts: DownloadRowFacts(route: route, liveTask: true))
                #expect(next.state?.lifecycle == .paused)
                #expect(next.state?.history.pauseCause == .user)
            }
        }
    }
}
