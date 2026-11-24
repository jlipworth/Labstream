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

Durable state: the row (`st`, `started`), the Pause All gate (`queuePaused`, in UserDefaults) and
the URLSession task (`live`). In memory: supervision (`sup`, `phase`), request backoff
(`backoff`, `deferrals`), pause exemptions (`exempt`), the scheduled pass (`pumpFlag`, `lastSig`)
and the wake timer (`timerArmed`). `Crash` resets every in-memory variable.

A row waits as `planned` (first start) or as paused or failed with `retryRequested`. It occupies
a lane while it is supervised or while an active lifecycle has a task behind it.

## Bounds

Two lanes: `liveForward` (cap 1) and `staticFile` (cap `max(1, MaxTotal - 1)`), under the total
`MaxTotal`. Default configs use two rows, or three rows with at most three user, crash or fault
steps. `MaxDeferrals` is 1 (the code allows 6 transient failures). Rows of one lane are
interchangeable, so safety runs use `SYMMETRY RowSymmetry`.

## Properties

| Property | Kind | Meaning |
| --- | --- | --- |
| `LaneCapRespected` | invariant | supervised starts plus running transfers never exceed a lane cap or the total (B63) |
| `LiveTasksWithinCap` | invariant | the same for the tasks alone |
| `NoOrphanQueued` | invariant | after recovery, an `admitted` row always has a supervised start behind it (B66) |
| `NothingGrantedBeforeRecovery` | invariant | no supervised start exists before startup recovery finished |
| `QueuePauseHolds` | invariant | during Pause All only a row the user resumed by hand is being started |
| `ExemptOnlyWhilePaused` | invariant | exemptions exist only while the queue is paused |
| `UserPauseHolds` | invariant | a row the user paused is not waiting, not being started and has no work until the user resumes it (a pause withdraws a waiting retry) |
| `PauseKeepsFirstStart` | action | a pause that parks a waiting first start keeps `seasonPlanned` (B65) |
| `OutageDefersFirstStart` | action | during an outage a first start never fails its row (B67) |
| `RelaunchKeepsUnstartedRow` | action | recovery never fails a forward-only row without start evidence (finding A1; not in the Current runs) |
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
| `Liveness-OneForward`, `-TwoForward` | pass | both liveness properties under `FairSpec` |
| `Faithful-B63-off` | `LaneCapRespected` | Resume All starts every parked row at once |
| `Faithful-B65-off` | `PauseKeepsFirstStart` | a pause drops the first-start intent |
| `Faithful-B65-off-Cap` | `LaneCapRespected` | the consequence: Resume then bypasses the window |
| `Faithful-B66-off` | `NoOrphanQueued` | a start without work forgets its request and stays queued |
| `Faithful-B67-off` | `OutageDefersFirstStart` | an outage fails a first start |
| `Mutant-NoBackoffWake` | `TEMPORAL` | without the wake timer a deferred row waits forever (`WaitingRowIsServed`; the script reports any liveness violation as `TEMPORAL`) |
| `Finding-A1-RelaunchFailsUnstartedRow` | `RelaunchKeepsUnstartedRow` | finding A1 |
| `Proposed-A1-RelaunchKeepsUnstartedRow` | pass | the proposed fix, with every safety property |
| `Deep-ThreeRows` | pass (deep) | the three-row run with four environment steps |

## Findings

Finding A1 is issue #475.

**A1: startup recovery fails a forward-only row that never started.** Two orderings:

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
ordering 1 because launch recovery re-drives interrupted static rows. Pinned by
`DownloadsFormalModelAdmissionTests.relaunchKeepsForwardOnlyRowThatNeverStarted`. The proposed
fix (`FixRelaunchKeepsUnstarted`) sends a granted row without start evidence back to `planned`
and leaves a paused one paused.

## Not covered

- The server-preparation lane, lane switches before server work (P4.5) and the render handoff
  into a static slot (#414). `DownloadsServerPrep` owns the prep runners.
- A change of the simultaneous-downloads setting while work runs, which can leave a lane over its
  cap until work ends.
- Request order (user before automatic, oldest first): the pump grants any maximal set that fits.
- The admission persistence proof (`admissionPersistenceProofs`), write failures and the
  30-second persistence deadline. Index writes are atomic per action.
- The stale continuation of a start whose supervision a pause ended. The model drops it at the
  pause; the generation fence and the reducer's guards are what make that safe in the code.
- Static range recovery (`launch_interrupted` auto-resume, pending-resume markers, manual resume
  during Pause All) and the season commit gate (`seasonPlanCommitsInFlight`).
- New rows added while the model runs, and Delete.
- The storage cap at admission (B24), which `DownloadsStorage` owns.
