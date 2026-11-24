# Downloads formal model (TLA+)

**Status (2026-11-24):** the pilot is done on `specs/downloads-tla`: one TLA+ model of the
session, finalize and sweep core with process death, a pinned TLC runner, three required
faithfulness checks (B03, B10, B12) plus three more (B02, B09, replayed outcomes), and two open
findings on the current design, each pinned by a known-issue PMSKit test. No product code changed.
The follow-up models below are not started.

**Scope:** model checking of the downloads manager design. Specs live in `specs/downloads/`; the
runner is `scripts/check-tla-specs.sh`. This plan owns the modelling program and its findings. It
does not own fixes: each finding needs its own issue and change.

**Evidence that motivated it:** the
[bugs versus main audit](../evidence/2026-10-17-downloads-overhaul-bugs-vs-main.md). Its
interleaving-only defects (B02, B03, B04, B06, B09 to B12, B22, B32) were found by review and by
field reports, not by a tool. The [overhaul plan](2026-10-16-downloads-overhaul.md) owns the design
the model describes.

**Out of scope:** proving the Swift implements the model. The model is a hand-written abstraction;
the reducer and policy unit tests and the `LabstreamTests` pins remain the implementation evidence.

## What the pilot models

`DownloadsSessionCore.tla` follows one row from `admitted` to a terminal lifecycle. Durable state
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
| `FinalizingHasBody` | invariant | A finalizing row has the body it is finalizing. |
| `QueuedBodyNotSwept` | invariant | A stash whose append or publication is queued is never unlinked (B03). |
| `StaleCallbackInert` | invariant | A callback from a stale attempt changes nothing (B12). |
| `FinishedBodyNotLost` | invariant | Once the app holds an attempt's whole body, it exists somewhere until a verdict, Delete, or a user pause of a forward-only row discards it. |
| `WorkingBodyKept` | action | A complete body at the working path is only published, condemned, deleted with its row, or replaced by a fresh attempt (B10). |
| `UserPauseSticky` | action | Nothing but the user moves a user-paused row to transferring (B02, B09). |
| `NoStartWhileUserPaused` | action | No task starts for a user-paused row (B02). |
| `ReplayedOutcomeIsNoOp` | action | A replayed finalize outcome changes no durable state. |
| `AdmittedEventuallyStable` | liveness | Under `FairSpec`, an admitted row reaches a terminal lifecycle, a user pause or deletion once the environment stops. |

Fairness for the liveness check: every app action is weakly fair, the daemon resolves every task,
and a task that keeps being retried eventually finishes (strong fairness). User actions, crashes
and foreground returns are not fair and are capped at five steps in the liveness configs.

### Abstractions to keep in mind

- A queued delegate-to-IO hop and its stash claim are one variable. The claim is taken when the
  hop is queued and released when it ends.
- Each action persists atomically. The persistence writer, path leases and the artifact intent
  queue's ordering are not modelled.
- Delete is one durable flag and one cleanup step.
- The pause chain's last step (`markPausedAfterUserPause`) is not modelled. See F2.
- A user pause may discard a finished forward-only body that has not reached `finalizing`. The
  code does this (`finishOpaqueBody` rejects a halted attempt) and Resume restarts such a stream
  from zero, so the model treats it as intended. It is worth a product decision: the static lane
  deliberately keeps a body that finishes during a pause.

## Results (2026-11-24, tla2tools v1.7.4, `-workers auto` on 14 cores)

