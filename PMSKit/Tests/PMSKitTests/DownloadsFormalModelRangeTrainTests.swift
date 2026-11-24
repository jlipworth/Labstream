import Foundation
import Testing
@testable import PMSKit

/// The static-range segment train as `specs/downloads/range-train/DownloadsRangeTrain.tla` models it.
///
/// The first tests tie the model's rules to the pure policies it copies, so a policy change that
/// the spec does not follow fails here. The `R1` and `R2` tests are orderings TLC found on the
/// current design (`specs/downloads/range-train/Finding-*.cfg`). Each states the behaviour the
/// design wants and is wrapped in `withKnownIssue`, so the suite stays green while the finding is
/// open. When a fix lands the expectation holds, no issue is recorded, and `withKnownIssue` fails
/// the test: delete the wrapper then, and flip the matching config to `EXPECT: pass`.
///
/// Both findings are decided inline in app code, with no PMSKit policy to call, so they pin the
/// shape of the app source and the pure decisions on either side of it. The fix needs a
/// `LabstreamTests` pin of the session behaviour itself.
@Suite("Downloads formal-model range train")
struct DownloadsFormalModelRangeTrainTests {
    private typealias R = DownloadLifecycleReducer
    private static let sessionSource =
        "Labstream/Capabilities/Downloads/Core/BackgroundDownloadSession.swift"

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

    /// Faithful-B00-off: the checkpoint is the attempt working partial, and the stale-row
    /// self-heal leaves a row alone while the session owns work for it (`StaleRowHeal`).
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
    /// (`ownsInProgressStaticRangeWork`, B00); reconcile does not.
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

        let reattach = try #require(Self.appFunctionSource(
            named: "reattachToResumedTasks", in: Self.sessionSource))
        #expect(reattach.contains("liveKeys.insert("))
        withKnownIssue("TLA+ finding R2 (#476): reconcile fails a row whose finished body is queued") {
            // The live keys reconcile receives must include a row with a queued append, a delayed
            // retry or a claimed finalizer, as the stale-row self-heal's check does.
            let countsSessionWork = reattach.contains("pendingStaticRangeWorkCounts")
                || reattach.contains("ownsLiveOrPendingStaticRangeWork")
                || reattach.contains("ownsInProgressStaticRangeWork")
            #expect(countsSessionWork,
                    "reattach reports only tracked tasks as live, not session-owned work")
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
