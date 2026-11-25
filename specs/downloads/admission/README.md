# DownloadsAdmission: the admission window

`DownloadsAdmission.tla` models how a download gets a lane: waiting rows, the pump, supervised
starts and their classification, Pause All and Resume All, and process death. It extends
`DownloadsReducer`, keeps a whole reducer state per row, and changes lifecycle only through
`Reduce`.

Run it with:

```sh
TLC_WORKERS=2 TLC_HEAP=2g scripts/check-tla-specs.sh specs/downloads/admission/DownloadsAdmission.tla
swift test --package-path PMSKit --no-parallel --filter DownloadsFormalModelAdmissionTests
```

## What is modelled

| Actor | Actions | Swift |
| --- | --- | --- |
| User | `UserPause`, `UserResume`, `PauseAll`, `ResumeAll` | `DownloadManager.pause(record:)`, `admitRowAction`, `pauseQueue`, `resumeQueue`; `DownloadQueueToolbarPolicy` decides when each queue button exists |
| Coordinator | `Pump`, `BackoffElapsed` | `pumpAdmission`, `scheduleAdmissionWake`, `DownloadAdmissionPolicy.grants`, `noteAdmissionOccupancy` |
| Start supervisor | `StartApply`, `StartSucceeds`, `StartNoWork`, `StartFails`, `Finish` | `launchAdmittedStart`, `runFirstStart`, `startPlannedRecord`, `retryRecordAsync`, `finishAdmittedStart` |
| Transfer | `TransferCompletes`, `TransferFails` | one task per row; `DownloadsSessionCore` models the detail |
| Backend | `OutageBegins`, `OutageEnds` | a refresh or session that is unavailable |
| Crash | `Crash`, `Relaunch`, `Recover` | process death; `reconcileOnWorker` (`relaunchObserved`), then `admission.recoveryComplete` |

Durable state: the row (`st`, `started`), the Pause All gate and the simultaneous-downloads
setting (`queuePaused`, `cap`, in UserDefaults), the URLSession task the app tracks (`live`) and
a paused row's task whose cancel has not landed (`cancelling`). In memory: supervision (`sup`, `phase`), request backoff
(`backoff`, `deferrals`), pause exemptions (`exempt`), the scheduled pass (`pumpFlag`, `lastSig`)
and the wake timer (`timerArmed`). `Crash` resets every in-memory variable.

A row waits as `planned` (first start) or as paused or failed with `retryRequested`. It occupies
a lane while it is supervised or while an active lifecycle has a task behind it.

## Ways past a cap

The app does not keep occupancy within the cap at all times, and the model follows the three
supported ways past it:

- **The setting changes at runtime** (`SetCap`, `CapChoices`). `DownloadAdmissionCoordinator`
  observes the preference and only wakes admission; running work is untouched. Lowering the
  setting from 3 to 1 leaves up to three occupants.
- **An Emby Convert request reuses a converted source** (`ReuseRows`). The start hands off to the
  static lane with `waitsForTransferSlot: false`, so static occupancy can be one over its cap.
  Until it starts, the row is in the server-preparation lane, which this model does not cap.
- **A pause's cancel lands later** (`AsyncCancel`, `cancelling`). `session.pause` drops its
  tracking before the `getAllTasks` completion cancels the task. The row is no longer an
  occupant, the pump may grant the slot, and for a moment the daemon holds one task more than
  the cap. With a cap of 1: grant, start, Pause, grant the other row, start (8 states).

What the code guarantees, and what the model checks, is that a new grant respects observed
occupancy (`GrantRespectsObservedOccupancy`): occupants are counted as they are, and nothing new
enters the total or a lane that is at or over its cap. `LaneCapRespected` and
`LiveTasksWithinCap` are kept for the configs that fix the setting and have no reuse row, where
they are true; `Current-CapLowered` and `Current-EmbyReuse` violate `LaneCapRespected` in 3 and
4 states and do not check it.

## Bounds

Two lanes: `liveForward` (cap 1) and `staticFile` (cap `max(1, cap - 1)`), under the total
`cap`, which starts at `MaxTotal`. Default configs use two rows, or three rows with at most three user, crash or fault
steps. `MaxDeferrals` is 1 (the code allows 6 transient failures). Rows of one lane are
interchangeable, so safety runs use `SYMMETRY RowSymmetry`.

