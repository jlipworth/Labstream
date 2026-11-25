# DownloadsRangeTrain: module notes

`DownloadsRangeTrain.tla` models the static-range lane of the downloads session: a train of
parallel segment tasks, bodies that finish out of order and are held on disk under a durable
manifest, in-order assembly into the working file, the two orphan sweeps, and recovery of the
checkpoint after process death, including a death in the middle of an append. It extends the pilot's static lane (`DownloadsSessionCore.tla`),
which fetches two segments one after the other and holds nothing.

Run it with:

```sh
TLC_WORKERS=2 TLC_HEAP=2g scripts/check-tla-specs.sh specs/downloads/range-train/DownloadsRangeTrain.tla
TLC_WORKERS=2 TLC_HEAP=2g scripts/check-tla-specs.sh specs/downloads/range-train/Deep-*.cfg
swift test --package-path PMSKit --no-parallel --filter DownloadsFormalModelRangeTrainTests
```

## What is modelled

A file is `NSeg` segments of `SegBytes` units ("bytes") each. A body is
`<<attempt, offset, length>>`: the response of the segment task that attempt started for that byte
range. The working file is `dur` bytes long. An append is atomic except at a crash:
`CrashMidAppend` leaves any proper prefix of the body in the working file, as the code's 4 MiB
writes can. With `SegBytes = 1` the model is segment-granular, which is what the configs without
`MidAppend` in their name use.

| Model | Swift |
| --- | --- |
| `Plan`, `LiveBodies`, `PlanFrom`, `PlanSet` | `startRangeRemainder`, `StaticRangeSegmentQueuePolicy.segmentsToEnqueue` (coverage by interval, gap fillers), `StaticRangeTransferConfiguration.maxQueuedSegments` and `segmentBytes` |
| `CrashMidAppend` | a kill inside `appendRangeBody`'s write loop |
| `DidFinishDownloading` | `finishRangeRemainder`, `adoptFinishedRangeSegment` (the stash, the claim, the queued apply) |
| `DidCompleteWithError`, `TerminalFail` | the transient retry path, `setFailedPurgingHeldSegments` |
| `Apply`, `Usable`, `Continue` | `applyFinishedRangeBody`, `StaticRangeFinishedBodyPolicy`, `StaticRangeTrainIntegrityPolicy.shouldProcessFinishedBody` and `preAppendDecision`, `continueRangeAfterBody` (with its wake-winding-down branch, `WakeWindsDown`) |
| `HoldManifested` | `submitHeldRangeSegment` and its completion |
| `DrainPass`, `RetireDone` | `drainHeldRangeSegments`, `StaticRangeSegmentAssemblyPolicy.appendableRun`, `removeHeldRangeSegments` |
| `PurgeHeld`, `FinalizeWhole` | `purgeHeldRangeSegments`, `finalizeRangeWhole` |
| `ResourceChanged` | `restartRangeFromChangedResource` |
| `UserPause`, `PauseSweep`, `UserResume`, `UserRetry` | `pause`, `pauseRangeTask` (it supersedes every listed task, a finished one too), resume (`DownloadRetryPolicy.shouldPromotePausedStaticPartial`, B00) and Retry of a static row |
| `Reattach` | `reattachToResumedTasks`: `restoreHeldRangeSegments`, adoption (`StaticRangeReattachPolicy`: ahead of the checkpoint on any grid; a rejected task makes the row live and asks for a rebuild), `sweepOrphanedRangeBodyStashes`, `sweepOrphanedDurableHeldRangeSegments`, the live-key snapshot |
| `RelaunchObserved`, `RelaunchFacts` | `DownloadStore.reconcileOnWorker`, `observeLifecycleFacts` |
| `StaleRowHeal`, `SessionOwnsWork` | `DownloadManager.refreshRecords`, `DownloadRetryPolicy.shouldDemoteStaleQueuedStaticPartial`, `ownsInProgressStaticRangeWork` |

Durable state is the row (a whole reducer state, the owner attempt, the held manifests), the files
(working file length, published body, `tmp/` stashes, held files) and the daemon's tasks. Everything
else is in memory and is reset by `Crash`. Lifecycle changes only through `Reduce`; the module has
no hand-written transition and needs no projection config.

