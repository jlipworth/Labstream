# DownloadsRangeTrain: module notes

`DownloadsRangeTrain.tla` models the static-range lane of the downloads session: a train of
parallel segment tasks, bodies that finish out of order and are held on disk under a durable
manifest, in-order assembly into the working file, the two orphan sweeps, and recovery of the
checkpoint after process death. It extends the pilot's static lane (`DownloadsSessionCore.tla`),
which fetches two segments one after the other and holds nothing.

Run it with:

```sh
TLC_WORKERS=2 TLC_HEAP=2g scripts/check-tla-specs.sh specs/downloads/DownloadsRangeTrain.tla
TLC_WORKERS=2 TLC_HEAP=2g scripts/check-tla-specs.sh specs/downloads/RangeTrain-Deep-*.cfg
swift test --package-path PMSKit --no-parallel --filter DownloadsFormalModelRangeTrainTests
```

## What is modelled

A file is `NSeg` segments. A body is `<<attempt, offset>>`: the response of the segment task that
attempt started for that offset. The working file is `dur` segments long.

| Model | Swift |
| --- | --- |
| `Plan`, `Covered`, `PlanSet` | `startRangeRemainder`, `StaticRangeSegmentQueuePolicy.segmentsToEnqueue`, `StaticRangeTransferConfiguration.maxQueuedSegments` |
| `DidFinishDownloading` | `finishRangeRemainder`, `adoptFinishedRangeSegment` (the stash, the claim, the queued apply) |
| `DidCompleteWithError`, `TerminalFail` | the transient retry path, `setFailedPurgingHeldSegments` |
| `Apply`, `Usable`, `Continue` | `applyFinishedRangeBody`, `StaticRangeFinishedBodyPolicy`, `StaticRangeTrainIntegrityPolicy.shouldProcessFinishedBody` and `preAppendDecision`, `continueRangeAfterBody` |
| `HoldManifested` | `submitHeldRangeSegment` and its completion |
| `DrainPass`, `RetireDone` | `drainHeldRangeSegments`, `StaticRangeSegmentAssemblyPolicy.appendableRun`, `removeHeldRangeSegments` |
| `PurgeHeld`, `FinalizeWhole` | `purgeHeldRangeSegments`, `finalizeRangeWhole` |
| `ResourceChanged` | `restartRangeFromChangedResource` |
| `UserPause`, `PauseSweep`, `UserResume`, `UserRetry` | `pause`, `pauseRangeTask`, resume and Retry of a static row |
| `Reattach` | `reattachToResumedTasks`: `restoreHeldRangeSegments`, adoption, `sweepOrphanedRangeBodyStashes`, `sweepOrphanedDurableHeldRangeSegments`, the live-key snapshot |
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
| `NSeg` | 3 | enough for two held bodies behind a missing head |
| `Depth` | 2 | the shipping `maxQueuedSegments` |
| `MaxAttempt` | 1 or 2 | 2 adds a terminal failure and a Retry that inherits the checkpoint |
| `MaxRestarts` | 0 or 1 | 1 adds one changed-resource restart |

## Properties

| Property | Kind | Says |
| --- | --- | --- |
| `AppendsAligned` | invariant | Every body is appended at its own offset. |
| `StaleTrainBodyInert` | invariant | A body whose train was torn down is never appended or held. |
| `QueuedBodyNotSwept` | invariant | A stash whose apply is queued is never unlinked (B03). |
| `HeldBodyNotSweptBeforeManifest` | invariant | A held body is never swept between its rename and its manifest (B22). |
| `ManifestedBodyExists`, `HeldBodyExists` | invariant | A manifest, and a held-map entry the session may drain, name a file that exists. |
| `FinalizingHasBody`, `CompleteIsWhole` | invariant | A finalizing or playable row has every segment. |
| `CheckpointNeverDiscarded` | action | The working file shrinks only when the source changed (B00). |
| `PlannerRespectsDepth` | action | After a step that starts a task, at most `Depth` offsets are covered. |
| `NoStartWhileUserPaused` | action | Nothing starts a task for a user-paused row. |
| `PauseKeepsHeldBodies` | action | While a row stays user-paused, a held body leaves the disk only by being appended. |
| `TrainNeverStranded` | invariant | An active, unhalted row always has session work (R1; fails today). |
| `ReconcileKeepsQueuedBody` | action | Reconcile never fails a row whose finished body is queued (R2; fails today). |
| `ReconcileNeverFailsOwnedWork` | action | The general form of R2; holds only with the proposed fix. |
| `AdmittedEventuallyStable` | liveness | An admitted row reaches a terminal or user-paused state. |

