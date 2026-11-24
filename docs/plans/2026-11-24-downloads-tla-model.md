# Downloads formal model (TLA+)

**Status (2026-11-24):** the pilot and the shared base (W0) are done on `specs/downloads-tla`:
one TLA+ model of the session, finalize and sweep core with process death; the lifecycle reducer
as shared TLA+ operators, held equal to the Swift by a generated table; a pinned TLC runner with
a default and a deep tier; a drift guard between modelled Swift files and their specs; three
required faithfulness checks (B03, B10, B12) plus three more (B02, B09, replayed outcomes); and
three open findings on the current design, each pinned by a known-issue PMSKit test. No product
code changed. The follow-up models W1 to W7 below are not started.

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
| `FinalizingHasBody` | invariant | A finalizing row has the body it is finalizing. |
| `QueuedBodyNotSwept` | invariant | A stash whose append or publication is queued is never unlinked (B03). |
| `StaleCallbackInert` | invariant | A callback from a stale attempt changes nothing (B12). |
| `FinishedBodyNotLost` | invariant | Once the app holds an attempt's whole body, it exists somewhere until a verdict or Delete discards it. This is the crash property (F1); the pause case is the next row. |
| `FinishedBodySurvivesPause` | action | While a row is paused by the user, no step of a live process gives up the whole body it holds, unless the body is published, condemned, deleted with its row, or replaced by a fresh attempt the user asked for (F3). |
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
- The session model keeps six of the reducer's ten state fields per row. `Projection-SessionCore`
  proves that the four it drops (`lastFailure`, `unverifiedReason`, `admissionIntent`,
  `storagePark`) never influence the others for the events it sends.
- One task slot per attempt. A queued rebuild can start a second task for an attempt whose body
  is still being appended, so a row can reach `finalizing` with a task running. That ordering was
  not checked against the Swift; it only widens what the model explores.

### Keeping the reducer equal to the Swift

`DownloadsReducer.tla` is not maintained by review. The PMSKit test
`DownloadsFormalModelReducerTests` runs the real reducer over 225 states (9 lifecycles by 25
histories), 126 event shapes and 163 fact combinations, and renders the results as
`specs/downloads/DownloadsReducerTable.tla`. The test fails when the checked-in table is stale;
`Reducer-Conformance.cfg` fails when `Reduce` does not return exactly that table or when the table
misses part of the vocabulary. Either side changing alone fails one of the two.
`docs/DOWNLOADS-OFFLINE.md` has the regeneration command.

Moving the pilot onto the reducer changed one behaviour, a modelling artefact: the pilot moved a
finalizing row back to transferring when reattach adopted a task for it. The code submits
`taskAdopted`, the reducer rejects it for a finalizing row, and the row stays finalizing. With
that one step left as the pilot wrote it, every passing config has the pilot's exact state count,
so nothing else changed.

## Results (2026-11-24, tla2tools v1.7.4, `TLC_WORKERS=2 TLC_HEAP=2g`)

| Config | Expectation | Result | Distinct states | Time |
| --- | --- | --- | --- | --- |
| `Current-Forward` | pass | pass | 6,038 | 1 s |
| `Current-Static` | pass | pass | 90,686 | 2 s |
| `Current-TwoForward` (symmetry) | pass | pass | 233,692 | 7 s |
| `Current-TwoRows` | pass | pass | 2,531,988 | 69 s |
| `Liveness-Forward` | pass | pass | 13,454 | 2 s |
| `Liveness-Static` | pass | pass | 68,653 | 14 s |
| `Proposed-Forward` | pass | pass | 2,854 | 1 s |
| `Proposed-Static` | pass | pass | 86,529 | 2 s |
| `Proposed-F3-PauseKeepsBody` | pass | pass | 4,932 | 1 s |
| `Reducer-Conformance` | pass | pass | one state; 65,025 reducer results compared | 1 s |
| `Projection-SessionCore` | pass | pass | one state | 1 s |
| `Deep-TwoStatic` (deep tier, symmetry) | pass | pass | 7,597,623 | 247 s |
| `Faithful-B03-off` | `QueuedBodyNotSwept` violated | violated | stops at first error | < 1 s |
| `Faithful-B10-off` | `WorkingBodyKept` violated | violated | stops at first error | < 1 s |
| `Faithful-B12-off` | `StaleCallbackInert` violated | violated | stops at first error | < 1 s |
| `Faithful-B02-off` | `NoStartWhileUserPaused` violated | violated | stops at first error | < 1 s |
| `Faithful-B09-off` | `UserPauseSticky` violated | violated | stops at first error | < 1 s |
| `Faithful-Replay-off` | `ReplayedOutcomeIsNoOp` violated | violated | stops at first error | < 1 s |
| `Finding-F1-StashCrash` | `FinishedBodyNotLost` violated | violated | stops at first error | < 1 s |
| `Finding-F2-PauseReconcile` | `UserPauseSticky` violated | violated | stops at first error | < 1 s |
| `Finding-F3-PauseDiscardsFinishedBody` | `FinishedBodySurvivesPause` violated | violated | stops at first error | < 1 s |

