import Foundation
import Testing
@testable import PMSKit

/// The static-range segment train as `specs/downloads/range-train/DownloadsRangeTrain.tla` models it.
///
/// The first tests tie the model's rules to the pure policies it copies, so a policy change that
/// the spec does not follow fails here. The `R1` to `R4` tests are orderings TLC found on the
/// current design (`specs/downloads/range-train/Finding-*.cfg`). Each states the behaviour the
/// design wants and is wrapped in `withKnownIssue`, so the suite stays green while the finding is
/// open. When a fix lands the expectation holds, no issue is recorded, and `withKnownIssue` fails
/// the test: delete the wrapper then, and flip the matching config to `EXPECT: pass`.
///
/// R1, R2 and R3 are decided inline in app code, with no PMSKit policy to call, so they pin the
/// shape of the app source and the pure decisions on either side of it. The fix needs a
/// `LabstreamTests` pin of the session behaviour itself. R4 is a pure policy decision.
@Suite("Downloads formal-model range train")
struct DownloadsFormalModelRangeTrainTests {
    private typealias R = DownloadLifecycleReducer
    private static let sessionSource =
        "Labstream/Capabilities/Downloads/Core/BackgroundDownloadSession.swift"
    private static let storeSource =
        "Labstream/Capabilities/Downloads/Core/DownloadStore.swift"

    // MARK: The rules the model copies

    /// `DrainPass`: the body exactly at the checkpoint is appendable, one behind it is discarded,
    /// one past a gap waits.
    @Test("Model rule: the held-body drain follows the assembly policy")
    func drainFollowsAssemblyPolicy() {
        let run = StaticRangeSegmentAssemblyPolicy.appendableRun(
            durableBytes: 1, stashedSegments: [(offset: 3, length: 1), (offset: 1, length: 1),
                                               (offset: 0, length: 1)])
        #expect(run.append.map(\.offset) == [1])
        #expect(run.hold.map(\.offset) == [3])
        #expect(run.discard.map(\.offset) == [0])
    }

    /// `PlanSet`: the first uncovered offsets from the checkpoint, up to the depth left over.
    /// Tracked tasks, held bodies and claimed finished bodies all count as covered.
    @Test("Model rule: the planner tops the train up to its depth around covered offsets")
    func plannerFollowsQueuePolicy() {
        func plan(durable: Int, covered: [Int]) -> [Int] {
            StaticRangeSegmentQueuePolicy.segmentsToEnqueue(
                durableBytes: durable, expectedBytes: 3,
                liveSegments: covered.map { StaticRangeSegmentPlan(offset: $0, length: 1) },
                segmentBytes: 1, maxQueuedSegments: 2).map(\.offset)
        }
        #expect(plan(durable: 0, covered: []) == [0, 1])
        #expect(plan(durable: 0, covered: [1]) == [0])
        #expect(plan(durable: 1, covered: [1]) == [2])
        #expect(plan(durable: 1, covered: [1, 2]).isEmpty)
        #expect(plan(durable: 3, covered: []).isEmpty)
    }

