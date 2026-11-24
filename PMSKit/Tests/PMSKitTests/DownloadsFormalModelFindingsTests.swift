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
/// live-key snapshot) is app code and needs a `LabstreamTests` pin with the fix. F3 has no pure
/// decision for its main ordering, so it also pins the shape of the app source it found.
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
    /// "live task" fact and promotes the user-paused row to transferring, with no task left.
    @Test("F2: relaunchObserved never promotes a user-paused row")
    func userPausedRowIsNotPromotedByLiveTaskFact() {
        withKnownIssue("TLA+ finding F2 (#473): a stale live-task snapshot undoes a user pause") {
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
