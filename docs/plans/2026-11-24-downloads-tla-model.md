# Downloads formal model (TLA+)

**Status (2026-11-24):** the modelling program is done on `specs/downloads-tla`: the pilot (the
session, finalize and sweep core with process death), the shared base W0 (the lifecycle reducer
as shared TLA+ operators, held equal to the Swift by a generated table; a pinned TLC runner with
a default and a deep tier; a drift guard between modelled Swift files and their specs), and the
subsystem models W1 to W8, each with fix-off configs that reproduce fixed bugs. A second round
followed an independent review of the specs against the Swift: every reviewer claim was
re-checked in the Swift and in TLC, the models, properties and runner were strengthened, and
each strengthened check is now shown to fail on the mutation that used to slip past it
([Round 2](#round-2-independent-review)). Twenty-nine findings are open, each with an issue
(#472 to #500, one of which also covers RangeTrain-R3); the models also confirm four known open
items (#392, #393, #394 and st-39). No product code changed. What remains is in
[Follow-ups](#follow-ups).

**Scope:** model checking of the downloads manager design. Specs live in `specs/downloads/`, one
folder per module with the shared modules in `base/` (`specs/README.md` has the layout, and
[Path map](#path-map) the old flat names); the runner is `scripts/check-tla-specs.sh`. This plan owns the modelling program and its findings. It
does not own fixes: each finding needs its own issue and change.

**Evidence that motivated it:** the
[bugs versus main audit](../evidence/2026-10-17-downloads-overhaul-bugs-vs-main.md). Its
interleaving-only defects (B02, B03, B04, B06, B09 to B12, B22, B32) were found by review and by
field reports, not by a tool. The [overhaul plan](2026-10-16-downloads-overhaul.md) owns the design
the model describes.

**Out of scope:** proving the Swift implements the model. The model is a hand-written abstraction;
the reducer and policy unit tests and the `LabstreamTests` pins remain the implementation evidence.

## What the pilot models

`DownloadsSessionCore.tla` follows one row from `admitted` to a terminal lifecycle. Lifecycle and
history change only through `Reduce` in `DownloadsReducer.tla`; the hand-written transitions that
remain are the fix-off branches and the proposed fixes. Durable state
(the index row, files, and the URLSession daemon's tasks) survives `Crash`; in-memory state
(tracked tasks, queued IO hops and their stash claims, halts, queued rebuilds, the finalizer, the
reattach snapshot) does not. Action names are the reducer's event names where one corresponds.

| Actor | Actions |
| --- | --- |
| User | `UserPause`, `UserResume`, `UserRetry`, `UserDelete` |
| URLSession daemon | `DaemonFinishes`, `DaemonFails` (run while the app is dead) |
| Session | `TransferStarted`, `TransferProgress`, `DidFinishDownloading`, `DidCompleteWithError`, `RangeIO`, `RebuildFires`, `StallDetected` |
| Finalizer | `BodyAtWorking`, `FinalizeOutcome`, `FinalizeOutcomeReplayed`, `PublishBody`, `PromotionCommitted`, `PromotionAbandoned` |
| Sweeper | the stash sweep inside `Reattach`; `CleanupRuns` |
| Recovery | `Reattach`, `RelaunchObserved`, `AutoResume`, `ForegroundReattachBegins` |
| Crash | `Crash`, `Relaunch` |

Two routes are modelled: forward-only (one opaque body) and static-range (two segments, fetched
one after the other). Bounds: one or two rows, attempt IDs 1 to 2.

Properties:

| Property | Kind | Meaning |
| --- | --- | --- |
| `CompleteHasPublishedBody` | invariant | A complete or unverified row has its published body. |
| `FinalizingHasBody` | invariant | A finalizing row has the body it is finalizing, except the residue of F4 (no intent, no finalizer, process down or reconcile pending) until reconcile fails it. `FinalizingAlwaysHasBody` is the unconditional form, which fails today. |
| `VerdictSurvivesCrash` | invariant | A truncation verdict that took a body off the working path is on the row (F4; fails today). |
| `QueuedBodyNotSwept` | invariant | A stash whose append or publication is queued is never unlinked (B03). |
| `StaleCallbackInert` | invariant | A callback or a manager-side handoff from a stale attempt changes nothing (B12). |
| `FinishedBodyNotLost` | invariant | Once the app holds an attempt's whole body, it exists somewhere until a verdict or Delete discards it. This is the crash property (F1); the pause case is the next row. |
| `FinishedBodySurvivesPause` | action | While a row is paused by the user, no step of a live process gives up the whole body it holds, unless the body is published, condemned, deleted with its row, or replaced by a fresh attempt the user asked for (F3). A static row holds its whole body from the moment its last segment has finished. Fails today on both lanes. |
| `WorkingBodyKept` | action | A complete body at the working path is only published, condemned, deleted with its row, or replaced by a fresh attempt (B10). |
| `UserPauseSticky` | action | Nothing but the user moves a user-paused row to transferring (B02, B09). |
| `NoStartWhileUserPaused` | action | No task starts for a user-paused row (B02). |
| `ReplayedOutcomeIsNoOp` | action | A replayed finalize outcome changes no durable state. |
| `AdmittedEventuallyStable` | liveness | Under `FairSpec`, an admitted row reaches a terminal lifecycle, a user pause or deletion once the environment stops. |

Fairness for the liveness check: every app action is weakly fair, the daemon resolves every task,
and a task that keeps being retried eventually finishes (strong fairness). User actions, crashes
and foreground returns are not fair and are capped at five steps in the liveness configs.

Those are three assumptions the code cannot promise by itself: the session's own steps run; a
retried transfer eventually finishes (the code has retry budgets instead, which the models do
not count); and the manager's main-actor recovery runs, which a suspended background app does
not get. `StallDetected` exists only on the forward-only lane in the code; on the static lane of
this model it stands in for stale-row recovery, which the range-train model has.

### Abstractions to keep in mind

- A queued delegate-to-IO hop and its stash claim are one variable. The claim is taken when the
  hop is queued and released when it ends.
- Each action persists atomically. The persistence writer, path leases and the artifact intent
  queue's ordering are not modelled.
- Delete is one durable flag and one cleanup step.
- The pause chain's last step (`markPausedAfterUserPause`) is not modelled. See F2.
- The session model stores five of the reducer's ten state fields per row and derives the
  truncation source. `session/Projection-SessionCore` proves that the four it drops
  (`lastFailure`, `unverifiedReason`, `admissionIntent`, `storagePark`) never influence the
  others for the events it sends. That check compares the reducer with itself over field names;
  `session/SessionRowMapCheck-Current-RowMap` checks the operators the model actually runs
  (`SessionRow`, `SessionStored` in `DownloadsSessionRowMap.tla`).
- `FinalizeOutcome` is no longer one atomic step for a truncation: `FinalizeTruncatedCrash` is
  the rename followed by a crash with the durable row unchanged (F4).
- One task slot per attempt. A queued rebuild can start a second task for an attempt whose body
  is still being appended, so a row can reach `finalizing` with a task running. That ordering was
  not checked against the Swift; it only widens what the model explores.

### Keeping the reducer equal to the Swift

`DownloadsReducer.tla` is not maintained by review. The PMSKit test
`DownloadsFormalModelReducerTests` runs the real reducer over 1,728 states (9 lifecycles by 192
histories: empty, 28 single values, 162 cross-field pairs and one full), 126 event shapes and
the whole finite fact space (1,280 records), and renders the results as
`specs/downloads/base/DownloadsReducerTable.tla` (217,728 event results and 80,640 relaunch
results; `specs/downloads/base/README.md` has the grids and the two lemmas that extend them to
the whole reducer). The first round sampled 225 states and 163 fact combinations, and a reducer
with a wrong deletion guard passed it; see [Round 2](#round-2-independent-review). The test fails when the checked-in table is stale;
`Reducer-Conformance.cfg` fails when `Reduce` does not return exactly that table or when the table
misses part of the vocabulary. Either side changing alone fails one of the two.
`docs/DOWNLOADS-OFFLINE.md` has the regeneration command.

Moving the pilot onto the reducer changed one behaviour, a modelling artefact: the pilot moved a
finalizing row back to transferring when reattach adopted a task for it. The code submits
`taskAdopted`, the reducer rejects it for a finalizing row, and the row stays finalizing. With
that one step left as the pilot wrote it, every passing config has the pilot's exact state count,
so nothing else changed.

## Results (2026-11-24, after round 2, tla2tools v1.7.4, `TLC_WORKERS=2 TLC_HEAP=2g`)

| Config | Expectation | Result | Distinct states | Time |
| --- | --- | --- | --- | --- |
| `session/Current-Forward` | pass | pass | 5,784 | 1 s |
| `session/Current-Static` | pass | pass | 97,135 | 3 s |
| `session/Current-TwoForward` (symmetry) | pass | pass | 200,463 | 7 s |
| `session/Current-TwoRows` | pass | pass | 2,353,462 | 73 s |
| `session/Liveness-Forward` | pass | pass | 13,621 | 6 s |
| `session/Liveness-Static` | pass | pass | 70,570 | 51 s |
| `session/Proposed-Forward` | pass | pass | 3,129 | < 1 s |
| `session/Proposed-Static` | pass | pass | 70,841 | 3 s |
| `session/Proposed-F4-VerdictBeforeRename` | pass | pass | 6,449 | < 1 s |
| `base/Reducer-Conformance` | pass | pass | one state; 298,368 reducer results compared | 24 s |
| `session/Projection-SessionCore` | pass | pass | one state | 14 s |
| `session/SessionRowMapCheck-Current-RowMap` | pass | pass | one state | 9 s |
| `session/Deep-TwoStatic` (deep tier, symmetry) | pass | pass | 7,908,854 | 176 s (4 workers) |
| `session/Faithful-B03-off` | `QueuedBodyNotSwept` violated | violated | stops at first error | < 1 s |
| `session/Faithful-B10-off` | `WorkingBodyKept` violated | violated | stops at first error | 1 s |
| `session/Faithful-B12-off` | `StaleCallbackInert` violated | violated | stops at first error | < 1 s |
| `session/Faithful-B02-off` | `NoStartWhileUserPaused` violated | violated | stops at first error | < 1 s |
| `session/Faithful-B09-off` | `UserPauseSticky` violated | violated | stops at first error | 1 s |
| `session/Faithful-F2-off` | `UserPauseSticky` violated | violated | stops at first error | 1 s |
| `session/Faithful-Replay-off` | `ReplayedOutcomeIsNoOp` violated | violated | stops at first error | 1 s |
| `session/Faithful-F1-off` (was `Finding-F1-StashCrash`) | `FinishedBodyNotLost` violated | violated | stops at first error | 1 s |
| `session/Faithful-F3-off` (was `Finding-F3-PauseDiscardsFinishedBody`) | `FinishedBodySurvivesPause` violated | violated | stops at first error | < 1 s |
| `session/Faithful-F3-off-Static` (was `Finding-F3-PauseSupersedesFinishedSegment`) | `FinishedBodySurvivesPause` violated | violated | stops at first error | 1 s |
| `session/Finding-F4-VerdictRenameCrash` | `VerdictSurvivesCrash` violated | violated | stops at first error | < 1 s |
| `session/Finding-F4-FinalizingRowWithoutBody` | `FinalizingAlwaysHasBody` violated | violated | stops at first error | 1 s |
| `base/Mutant-DeletionGuardStaticOnly`, `base/Mutant-PendingHeadIgnoredWithLiveTask`, `base/Mutant-IneligibleSnapshotFailsFinalizing` | `TableMatches` violated | violated | fails at startup | 2 s each |
| `session/SessionRowMapCheck-Mutant-RowDropsCondemned`, `-RowDropsCounted` | `RowMapSound` violated | violated | fails at startup | 3 s each |

The `Current-*` configs are the code as it stands and check every property except the ones the
findings break. With F1 and F3 fixed (see [Fixes](#fixes-f1-f3-rangetrain-r2-and-r3)) every
session `Current-*` and `Deep-*` config lists `FinishedBodyNotLost` and
`FinishedBodySurvivesPause`, and their state counts are the ones in
`specs/downloads/session/README.md`, not the ones above. In the first round the static pause
check was vacuous, because the model counted a static body as whole only
once the working file was complete. `session/Current-TwoRows` uses one attempt per row and the
`complete` verdict only.

State counts before round 2, against the pilot (which ran the same configs with `-workers auto`).
The round-2 counts are in the table above:

| Config | Pilot | After W0 | Why |
| --- | --- | --- | --- |
| `session/Current-Forward`, `session/Liveness-Forward`, `session/Proposed-Forward` | 6,038; 13,454; 2,854 | the same | |
| `session/Current-Static` | 146,692 | 90,686 | The adoption artefact above. |
| `session/Current-TwoRows` | 4,822,941 | 2,531,988 | The same. 88 s before, 69 s after, both at two workers. |
| `session/Liveness-Static` | 75,321 | 68,653 | The same. |
| `session/Proposed-Static` | 142,535 | 86,529 | The same. |

Symmetry: TLC's `SYMMETRY` is sound only over model values the spec never tells apart, and never
for liveness. The pilot's configs have one row, or one forward-only and one static-range row, so
none of them has interchangeable rows and none gained a symmetry set. The two configs that do
have interchangeable rows use it: `session/Current-TwoForward` and `session/Deep-TwoStatic`.
Attempt IDs are ordered integers and are not symmetric.

### Faithfulness: the model sees the fixed bugs

Each fix is a constant. With the fix off TLC returns the bug's ordering; with it on the same
property passes in the `Current-*` configs.

- **B03 off.** A transfer finishes and its body is stashed with the append queued; the app returns
  to the foreground; the reattach sweep finds no live task for the stash and deletes it while the
  append is still queued.
- **B10 off.** A forward-only transfer finishes and its body reaches the working path; the process
  dies; on relaunch reconcile sees a transferring row with no live task, fails it and deletes the
  finished body.
- **B12 off.** A forward-only transfer of attempt 1 fails and its error is handed to the manager;
  the user pauses and resumes into attempt 2; the late handoff, matched by row, fails attempt 2.
  (The first round dropped ownership checks from every callback, which is broader than the
  historical bug: B12 is the manager's side of an error handoff.)
- **B02 off.** A transfer fails and a delayed retry is queued; the user pauses; the retry fires
  and starts a task for the paused row.
- **B09 off.** The user pauses; a late progress callback moves the row back to transferring.
  `FixPauseReconcile` is on (the shipping F2 fix), so the F2 path does not mask the result.
- **F2 off.** Reattach snapshots a live task; the user pauses the row; reconcile promotes the
  paused row to transferring from the stale snapshot, as the reducer did before #473.
- **Replay off.** A second truncation verdict stores an unverified publish intent; the same
  verdict arrives again and counts a third strike. This is the counter as it was before outcome
  IDs existed: one strike per truncated finalizer run.

## Findings on the current design

F1 to F3 were checked against the Swift before being recorded, and an independent reviewer later
confirmed all three by tracing the Swift. F1 and F3 are fixed on `specs/downloads-tla`, pending
merge ([Fixes](#fixes-f1-f3-rangetrain-r2-and-r3)); the sections below describe the code before
the fix. Round 2 added F4 and the
static-lane form of F3; their traces are in `specs/downloads/session/README.md` and
`specs/downloads/range-train/README.md`, and they are in the findings table below.

### F1: a crash between the stash and the working path loses a finished forward-only body

Trace: the transfer finishes; `didFinishDownloadingTo` moves the body into the `tmp/` stash and
queues `finishOpaqueBody`; the process dies before that hop runs; on relaunch the task is no longer
live, so `sweepOrphanedRangeBodyStashes` deletes the stash; reconcile sees a transferring
forward-only row with no task and no working body and fails it. The stream restarts from zero.

Why it is real: the stash claim is in memory only, and the relaunch sweep's stated assumption ("its
body was never appended, so the durable partial re-fetches it on resume") holds for a static
segment but not for a forward-only body, which cannot be re-fetched. B10 protects the body from the
working path onward; the stash step in front of it is the gap. The reducer already has the event
and fact for it (`bodyCaptured`, `Body.captured`), but no app code emits or reports them, and a
transferring row ignores `.captured` on relaunch. The window is the IO-queue hop plus any wait for
the working-path lease.

Verdict: real, low likelihood, high cost when it happens (a full re-transcode).
`session/Proposed-Forward` shows one sufficient design: persist `bodyCaptured` with the stash, make the
sweep honor that durable reference, and requeue the publication on relaunch.

Pin: `DownloadsFormalModelFindingsTests.finishedForwardOnlyBodyInStashSurvivesRelaunch`.
Issue: #472.

### F2: foreground reconcile can undo a user pause

Trace: the app returns to the foreground and reattach asks for the task list; the user pauses a
downloading row; reattach's completion still counts that row as live (its task is tracked, or was
when the snapshot was taken); reconcile runs `relaunchObserved` with `liveTask: true` and the
reducer moves the paused row to transferring ("a paused row a live task proves active"). The task
itself is cancelled by the pause, so the row reads as downloading with nothing running.

Why it is real: reconcile reads the row fresh but takes `liveRatingKeys` from the earlier snapshot,
and the reducer's relaunch table promotes any paused row with a live task without looking at the
pause cause. Reattach's own B02 gates never put a paused row's task in the live set on purpose, so
this branch is reached only through a stale or in-flight snapshot.

What limits it: if reconcile commits before the pause chain's last step, that step
(`markPausedAfterUserPause`) pauses the row again. The row stays wrong only when reconcile commits
after the whole pause chain, which needs the store worker to be busy for that long (a large
library's reconcile loop is a candidate). The model does not include that last step, so it reports
both orders.

Verdict: real race, low severity, user-visible (a paused row shows as downloading and may later
be failed as stalled or restarted).

Fix (fixed on specs/downloads-tla, pending merge): `DownloadLifecycleReducer`'s `relaunchObserved`
leaves a paused row unchanged when the facts report a live task, on every route and for every
pause cause, not only `user`. Every pause cause cancels its task, and reattach cancels rather than
adopts the task of any paused row (`BackgroundReattachTaskGatePolicy` looks at the status, not the
cause), so no paused row has a task the app means to keep; a live-task fact for one is always the
stale or in-flight case. Leaving the row as it is matches the model's former proposal (`Keep`) and
avoids the no-task branches, which could fail a forward-only row whose task is still being torn
down. The reducer table is regenerated; the session model gets the fix through `Reduce`, and
`FixPauseReconcile = FALSE` (`session/Faithful-F2-off`) restores the old promotion. The `Current-*`
and `Deep-TwoStatic` configs now check `UserPauseSticky`.

Pin: `DownloadsFormalModelFindingsTests.userPausedRowIsNotPromotedByLiveTaskFact`.
Issue: #473.

### F3: a user pause discards a finished forward-only body

Decision (2026-11-24): a finished body must survive a user pause on either lane. The pilot
treated the forward-only behaviour as intended; it is a defect.

Trace: a forward-only transfer is running; the user pauses, which installs the pause halt and
asks URLSession to cancel the task; the task finishes before the cancellation lands;
`didFinishDownloadingTo` adopts the finished task, moves the body into the `tmp/` stash and
queues `finishOpaqueBody`; that hop requires `checkpointIsCurrent(currency, halt: nil)`, the
pause halt fails it, and it releases the stash claim and returns. The row stays paused with an
orphaned stash. Resume starts a fresh attempt from zero, and the next sweep deletes the stash.
The same guard drops the body when the transfer finishes first and the pause lands before the
queued hop runs.

A second ordering reaches the same loss through the reducer: the body is already at the working
path, the user pauses, and the process dies before `bodyAtWorking` is persisted. On relaunch
`relaunchObserved` excludes a paused row from the B10 clause, so a user-paused forward-only row
with its whole body at the working path is failed and the body deleted.

Why it is real: the static lane has an explicit decision for this case
(`StaticRangeFinishedBodyPolicy`: a `.pause` halt is `writeThenPause`) and the reducer already
lets a paused row enter `finalizing` from `bodyAtWorking`. The forward-only lane has neither: its
guard treats a pause halt like a cancel.

Correction (round 2): the static lane is not safe either. `writeThenPause` applies only when the
finish callback runs before the completion of the pause's task listing. When the segment
finishes in between, `pauseRangeTask` supersedes the task and its finish callback is ignored
(RangeTrain-R3, probable; `session/Finding-F3-PauseSupersedesFinishedSegment`,
`range-train/Finding-R3-PauseDropsFinishedSegment`). The first round's `session/Current-Static`
passed the property vacuously.

Verdict: real. The first ordering needs only a pause near the end of a transfer, with no crash,
and costs a full re-transcode. The second needs a crash in a short window.
`session/Proposed-F3-PauseKeepsBody` shows the fix on its own: the queued publication accepts a pause
halt (and still rejects a cancel), and relaunch finalizes a paused forward-only row whose body
is at the working path. One window stays open under that fix: a Resume that lands between the
stash and the working path still starts a fresh attempt. The property allows it, as a fresh
attempt the user asked for. Persisting the capture (the F1 proposal) closes it, because the row
is then `finalizing` before the user can act.

Pin: `DownloadsFormalModelFindingsTests.finishedForwardOnlyBodySurvivesUserPause`. It pins the
reducer's relaunch decision and, because the first ordering is decided inline in app code with
no PMSKit policy to call, the guard in `finishOpaqueBody` as source text. The fix should move
that decision into a policy and replace the source pin. Issue: #474.

A pin uses `withKnownIssue` while its finding is open: the suite stays green, and the test
fails as soon as the expectations hold, which is the signal to remove the wrapper and turn the
`Finding-*.cfg` into a `Faithful-*-off.cfg`. They pin the pure decisions. The session glue (the
capture and the live-key snapshot) is app code and still needs a `LabstreamTests` pin with each fix.

### Fixes: F1, F3, RangeTrain-R2 and R3

Fixed on `specs/downloads-tla`, pending merge (#472, #474, #476). The three sit in one window,
between the URLSession temp and the working file, and share one rule: once the app holds a
finished body, a durable or session-owned claim on it is what every sweep, pause and reconcile
asks about.

- **F1 (#472).** `didFinishDownloadingTo` moves a forward-only media response to the attempt's
  capture path (`DownloadStore.forwardOnlyCapturedBodyURL`, an attempt-staging name in the
  downloads directory) and submits `bodyCaptured`, so the row is `finalizing` at once. The row
  references that path while it is not terminal (`artifactPathsReferenced`), which is the
  durable reference: the staging sweep leaves it, Delete removes it, the storage audit counts
  it. Reconcile reports it as `Body.captured`; the reducer's relaunch finalizes an admitted,
  transferring or paused forward-only row that has one (the crash may come before `bodyCaptured`
  is durable); `finalizeCompletedStaticRangeFile` requeues the publication
  (`requeueCapturedForwardOnlyBody`).
  - The design differs from `Proposed-Forward` in one place: the capture is not a `tmp/` stash
    that the stash sweep learns to keep, because the OS may purge `tmp/` while the app is not
    running, which is exactly when this body waits. `sweepOrphanedRangeBodyStashes` never sees it.
  - Only a response that passes the HTTP status and MIME checks
    (`ForwardOnlyFinishedBodyPolicy.responseRejection`) is captured. A relaunch has no response,
    so a captured body is published without them. A rejected response keeps the old in-memory
    stash and fails the row.
- **F3 (#474), forward-only.** `finishOpaqueBody` asks
  `ForwardOnlyFinishedBodyPolicy.publication`: a pause halt publishes, a cancel discards. It
  then drops the pause halt, because the finalizer stands down for any halt, and the row
  finalizes. The reducer's relaunch no longer excludes a paused row from the B10 clause. With
  F1 the Resume window is closed too: the row is `finalizing` before the user can act, and the
  manager ignores a pause of a finalizing row.
- **RangeTrain-R3 (#474), static.** `pauseRangeTask` asks
  `StaticRangeFinishedBodyPolicy.pauseSweepDisposition` and leaves a finished task tracked
  (URLSession reports it completed, or every declared byte has arrived), so its finish callback
  reaches `writeThenPause`. Still probable, not confirmed: the fix rests on the same unexecuted
  step as the finding, that `getAllTasks` lists a finished task whose callback is queued.
- **RangeTrain-R2 (#476).** `DownloadStore.reconcileOnWorker` takes the session's
  `ownsInProgressStaticRangeWork` and asks it per row through
  `DownloadReconcileLiveWorkPolicy`, inside its generation-checked retry loop, for an admitted
  or transferring row only. A dead-finish adoption advances the row's mutation generation once
  the session holds the body, so a reconcile that asked just before retries. The fix as first
  proposed (owned work in the reattach snapshot) is `range-train/Faithful-R2-off-SnapshotOnly`
  and still fails.
  - **Still open:** `range-train/Finding-R2-UndeliveredBodyLost`. A finished task the daemon
    has not redelivered when reconcile runs is owned by nobody; the zero-byte row is failed and
    adoption refuses the late body. Closing it means a zero-byte static row stays resumable on
    relaunch, which changes the reducer's last relaunch branch. That branch is also
    Admission-A1's (#475) and is pinned by `LabstreamTests` (a zero-byte row with no task
    fails), so it was left for one decision covering both.

Configs: `session/Finding-F1-StashCrash` is `Faithful-F1-off`; `session/Finding-F3-*` are
`Faithful-F3-off` and `Faithful-F3-off-Static`; `range-train/Finding-R2-ReconcileFailsQueuedBody`
and `Finding-R2-SnapshotFixLeavesWindow` are `Faithful-R2-off` and `Faithful-R2-off-SnapshotOnly`;
`range-train/Finding-R3-PauseDropsFinishedSegment` is `Faithful-R3-off`.
`session/Proposed-F3-PauseKeepsBody` is gone (the fix is in every `Current-*`). In the session
model `DurableCapture` and `FixPauseKeepsBody`, and in the range train `FixReconcileOwnedWork`
and `FixPauseKeepsFinished`, are `TRUE` in every config but those. The four pins are plain
regression tests; `DownloadLifecycleStoreTests` has two app-target cases for phase B
(`relaunchKeepsCapturedForwardOnlyBody`, `reconcileAsksTheSessionForOwnedWork`).

## Subsystem models (W0 to W8)

Every model extends `DownloadsReducer.tla`, which extends `DownloadsBase.tla`: the vocabulary, and
the reducer as pure operators (`Reduce(state, event, facts)`), so each model applies the same
transition table instead of restating it. The comment block at the top of `DownloadsBase.tla` is
the authoring contract: file and config names, the `MODELS:` header the drift guard reads, the
Crash convention, tiers, and where findings are pinned (`DownloadsFormalModel<Name>Tests.swift`).
Each module has at least one `Faithful-<bug>-off` config for a fixed bug from the audit, or a
`Mutant-*` config where its subsystem has none. Each has a notes file in its folder
(`specs/downloads/<folder>/README.md`) with its model-to-Swift table, bounds, properties,
per-config results, faithfulness traces, full finding traces, the artefacts fixed in the model
and what it leaves out. `docs/DOWNLOADS-OFFLINE.md` summarises each module.

| Item | Module | Scope | Fixed bugs reproduced | Injected mutants | Findings |
| --- | --- | --- | --- | --- | --- |
| W0 base | `DownloadsBase`, `DownloadsReducer`, `DownloadsReducerTable` (generated), `DownloadsReducerConformance`; `DownloadsSessionCore` moved onto it, with `DownloadsSessionRowMap` and its check | Reducer as operators; the pilot | B02, B03, B09, B10, B12, replayed outcomes | three wrong relaunch guards in the reducer; two wrong row mappings | F1, F2, F3 (both lanes), F4 |
| W1 admission | `DownloadsAdmission` | Lanes and the total, waiting rows, the pump, supervised starts, Pause All, backoff, a cap changed at run time, the Emby reuse handoff, a late cancel | B63, B65, B66, B67 | no backoff wake; pause erases the first-start intent; stale cap | Admission-A1 |
| W2 server prep | `DownloadsServerPrep` | Plex optimize and Emby Convert: create or adopt, poll, hand off, cancel, the 24-hour render deadline, the wait for a static slot | B28, B35, B37, B47 | unchecked hand-off; the static slot never returns | ServerPrep-S1, ServerPrep-S2 |
| W3 cleanup and Delete | `DownloadsCleanup` | Deletion barrier, artifact worker in sorted unlink order, cleanup journal and runner, a full volume with a sized reserve, failed unlinks and directory sync, power loss | B18, B28, B44 | B27 preemption without a fence (stable name sorts first); reserve too small; a retried Delete needs a fresh write | Cleanup-C1; confirms B27, B30 |
| W4 wake | `DownloadsWake`, `DownloadsWakeLaunchGate` | Completion registry, wake coordinator with a running clock and timer slack, startup admission; the launch recovery gate | B04, B05, B06, B11, B13, B77 | release by identifier; no absolute deadline; no registry timer | Wake-W1, Wake-W2 |
| W5 side assets | `DownloadsSideAssets` | Work registry, fetch coordinator commands, retry budget, repair edges and inventory pass, per-backend sessions, trickplay, staged Delete and promotion | B25, B32 | Delete skips published files; promote confirm unfenced; no discovery dispatch; payloads fail; window chapters only; unowned row | SideAssets-S1 to S8; confirms st-39, #394 |
| W6 storage | `DownloadsStorage` | Byte accounting, the cap, preflights, storage-full parking, two-step launch, the audit | B01, B19, B24, B26, B31, B86 | audit skips held bodies | Storage-S1 |
| W7 range train | `DownloadsRangeTrain` | Parallel segments in bytes, held bodies and manifests, drain, a crash inside an append, sweeps, reconcile, self-heal | B00, B03, B22 | no alignment check; no epoch check; offset-equality planner; no foreground refresh | RangeTrain-R1 to R4 |
| W8 status and speed | `DownloadsStatus`, `DownloadsStatusPhase` | Aggregate and row speed, bytes in three places, phase, caption, the stall restart cap | pu-33, B09 | #379 partial sum; #379 quiet member omitted; #379 no common window; #224 no wake reset; #224 no settling; #416 segment dip not held | Status-S1 to S7 |

W8 was added to the program after the plan was first written; it has no row in the audit's bug
table for #379, #224 and #416, so those three are mutants.

### Results of the merged run after round 2 (2026-11-24, tla2tools v1.7.4, `TLC_WORKERS=auto`, 14 cores)

Every config ended as its header expects, under the stricter rule that TLC's exit status, banner
and clean finish must agree. The table sums each module's configs; the notes files have the
per-config rows, measured at `TLC_WORKERS=2 TLC_HEAP=2g`. Wall time was 841 s for the default
tier (226 configs and 17 module parses) and 1,369 s for the 9 deep configs. Before round 2 the
same run was 153 configs, 335 s and 293 s.

| Module | Configs | Pass | Violated as expected | Deep | Largest state space (config) | Default tier | Deep tier |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `DownloadsSessionCore` | 23 | 11 | 12 | 1 | 7,908,854 (`session/Deep-TwoStatic`) | 51 s | 58 s |
| `DownloadsReducerConformance` | 5 | 2 | 3 | 0 | 1 (`base/Reducer-Conformance`) | 41 s |  |
| `DownloadsSessionRowMapCheck` | 3 | 1 | 2 | 0 | 1 (`session/SessionRowMapCheck-Current-RowMap`) | 15 s |  |
| `DownloadsAdmission` | 20 | 11 | 9 | 2 | 5,832,083 (`admission/Deep-CapLowered`) | 71 s | 120 s |
| `DownloadsServerPrep` | 18 | 9 | 9 | 0 | 154,948 (`server-prep/Current-PlexThreePollers`) | 20 s |  |
| `DownloadsCleanup` | 16 | 7 | 9 | 0 | 1,249,082 (`cleanup/Current-TwoRows`) | 22 s |  |
| `DownloadsWake` | 13 | 3 | 10 | 0 | 9,290,572 (`wake/Current-Wake`) | 114 s |  |
| `DownloadsWakeLaunchGate` | 2 | 1 | 1 | 0 | 112 (`wake/WakeLaunchGate-Current-Gate`) | 2 s |  |
| `DownloadsSideAssets` | 55 | 27 | 28 | 1 | 16,294,270 (`side-assets/Deep-AllKinds`) | 102 s | 111 s |
| `DownloadsStorage` | 16 | 7 | 9 | 0 | 833,784 (`storage/Current-ThreeStatic`) | 48 s |  |
| `DownloadsRangeTrain` | 25 | 11 | 14 | 2 | 4,182,753 (`range-train/Deep-TwoRows`) | 130 s | 49 s |
| `DownloadsStatus` | 39 | 21 | 18 | 3 | 66,650,051 (`status/Deep-Mixed`) | 199 s | 1013 s |
| Total | 235 | 111 | 124 | 9 | | 815 s | 1351 s |

The seconds are per-config times summed, so they leave out parsing and JVM start-up. The
reducer checks explore one state each; their cost is the table comparison.

### Findings (all models, after round 2)

Each was checked against the Swift before it was recorded. "Probable" means the code path is
certain from reading and the trigger or the intent is not: it needs a device, a running test or a
product decision. A finding with no pin is decided in app-target code or has no pure PMSKit
decision to call. Full traces and evidence are in the module notes and the issues.

| Finding | What goes wrong | Verdict | Config | Pin (`DownloadsFormalModel<Name>Tests`) | Issue |
| --- | --- | --- | --- | --- | --- |
| F1 | A crash between the `tmp/` stash and the working path loses a finished forward-only body. | fixed on `specs/downloads-tla`, pending merge (was real; reviewer confirmed) | `session/Faithful-F1-off` | `finishedForwardOnlyBodyInStashSurvivesRelaunch` (regression test) | #472 |
| F2 | Foreground reconcile moves a user-paused row back to transferring from a stale live-task snapshot. | real; reviewer confirmed; fixed on specs/downloads-tla, pending merge | `session/Faithful-F2-off` (was `Finding-F2-PauseReconcile`) | `userPausedRowIsNotPromotedByLiveTaskFact` (passes) | #473 |
| F3 | A user pause that lands while a forward-only transfer finishes discards the finished body. | fixed on `specs/downloads-tla`, pending merge (was real; reviewer confirmed) | `session/Faithful-F3-off` | `finishedForwardOnlyBodySurvivesUserPause` (regression test) | #474 |
| RangeTrain-R3 (F3 on the static lane) | The pause's task listing supersedes a static segment that has already finished and its finish callback is ignored. One segment on a train, the whole remainder on the open-ended fallback. Raised by the reviewer. | fixed on `specs/downloads-tla`, pending merge (was probable; the `getAllTasks` step is still unexecuted) | `range-train/Faithful-R3-off`, `session/Faithful-F3-off-Static` | `pauseKeepsAFinishedSegment` (regression test) | #474 |
| F4 | A failing truncation verdict renames the body away before the verdict is durable; a crash in between leaves a finalizing row with no body, which reconcile fails as an internal error, and the strike is lost. Raised by the reviewer. | real, low | `session/Finding-F4-VerdictRenameCrash`, `session/Finding-F4-FinalizingRowWithoutBody` | `truncationVerdictIsDurableBeforeTheBodyMoves` | #491 |
| Admission-A1 | Startup recovery fails a forward-only row that never started (a granted start cut by a crash, or a first start the user paused). | real, medium; reviewer confirmed; fixed on specs/downloads-tla, pending merge (relaunch requeues a granted forward-only row with no task, body or checkpoint and keeps a paused one paused; foreground reconcile skips rows a start may own) | `admission/Faithful-A1-off` (was `Finding-A1-RelaunchFailsUnstartedRow`); `RelaunchKeepsUnstartedRow` now in the Current and Deep runs | `relaunchKeepsForwardOnlyRowThatNeverStarted` (passes) | #475 |
| ServerPrep-S1 | Retry of a failed Plex preparation row abandons its running optimize job with no durable cancel and creates a second job. | real, low to medium; reviewer confirmed | `server-prep/Finding-S1-RetryOrphansRender`, `server-prep/Finding-S1-HandoffLeavesJob` | `retryOfFailedPlexPrepKeepsOrCancelsItsJob` | #478 |
| ServerPrep-S2 | The 24-hour Plex render deadline is checked before the create decision and its clock starts when the row is seeded, so a row resumed a day later fails as timed out before the server was asked for anything. | probable, low | `server-prep/Finding-S2-TimeoutBeforeCreate` | `renderDeadlineDoesNotPrecedeTheCreate` | #500 |
| Cleanup-C1 | After a failed intent commit, an explicit artifact recovery re-registers the row deletion with prepared revision 0, and files are unlinked before the intent is durable. | real, low to medium; reviewer confirmed | `cleanup/Finding-C1-UnlinkBeforeDurableIntent` | `rowDeletionUnlinksOnlyAfterDurableIntent` | #479 |
| B27 | A legacy validated promotion whose body is gone makes Delete a permanent no-op. The first round's extra requirement (a fence between Delete and the launch promotion recovery) is withdrawn for names the app generates: the sorted unlink order removes the working body first. | real, known; wedge confirmed, fence claim refuted by the reviewer | `cleanup/Finding-B27-LegacyPromotionWedgesDelete` | `deleteIsNotRefusedByLegacyPromotion` | #392 |
| B30 | On a completely full volume the deletion intent cannot be saved, so nothing is unlinked. A reserve must cover four writes, and a retried Delete must reuse a durable intent. Fix together with Cleanup-C1. | real, known; reviewer confirmed | `cleanup/Finding-B30-FullVolumeDelete` | `deleteOnFullVolumeReclaims` | #393 |
| Wake-W1 | A completion handler that arrives while a claimed batch waits for its MainActor release inherits that batch's deadline. | probable, low; reviewer confirmed by reading | `wake/Finding-W1-StaleDeadline` | none (app-target code) | #480 |
| Wake-W2 | An operation begun while an expired operation lingers is marked expired and does not hold the next wake. | behaviour confirmed, low; intent is a product decision | `wake/Finding-W2-UnsettledWork` | none (app-target code) | #481 |
| SideAssets-S1 | A cancel that keeps the attempt leaves the poster's coordinator owner cancelled for the launch, so the poster is not fetched until a relaunch. | real, medium; reviewer confirmed; fixed on specs/downloads-tla, pending merge (the poster fetch registers its owner) | `side-assets/Faithful-S1-off` (was `Finding-S1-PosterOwnerStaysCancelled`); `side-assets/Current-S1-PosterReregisters` passes | `posterFetchReopensItsCancelledOwner` (no longer a known issue) | #482 |
| SideAssets-S2 | Pause All parks a completed row's side assets, Resume All never unparks them, and repair cannot re-enter a registered kind. Subtitles, Jellyfin trickplay tiles and any late fetch entry; lasts one launch. | real, medium; reviewer confirmed; fixed on specs/downloads-tla, pending merge (Resume All unparks every row that is not paused) | `side-assets/Faithful-S2-off-Subs`, `side-assets/Faithful-S2-off-Tiles` (were `Finding-S2-PauseAllStrandsCompletedRow`, `Finding-S2-TilesParkedBehindPauseAll`); `side-assets/Current-S2-ResumeAllUnparks-*` pass | `resumeAllUnparksCompletedRows` (no longer a known issue) | #483 |
| SideAssets-S3 | A server outage spends the per-launch retry budget for an asset the server has. Trickplay retries are gated by the playlist's budget alone; a park of an in-flight request also costs a dispatch. | behaviour confirmed by the reviewer, low; product decision | `side-assets/Finding-S3-OutageExhaustsBudget`, `side-assets/Finding-S3-TilesBehindPlaylistBudget` | none | #484 |
| SideAssets-S4 | A refused Resume leaves a user-paused row's side assets unparked. | behaviour confirmed by the reviewer, low; product decision | `side-assets/Finding-S4-RefusedResumeUnparks` | none | #485 |
| SideAssets-S5 | A completed-row repair pass that is dropped (an edge while one runs, the 30 s timeout, a row whose generation moved) is not run again. Raised by the reviewer. | real, low | `side-assets/Finding-S5-BusyEdgeDropped`, `-PassTimeoutNoRerun`, `-StaleRowSkipped` | `droppedRepairEdgeRunsAgain` | #493 |
| SideAssets-S6 | A completed row on a backend that is not selected gets no session at launch, so no launch repairs its side assets until the user switches backend. Raised by the reviewer. | real, medium; fixed on specs/downloads-tla, pending merge (launch also hydrates backends of completed rows missing an asset) | `side-assets/Faithful-S6-off` (was `Finding-S6-InactiveBackendStaysCold`); `side-assets/Current-S6-HydrateCompleted` passes | `launchHydratesBackendsOfCompletedRowsMissingAssets` (no longer a known issue) | #494 |
| SideAssets-S7 | The Plex BIF is selected from the media's first part, not the downloaded part: never requested when only the downloaded part has one, the wrong index cached when the first part has one. Raised by the reviewer; the wrong-index half is from the model. Fixed on `specs/downloads-tla`, pending merge: both call sites pass the part index and `selectedPlexBIFPart` selects `part[partIndex]`. | real, medium; fixed | `side-assets/Current-S7-BifChosenPart` passes; the fix switched off: `Faithful-S7-off-BifOfChosenPartNeverAsked`, `-BifOfChosenPartNotOwed`, `-WrongPartBifCached` | `plexBIFComesFromTheDownloadedPart` (passes) | #495 |
| SideAssets-S8 | A side-asset promotion gives up on any concurrent write to its row and nothing retries. | real, low | `side-assets/Finding-S8-PromotionLostToRowMutation` | `promotionSurvivesAnUnrelatedRowWrite` | #496 |
| st-39 | A side-asset file renamed but not yet recorded is left on disk by Delete, after a crash or after a replacement attempt. | real, known, deferred; reviewer confirmed | `side-assets/Finding-st39-CrashOrphanAfterDelete`, `side-assets/Finding-st39-ReplacedAttemptOrphan` | none | #401 |
| #394 | Fetched chapter-image and trickplay-tile payloads wait in memory behind one-at-a-time preparation. | real, known; reviewer confirmed | `side-assets/Finding-394-PayloadsBehindPreparation`, `side-assets/Finding-394-TilePayloadsBehindPreparation` | none | #394 |
| Storage-S1 | An automatic requeue erases a storage-full park, so the row is redriven once without measuring free space. The reachable order is the reviewer's: a redelivered body's own append fails with ENOSPC before the launch enumeration. | real, low; reviewer confirmed by a different ordering | `storage/Finding-S1-RequeueErasesPark` | `automaticRequeueKeepsTheStoragePark` | #486 |
| RangeTrain-R1 | A drain pass run by a held-body removal completion discards its result, so nothing finalizes the file or tops the train up until the self-heal, which needs the foreground. | real, low; reviewer confirmed | `range-train/Finding-R1-StrandedDrain` | `removalCompletionDrainContinuesTheTrain` | #477 |
| RangeTrain-R2 | Reconcile fails a static row whose finished body is stashed and queued for append; for a one-segment file that is the whole download. Observing owned work in the reattach snapshot is not enough (`Faithful-R2-off-SnapshotOnly`); a body the daemon has not redelivered yet is lost with any ownership check (`Finding-R2-UndeliveredBodyLost`). | fixed on `specs/downloads-tla`, pending merge, for work the session owns (was real, medium; reviewer confirmed). The undelivered body is still open. | `range-train/Faithful-R2-off`; open: `range-train/Finding-R2-UndeliveredBodyLost` | `reconcileCountsQueuedBodiesAsLiveWork` (regression test) | #476 |
| RangeTrain-R4 | After a crash inside an append, a segment finished while the app was dead is held beside the ones the planner started; when the head segment fails once, two held bodies fill the depth of two and the planner never fetches the gap at the checkpoint. | probable, medium, rare | `range-train/Finding-R4-HeldBodiesStarveHead` | `plannerAlwaysFetchesTheHeadGap` | #492 |
| Status-S1 | A silently stalled transfer hides the batch speed for as long as it is silent. | real, medium; reviewer confirmed; fixed on specs/downloads-tla, pending merge (a transfer silent for the callback gap counts as zero) | `status/Liveness-SilentMember` passes; fix off: `status/Faithful-S1-off` | `silentTransferDoesNotHideBatchSpeedForever` (passes) | #487 |
| Status-S2 | A stalled static-range row keeps showing a stale speed and ETA, because the refresh loop stops first. | real, medium; reviewer confirmed; fixed on specs/downloads-tla, pending merge (the refresh loop runs while any row transfers) | `status/Liveness-StaleRowSettles` passes; fix off: `status/Faithful-S2-off` | `stalledStaticRowStopsShowingSpeed` (passes) | #488 |
| Status-S3 | After a process death a row shows fewer bytes than before, with no reducer reset: a static-range row loses its in-memory optimistic total, a forward-only row loses the progress samples since its last persistence ticket. | probable, low; reviewer confirmed with conditions | `status/Finding-S3-RelaunchDip`, `status/Finding-S3-RelaunchDipForward` | none (source check `throttledProgressHasNoPersistenceTicket`) | #490 |
| Status-S4 | A forward-only row's first callback after the 4 s foreground grace inflates its speed. | probable, low; reviewer uncertain on a device | `status/Finding-S4-LateCallbackInflatesRow` | none | #489 |
| Status-S5 | Past its two automatic restarts a stalled forward-only stream has no verdict; it stays downloading at zero bytes and hides the batch speed. Raised by the reviewer. | real, medium; fixed on specs/downloads-tla, pending merge (past the cap the row fails as stalled, retryable) | `status/Liveness-StallCap`, `status/Liveness-StallCapFlow` pass; fix off: `status/Faithful-S5-off`, `status/Faithful-S5-off-Flow` | `stalledForwardOnlyStreamGetsVerdictPastTheCap` (passes) | #497 |
| Status-S6 | Fresh evidence without a common 0.5 s window hides the batch speed; a member reporting every 3.5 to 6 s makes it come and go. Raised by the reviewer. | real, low | `status/Finding-S6-SlowMemberFlapsSpeed` | `freshNonOverlappingWindowsHideTotal`, `slowMemberMakesTotalFlap` | #498 |
| Status-S7 | A backlog reported after the 4 s settling and grace windows is published as live speed (timing assumption A1 lifted). Raised by the reviewer. | probable, low | `status/Finding-S7-LateBacklogInflatesTotal`, `status/Finding-S7-LateBacklogInflatesRow` | `lateBacklogAfterSettlingIsNotPublishedAsSpeed`, `lateBacklogAtTheEndOfTheGraceIsNotPublishedAsRowSpeed`, and the known-issue halves of the two seeded batch tests | #499 |
| Status-S8 | A queued forward-only stall verdict re-read the row but not its bytes (#501), so a stream that moved again before the operation ran was cancelled and restarted from byte 0. The stall action is now split into `StallObserve` and `StallAct`. Raised by the independent reviewer (probable). | real, low (confirmed in the Swift); fixed on specs/downloads-tla, pending merge | `status/Current-OneForward` checks `NoRestartOfMovingStream`; fix off: `status/Faithful-S8-off` | `queuedStallVerdictRechecksBytes` (passes) | #501 |

Findings that touch each other:

- F1, F3 and RangeTrain-R2 all sit in the window between the `tmp/` stash and the working file.
  Persisting the capture (the F1 proposal) closes F3's last window.
- F2 and RangeTrain-R2 are the two directions of one snapshot: reconcile's live keys are too
  generous for a paused row and too strict for a row with queued work. The R2 fix must ask the
  session when reconcile decides, and must not count session work as live for a paused row.
- F3 and RangeTrain-R3 are one defect on two lanes; one fix should cover both.
- SideAssets-S1, S2, S3 and S5 each last one launch; S6 and S7 are the ones a relaunch does not
  heal. S1, S2 and S6 are fixed on specs/downloads-tla (pending merge).
- Status-S5 is Status-S1 for a forward-only row past its restart cap. Status-S7 and Status-S4
  both depend on how late URLSession reports a backlog after a wake; one device capture settles
  both.
- Admission-A1 and F3's crash ordering both go through the last branch of `relaunchObserved`.
- Cleanup-C1 is today the only way Delete frees space on a full volume for a row with no server
  job, so C1 and B30 should be fixed together.
- Status-S2 is the common case partly because of Status-S1: while the aggregate is hidden, no
  refresh loop runs.

## Round 2: independent review

After the first round a different model audited the specs against the Swift at f0496938 and
reported 38 items in three areas (R1: base, session and range train; R2: side assets and status;
R3: admission, server preparation, cleanup, wake, storage and tooling), plus a verdict on each
open issue. The rule for the round: every reviewer item is a claim. Each was reproduced in the
Swift and, where the reviewer described a scratch experiment, in TLC, before anything changed.
A valid item was closed in the model, property, config or tool, and the strengthened check was
then shown to fail on the reviewer's mutation and pass on the real model. Where it was cheap the
mutation was kept as a `Mutant-*` config.

Outcome: no reviewer item was wrong. Thirty-two were valid and fixed, four partly valid (the
valid part fixed, the rest recorded), and two are accurate observations left as documented
limits. The review also turned up ten new findings (#491 to #500) and one extension of an
existing one (RangeTrain-R3, on #474). Three of the ten came from the strengthened models
themselves and not from the reviewer's text: RangeTrain-R4, SideAssets-S8 and ServerPrep-S2.

What the first round got wrong, stated plainly:

- **A liveness property that proved nothing.** Side assets' `NeverForgotten` counted a spent
  in-memory retry budget as an account of the asset. It passed with all discovery switched off
  and with every payload failing.
- **Checks that passed vacuously.** The static lane's `FinishedBodySurvivesPause`; `Current-OneForward`'s
  `RelaunchKeepsBytes`; the wake budget invariant, which accepted any due timer as an excuse;
  storage's audit property, which compared a quantity with itself.
- **A sampled table presented as conformance.** The reducer table sampled states and facts, and a
  reducer with a wrong deletion guard passed both reducer checks.
- **Fix-off configs that switched off more, or something else, than the historical fix.** B00,
  B12, B13, B31, B37 and B65.
- **A requirement attached to a fix that the code does not need.** The Delete fence in #392.
- **A fix design that leaves a window.** #476's reattach-snapshot fix.
- **A trace the Swift does not take.** #486's original ordering.
- **A runner that could report a crash as a pass.** An expected-violation config passed when TLC
  died after printing the banner.

### Reviewer items

"Strength test" is the check that now fails on the mutation that used to pass.

| Item | Claim | Verdict | Change | Strength test |
| --- | --- | --- | --- | --- |
| R1-1 | A crash can leave a durable finalizing row with no working body; the model's finalize step was atomic. | valid, fixed | `FinalizeTruncatedCrash`; `FinalizingHasBody` restated with that one exception; `VerdictSurvivesCrash`; proposed `FixVerdictBeforeRename`. New finding F4. | `session/Finding-F4-*` violated; `Proposed-F4-VerdictBeforeRename` passes |
| R1-2 | `Proposed-Train` checks a stronger #476 fix than adding owned work to the reattach snapshot. | valid, fixed | `FixSnapshotOwnedWork` (not enough) beside `FixReconcileOwnedWork`; `ReconcileKeepsUndeliveredBody`. | `range-train/Finding-R2-SnapshotFixLeavesWindow`, `Finding-R2-UndeliveredBodyLost` violated; `Proposed-Train` passes |
| R1-3 | Both reducer checks pass a wrong deletion guard; coverage is a sample; Projection never runs the session's row mapping. | valid, fixed (one sub-claim is by design: Projection compares the reducer with itself) | Table over the whole fact space and 1,728 states, two lemmas checked on both sides, `TableCovers` requires all facts; `DownloadsSessionRowMap` and its check. | `base/Mutant-DeletionGuardStaticOnly` and two more; `session/SessionRowMapCheck-Mutant-*` |
| R1-4 | The range train cannot exercise recovery from a partially appended segment. | valid, fixed | Byte-granular model (`SegBytes`), `CrashMidAppend`, the interval-aware planner, `PlannerFillsGapsOnly`, `TrainNeverWedged`. Found RangeTrain-R4. | `range-train/Mutant-OffsetEqualityPlan`; `Current-MidAppend` passes |
| R1-5 | The static pause property starts protecting the body too late; a superseded finish is dropped. | valid, fixed | `superseded`, `PauseSweep`; a static row holds its whole body from the last finish. `FinishedBodySurvivesPause` left `Current-Static`. RangeTrain-R3. | `session/Finding-F3-PauseSupersedesFinishedSegment`, `range-train/Finding-R3-PauseDropsFinishedSegment` |
| R1-6 | `Faithful-B00-off` changes the wrong component. | valid, fixed | B00 off is now the manager's retry policy and stale-row detector, as 852e9f7f fixed them. | `range-train/Faithful-B00-off` (through Resume), `Faithful-B00-off-NoSelfHeal` |
| R1-7 | Liveness assumes foreground recovery and eventual network success. | valid, fixed | Fairness split into session, network and foreground parts, each stated; the wake-winding-down branch modelled. The retry budget is still not modelled. | `range-train/Mutant-NoForegroundRefresh` |
| R1-8 | Replay-off and B12-off are broader than the historical mechanisms. | partly valid, fixed | B12 valid: now the manager's error handoff alone. Replay: the mutation was already the pre-R2-5 counter; only its description was wrong. | `session/Faithful-B12-off` (handoff trace), `Faithful-Replay-off` |
| R2-1 | Side assets' never-forgotten liveness does not prove it. | valid, fixed | `NeverForgotten` restated over durable facts and checked across relaunches with an empty budget; `MissingIsDurablyOwed`; the old reading kept as `CachedThisLaunch`. | `side-assets/Mutant-NoDiscoveryDispatch`, `Mutant-PayloadsFail`, `Mutant-PayloadsFail-ThisLaunch` |
| R2-2 | The Plex BIF uses the first part, not the chosen part. | valid, fixed | Advertised, produced and served parts separated; `CachedBifIsForChosenPart`. SideAssets-S7. | `Faithful-S7-off-*`; `Current-S7-BifChosenPart` passes (#495 fixed) |
| R2-3 | A completed legacy row with no attempt ID is excluded from the inventory. | partly valid | The exclusion is real, but the store treats such a row as a malformed index and resets it on load, and a test asserts that. Properties are scoped to owned rows. Not a finding. | `side-assets/Mutant-UnownedRow` |
| R2-4 | Recurring repair is assumed, but edges are dropped when busy, on the 30 s timeout or on a generation mismatch. | valid, fixed | The scan is an edge, a pass with a snapshot, a timeout and a rerun; only the launch edge is assumed for the durable property. SideAssets-S5. | `Finding-S5-*`; `Proposed-S5-PassReruns*` pass |
| R2-5 | Launch leaves inactive backends with only completed rows cold. | valid, fixed | Per-backend sessions, launch hydration, `SwitchBackend`. SideAssets-S6. | `Finding-S6-InactiveBackendStaysCold`; `Proposed-S6-HydrateCompleted` passes (since the #494 fix: `Faithful-S6-off`, `Current-S6-HydrateCompleted`) |
| R2-6 | The repair requires the row's own server and user; one global session is not enough. | valid, fixed | Sessions and saved credentials are per backend and mean the row's own server and user. No finding: refusing another server's credentials is correct. | Covered by the S6 pair and `Current-TwoBackends` |
| R2-7 | Delete atomicity assumes fences the coordinator does not provide. | partly valid, fixed | The model did assume it. The code is fenced, by the store and not the coordinator. Delete and promotion are now multi-step with those fences. Surfaced SideAssets-S8. | `Mutant-PromoteConfirmUnfenced`, `Mutant-DeleteSkipsPublished`; `Current-Delete` passes |
| R2-8 | Jellyfin tiles are not the serial subtitle shape; retries are gated by the playlist's budget; the #394 fix does not cover tiles. | valid, fixed | New kind `tiles` with a playlist and a task group; the payload bound covers both groups. | `Finding-394-TilePayloadsBehindPreparation`, `Mutant-WindowChaptersOnly`, `Finding-S3-TilesBehindPlaylistBudget` |
| R2-9 | Status durability: forward-only samples are not all persisted; the #490 trace had no published value before the crash. | valid, fixed | Bytes in three places (file, live row, published snapshot); the throttle modelled. `RelaunchKeepsBytes` removed from `Current-OneForward`. | `status/Finding-S3-RelaunchDipForward`; passes when the throttle is replaced by a ticket |
| R2-10 | #224: the model forbids late catch-up; a backlog after settling is published as speed. | valid, fixed | `LateCatchUp` lifts assumption A1. Status-S7. | `Finding-S7-LateBacklogInflatesTotal`, `-Row` |
| R2-11 | #379: the model needs no common window; the estimator does. | valid, fixed | The 0.5 s common window and evidence age (fresh, thin, stale); `NoUnsharedWindow`. Status-S6. | `Mutant-I379-NoOverlap`, `Finding-S6-SlowMemberFlapsSpeed` |
| R2-12 | A mutation that omits every quiet member still passed `NoPartialSum`. | valid, fixed | The excused set is only the proposed counts-as-zero rule. | `Mutant-I379-QuietOmitted` |
| R2-13 | A fair stall check removes any stalled forward row; the code caps restarts at two. | valid, fixed | The stall count and cap; `ForwardStallGetsVerdict`, `StallRestartsCapped`. Status-S5. | `Finding-S5-StallCapNoVerdict`, `Finding-S5-StallCapHidesSpeed` (now `Faithful-S5-off`, `Faithful-S5-off-Flow` after the #497 fix) |
| R2-14 | The segment mutant sets the reset flag directly; the hold is conditional on claim debt. | valid, fixed | `SegmentFinish` and `AppendLands`; the reset comes from the estimator's own regression rule. | `Mutant-I416-SegmentNoHold` |
| R2-15 | `EventuallyStable` asserts only number or none. | valid, documented | True by construction: the model has no numeric speed. Stated in the notes; the property now carries Status-S6. | none needed |
| R2-16 | The phase omits `backendConfigured` and progress finalization; the Swift test does not check equality with the TLA+. | valid, fixed | `DownloadsStatusPhase.tla`: `PhaseOf` and a 288-row table; the Swift test reads the table and compares row for row. | Flipping one row fails TLC at startup and fails the Swift test |
| R2-17 | The #224 mutant disables four defences together. | partly valid, fixed | One `Mutant` constant with single-protection values. Two became configs. No-gap-reset passes in the model (every sleep is reset at foreground first) and no-grace is not a sound mutant; both are explained in the notes. | `Mutant-I224-NoWakeReset`, `Mutant-I224-NoSettling` |
| R2-18 | The #379 mutant is a membership example; B09 restores only the late-progress part. | valid, documented | Both statements are accurate and are now in the notes. | none needed |
| R3-1 | The #392 orphan trace depends on unlink order. | valid, fixed | Sorted unlink order; the fence claim withdrawn for generated names. | `cleanup/Mutant-B27-PreemptWithoutFence` (stable name sorts first); `Proposed-B27-GeneratedPathsNoFence*` pass |
| R3-2 | `Faithful-B31-off` creates its own relaunch candidate. | valid, fixed | B31 off persists a failure without the storage reason; `ParkedFailureSaysStorage`. | `storage/Faithful-B31-off` |
| R3-3 | The B13 check passes with a broken operation watchdog; the clock stops while a timer is due. | valid, fixed | A running clock with `TimerSlack`; `OperationHoldBounded`; B13 is the operation deadline alone. | `wake/Faithful-B13-off` (passes when there are no operations), `Mutant-NoAbsoluteDeadline`, `Mutant-NoRegistryTimer` |
| R3-4 | The runner accepts a crash after an expected-violation banner; several temporal properties are indistinguishable. | valid, fixed | A result needs exit status, banner and clean finish to agree; `EXPECT: violation TEMPORAL <Property>` with two runs. | `scripts/tests/test_check_tla_specs.py` (15 of 27 fake-Java cases fail on the old script) |
| R3-5 | The #486 counterexample omits two Swift recovery decisions. | valid, fixed | Two-step launch, request-less adopted bodies; the finding now has the reviewer's ordering. | `storage/Finding-S1-RequeueErasesPark` (new trace); `Proposed-S1-DurableParkGate` passes |
| R3-6 | Admission's cap invariants exclude supported ways past a cap. | valid, fixed | A cap that changes, the Emby reuse handoff, a late cancel; `GrantRespectsObservedOccupancy`. | `admission/Mutant-StaleCap`, `Faithful-B63-off`, `Faithful-B65-off-Cap` |
| R3-7 | The drift check misses merge edits, reads the checkout, and fails on a deleted base config. | valid, fixed | Git objects only; merges compared with their re-merge; removed configs counted for the module they ran. | `scripts/tests/test_check_tla_drift.py` |
| R3-8 | Storage's drift coverage leaves out the app files behind its finding; the audit property is a tautology. | valid, fixed | Three `MODELS:` lines; `AuditEnumeratedKinds` apart from ownership; a Swift test ties the list to the function. | `storage/Mutant-AuditSkipsHeld` |
| R3-9 | B37's trace exaggerates; the hand-off is assumed fair. | valid, fixed | The 24-hour deadline and the slot wait; B37 off is a safety run. Found ServerPrep-S2. | `server-prep/Faithful-B37-off`, `Mutant-SlotNeverReturns` |
| R3-10 | B65 combines two mutations. | valid, fixed | B65 off is the Resume bypass alone; the intent erasure is a mutant. | `admission/Faithful-B65-off`, `Mutant-PauseErasesFirstStart` |
| R3-11 | The proposed full-volume fix assumes every write fits. | valid, fixed | A reserve counted in writes, failed unlinks, a failed directory sync, the retried-ticket rule. | `cleanup/Mutant-B30-ReserveTooSmall`, `Mutant-B30-RetapNeedsFreshWrite` |
| R3-12 | The PR drift pipeline always compares against `main`. | valid, fixed | The step uses the pull request's target branch and stops if it is unset. Not yet run on a live server. | `TlaPipelineTests.test_the_drift_step_compares_against_the_target_branch` |

### Reviewer verdicts on the open issues

| Issue | Reviewer verdict | Effect of the strengthened model |
| --- | --- | --- |
| #472 F1, #473 F2 | confirmed | Same traces. |
| #474 F3 | confirmed | Widened to the static lane (RangeTrain-R3, probable). |
| #475 A1, #478 S1, #479 C1, #480 W1 | confirmed | Reproduce unchanged. |
| #476 R2 | confirmed | Fix design corrected: observe owned work when reconcile decides. One ordering remains with any ownership check. |
| #477 R1 | confirmed, duration not measured | Duration now checked: heals at the next foreground refresh, never in a suspended app. |
| #481 W2 | behaviour confirmed; intent is a product decision | Unchanged. |
| #482 S1, #483 S2 | confirmed | Each lasts one launch; S2 widened to trickplay and any late fetch entry. |
| #484 S3, #485 S4 | confirmed | Behaviour confirmed; the product question each issue asks stays open, so the label stays. |
| #486 S1 | confirmed by a different ordering | Trace replaced. |
| #487 S1, #488 S2 | confirmed | Unchanged; #487 gains a forward-only form (Status-S5). |
| #489 S4 | uncertain on a device | Stays probable. |
| #490 S3 | confirmed with conditions | Widened to forward-only rows; the round-1 claim that they keep their bytes is withdrawn. |
| #392 B27 | wedge confirmed; fence trace refuted for generated paths | Fence claim withdrawn. |
| #393 B30 | confirmed | Reserve sized: four writes and intent reuse. |
| #394, #401 st-39 | confirmed | #394 widened to trickplay tiles; st-39 unchanged. |

### What a pass now proves, and what it assumes

- A `Current-*` pass says the listed invariants hold in every reachable state of that model at
  that config's bounds. It says nothing about properties the config does not list, and several
  `Current-*` configs deliberately leave out a property that a `Finding-*` config breaks.
- A `Liveness-*` pass holds under the fairness written in its header. The session and
  range-train runs assume the foreground recovery runs and a retried transfer eventually
  finishes; the durable side-asset run assumes only that launches keep coming.
- Status results about inflated speed hold under timing assumption A1 (a backlog is fully
  reported inside the 4 s windows). Status-S7 is what follows without it.
- A `Faithful-*` config now switches off the historical mechanism alone, as far as the audit and
  the fix commits show it. `Faithful-B31-off` and `Faithful-B37-off` changed property; neither
  claims what it claimed in the first round.
- A `Proposed-*` pass shows the modelled fix is sufficient in the model. Two are marked not
  enough and paired with a finding (`FixSnapshotOwnedWork`; a reserve below four writes).
- Reducer conformance is exhaustive over the fact space and relies on two checked lemmas for
  states beyond the table's 1,728. The rest of each model is hand-written. Most new pins are
  source-text checks of app code: they fail when the text moves, not when the behaviour does.
- Probable findings have a step that was read and not run: RangeTrain-R3 (whether `getAllTasks`
  lists a finished task whose callback is queued), RangeTrain-R4 (the session path into the
  planner), Status-S7 and Status-S4 (how late URLSession reports a backlog), ServerPrep-S2 (the
  app path), Wake-W1.
- One review round finding this much is evidence that more remains. Nothing shows the second
  round found everything.

## Follow-ups

Fixes are tracked by the issues above. The rest is about the models and their tooling.

Tooling:

- Done in round 2: the `EXPECT` header can require a named liveness property
  (`violation TEMPORAL <Property>`), and a run counts only when TLC's exit status, banner and
  clean finish agree. Every current temporal-violation config checks one property.
- `.woodpecker/tla.yml` runs the model check on the macOS runner, which is not enrolled yet
  (`docs/MACOS-CI.md`). Neither it nor `.woodpecker/tla-drift.yml` has run on Woodpecker. The
  first real pull-request pipeline should be checked to confirm `CI_COMMIT_TARGET_BRANCH` is
  present at run time with the `$${...}` escape. A Linux container with a JDK could run the
  default tier on pull requests today.
- Two runs of `scripts/check-tla-specs.sh` in one worktree share their log folders and report
  wrong results. The runner does not lock; a per-worktree lock would make that an error.
- The drift guard needs git 2.36 or later for merge commits.
- The phase table in `DownloadsStatusPhase.tla` was generated once by a throwaway script and is
  kept honest by a TLC `ASSUME` and a Swift test. It has no committed generator; the
  reducer-table generator is the natural home.
- The drift guard: `DownloadsServerPrep`, `DownloadsCleanup`, `DownloadsStatus` and now
  `DownloadsStorage` list `DownloadManager.swift` on `MODELS:` lines, and storage and status also
  list `BackgroundDownloadSession.swift` and `DownloadStore.swift`, beside the session core and
  the range train. Those files change often, so most downloads changes will need a spec edit or
  a `Spec-Unaffected:` trailer. Some modelled code is still unlisted and held only by a source
  pin: side assets (`DownloadStore.swift` promotion and deletion fences, `DownloadManager+Plex.swift`,
  `ContentView.swift`), admission (`DownloadManager+EmbyConvert.swift`, the session's pause) and
  server preparation (`DownloadManager+Admission.swift`). Decide whether to keep the friction,
  narrow the guard to functions, or move the modelled code into smaller files.
- Default-tier cost. Round 2 took the default tier from 147 configs and about six minutes to
  226 and about fourteen on 14 cores. `DownloadsStatus`, `DownloadsRangeTrain`, `DownloadsWake`
  and `DownloadsSideAssets` are the slowest. Candidates for the deep tier if that is too long
  for CI: `range-train/Proposed-Liveness-MidAppend`, `wake/Liveness-HandlerCalled`,
  `wake/Current-Wake`, `status/Current-Mixed`. `status/Deep-Mixed` is the heaviest deep config;
  restricting its interference kinds would cut it.
- `DownloadsReducerTable.tla` is now a 1.4 MB generated file and the reducer suite takes about
  half a minute. That is the price of covering the whole fact space.
- Not modelled, from round 2: the retry budget (network fairness stands in for it);
  `SegBytes = 2` with three segments (too large to finish, so the restated depth bound under the
  proposed R4 fix is checked at two segments only); the callback-gap reset in the status model
  (no sleep reaches it without a foreground reset); a held body stashed but not yet in its
  manifest at process death; #476's last ordering (a zero-byte static row staying resumable).
- Open question for the session model: its static lane keeps `StallDetected` as a stand-in for
  stale-row recovery. Restricting it to the forward-only lane, as in the code, makes
  `Liveness-Static` fail on a model artefact. The static lane may be better retired in favour
  of the range-train model.

Pins:

- Device or app-target checks that would settle a probable verdict: whether `getAllTasks` lists a
  finished task whose finish callback is queued (RangeTrain-R3); a kill inside an append with a
  second segment in flight (RangeTrain-R4); post-wake callback timings (Status-S4, Status-S7);
  an old optimize start stamp with no dispatched create (ServerPrep-S2).
- Wake-W1, Wake-W2, Status-S3 and Status-S4 need `LabstreamTests` pins; sketches for the two wake
  findings are in `specs/downloads/wake/README.md`. RangeTrain-R2 and Cleanup-C1 were confirmed
  by reading and want a runtime reproduction (hold the range-IO queue; full-volume fault
  injection).
- Several pins read app source as text because the decision is inline app code: F3,
  ServerPrep-S1 and S2, Cleanup-C1, B27, B30, SideAssets-S1, S2, S5, S6 and S8, Storage-S1,
  RangeTrain-R1, R2 and R3, F4, Status-S2. ServerPrep-S2, the cleanup retried-ticket rule and
  the storage launch ordering would each be better held by a `LabstreamTests` case with injected
  clocks and filesystems; none exists for these paths. Each fix should move the decision into a PMSKit policy and replace the pin. The B30
  pin watches the bare failure branch; a reserve-based fix may leave that text unchanged, and
  the pin must then be removed by hand.

Reducer and base gaps the models met:

- `DownloadRowFacts` has no fact for "this attempt never started", and `admissionGranted` clears
  the intent (Admission-A1). Fixed without a new fact: a forward-only row with no task, body or
  checkpoint has nothing a failure would discard, so relaunch requeues an admitted one
  (`seasonPlanned`) and keeps a paused one paused. Relaunch now also writes `admissionIntent`;
  `relaunchIsLocal` and `RelaunchLocal` allow it. The table was regenerated.
- `storagePark` and `transferInterrupted(.storage)` are unreachable: every app storage-full path
  submits `transferFailed(.storage)` (Storage-S1). Wire it or remove it.
- The app never submits the reducer's `prepHandoff` event. The Plex hand-off is a metadata
  rewrite plus `transferStarted`, and the Emby hand-off replaces the attempt.
- `TaskStates` in the base includes `"failed"`, which `DownloadsStatus` does not use, so it
  defines its own set.

Not modelled, worth a later model or a hermetic test:

- Interactions across modules: admission with the server-preparation lane and the render handoff
  (#414);
  the cleanup runner's boundary between `DownloadsServerPrep` and `DownloadsCleanup`; retry by
  replacement and paths shared across rows in cleanup.
- RangeTrain-R2's general form: a pending delayed retry or request rebuild at a zero checkpoint
  is failed by reconcile in the same way. Only the queued-body case is pinned.
- A purge that overtakes a hold in flight leaves a held-map entry with no file and no manifest;
  the completion checks the halt and ownership and not the train epoch. Three held-file
  properties are scoped to runs without a restart because of it.
- Whether a static row cut during a granted start is re-driven at launch under Pause All, where
  the automatic resume is skipped (Admission-A1 is stated for forward-only rows).
- `requestAdmission` leaves its persistence proof set when its queued operation is fenced, and
  the pump skips rows with a proof.

Observations from reading that are not findings:

- After a relaunch under Pause All, a planned row that lost its in-memory exemption may count as
  active work for `DownloadQueueToolbarPolicy`, so the toolbar could offer Pause All while the
  queue is paused.
- Nothing in the app calls `BackgroundDownloadCompletionRegistry.noteStartupWakeState`.
- After a timed-out wake, `isWindingDown` stays true while any expired operation is registered,
  so a leaked operation would park health refill until relaunch.
- The launch-gate rerun after a ready edge starts in a MainActor task; browse can stop being
  ready before it begins, and the gate does not rerun again.
- A storage-cap refusal at start fails the row as aborted, and its message lives only in memory,
  so after a relaunch the row is failed with no caption.
- A row whose tasks all wait behind the per-host connection limit would be a silent member of a
  healthy batch (a possible trigger for Status-S1; not checked on a device).
- "Shown bytes never go backwards" does not hold literally: leaving `downloading` drops the
  optimistic overlay on purpose. `BytesMonotone` is stated for a row that stays downloading in a
  live process.

## Path map

The specs were one flat folder until 2026-11-24. Issues #472 to #490 and comments on #392, #393,
#394 and #401 cite the flat paths. The files moved without a change to what they check:

| Old path under `specs/downloads/` | Now |
| --- | --- |
| `Admission-<rest>.cfg` | `admission/<rest>.cfg` |
| `ServerPrep-<rest>.cfg` | `server-prep/<rest>.cfg` |
| `Cleanup-<rest>.cfg` | `cleanup/<rest>.cfg` |
| `Wake-<rest>.cfg` | `wake/<rest>.cfg` |
| `WakeLaunchGate-<rest>.cfg` | `wake/WakeLaunchGate-<rest>.cfg` (name kept) |
| `SideAssets-<rest>.cfg` | `side-assets/<rest>.cfg` |
| `Storage-<rest>.cfg` | `storage/<rest>.cfg` |
| `RangeTrain-<rest>.cfg` | `range-train/<rest>.cfg` |
| `Status-<rest>.cfg` | `status/<rest>.cfg` |
| A config with no module name in front (`Current-*`, `Liveness-*`, `Faithful-*`, `Finding-F1-*` to `Finding-F3-*`, `Proposed-*`, `Deep-TwoStatic`, `Projection-SessionCore`) | `session/`, name kept |
| `Reducer-Conformance.cfg` | `base/Reducer-Conformance.cfg` |
| `DownloadsBase.tla`, `DownloadsReducer.tla`, `DownloadsReducerTable.tla`, `DownloadsReducerConformance.tla` | `base/`, name kept |
| `DownloadsSessionCore.tla` | `session/DownloadsSessionCore.tla` |
| `Downloads<Name>.tla` | `<folder>/Downloads<Name>.tla`; `DownloadsWakeLaunchGate.tla` is in `wake/` |
| `Downloads<Name>.md` | `<folder>/README.md` |

Round 2 renamed or split these configs:

| Before round 2 | Now |
| --- | --- |
| `side-assets/Liveness-PosterChapters` | `side-assets/Liveness-Durable-PosterChapters`, `side-assets/Liveness-ThisLaunch-PosterChapters` |
| `side-assets/Liveness-Discovered` | `side-assets/Liveness-Durable-Discovered`, `side-assets/Liveness-ThisLaunch-Discovered` |
| `side-assets/Proposed-NeverForgotten-Poster` | `side-assets/Proposed-S1-PosterReregisters` |
| `side-assets/Proposed-NeverForgotten-Subs`, `-ChaptersSubs` | `side-assets/Proposed-S2-ResumeAllUnparks-Subs`, `-ChaptersSubs` |
| `status/Mutant-I224-NoCatchUpGuard` | `status/Mutant-I224-NoWakeReset`, `status/Mutant-I224-NoSettling` |
| `status/Mutant-I416-SegmentDip` | `status/Mutant-I416-SegmentNoHold` |

The F1, F3, R2 and R3 fixes renamed these:

| Before the fix | Now |
| --- | --- |
| `session/Finding-F1-StashCrash` | `session/Faithful-F1-off` |
| `session/Finding-F3-PauseDiscardsFinishedBody` | `session/Faithful-F3-off` |
| `session/Finding-F3-PauseSupersedesFinishedSegment` | `session/Faithful-F3-off-Static` |
| `session/Proposed-F3-PauseKeepsBody` | removed |
| `range-train/Finding-R2-ReconcileFailsQueuedBody` | `range-train/Faithful-R2-off` |
| `range-train/Finding-R2-SnapshotFixLeavesWindow` | `range-train/Faithful-R2-off-SnapshotOnly` |
| `range-train/Finding-R3-PauseDropsFinishedSegment` | `range-train/Faithful-R3-off` |

The side-assets S1, S2 and S3 finding configs keep their names and now check `CachedThisLaunch`;
the properties `AvailableEventuallyCached` and `Accounted` no longer exist.

The S1, S2 and S6 fixes (#482, #483, #494; pending merge) renamed again: each `Proposed-S1/S2/S6-*`
config is now `Current-S1/S2/S6-*`, and each `Finding-S1/S2/S6-*` config is a `Faithful-*-off`
config (`Faithful-S1-off`, `Faithful-S2-off-Subs`, `Faithful-S2-off-Tiles`, `Faithful-S6-off`)
that still fails with its fix switched off. The three `Fix*` constants are `TRUE` in every other
config.

So `specs/downloads/Finding-F1-StashCrash.cfg` is `specs/downloads/session/Finding-F1-StashCrash.cfg`,
and `specs/downloads/SideAssets-Finding-S1-PosterOwnerStaysCancelled.cfg` is
`specs/downloads/side-assets/Finding-S1-PosterOwnerStaysCancelled.cfg` (since the #482 fix,
`specs/downloads/side-assets/Faithful-S1-off.cfg`). This document and the
module notes name a config as `<folder>/<config>`.

## Verification gates for this plan

- `scripts/check-tla-specs.sh` passes: every module parses and every config ends as its header
  expects, with TLC's exit status, banner and clean finish in agreement.
- A check that was strengthened keeps a `Mutant-*` config (or a tooling test) that fails on the
  mutation it used to pass.
- Each `Faithful-*` config is violated on the property its header names.
- Hermetic PMSKit tests pass, with the pinned findings recorded as known issues, and the reducer
  table test passes without regeneration.
- `scripts/check-tla-drift.py` passes for the branch.
- A finding is closed only by a code change with its own tests, after which its `Finding-*.cfg`
  expects `pass`.