    /// `PlanFrom` with `SegBytes > 1` (Current-MidAppend, Mutant-OffsetEqualityPlan): coverage is
    /// by interval. After a crash in the middle of an append the checkpoint is inside the grid
    /// the live segments were planned on, and the planner fills only the gap up to the next one.
    @Test("Model rule: the planner fills gaps by interval when the checkpoint is off the grid")
    func plannerFillsGapsByInterval() {
        func plan(durable: Int, total: Int, live: [(Int, Int)]) -> [StaticRangeSegmentPlan] {
            StaticRangeSegmentQueuePolicy.segmentsToEnqueue(
                durableBytes: durable, expectedBytes: total,
                liveSegments: live.map { StaticRangeSegmentPlan(offset: $0.0, length: $0.1) },
                segmentBytes: 2, maxQueuedSegments: 2)
        }
        // Checkpoint 1 inside [0, 2); the adopted segment [2, 4) is still live.
        #expect(plan(durable: 1, total: 6, live: [(2, 2)])
            == [StaticRangeSegmentPlan(offset: 1, length: 1)])
        // Nothing live: full-size segments from the checkpoint, off the old grid.
        #expect(plan(durable: 1, total: 6, live: [])
            == [StaticRangeSegmentPlan(offset: 1, length: 2), StaticRangeSegmentPlan(offset: 3, length: 2)])
        // A live segment that covers the checkpoint is jumped over; the tail is clamped.
        #expect(plan(durable: 3, total: 6, live: [(2, 2)])
            == [StaticRangeSegmentPlan(offset: 4, length: 2)])
        #expect(plan(durable: 3, total: 4, live: []) == [StaticRangeSegmentPlan(offset: 3, length: 1)])
    }

    /// `Reattach` and `DrainPass` with `SegBytes > 1`: a segment ahead of the checkpoint is
    /// adopted on any grid, one that starts behind it is not, and a held body that overlaps the
    /// checkpoint without starting on it is discarded, never appended.
    @Test("Model rule: recovery from a partial append adopts ahead, rejects behind, discards overlap")
    func partialAppendRecoveryRules() throws {
        let attempt = try #require(DownloadAttemptID(rawValue: "attempt-A"))
        func disposition(offset: Int, durable: Int) -> StaticRangeReattachDisposition {
            StaticRangeReattachPolicy.plan(
                taskIdentifier: 7, downloadID: "plex-item", durableBytes: durable,
                requestedOffset: offset, rangeRequestShape: .closed, bodyBytesWritten: 0,
                existingTasks: [],
                taskMarker: StaticRangeSegmentMarker.taskDescription(
                    ratingKey: "plex-item", offset: offset, attemptID: attempt),
                rowAttemptID: attempt).disposition
        }
        // Checkpoint 3 after a partial append of [2, 4): the old grid is 0, 2, 4, ...
        #expect(disposition(offset: 4, durable: 3) == .adopt)
        #expect(disposition(offset: 3, durable: 3) == .adopt)
        #expect(disposition(offset: 2, durable: 3)
            == .rejectOffsetMismatch(requestedOffset: 2, durableBytes: 3))

        let run = StaticRangeSegmentAssemblyPolicy.appendableRun(
            durableBytes: 3, stashedSegments: [(offset: 2, length: 2), (offset: 4, length: 2)])
        #expect(run.append.isEmpty)
        #expect(run.discard.map(\.offset) == [2])
        #expect(run.hold.map(\.offset) == [4])
    }

    /// `Apply` and `Usable`: a pause halt keeps a finished body, a cancel halt discards it, and a
    /// body whose train epoch has passed is never applied (Mutant-NoEpochCheck).
    @Test("Model rule: halts and train epochs decide a finished body's fate")
    func finishedBodyDisposition() {
        #expect(StaticRangeFinishedBodyPolicy.disposition(haltKind: .pause) == .writeThenPause)
        #expect(StaticRangeFinishedBodyPolicy.disposition(haltKind: .cancel) == .discardTemp)
        #expect(StaticRangeFinishedBodyPolicy.disposition(haltKind: nil) == .writeThenContinue)
        #expect(StaticRangeFinishedBodyPolicy.shouldDiscardBeforeStash(haltKind: .cancel))
        #expect(!StaticRangeFinishedBodyPolicy.shouldDiscardBeforeStash(haltKind: .pause))
        #expect(!StaticRangeTrainIntegrityPolicy.shouldProcessFinishedBody(
            bodyTrainEpoch: 0, currentTrainEpoch: 1))
        #expect(StaticRangeTrainIntegrityPolicy.terminalFailureTeardown().advanceTrainEpoch)
        #expect(StaticRangeTrainIntegrityPolicy.teardownActions(for: .changedResourceRestart)
            == .init(supersedeInFlightTasks: true, purgeHeldSegments: true, advanceTrainEpoch: true))
    }

    /// `AppendsAligned` (Mutant-NoAlignment): an append is allowed only at the body's own offset.
    @Test("Model rule: a body is appended only at its own offset")
    func appendsStayAligned() {
        #expect(StaticRangeTrainIntegrityPolicy.preAppendDecision(
            bodyTrainEpoch: 2, currentTrainEpoch: 2, durableBytes: 5, baseOffset: 5) == .append)
        #expect(StaticRangeTrainIntegrityPolicy.preAppendDecision(
            bodyTrainEpoch: 2, currentTrainEpoch: 2, durableBytes: 4, baseOffset: 5)
            == .discardOffsetDrift)
        #expect(StaticRangeTrainIntegrityPolicy.preAppendDecision(
            bodyTrainEpoch: 1, currentTrainEpoch: 2, durableBytes: 5, baseOffset: 5)
            == .discardStaleTrain)
    }

    /// Faithful-B03-off and Faithful-B22-off: the sweeps' file-name rules alone would delete the
    /// body of a task that just finished, so the claim the session takes is what protects it.
    @Test("Model rule: only a claim protects a finished body from the orphan sweep (B03, B22)")
    func sweepRuleNeedsTheClaim() {
        let stash = BackgroundTempFileCleanupPolicy.rangeBodyStashPrefix + "7-o1"
        #expect(BackgroundTempFileCleanupPolicy.shouldDeleteRangeBodyStash(
            fileName: stash, liveTaskIdentifiers: []))
        #expect(!BackgroundTempFileCleanupPolicy.shouldDeleteRangeBodyStash(
            fileName: stash, liveTaskIdentifiers: [7]))
    }

    /// Faithful-B00-off and Faithful-B00-off-NoSelfHeal (852e9f7f): the manager's retry policy
    /// and its stale-row detector measure the attempt working partial. Measured at the published
    /// path (the old behaviour, `partial: nil` here) Resume sees no checkpoint and replaces the
    /// attempt (`UserResume`), and the self-heal never fires (`StaleRowHeal`). The detector also
    /// leaves a row alone while the session owns work for it. Store reconcile was never part of
    /// B00: it has always measured the working file.
    @Test("Model rule: recovery measures the working partial and respects session work (B00)")
    func recoveryMeasuresTheWorkingPartial() {
        let working = URL(fileURLWithPath: "/tmp/.attempt-stage-working.stage")
        let record = DownloadRecord(
            ratingKey: "plex-item", title: "Item",
            localURL: URL(fileURLWithPath: "/tmp/published.mp4"), bytes: 10, progress: 0.4,
            status: .downloading,
            metadata: OfflineMetadata(ratingKey: "plex-item", title: "Item", type: "movie",
                                      downloadLane: .original, resumeMode: .staticByteRange))
        func stale(active: Bool, partial: URL?) -> Bool {
            DownloadRetryPolicy.shouldDemoteStaleQueuedStaticPartial(
                record, isActive: active, durablePartialURL: partial,
                fileExists: { $0 == working }, fileSize: { $0 == working ? 10 : nil })
        }
        #expect(stale(active: false, partial: working))
        #expect(!stale(active: true, partial: working))
        #expect(!stale(active: false, partial: nil))

        var paused = record
        paused.status = .paused
        func keepsCheckpoint(partial: URL?) -> Bool {
            DownloadRetryPolicy.shouldPromotePausedStaticPartial(
                paused, durablePartialURL: partial,
                fileExists: { $0 == working }, fileSize: { $0 == working ? 10 : nil })
        }
        #expect(keepsCheckpoint(partial: working))
        #expect(!keepsCheckpoint(partial: nil))

        // The reducer keeps a row with a durable partial and fails one without.
        let transferring = DownloadLifecycleState(lifecycle: .transferring)
        let kept = R.reduce(transferring, .relaunchObserved,
                            facts: DownloadRowFacts(route: .staticRange,
                                                    checkpoint: .durablePartial(bytes: 10)))
        #expect(kept.state?.lifecycle == .paused)
        #expect(!kept.effects.contains(.deleteWorkingBody))
    }

    // MARK: Findings

    /// R1. Two held bodies are contiguous with the checkpoint, at offsets 1 and 2 of a
    /// three-segment file. A drain pass appends the first and submits its manifest removal, which
    /// is asynchronous, so the pass stops there. The removal's completion runs the next pass,
    /// which appends the second body and completes the file, and then discards the result: it
    /// neither finalizes nor asks the planner for the next segment. The row stays `transferring`
    /// with no task and no queued work until the manager's stale-row self-heal restarts it.
    /// The two bodies are held together when the train's continuation is deferred, which is the
    /// case for every task adopted after a relaunch (its entry has no request).
    @Test("R1: a drain run by a held-body removal continues the train")
    func removalCompletionDrainContinuesTheTrain() throws {
        // The policies on either side of the gap. Both bodies are appendable in order...
        let run = StaticRangeSegmentAssemblyPolicy.appendableRun(
            durableBytes: 1, stashedSegments: [(offset: 1, length: 1), (offset: 2, length: 1)])
        #expect(run.append.map(\.offset) == [1, 2])
        // ...and with both held the planner has nothing to enqueue, so no task remains whose
        // finish would continue the train after the drain.
        let plans = StaticRangeSegmentQueuePolicy.segmentsToEnqueue(
            durableBytes: 2, expectedBytes: 3,
            liveSegments: [StaticRangeSegmentPlan(offset: 1, length: 1),
                           StaticRangeSegmentPlan(offset: 2, length: 1)],
            segmentBytes: 1, maxQueuedSegments: 2)
        #expect(plans.isEmpty)

        let removal = try #require(Self.appFunctionSource(
            named: "removeHeldRangeSegments", in: Self.sessionSource))
        #expect(removal.contains("drainHeldRangeSegments("))
        withKnownIssue("TLA+ finding R1 (#477): a removal-completion drain strands the train") {
            // The completion drops the size the drain reached. The fixed completion uses it
            // to finalize a whole file or to continue the train, as the append path does.
            let discardsDrainResult = removal.contains("_ = self.drainHeldRangeSegments(")
            #expect(!discardsDrainResult,
                    "the removal completion drains and then neither finalizes nor re-plans")
        }
    }

    /// R2. A segment task finishes; the delegate stashes its body, drops the task from live
    /// tracking and queues the append. The app returns to the foreground (or was just relaunched)
    /// and reattach hands reconcile its live keys, which are the tracked tasks only. The row has
    /// none, and no durable bytes yet, so `relaunchObserved` fails it and deletes its working
    /// file; the queued append then has nothing to open and the body is discarded. For a file of
    /// one segment that is the whole download. The stale-row self-heal already counts this work
    /// (`ownsInProgressStaticRangeWork`, B00); reconcile does not. The live keys are a snapshot:
    /// reattach takes it, and reconcile uses it later on another queue.
    @Test("R2: reconcile does not fail a row whose finished body is queued for append")
    func reconcileCountsQueuedBodiesAsLiveWork() throws {
        // The reducer does what the facts say: with no live task and no checkpoint the row is
        // dead, and with a live task it is left alone.
        let transferring = DownloadLifecycleState(lifecycle: .transferring)
        let dead = R.reduce(transferring, .relaunchObserved,
                            facts: DownloadRowFacts(route: .staticRange))
        #expect(dead.state?.lifecycle == .failed)
        #expect(dead.effects.contains(.deleteWorkingBody))
        let live = R.reduce(transferring, .relaunchObserved,
                            facts: DownloadRowFacts(route: .staticRange, liveTask: true))
        #expect(live.state?.lifecycle == .transferring)
        #expect(live.effects.isEmpty)

        // Where the evidence is taken. Reattach builds the live keys on the delegate queue and
        // hands them over; reconcile runs later on a store worker and reads only that set.
        let reattach = try #require(Self.appFunctionSource(
            named: "reattachToResumedTasks", in: Self.sessionSource))
        #expect(reattach.contains("liveKeys.insert("))
        #expect(reattach.contains("onReattached?(liveKeys)"))
        let reconcile = try #require(Self.appFunctionSource(
            named: "reconcileOnWorker", in: Self.storeSource))
        withKnownIssue("TLA+ finding R2 (#476): reconcile fails a row whose finished body is queued") {
            // Adding session-owned work to the keys reattach builds is not enough
            // (Finding-R2-SnapshotFixLeavesWindow): a finished task the daemon redelivers between
            // reattach and reconcile queues its body after the snapshot. Reconcile has to ask
            // the session for owned work when it decides, as the stale-row self-heal does, so
            // its live-task fact cannot be the snapshot alone.
            let snapshotOnly = reconcile.contains("let hasLiveTask = liveRatingKeys.contains(ratingKey)")
            #expect(!snapshotOnly,
                    "reconcile decides from the reattach snapshot, not from session-owned work now")
        }
    }

    /// R3. A segment finishes in the daemon while a user pause is landing. The pause snapshots the
    /// row's task IDs and installs the halt; its `getAllTasks` completion then runs
    /// `pauseRangeTask` for every listed task, which removes the task's tracking and marks its
    /// identifier superseded. A task that has finished but whose finish callback is queued behind
    /// that completion is still listed. Its callback then sees `superseded` and returns, so the
    /// body, which `writeThenPause` exists to keep, is dropped with the OS temp file. On a train
    /// that is one segment to fetch again; on the open-ended fallback it is the whole remainder.
    @Test("R3: a pause keeps a segment that has already finished")
    func pauseKeepsAFinishedSegment() throws {
        // The decision the design states: a finished body under a pause halt is written.
        #expect(StaticRangeFinishedBodyPolicy.disposition(haltKind: .pause) == .writeThenPause)
        #expect(!StaticRangeFinishedBodyPolicy.shouldDiscardBeforeStash(haltKind: .pause))

        let pauseTask = try #require(Self.appFunctionSource(
            named: "pauseRangeTask", in: Self.sessionSource))
        #expect(pauseTask.contains("rangeInflight.removeValue(forKey: task.taskIdentifier)"))
        withKnownIssue("TLA+ finding R3 (#474): a pause supersedes a finished segment") {
            // The sweep supersedes every listed task without asking whether it has finished.
            // The fixed sweep leaves a finished task tracked (or routes its body through the
            // finished-body path), so `writeThenPause` gets to run.
            let supersedesUnconditionally = pauseTask.contains(
                "supersededRangeTaskIdentifiers.insert(task.taskIdentifier)")
                && !pauseTask.contains(".completed")
                && !pauseTask.contains("countOfBytesExpectedToReceive")
            #expect(!supersedesUnconditionally,
                    "pauseRangeTask supersedes a task whose finish callback is already queued")
        }
    }

    /// R4. Two-byte segments, depth two. The process dies in the middle of an append, so the
    /// checkpoint (1) is inside the old grid, and the daemon finishes segment [2, 4) while the app
    /// is dead. On relaunch the planner knows nothing of that finished task and starts [1, 3) and
    /// [3, 5). The finished task is then redelivered and its body is held, as is [3, 5) when it
    /// finishes. The head task [1, 3) fails once. The planner now counts the two held bodies
    /// against its depth of two and plans nothing, although neither covers the checkpoint, so the
    /// gap they wait for is never fetched: a restart of the row plans nothing again, and a
    /// relaunch restores both manifests.
    @Test("R4: held bodies never keep the planner from fetching the gap at the checkpoint")
    func plannerAlwaysFetchesTheHeadGap() {
        let held = [StaticRangeSegmentPlan(offset: 2, length: 2), StaticRangeSegmentPlan(offset: 3, length: 2)]
        // The assembly side: neither held body is appendable at checkpoint 1.
        let run = StaticRangeSegmentAssemblyPolicy.appendableRun(
            durableBytes: 1, stashedSegments: held.map { (offset: $0.offset, length: $0.length ?? 0) })
        #expect(run.append.isEmpty)
        #expect(run.hold.map(\.offset) == [2, 3])
        withKnownIssue("TLA+ finding R4 (#492): held bodies fill the depth and starve the head gap") {
            let plans = StaticRangeSegmentQueuePolicy.segmentsToEnqueue(
                durableBytes: 1, expectedBytes: 6, liveSegments: held,
                segmentBytes: 2, maxQueuedSegments: 2)
            #expect(plans.first == StaticRangeSegmentPlan(offset: 1, length: 1),
                    "nothing is planned for [1, 2), so the two held bodies wait for ever")
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
              let start = source.range(of: "    private func \(name)(")
                ?? source.range(of: "    func \(name)(") else { return nil }
        let rest = source[start.upperBound...]
        let end = ["\n    private func ", "\n    func "]
            .compactMap { rest.range(of: $0)?.lowerBound }.min() ?? rest.endIndex
        return String(source[start.lowerBound..<end])
    }
}