| Config | Expectation | Result | Distinct states | Time |
| --- | --- | --- | --- | --- |
| `Current-Forward` | pass | pass | 6,038 | 1 s |
| `Current-Static` | pass | pass | 146,692 | 2 s |
| `Current-TwoRows` | pass | pass | 4,822,941 | 21 s |
| `Liveness-Forward` | pass | pass | 13,454 | 2 s |
| `Liveness-Static` | pass | pass | 75,321 | 4 s |
| `Proposed-Forward` | pass | pass | 2,854 | 1 s |
| `Proposed-Static` | pass | pass | 142,535 | 1 s |
| `Faithful-B03-off` | `QueuedBodyNotSwept` violated | violated | stops at first error | < 1 s |
| `Faithful-B10-off` | `WorkingBodyKept` violated | violated | stops at first error | < 1 s |
| `Faithful-B12-off` | `StaleCallbackInert` violated | violated | stops at first error | < 1 s |
| `Faithful-B02-off` | `NoStartWhileUserPaused` violated | violated | stops at first error | < 1 s |
| `Faithful-B09-off` | `UserPauseSticky` violated | violated | stops at first error | < 1 s |
| `Faithful-Replay-off` | `ReplayedOutcomeIsNoOp` violated | violated | stops at first error | < 1 s |
| `Finding-F1-StashCrash` | `FinishedBodyNotLost` violated | violated | stops at first error | < 1 s |
| `Finding-F2-PauseReconcile` | `UserPauseSticky` violated | violated | stops at first error | < 1 s |

The `Current-*` configs are the code as it stands and check every property except the two that
the findings break. `Current-TwoRows` uses one attempt per row and the `complete` verdict only.

### Faithfulness: the model sees the fixed bugs

Each fix is a constant. With the fix off TLC returns the bug's ordering; with it on the same
property passes in the `Current-*` configs.

- **B03 off.** A transfer finishes and its body is stashed with the append queued; the app returns
  to the foreground; the reattach sweep finds no live task for the stash and deletes it while the
  append is still queued.
- **B10 off.** A forward-only transfer finishes and its body reaches the working path; the process
  dies; on relaunch reconcile sees a transferring row with no live task, fails it and deletes the
  finished body.
- **B12 off.** A forward-only transfer of attempt 1 finishes and its publication is queued; the
  user pauses and resumes, which starts attempt 2; the queued hop of attempt 1 runs and writes its
  body into the row attempt 2 now owns.
- **B02 off.** A transfer fails and a delayed retry is queued; the user pauses; the retry fires
  and starts a task for the paused row.
- **B09 off.** The user pauses; a late progress callback moves the row back to transferring.
  This config turns `FixPauseReconcile` on so that F2 does not mask the result.
- **Replay off.** A second truncation verdict stores an unverified publish intent; the same
  verdict arrives again and counts a third strike.

## Findings on the current design

Both were checked against the Swift before being recorded. Neither is fixed here.

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
`Proposed-Forward` shows one sufficient design: persist `bodyCaptured` with the stash, make the
sweep honor that durable reference, and requeue the publication on relaunch.

Pin: `DownloadsFormalModelFindingsTests.finishedForwardOnlyBodyInStashSurvivesRelaunch`.

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
be failed as stalled or restarted). `Proposed-*` shows the reducer-side fix: `relaunchObserved`
never promotes a paused row.

Pin: `DownloadsFormalModelFindingsTests.userPausedRowIsNotPromotedByLiveTaskFact`.

Both pins use `withKnownIssue`: the suite stays green while a finding is open, and the test fails
as soon as the expectations hold, which is the signal to remove the wrapper and flip the
`Finding-*.cfg` to `EXPECT: pass`. They pin the pure decisions. The session glue (the stash claim
and the live-key snapshot) is app code and still needs a `LabstreamTests` pin with each fix.

## Follow-up work, split for parallel worktrees

**Land first: W0, the shared base.** Every later model extends `DownloadsBase.tla`. Today it holds
the lifecycle, pause-cause, route, body and task vocabularies. W0 adds the reducer itself as pure
operators (`Reduce(state, event, facts)`), so that each model applies the same transition table
instead of restating it, and fixes the config header and naming convention. W1 to W7 then own
disjoint modules and do not edit the base; a base change is its own small change that all rebase
onto.