## Configs and results

2026-11-24, tla2tools v1.7.4, `TLC_WORKERS=2 TLC_HEAP=2g`.

| Config | Expect | Result | Distinct states | Time |
| --- | --- | --- | --- | --- |
| `RangeTrain-Current-Train` | pass | pass | 7,300 | 1 s |
| `RangeTrain-Current-Retry` | pass | pass | 276,284 | 11 s |
| `RangeTrain-Current-Restart` | pass | pass | 42,005 | 3 s |
| `RangeTrain-Current-FourSegments` | pass | pass | 11,479 | 1 s |
| `RangeTrain-Liveness-Train` | pass | pass | 20,461 | 5 s |
| `RangeTrain-Proposed-Train` | pass | pass | 6,548 | 1 s |
| `RangeTrain-Faithful-B00-off` | `CheckpointNeverDiscarded` violated | violated | stops at first error | 1 s |
| `RangeTrain-Faithful-B03-off` | `QueuedBodyNotSwept` violated | violated | stops at first error | < 1 s |
| `RangeTrain-Faithful-B22-off` | `HeldBodyNotSweptBeforeManifest` violated | violated | stops at first error | 1 s |
| `RangeTrain-Mutant-NoAlignment` | `AppendsAligned` violated | violated | stops at first error | < 1 s |
| `RangeTrain-Mutant-NoEpochCheck` | `StaleTrainBodyInert` violated | violated | stops at first error | 1 s |
| `RangeTrain-Finding-R1-StrandedDrain` | `TrainNeverStranded` violated | violated | stops at first error | 1 s |
| `RangeTrain-Finding-R2-ReconcileFailsQueuedBody` | `ReconcileKeepsQueuedBody` violated | violated | stops at first error | < 1 s |
| `RangeTrain-Deep-RetryRestart` (deep) | pass | pass | 2,908,252 | 111 s |
| `RangeTrain-Deep-TwoRows` (deep, symmetry) | pass | pass | 4,182,753 | 205 s |

### Faithfulness

- **B00 off** (recovery measures the checkpoint at the published path). A segment is appended, the
  second task finishes, the process dies. On relaunch nothing is live and the facts report no
  checkpoint, so the reducer fails the row and deletes the working partial. With the fix off the
  stale-row self-heal also never fires, because it never sees a checkpoint.
- **B03 off** (the stash sweep ignores claims). A segment finishes and its body is stashed with
  the apply queued; the app returns to the foreground; reattach sweeps the stash because its task
  is no longer live.
- **B22 off** (no claim on the durable held path). An out-of-order body is renamed to its held
  path; the app returns to the foreground before the manifest is committed; the held-body sweep
  finds a file no manifest names and deletes it.
- **Mutant-NoAlignment** and **Mutant-NoEpochCheck** are injected bugs, not historical ones. The
  train epoch and the offset checks have no entry in the B00 to B87 table.

## Findings

### R1: a drain run by a held-body removal strands the train

Issue: #477.

Trace (`RangeTrain-Finding-R1-StrandedDrain`), a three-segment file, depth two:

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
stale-row self-heal restarts it at its next refresh, so `RangeTrain-Liveness-Train` passes; a
background wake that ends first leaves the download idle until the app is next in the foreground.

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

Trace (`RangeTrain-Finding-R2-ReconcileFailsQueuedBody`), a one-segment file:

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
Proposed fix (`FixReconcileOwnedWork`): reconcile counts session-owned work of an active row as
live. It must not do so for a paused row, where a live task promotes the row (F2).
Pinned by `DownloadsFormalModelRangeTrainTests.reconcileCountsQueuedBodiesAsLiveWork`.

### Modelling artefacts fixed in the model

- Restore and reattach were two steps. They are one completion block in the code, and the split
  let a plan start a second task for an offset whose held body was not yet restored.
- `DepthBounded` as an invariant on running tasks was too strong: a pause cancels only tracked
  tasks, so an untracked task can outlive it and be adopted later. The property is now
  `PlannerRespectsDepth`, about what the planner starts.
- `HeldBodyExists` is limited to rows that can still drain. After R2 fails a row, a foreground
  restore removes its manifests while the in-memory map keeps the entries.

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
- Two tasks for one offset in one attempt. A task is named by its body, so the duplicate-task
  decisions of reattach are not exercised.