The `Current-*` configs are the code as it stands and check every property except the ones the
findings break. `Current-Static` also checks `FinishedBodySurvivesPause`: the static lane keeps a
body that finishes during a pause. `Current-TwoRows` uses one attempt per row and the `complete`
verdict only.

State counts against the pilot (which ran the same configs with `-workers auto`):

| Config | Pilot | Now | Why |
| --- | --- | --- | --- |
| `Current-Forward`, `Liveness-Forward`, `Proposed-Forward` | 6,038; 13,454; 2,854 | the same | |
| `Current-Static` | 146,692 | 90,686 | The adoption artefact above. |
| `Current-TwoRows` | 4,822,941 | 2,531,988 | The same. 88 s before, 69 s now, both at two workers. |
| `Liveness-Static` | 75,321 | 68,653 | The same. |
| `Proposed-Static` | 142,535 | 86,529 | The same. |

Symmetry: TLC's `SYMMETRY` is sound only over model values the spec never tells apart, and never
for liveness. The pilot's configs have one row, or one forward-only and one static-range row, so
none of them has interchangeable rows and none gained a symmetry set. The two configs that do
have interchangeable rows use it: `Current-TwoForward` explores 233,692 distinct states instead
of 466,603, and `Deep-TwoStatic` 7,597,623 (not run without it). Attempt IDs are ordered
integers and are not symmetric.

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

All three were checked against the Swift before being recorded. None is fixed here.

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
guard treats a pause halt like a cancel. `Current-Static` passes the property; `Finding-F3` does
not.

Verdict: real. The first ordering needs only a pause near the end of a transfer, with no crash,
and costs a full re-transcode. The second needs a crash in a short window.
`Proposed-F3-PauseKeepsBody` shows the fix on its own: the queued publication accepts a pause
halt (and still rejects a cancel), and relaunch finalizes a paused forward-only row whose body
is at the working path. One window stays open under that fix: a Resume that lands between the
stash and the working path still starts a fresh attempt. The property allows it, as a fresh
attempt the user asked for. Persisting the capture (the F1 proposal) closes it, because the row
is then `finalizing` before the user can act.

Pin: `DownloadsFormalModelFindingsTests.finishedForwardOnlyBodySurvivesUserPause`. It pins the
reducer's relaunch decision and, because the first ordering is decided inline in app code with
no PMSKit policy to call, the guard in `finishOpaqueBody` as source text. The fix should move
that decision into a policy and replace the source pin.

All three pins use `withKnownIssue`: the suite stays green while a finding is open, and the test
fails as soon as the expectations hold, which is the signal to remove the wrapper and flip the
`Finding-*.cfg` to `EXPECT: pass`. They pin the pure decisions. The session glue (the stash claim
and the live-key snapshot) is app code and still needs a `LabstreamTests` pin with each fix.

## Follow-up work, split for parallel worktrees

**W0, the shared base, has landed.** Every later model extends `DownloadsReducer.tla`, which
extends `DownloadsBase.tla`: the vocabulary, and the reducer as pure operators
(`Reduce(state, event, facts)`), so that each model applies the same transition table instead of
restating it. The comment block at the top of `DownloadsBase.tla` is the authoring contract:
file and config names, the `MODELS:` header the drift guard reads, the Crash convention, tiers,
and where findings are pinned (`DownloadsFormalModel<Name>Tests.swift`). W1 to W7 own disjoint
modules and do not edit the base; a base change is its own small change that all rebase onto.
Each module needs at least one `Faithful-<bug>-off` config for a fixed bug from the audit, or a
`Mutant-*` config when its subsystem has none.

| Item | Scope and actors | Reads | Owns | Depends on | TLC cost | Checks |
| --- | --- | --- | --- | --- | --- | --- |
| W0 base (done) | Reducer as operators; row, attempt, body and task definitions; the pilot refactored onto it | `DownloadLifecycle.swift`, `DownloadLifecycleReducer.swift` | `DownloadsBase.tla`, `DownloadsReducer.tla`, `DownloadsReducerTable.tla` (generated), `DownloadsReducerConformance.tla`; edits `DownloadsSessionCore.tla` | none | seconds | the generated reducer table |
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

- `.woodpecker/tla.yml` runs the model check on the macOS runner, which is not enrolled yet
  (`docs/MACOS-CI.md`). Neither it nor `.woodpecker/tla-drift.yml` has run on Woodpecker. A
  Linux container with a JDK could run the default tier on pull requests today; the script
  already accepts a `java` on `PATH` off macOS.
- Model the pause chain's last step and the reconcile generation check, to narrow F2 to the
  orderings that survive in the code.
- File issues for F1, F2 and F3.

## Verification gates for this plan

- `scripts/check-tla-specs.sh` passes: every module parses and every config ends as its header
  expects.
- Each `Faithful-*` config is violated on the property its header names.
- Hermetic PMSKit tests pass, with the three findings recorded as known issues, and the reducer
  table test passes without regeneration.
- `scripts/check-tla-drift.py` passes for the branch.
- A finding is closed only by a code change with its own tests, after which its `Finding-*.cfg`
  expects `pass`.