| Item | Scope and actors | Reads | Owns | Depends on | TLC cost | Checks |
| --- | --- | --- | --- | --- | --- | --- |
| W0 base | Reducer as operators; row, attempt, body and task definitions; refactor the pilot onto it | `DownloadLifecycle.swift`, `DownloadLifecycleReducer.swift`, `DownloadLifecycleReducerTests.swift` | `DownloadsBase.tla`, `DownloadsReducer.tla`; edits `DownloadsSessionCore.tla` | none | seconds | reducer table against the unit tests |
| W1 admission | Admission coordinator, lanes and slots, waiting intents, Pause All, backoff. Actors: user, coordinator, start supervisor, crash | `DownloadAdmissionCoordinator.swift`, `DownloadManager+Admission.swift`, `DownloadAdmissionPolicy.swift` | `DownloadsAdmission.tla` | W0 | under 1 min (3 rows, 2 lanes) | B65, B66, B67; lane count never exceeded; no row waits forever. B24 (the storage cap at admission) is shared with W6 |
| W2 server prep | Plex optimize and Emby Convert runners: create, poll, hand off, cancel. Actors: poller, server, user, crash | `DownloadManager+PlexOptimize.swift`, `DownloadManager+EmbyConvert.swift`, `ServerPrepAttemptTracker.swift`, `PlexOptimize*Policy.swift` | `DownloadsServerPrep.tla` | W0 | 1 to 5 min | no orphaned server job; no duplicate create after a crash; hand-off happens once |
| W3 cleanup journal and Delete | Cleanup intent journal, runner, row-deletion barrier, volume-full writes. Actors: user Delete, runner, server, disk (ENOSPC), crash | `DownloadCleanupIntentJournal.swift`, `DownloadCleanupIntentRunner.swift`, `DownloadManager+CleanupRunner.swift`, `DownloadArtifactLifecycleCoordinator.swift` | `DownloadsCleanup.tla` | W0 | 1 to 5 min | B28, B30 (#393), B27 (#392); Delete always ends; no cleanup of a live replacement |
| W4 startup and wake | Startup admission, completion registry, wake budget, finish-events, operation deadlines. Actors: OS wake, handler registration, startup, timers, crash | `BackgroundDownloadWakeCoordinator.swift`, `BackgroundDownloadCompletionRegistry.swift`, `DownloadWakeBudgetContract.swift`, `DownloadManager.swift` (startup) | `DownloadsWake.tla` | W0 | under 1 min | B04, B06, B11, B13; every completion handler is called exactly once and inside its budget |
| W5 side assets | Side-asset park, unpark and cancel ordering; retry authority hand-over. Actors: user, side-asset workers, ordered work coordinator | `DownloadManager+SideCache.swift`, `DownloadSideAssetService.swift`, `OrderedAsyncWorkCoordinator.swift`, `DownloadWorkRegistry.swift` | `DownloadsSideAssets.tla` | W0 | seconds | B32; #394; controls apply in request order |
| W6 storage accounting | Byte accounting, storage-full parking, admission reserve, held-body credit. Actors: transfers, sweeps, admission, disk | `DownloadStorageAdmissionPolicy.swift`, `DownloadVolumeFreeSpace.swift`, `DownloadStore.swift` (accounting) | `DownloadsStorage.tla` | W0; reads W1 | 1 to 5 min (small integer bytes) | B24, B26; accounted bytes equal files on disk; no auto-redrive of a storage-parked row without re-measuring; #401 limits |
| W7 segment trains | Parallel segment trains, held out-of-order bodies and their durable manifests, train epochs, the durable held-body sweep | `BackgroundDownloadSession.swift` (range lane), `StaticRange*Policy.swift` | `DownloadsRangeTrain.tla` | W0; extends the pilot's static lane | 5 to 30 min (2 segments in flight, 3 total) | B22, B00; the rest of B03 for held bodies |

W1 to W7 are independent of each other once W0 lands. W7 is the largest and the closest to the
pilot; give it to whoever fixes F1, since both touch the stash and claim design.

Other follow-ups, smaller than a work item:

- Add `scripts/check-tla-specs.sh` to CI (it needs a JDK and one cached download) once W0 settles
  the layout.
- Model the pause chain's last step and the reconcile generation check, to narrow F2 to the
  orderings that survive in the code.
- File issues for F1 and F2 (not filed by the pilot; the lead decides).

## Verification gates for this plan

- `scripts/check-tla-specs.sh` passes: every module parses and every config ends as its header
  expects.
- Each `Faithful-*` config is violated on the property its header names.
- Hermetic PMSKit tests pass, with the two findings recorded as known issues.
- A finding is closed only by a code change with its own tests, after which its `Finding-*.cfg`
  expects `pass`.