The stash and claim design behind F1 has three stages here, each with its own protection:

1. `tmp/` stash, claimed by the queued apply (in memory). The stash sweep honours the claim (B03).
2. Durable held file after the rename, claimed by the hold in flight (in memory). The held-body
   sweep honours the claim (B22).
3. Manifest in the row (durable). The sweep sees the reference, and a relaunch restores the body.

A crash in stage 1 or 2 loses one segment body, which is fetched again. That is the same shape as
F1, but the lost body is one segment of a resumable file and not a finished download, so it is not
a finding on this lane. The whole-file loss on this lane is R2 below.

## Bounds

| Constant | Default configs | Meaning |
| --- | --- | --- |
| `Rows` | one row | all rows are static; `RowSymmetry` is sound for safety runs |
| `NSeg` | 3 (2 in the `MidAppend` configs) | enough for two held bodies behind a missing head |
| `SegBytes` | 1 (2 in the `MidAppend` configs) | 2 lets a crash leave the checkpoint inside a segment |
| `Depth` | 2 | the shipping `maxQueuedSegments` |
| `MaxAttempt` | 1 or 2 | 2 adds a terminal failure and a Retry that inherits the checkpoint |
| `MaxRestarts` | 0 or 1 | 1 adds one changed-resource restart |

## Properties

| Property | Kind | Says |
| --- | --- | --- |
| `AppendsAligned` | invariant | Every body is appended at its own offset. |
| `StaleTrainBodyInert` | invariant | A body whose train was torn down is never appended or held. |
| `QueuedBodyNotSwept` | invariant | A stash whose apply is queued is never unlinked (B03). |
| `HeldBodyNotSweptBeforeManifest` | invariant | A held body the checkpoint has not passed is never swept between its rename and its manifest (B22). |
| `ManifestedBodyExists`, `HeldBodyExists` | invariant | A manifest, and a held-map entry the session may still append, name a file that exists. |
| `FinalizingHasBody`, `CompleteIsWhole` | invariant | A finalizing or playable row has every byte. |
| `TrainNeverWedged` | invariant | An active row with an unfinished file, no task and nothing queued can always plan its next segment (R4; fails today with `SegBytes = 2`). |
| `CheckpointNeverDiscarded` | action | The working file shrinks only when the source changed (B00). |
| `PlannerRespectsDepth` | action | After a step that starts a task, at most `Depth` segments are live. |
| `PlannerFillsGapsOnly` | action | A segment the planner starts begins at or ahead of the checkpoint and overlaps no live segment of the attempt, on whatever grid that one was planned. |
| `NoStartWhileUserPaused` | action | Nothing starts a task for a user-paused row. |
| `PauseKeepsHeldBodies` | action | While a row stays user-paused, a held body leaves the disk only by being appended. |
| `PauseKeepsFinishedSegment` | action | A tracked segment that has finished in the daemon stays finished or reaches the stash while the pause stands (R3; fails today). |
| `TrainNeverStranded` | invariant | An active, unhalted row always has session work (R1; fails today). |
| `ReconcileKeepsQueuedBody` | action | Reconcile never fails a row whose finished body is queued (R2; fails today). |
| `ReconcileNeverFailsOwnedWork` | action | The general form of R2; holds only with the reconcile-time fix. |
| `ReconcileKeepsUndeliveredBody` | action | Reconcile never fails a row while the daemon holds a finished, undelivered task of its attempt (R2; fails with either fix). |
| `AdmittedEventuallyStable` | liveness | An admitted row reaches a terminal or user-paused state. |

### What the liveness runs assume

`Fairness` is three named assumptions, and the code can promise none of them by itself:

- `SessionFairness`: the session, delegate-queue and range-IO steps run, and the daemon resolves
  every task. True while the process runs or the daemon can wake it.
- `NetworkFairness`: a segment that keeps being retried eventually finishes. The code has a retry
  budget instead; the model does not count it, so without this assumption a segment could fail and
  be retried for ever. With `AllowFailure` the row may also fail, which is a stable end.
