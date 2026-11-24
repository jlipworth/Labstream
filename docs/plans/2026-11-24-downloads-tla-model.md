# Downloads formal model (TLA+)

**Status (2026-11-24):** the modelling program is done on `specs/downloads-tla`: the pilot (the
session, finalize and sweep core with process death), the shared base W0 (the lifecycle reducer
as shared TLA+ operators, held equal to the Swift by a generated table; a pinned TLC runner with
a default and a deep tier; a drift guard between modelled Swift files and their specs), and the
subsystem models W1 to W8, each with fix-off configs that reproduce fixed bugs. Nineteen new
findings are open, each with an issue; thirteen are pinned by known-issue PMSKit tests. The
models also confirm four known open items (#392, #393, #394 and st-39). No product code changed.
What remains is in [Follow-ups](#follow-ups).

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
be failed as stalled or restarted). `Proposed-*` shows the reducer-side fix: `relaunchObserved`
never promotes a paused row.

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
that decision into a policy and replace the source pin. Issue: #474.

All three pins use `withKnownIssue`: the suite stays green while a finding is open, and the test
fails as soon as the expectations hold, which is the signal to remove the wrapper and flip the
`Finding-*.cfg` to `EXPECT: pass`. They pin the pure decisions. The session glue (the stash claim
and the live-key snapshot) is app code and still needs a `LabstreamTests` pin with each fix.

## Subsystem models (W0 to W8)

Every model extends `DownloadsReducer.tla`, which extends `DownloadsBase.tla`: the vocabulary, and
the reducer as pure operators (`Reduce(state, event, facts)`), so each model applies the same
transition table instead of restating it. The comment block at the top of `DownloadsBase.tla` is
the authoring contract: file and config names, the `MODELS:` header the drift guard reads, the
Crash convention, tiers, and where findings are pinned (`DownloadsFormalModel<Name>Tests.swift`).
Each module has at least one `Faithful-<bug>-off` config for a fixed bug from the audit, or a
`Mutant-*` config where its subsystem has none. Each has a notes file beside it
(`specs/downloads/Downloads<Name>.md`) with its model-to-Swift table, bounds, properties,
per-config results, faithfulness traces, full finding traces, the artefacts fixed in the model
and what it leaves out. `docs/DOWNLOADS-OFFLINE.md` summarises each module.

| Item | Module | Scope | Fixed bugs reproduced | Injected mutants | Findings |
| --- | --- | --- | --- | --- | --- |
| W0 base | `DownloadsBase`, `DownloadsReducer`, `DownloadsReducerTable` (generated), `DownloadsReducerConformance`; `DownloadsSessionCore` moved onto it | Reducer as operators; the pilot | B02, B03, B09, B10, B12, replayed outcomes | | F1, F2, F3 |
| W1 admission | `DownloadsAdmission` | Lanes and the total, waiting rows, the pump, supervised starts, Pause All, backoff | B63, B65, B66, B67 | no backoff wake | Admission-A1 |
| W2 server prep | `DownloadsServerPrep` | Plex optimize and Emby Convert: create or adopt, poll, hand off, cancel | B28, B35, B37, B47 | unchecked hand-off | ServerPrep-S1 |
| W3 cleanup and Delete | `DownloadsCleanup` | Deletion barrier, artifact worker, cleanup journal and runner, a full volume, power loss | B18, B28, B44 | B27 preemption without a fence | Cleanup-C1; confirms B27, B30 |
| W4 wake | `DownloadsWake`, `DownloadsWakeLaunchGate` | Completion registry, wake coordinator, startup admission; the launch recovery gate | B04, B05, B06, B11, B13, B77 | release by identifier | Wake-W1, Wake-W2 |
| W5 side assets | `DownloadsSideAssets` | Work registry, fetch coordinator commands, retry budget, repair pass, Delete | B25, B32 | Delete skips published files | SideAssets-S1 to S4; confirms st-39, #394 |
| W6 storage | `DownloadsStorage` | Byte accounting, the cap, preflights, storage-full parking, the audit | B01, B19, B24, B26, B31, B86 | | Storage-S1 |
| W7 range train | `DownloadsRangeTrain` | Parallel segments, held bodies and manifests, drain, sweeps, reconcile, self-heal | B00, B03, B22 | no alignment check; no epoch check | RangeTrain-R1, RangeTrain-R2 |
| W8 status and speed | `DownloadsStatus` | Aggregate and row speed, bytes, phase, caption | pu-33, B09 | #379 partial sum; #224 no catch-up guard; #416 segment dip | Status-S1 to S4 |

W8 was added to the program after the plan was first written; it has no row in the audit's bug
table for #379, #224 and #416, so those three are mutants.

### Results of the merged run (2026-11-24, tla2tools v1.7.4, `TLC_WORKERS=auto`, 14 cores)

Every config ended as its header expects. The table sums each module's configs; the notes files
have the per-config rows, measured at `TLC_WORKERS=2 TLC_HEAP=2g`.

| Module | Configs | Pass | Violated as expected | Deep | Largest state space (config) | Default tier | Deep tier |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `DownloadsSessionCore` | 19 | 10 | 9 | 1 | 7,597,623 (`Deep-TwoStatic`) | 37 s | 51 s |
| `DownloadsReducerConformance` | 2 | 2 | 0 | 0 | 1 (`Projection-SessionCore`) | 3 s |  |
| `DownloadsAdmission` | 14 | 7 | 7 | 1 | 2,727,903 (`Admission-Deep-ThreeRows`) | 34 s | 34 s |
| `DownloadsServerPrep` | 14 | 7 | 7 | 0 | 60,392 (`ServerPrep-Current-EmbyThreePollers`) | 14 s |  |
| `DownloadsCleanup` | 12 | 5 | 7 | 0 | 1,426,644 (`Cleanup-Current-TwoRows`) | 18 s |  |
| `DownloadsWake` | 11 | 3 | 8 | 0 | 3,412,505 (`Wake-Current-Wake`) | 44 s |  |
| `DownloadsWakeLaunchGate` | 2 | 1 | 1 | 0 | 112 (`WakeLaunchGate-Current-Gate`) | 1 s |  |
| `DownloadsSideAssets` | 27 | 16 | 11 | 1 | 14,221,199 (`SideAssets-Deep-AllKinds`) | 61 s | 80 s |
| `DownloadsStorage` | 15 | 7 | 8 | 0 | 256,342 (`Storage-Current-TwoStatic`) | 18 s |  |
| `DownloadsRangeTrain` | 15 | 8 | 7 | 2 | 4,182,753 (`RangeTrain-Deep-TwoRows`) | 15 s | 59 s |
| `DownloadsStatus` | 22 | 13 | 9 | 1 | 8,434,679 (`Status-Deep-TwoStatic`) | 90 s | 69 s |
| Total | 153 | 79 | 74 | 6 | | 335 s | 293 s |

### Findings from the subsystem models

Each was checked against the Swift before it was recorded. "Probable" means the code path is
certain from reading and the trigger or the intent is not: it needs a device, a running test or a
product decision. A finding with no pin is decided in app-target code or has no pure PMSKit
decision to call. Full traces and evidence are in the module notes and the issues.

| Finding | What goes wrong | Verdict | Config | Pin (`DownloadsFormalModel<Name>Tests`) | Issue |
| --- | --- | --- | --- | --- | --- |
| Admission-A1 | Startup recovery fails a forward-only row that never started (a granted start cut by a crash, or a first start the user paused). | real, medium | `Admission-Finding-A1-RelaunchFailsUnstartedRow` | `relaunchKeepsForwardOnlyRowThatNeverStarted` | #475 |
| ServerPrep-S1 | Retry of a failed Plex preparation row abandons its running optimize job with no durable cancel and creates a second job. | real, low to medium | `ServerPrep-Finding-S1-RetryOrphansRender`, `ServerPrep-Finding-S1-HandoffLeavesJob` | `retryOfFailedPlexPrepKeepsOrCancelsItsJob` | #478 |
| Cleanup-C1 | After a failed intent commit, an explicit artifact recovery re-registers the row deletion with prepared revision 0, and files are unlinked before the intent is durable. | real, low to medium | `Cleanup-Finding-C1-UnlinkBeforeDurableIntent` | `rowDeletionUnlinksOnlyAfterDurableIntent` | #479 |
| B27 | A legacy validated promotion whose body is gone makes Delete a permanent no-op. A fix must make Delete and the launch promotion recovery exclude each other. | real, known | `Cleanup-Finding-B27-LegacyPromotionWedgesDelete` | `deleteIsNotRefusedByLegacyPromotion` | #392 |
| B30 | On a completely full volume the deletion intent cannot be saved, so nothing is unlinked. Fix together with Cleanup-C1. | real, known | `Cleanup-Finding-B30-FullVolumeDelete` | `deleteOnFullVolumeReclaims` | #393 |
| Wake-W1 | A completion handler that arrives while a claimed batch waits for its MainActor release inherits that batch's deadline. | probable, low | `Wake-Finding-W1-StaleDeadline` | none (app-target code) | #480 |
| Wake-W2 | An operation begun while an expired operation lingers is marked expired and does not hold the next wake. | probable, low; may be intended | `Wake-Finding-W2-UnsettledWork` | none (app-target code) | #481 |
| SideAssets-S1 | A cancel that keeps the attempt leaves the poster's coordinator owner cancelled for the launch, so the poster is never fetched. | real, medium | `SideAssets-Finding-S1-PosterOwnerStaysCancelled` | `posterFetchReopensItsCancelledOwner` | #482 |
| SideAssets-S2 | Pause All parks a completed row's side assets, Resume All never unparks them, and repair cannot re-enter a registered kind. | real, medium | `SideAssets-Finding-S2-PauseAllStrandsCompletedRow` | `resumeAllUnparksCompletedRows` | #483 |
| SideAssets-S3 | A server outage spends the per-launch retry budget for an asset the server has. | probable, low; product decision | `SideAssets-Finding-S3-OutageExhaustsBudget` | none | #484 |
| SideAssets-S4 | A refused Resume leaves a user-paused row's side assets unparked. | probable, low; product decision | `SideAssets-Finding-S4-RefusedResumeUnparks` | none | #485 |
| st-39 | A side-asset file renamed but not yet recorded is left on disk by Delete, after a crash or after a replacement attempt. | real, known, deferred | `SideAssets-Finding-st39-CrashOrphanAfterDelete`, `SideAssets-Finding-st39-ReplacedAttemptOrphan` | none | #401 |
| #394 | Fetched chapter payloads wait in memory behind one-at-a-time preparation. | real, known | `SideAssets-Finding-394-PayloadsBehindPreparation` | none | #394 |
| Storage-S1 | An automatic requeue erases a storage-full park, so the row is redriven once without measuring free space. | real, low | `Storage-Finding-S1-RequeueErasesPark` | `automaticRequeueKeepsTheStoragePark` | #486 |
| RangeTrain-R1 | A drain pass run by a held-body removal completion discards its result, so nothing finalizes the file or tops the train up until the self-heal. | real, low | `RangeTrain-Finding-R1-StrandedDrain` | `removalCompletionDrainContinuesTheTrain` | #477 |
| RangeTrain-R2 | Reconcile fails a static row whose finished body is stashed and queued for append; for a one-segment file that is the whole download. | real, medium | `RangeTrain-Finding-R2-ReconcileFailsQueuedBody` | `reconcileCountsQueuedBodiesAsLiveWork` | #476 |
| Status-S1 | A silently stalled transfer hides the batch speed for as long as it is silent. | real, medium | `Status-Finding-S1-SilentMemberHidesSpeed` | `silentTransferDoesNotHideBatchSpeedForever` | #487 |
| Status-S2 | A stalled static-range row keeps showing a stale speed and ETA, because the refresh loop stops first. | real, medium | `Status-Finding-S2-StaleRowSpeed` | `stalledStaticRowStopsShowingSpeed` | #488 |
| Status-S3 | After a process death a static-range row shows fewer bytes than before, with no reducer reset. | probable, low | `Status-Finding-S3-RelaunchDip` | none | #490 |
| Status-S4 | A forward-only row's first callback after the 4 s foreground grace inflates its speed. | probable, low | `Status-Finding-S4-LateCallbackInflatesRow` | none | #489 |

Findings that touch each other:

- F1, F3 and RangeTrain-R2 all sit in the window between the `tmp/` stash and the working file.
  Persisting the capture (the F1 proposal) closes F3's last window.
- F2 and RangeTrain-R2 are the two directions of one snapshot: reconcile's live keys are too
  generous for a paused row and too strict for a row with queued work. The R2 fix must not count
  session work as live for a paused row.
- Admission-A1 and F3's crash ordering both go through the last branch of `relaunchObserved`.
- Cleanup-C1 is today the only way Delete frees space on a full volume for a row with no server
  job, so C1 and B30 should be fixed together.
- Status-S2 is the common case partly because of Status-S1: while the aggregate is hidden, no
  refresh loop runs.

## Follow-ups

Fixes are tracked by the issues above. The rest is about the models and their tooling.

Tooling:

- `scripts/check-tla-specs.sh` reports a violated liveness property as `TEMPORAL`, so nine
  configs declare `EXPECT: violation TEMPORAL` and name the property in a comment. The script
  could read the property from a config that lists exactly one.
- `.woodpecker/tla.yml` runs the model check on the macOS runner, which is not enrolled yet
  (`docs/MACOS-CI.md`). Neither it nor `.woodpecker/tla-drift.yml` has run on Woodpecker. A
  Linux container with a JDK could run the default tier on pull requests today.
- The drift guard: `DownloadsServerPrep`, `DownloadsCleanup` and `DownloadsStatus` list
  `DownloadManager.swift` (and `DownloadsCleanup` lists `DownloadStore.swift`) on `MODELS:`
  lines, beside `BackgroundDownloadSession.swift` and `DownloadStore.swift` for the session core
  and the range train.
  Those files change often, so most downloads changes will need a spec edit or a
  `Spec-Unaffected:` trailer. `DownloadsStorage` and `DownloadsRangeTrain` left
  `DownloadManager.swift` out for that reason although they model code in it. Decide whether to
  keep the friction, narrow the guard to functions, or move the modelled code into smaller files.
- Default-tier cost. `DownloadsSideAssets` and `DownloadsStatus` are the slowest modules. If the
  default run is too long for CI, `SideAssets-Current-AllKinds`, `Status-Current-Mixed` and
  `Status-Current-TwoStatic` are the candidates for the deep tier.
- `DownloadsReducerTable.tla` is a 312 KB generated file. Fewer histories in the relaunch grid
  would cut it to about a third, at the cost of coverage.

Pins:

- Wake-W1, Wake-W2, Status-S3 and Status-S4 need `LabstreamTests` pins; sketches for the two wake
  findings are in `specs/downloads/DownloadsWake.md`. RangeTrain-R2 and Cleanup-C1 were confirmed
  by reading and want a runtime reproduction (hold the range-IO queue; full-volume fault
  injection).
- Several pins read app source as text because the decision is inline app code: F3,
  ServerPrep-S1, Cleanup-C1, B27, B30, SideAssets-S1 and S2, Storage-S1, RangeTrain-R1 and R2,
  Status-S2. Each fix should move the decision into a PMSKit policy and replace the pin. The B30
  pin watches the bare failure branch; a reserve-based fix may leave that text unchanged, and
  the pin must then be removed by hand.

Reducer and base gaps the models met:

- `DownloadRowFacts` has no fact for "this attempt never started", and `admissionGranted` clears
  the intent (Admission-A1). A fix needs a reducer or facts change and a regenerated table.
- `storagePark` and `transferInterrupted(.storage)` are unreachable: every app storage-full path
  submits `transferFailed(.storage)` (Storage-S1). Wire it or remove it.
- The app never submits the reducer's `prepHandoff` event. The Plex hand-off is a metadata
  rewrite plus `transferStarted`, and the Emby hand-off replaces the attempt.
- `TaskStates` in the base includes `"failed"`, which `DownloadsStatus` does not use, so it
  defines its own set.

Not modelled, worth a later model or a hermetic test:

- Interactions across modules: admission with the server-preparation lane and the render handoff
  (#414); a reconcile-promoted pause (F2) leaving the side-asset owner parked on a running row;
  the cleanup runner's boundary between `DownloadsServerPrep` and `DownloadsCleanup`; retry by
  replacement and paths shared across rows in cleanup.
- The pause chain's last step and the reconcile generation check, to narrow F2 to the orderings
  that survive in the code.
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

## Verification gates for this plan

- `scripts/check-tla-specs.sh` passes: every module parses and every config ends as its header
  expects.
- Each `Faithful-*` config is violated on the property its header names.
- Hermetic PMSKit tests pass, with the pinned findings recorded as known issues, and the reducer
  table test passes without regeneration.
- `scripts/check-tla-drift.py` passes for the branch.
- A finding is closed only by a code change with its own tests, after which its `Finding-*.cfg`
  expects `pass`.