## Properties

| Property | Kind | Meaning |
| --- | --- | --- |
| `GrantRespectsObservedOccupancy` | action | in every step that begins a supervised start, the total and each lane that received a grant are within the current cap afterwards, counting every observed occupant (B63, B65) |
| `OccupancyBoundedByHistory` | invariant | occupancy never exceeds the highest setting there has been, plus reuse rows that handed off |
| `DaemonTasksBounded` | invariant | the daemon's tasks are bounded the same way, plus one per pause whose cancel has not landed |
| `LaneCapRespected` | invariant | occupancy is within the current cap; true only with a fixed setting and no reuse row |
| `LiveTasksWithinCap` | invariant | the same for the tracked tasks alone |
| `FirstStartGoesThroughWindow` | action | a row that carries the first-start intent is only ever started as a first start, by the pump (B65) |
| `NoOrphanQueued` | invariant | after recovery, an `admitted` row always has a supervised start behind it (B66) |
| `NothingGrantedBeforeRecovery` | invariant | no supervised start exists before startup recovery finished |
| `QueuePauseHolds` | invariant | during Pause All only a row the user resumed by hand is being started |
| `ExemptOnlyWhilePaused` | invariant | exemptions exist only while the queue is paused |
| `UserPauseHolds` | invariant | a row the user paused is not waiting, not being started and has no work until the user resumes it (a pause withdraws a waiting retry) |
| `PauseKeepsFirstStart` | action | a pause that parks a waiting first start keeps `seasonPlanned` (injected mutation) |
| `OutageDefersFirstStart` | action | during an outage a first start never fails its row (B67) |
| `RelaunchKeepsUnstartedRow` | action | recovery never fails a forward-only row without start evidence (A1, #475) |
| `WaitingRowIsServed` | liveness | a waiting row outside Pause All eventually stops waiting |
| `SupervisedStartEnds` | liveness | every supervised start ends |

Liveness assumes the app relaunches and recovers, a scheduled pass runs, timers fire, started work
proceeds and an outage ends, and that the user, crashes and faults take a bounded number of steps.

## Configs

| Config | Expect | Shows |
| --- | --- | --- |
| `Current-TwoForward` | pass | two forward-only rows compete for one slot |
| `Current-Mixed` | pass | a forward-only and a static row under a total of one |
| `Current-ThreeRows` | pass | two forward-only rows and a static row, total two, three environment steps |
| `Current-CapLowered` | pass | a forward-only and a static row, the setting switched between 2 and 1, cancels that land later (143,929 states, 7 s) |
| `Current-EmbyReuse` | pass | three static rows, one a reused Emby source, total two (1,225,736 states, 78 s) |
| `Liveness-OneForward`, `-TwoForward` | pass | both liveness properties under `FairSpec` |
| `Liveness-CapLowered` | pass | two static rows, the setting switched between 3 and 1: occupants over a lowered cap drain and every waiting row is served (114,099 states, 66 s) |
| `Faithful-B63-off` | `GrantRespectsObservedOccupancy` | Resume All starts every parked row at once |
| `Faithful-B65-off` | `FirstStartGoesThroughWindow` | Resume of a paused first start is the generic Retry, outside the window |
| `Faithful-B65-off-Cap` | `GrantRespectsObservedOccupancy` | the consequence: it starts beside a running row |
| `Mutant-PauseErasesFirstStart` | `PauseKeepsFirstStart` | a pause drops the first-start intent |
| `Mutant-StaleCap` | `GrantRespectsObservedOccupancy` | the pump grants against the highest setting it has seen |
| `Faithful-B66-off` | `NoOrphanQueued` | a start without work forgets its request and stays queued |
| `Faithful-B67-off` | `OutageDefersFirstStart` | an outage fails a first start |
| `Mutant-NoBackoffWake` | `TEMPORAL` | without the wake timer a deferred row waits forever (`WaitingRowIsServed`, the one property it checks; the script reports any liveness violation as `TEMPORAL`) |
| `Faithful-A1-off` | `RelaunchKeepsUnstartedRow` | relaunch fails a granted forward-only row cut before its task existed, or a paused first start (A1 before #475) |
| `Deep-ThreeRows` | pass (deep) | the three-row run with four environment steps (2,685,087 states, 108 s at 4 workers) |
| `Deep-CapLowered` | pass (deep) | three rows, the setting switched between 3 and 1 (5,813,009 states, 3.5 min at 4 workers) |

B65 has one switch and one mutant. At the audit baseline a pause changed only the status, the
pending first start was a separate durable mark that the planner cleared when it admitted the
row, and the generic Retry could start the row without the planner. `FixB65` off restores that
bypass and nothing else. Erasing the intent on pause was never in the code; it is
`MutantPauseErasesIntent`. An earlier version of this model had both under `FixB65`, and let
every parked row with no intent skip the window.

## Findings

Finding A1 is issue #475, fixed on `specs/downloads-tla` (pending merge).

**A1: startup recovery failed a forward-only row that never started.** Two orderings:

1. The pump grants a waiting first start (`admissionGranted`: `planned` to `admitted`, intent
   cleared). The process dies while the start is still refreshing the item, before a transfer
   task exists. On relaunch the row has no task, no body and no checkpoint, so `relaunchObserved`
   fails it with `network`, and nothing asks for a lane again. The same start ending in process
   sends `admissionDeferred` and the row waits again (B66, B67).
2. The user pauses a waiting first start, or taps Pause All on a queue of them. The rows are
   `paused(user)` with `seasonPlanned`. After a relaunch the same rule fails each of them, so rows
   the user only paused show as network failures. Resume or Resume All still re-queues them.

The reducer has no fact for "this attempt never started": `DownloadRowFacts` carries route,
checkpoint, body and task, and `admissionGranted` clears the intent. The static lane hides
ordering 1 because launch recovery re-drives interrupted static rows.

The fix needs no new fact. A forward-only row with no task, body or checkpoint has nothing a
failure would discard, so `relaunchObserved` sends an `admitted` one back to `planned` with
`seasonPlanned` (what `admissionDeferred` does in process) and keeps a `paused` one paused, with
its cause and intent. A row with a task, a body or a checkpoint, and a `transferring` row, keep
the old decisions. The model takes this from `Reduce`; `FixRelaunchKeepsUnstarted = FALSE`
(`Faithful-A1-off`) restores the old failure by hand. `RelaunchKeepsUnstartedRow` is checked by
the Current and Deep runs that have a forward-only row, and
`DownloadsFormalModelAdmissionTests.relaunchKeepsForwardOnlyRowThatNeverStarted` passes.

The same rule would be wrong while a granted start is still running: an admitted row whose task
does not exist yet would go back to `planned` under it. Startup reconcile runs before admission
opens (`NothingGrantedBeforeRecovery`); foreground reconcile, which this model does not have,
skips forward-only rows that are supervised or waiting (`forwardOnlyRowsAdmissionMayOwn`).

## Not covered

- The server-preparation lane, lane switches before server work (P4.5) and the render handoff
  into a static slot (#414). `DownloadsServerPrep` owns the prep runners.
- The server-preparation lane's own cap (5) for a reuse row before it starts.
- Two tasks for one row: a row resumed while its old task's cancel is still pending is one
  element of each set here.
- Request order (user before automatic, oldest first): the pump grants any maximal set that fits.
- The admission persistence proof (`admissionPersistenceProofs`), write failures and the
  30-second persistence deadline. Index writes are atomic per action.
- The stale continuation of a start whose supervision a pause ended. The model drops it at the
  pause; the generation fence and the reducer's guards are what make that safe in the code.
- Static range recovery (`launch_interrupted` auto-resume, pending-resume markers, manual resume
  during Pause All) and the season commit gate (`seasonPlanCommitsInFlight`).
- New rows added while the model runs, and Delete.
- Foreground reconcile (`recoverStaticRangeTransfersAfterForeground`) and its exclusion of
  forward-only rows a granted start may own.
- The storage cap at admission (B24), which `DownloadsStorage` owns.