- `ForegroundFairness`: the manager's stale-row self-heal and auto-resume run. Both are driven by
  `DownloadManager.refreshRecords` and the foreground resume pass on the main actor, gated on the
  queue not being paused, a backend session and no pending resume intent. A suspended background
  app runs neither. `Mutant-NoForegroundRefresh` (`BackgroundFairSpec`) drops this assumption, and
  the stranded train of R1, or one whose background wake wound down before it refilled
  (`WakeWindsDown`), then never moves.

## Configs and results

2026-11-24, tla2tools v1.7.4, `TLC_WORKERS=2 TLC_HEAP=2g`.

| Config | Expect | Result | Distinct states | Time |
| --- | --- | --- | --- | --- |
| `Current-FourSegments` | pass | pass | 11,408 | 1 s |
| `Current-MidAppend` | pass | pass | 431,165 | 19 s |
| `Current-Restart` | pass | pass | 18,940 | 1 s |
| `Current-Retry` | pass | pass | 243,453 | 10 s |
| `Current-Train` | pass | pass | 7,192 | 1 s |
| `Liveness-Train` | pass | pass | 20,175 | 5 s |
| `Proposed-Liveness-MidAppend` | pass | pass | 65,352 | 78 s |
| `Proposed-MidAppend` | pass | pass | 429,298 | 19 s |
| `Proposed-Train` | pass | pass | 6,436 | 1 s |
| `Faithful-B00-off` | `CheckpointNeverDiscarded` violated | violated | stops at first error | 1 s |
| `Faithful-B00-off-NoSelfHeal` | `AdmittedEventuallyStable` (liveness) violated | violated | stops at first error | 8 s |
| `Faithful-B03-off` | `QueuedBodyNotSwept` violated | violated | stops at first error | 1 s |
| `Faithful-B22-off` | `HeldBodyNotSweptBeforeManifest` violated | violated | stops at first error | < 1 s |
| `Mutant-NoAlignment` | `AppendsAligned` violated | violated | stops at first error | 1 s |
| `Mutant-NoEpochCheck` | `StaleTrainBodyInert` violated | violated | stops at first error | 1 s |
| `Mutant-NoForegroundRefresh` | `AdmittedEventuallyStable` (liveness) violated | violated | stops at first error | 4 s |
| `Mutant-OffsetEqualityPlan` | `PlannerFillsGapsOnly` violated | violated | stops at first error | < 1 s |
| `Finding-R1-StrandedDrain` | `TrainNeverStranded` violated | violated | stops at first error | 1 s |
| `Finding-R2-ReconcileFailsQueuedBody` | `ReconcileKeepsQueuedBody` violated | violated | stops at first error | 1 s |
| `Finding-R2-SnapshotFixLeavesWindow` | `ReconcileKeepsQueuedBody` violated | violated | stops at first error | 1 s |
| `Finding-R2-UndeliveredBodyLost` | `ReconcileKeepsUndeliveredBody` violated | violated | stops at first error | < 1 s |
| `Finding-R3-PauseDropsFinishedSegment` | `PauseKeepsFinishedSegment` violated | violated | stops at first error | 1 s |
| `Finding-R4-HeldBodiesStarveHead` | `TrainNeverWedged` violated | violated | stops at first error | 2 s |
| `Deep-RetryRestart` (deep) | pass | pass | 613,306 | 23 s |
| `Deep-TwoRows` (deep) | pass | pass | 4,182,753 | 216 s |

### Faithfulness and mutants

- **B00 off** (852e9f7f: the manager's retry policy and stale-row detector measure the published
  path). Two configs, one per half of the fix. `Faithful-B00-off`: a paused row with a partial is
  resumed; `shouldPromotePausedStaticPartial` sees no checkpoint, so Resume replaces the attempt
  and deletes the partial. `Faithful-B00-off-NoSelfHeal`: a liveness run; the stale-row detector
  never sees a checkpoint and never fires, so a stranded train stays `transferring` for ever.
  Store reconcile was never part of B00 and measures the working partial in every config; the
  first version of this model switched the wrong component off.
- **B03 off** (the stash sweep ignores claims). A segment finishes and its body is stashed with
  the apply queued; the app returns to the foreground; reattach sweeps the stash because its task
  is no longer live.
- **B22 off** (no claim on the durable held path). An out-of-order body is renamed to its held
  path; the app returns to the foreground before the manifest is committed; the held-body sweep
  finds a file no manifest names and deletes it.
- **Mutant-NoAlignment** and **Mutant-NoEpochCheck** are injected bugs, not historical ones. The
  train epoch and the offset checks have no entry in the B00 to B87 table.
- **Mutant-OffsetEqualityPlan** (`IntervalAwarePlan = FALSE`, `SegBytes = 2`): the planner judges
  coverage by offset equality and plans full-size segments from the checkpoint. After a crash in
  the middle of an append it starts a segment that overlaps an adopted one
  (`PlannerFillsGapsOnly`). This is the check that fails if interval-aware gap filling is removed.
- **Mutant-NoForegroundRefresh**: see the liveness assumptions above.

## Findings

### R1: a drain run by a held-body removal strands the train

Issue: #477.

Trace (`Finding-R1-StrandedDrain`), a three-segment file, depth two:

1. Segments 0 and 1 are in flight. Both finish. The apply of body 1 runs first: it is ahead of the
   checkpoint, so it is renamed to its held path and its manifest is submitted.
2. The apply of body 0 appends it. The held map is still empty, so nothing drains. The planner
   counts body 1's claim as covered and starts segment 2.
3. Body 1's manifest completes and it joins the held map. Its continuation is deferred.
4. Segment 2 finishes. Its body is ahead of the checkpoint (1), so it is held too.
5. The deferred continuation runs. Its drain pass appends body 1 and submits the removal of its
   manifest. The removal is asynchronous, so the pass stops. Both remaining offsets are covered by
   the held map, so the planner starts nothing.
6. The removal completes and runs another drain pass, which appends body 2. The file is whole.
   The completion discards the result. Nothing finalizes the file.

The row is `transferring` with a whole working file, no task and no queued work. With four
segments the same ordering leaves the train idle in the middle of the file. The manager's
stale-row self-heal restarts it at its next refresh, so `Liveness-Train` passes; a
background wake that ends first leaves the download idle until the app is next in the foreground
(`Mutant-NoForegroundRefresh`).

Swift evidence: `BackgroundDownloadSession.swift`, `removeHeldRangeSegments` (the completion calls
`_ = self.drainHeldRangeSegments(...)` and returns), `drainHeldRangeSegments` (the loop breaks once
a removal is submitted, because `removeHeldRangeSegments` returns false), `continueRangeAfterBody`
(`requestNeeded` defers the plan when the entry has no request, which is every task from
`reattachToResumedTasks` and `adoptFinishedRangeSegment`).

Verdict: real. Low severity (the self-heal recovers it; no bytes are lost).
Proposed fix (`FixDrainContinues`): the removal completion finalizes a file its drain completed and
otherwise continues the train, as the append path does.
Pinned by `DownloadsFormalModelRangeTrainTests.removalCompletionDrainContinuesTheTrain`.

### R2: reconcile fails a row whose finished body is queued for append

Issue: #476.

Trace (`Finding-R2-ReconcileFailsQueuedBody`), a one-segment file:

1. The segment task finishes. The delegate moves the body to a `tmp/` stash, drops the task from
   live tracking and queues the append.
2. The app returns to the foreground. Reattach finds no task and reports no live key for the row.
3. Reconcile runs `relaunchObserved` with no live task and no durable bytes. The reducer fails the
   row and deletes its working file.
4. The queued append has no file to open. The body, which is the whole download, is discarded.

The same happens at the first segments of a longer file, and after a relaunch. With durable bytes
the row is parked `deferredResume` instead and resumes, which is the intended recovery. The append
is usually quick, so the window needs the range-IO queue to be busy (it is one serial queue for all
rows) or the relaunch reconcile to run before the finished task's callback.

Swift evidence: `BackgroundDownloadSession.swift`, `reattachToResumedTasks` (live keys are the
matched tasks plus `inflight` and `rangeInflight`; `pendingStaticRangeWorkCounts` is not
consulted); `DownloadStore.swift`, `reconcileOnWorker` (`hasLiveTask = liveRatingKeys.contains`)
and `observeLifecycleFacts` (checkpoint `.none` at zero working bytes);
`DownloadLifecycleReducer.swift`, `relaunch` (the last branch: `failed(.network)` with
`deleteWorkingBody`); `DownloadManager.swift`, `refreshRecords` (the stale-row self-heal does
consult `ownsInProgressStaticRangeWork`, the B00 containment).

Verdict: real, from reading the code; the app-target path was not executed. Medium severity.

The fix has three depths, and the model checks each:

1. **Add session-owned work to the live keys reattach builds** (`FixSnapshotOwnedWork`, the fix
   as first proposed). Not enough: `Finding-R2-SnapshotFixLeavesWindow`. The keys are a snapshot.
   Reattach takes it on the delegate queue; reconcile uses it later on a store worker. After a
   relaunch the daemon redelivers a task that finished while the app was dead; when that callback
   lands between the two, its body is queued after the snapshot and reconcile still fails the row.
   A Resume in the same gap is failed the same way.
2. **Ask the session when reconcile decides** (`FixReconcileOwnedWork`, `Proposed-Train`):
   reconcile's live-task fact is the snapshot or the session's owned work at that moment, read
   under the row's mutation generation so that a row change in between retries the decision. This
   closes every ordering in which the session owns the work. It must not count owned work for a
   paused row, where a live task promotes the row (F2).
3. **A body still in the daemon.** `Finding-R2-UndeliveredBodyLost`: when the finished task's
   callback has not been redelivered at all by the time reconcile runs, the session owns nothing,
   the zero-byte row is failed, and the body is dropped when it arrives (adoption refuses a failed
   row). No ownership check closes this. It needs the row to stay resumable (park a zero-byte
   static row as `deferredResume` on relaunch, since a restart from zero loses nothing) or the
   late body to revive it.

Pinned by `DownloadsFormalModelRangeTrainTests.reconcileCountsQueuedBodiesAsLiveWork`, which now
fails only when reconcile stops deciding from the snapshot alone.

### R3: a pause supersedes a segment that has already finished

Broadens #474 (F3) to the static lane.

Trace (`Finding-R3-PauseDropsFinishedSegment`; the session model has the same one as
`session/Finding-F3-PauseSupersedesFinishedSegment`):

1. A segment task is running. The user pauses. `pause` snapshots the row's task IDs, installs the
   pause halt and asks URLSession for its tasks.
2. The segment finishes in the daemon. Its finish callback is queued on the delegate queue behind
   the task listing's completion, and the listing still holds the task.
3. The completion runs `pauseRangeTask` for it: the task leaves tracking and its identifier is
   marked superseded.
4. The finish callback sees `superseded` and returns. The body goes with the OS temp file.

`pause` says a finish racing the halt "is preserved by the writeThenPause path, so no bytes are
lost"; that holds only when the finish callback runs before the listing's completion. On a train
the cost is one segment fetched again. On the open-ended fallback (unknown total size) the
finished body is the whole remainder.

Swift evidence: `BackgroundDownloadSession.swift`, `pause` (the comment above
`installPauseHaltLocked`), `pauseRangeTask` (`rangeInflight.removeValue` then
`supersededRangeTaskIdentifiers.insert`, with no test of the task's state),
`urlSession(_:downloadTask:didFinishDownloadingTo:)` (`if superseded { ... return }`, before
`finishRangeRemainder`).

Verdict: probable. The code path is plain; that a finished task is still listed by `getAllTasks`
while its callback is queued was not executed. Low severity on a train, medium on the open-ended
fallback.
Proposed fix (`FixPauseKeepsFinished`): the sweep leaves a finished task tracked, or routes its
body through the finished-body path.
Pinned by `DownloadsFormalModelRangeTrainTests.pauseKeepsAFinishedSegment`. Recorded on #474.

### R4: held bodies fill the depth and starve the gap at the checkpoint

Trace (`Finding-R4-HeldBodiesStarveHead`), two-byte segments, depth two:

1. Segments [0, 2) and [2, 4) are in flight. [0, 2) finishes and its append starts. The process
   dies after one byte: the checkpoint is 1. The daemon finishes [2, 4) while the app is dead.
2. Relaunch. Reattach finds no running task, reconcile parks the row and it resumes. The planner
   knows nothing of the finished task and starts [1, 3) and [3, 5).
3. The finished task is redelivered. Its body is ahead of the checkpoint and is held.
4. The head task [1, 3) fails once. [3, 5) finishes and is held.
5. The planner counts live segments against its depth: two held bodies, depth two, nothing left.
   It plans nothing, although neither held body covers the checkpoint.

The row is `transferring` with no task. The stale-row self-heal restarts it and the planner plans
nothing again; a relaunch restores both manifests; a pause and resume keeps the held bodies; the
stall watchdog is forward-only. Only a terminal failure, a changed source or a delete purges them. On the aligned grid the model finds
no such state (`TrainNeverWedged` holds in every `SegBytes = 1` config): it needs a body the
planner did not count, which here is the redelivered one, at an offset the planner would not plan,
which is what an off-grid checkpoint gives.

Swift evidence: `StaticRangeSegmentQueuePolicy.segmentsToEnqueue`
(`budget = maxQueuedSegments - liveSegments.count; guard budget > 0`), called directly by the pin
with the trace's values; `startRangeRemainder` (`if plans.isEmpty { ...; return -1 }`, and held
bodies appended to `liveSegments`); `adoptFinishedRangeSegment` and `StaticRangeReattachPolicy`
(a marked segment ahead of the checkpoint is adoptable on any grid).

Verdict: probable. The policy's answer is executed by the pin; the session path that produces
those inputs was traced by reading, not run. Medium severity (the row never finishes by itself),
rare trigger (a kill inside an append, a segment finished while dead, one transient error).
Proposed fix (`FixHeadGapPlanned`, `Proposed-MidAppend`, `Proposed-Liveness-MidAppend`): the
planner always plans the gap at the checkpoint, whatever the depth left over.
Pinned by `DownloadsFormalModelRangeTrainTests.plannerAlwaysFetchesTheHeadGap`. Issue #492.

### Modelling artefacts fixed in the model

- Restore and reattach were two steps. They are one completion block in the code, and the split
  let a plan start a second task for an offset whose held body was not yet restored.
- `DepthBounded` as an invariant on running tasks was too strong: a pause cancels only tracked
  tasks, so an untracked task can outlive it and be adopted later. The property is now
  `PlannerRespectsDepth`, about what the planner starts.
- `HeldBodyExists` is limited to rows that can still drain, and to bodies the checkpoint has not
  passed. After R2 fails a row, or once a body overlaps the checkpoint, a foreground restore
  removes the manifest while the in-memory map keeps the entry until a drain discards it.
- A teardown (`TerminalFail`, `ResourceChanged`) cancelled only running tasks, so a task that had
  finished in the daemon outlived it and its body was applied to the new train. The code
  supersedes every tracked task; the model now ends them all in the teardown step.
  `ResourceChanged` also ends untracked tasks of the row: their bodies carry the old validator
  and are discarded when they arrive, which a model without validators cannot decide later.
- Store reconcile was switched off with B00. See the faithfulness notes.

## Not covered

- Resource validators (`arrivingBodyDecision`, `heldSpliceDecision`, the unowned-body gate), HTTP
  200 replace-whole, HTTP 416, offset-mismatch retries and their budgets. A changed resource is
  one environment step.
- A purge that overtakes a hold in flight leaves a held-map entry with no file and no manifest.
  The code drops it when the drain's append fails. The model reaches this only after
  `ResourceChanged`, and the three properties about held files are scoped to `restarts = 0`.
- Blob resume of an open-ended remainder, the health-refill lane, path leases, the persistence
  writer (index commits are atomic per step), the background-completion gate and wake budget.
- Delete and the cleanup journal; finalizer verdicts other than `complete`.
- `DownloadLiveRangeProgressPolicy` (progress display) and `DownloadStaticRetryTargetPolicy`
  (which source part a Retry targets) change no state this model tracks.
- Two tasks for one byte range in one attempt. A task is named by its body, so the
  duplicate-task decisions of reattach are not exercised.
- The retry budget. `NetworkFairness` stands in for it in the liveness runs.
- `SegBytes = 2` with three segments is too large to finish (more than ten million states); the
  `MidAppend` configs use two segments, and `Finding-R4` three because it stops at the first error.
- A pause-superseded finished task loses its body in the sweep step itself, not when its callback
  arrives, so a crash between the two (after which the code could still adopt the task) is not an
  ordering the model has.
