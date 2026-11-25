# DownloadsSessionCore: module notes

`DownloadsSessionCore.tla` is the pilot model: one row from `admitted` to a terminal lifecycle
through the session, the finalizer, the stash sweep and relaunch recovery, with process death. Its
design, properties and the F1 to F3 traces (F2 is fixed: `Faithful-F2-off`) are in
[docs/plans/2026-11-24-downloads-tla-model.md](../../../docs/plans/2026-11-24-downloads-tla-model.md).
This page holds what the second review round changed, the F1 and F3 fixes and the current
results.

```sh
TLC_WORKERS=2 TLC_HEAP=2g scripts/check-tla-specs.sh specs/downloads/session
swift test --package-path PMSKit --no-parallel --filter DownloadsFormalModelFindingsTests
```

## Modules

| Module | Role |
| --- | --- |
| `DownloadsSessionCore` | The model. |
| `DownloadsSessionRowMap` | The two operators that store a reducer state as a row and rebuild it (`SessionStored`, `SessionRow`). `Row` and `ApplyRow` in the model are these. |
| `DownloadsSessionRowMapCheck` | Checks that mapping against the generated reducer table. |
| `DownloadsCapturePublication` | The publication of one finished forward-only body, which the model above treats as one queued hop: the claim, the capture, the working path's lease, and the publications that compete or wait. Configs `CapturePublication-*`. |

The session keeps five fields of a reducer state. `SessionRowMapCheck-Current-RowMap` checks, for
every table state, every event the session sends and every fact record, that reducing the real
state and reducing the rebuilt one are accepted alike, carry the same effects and store the same
row. It runs the operators the model runs, so a mapping error fails it
(`SessionRowMapCheck-Mutant-RowDrops*`). `Projection-SessionCore` stays as the weaker statement
about field names.

## What the second round changed

- **The finalize rename window (F4).** A failing truncation verdict is applied in memory, the body
  is renamed off the working path at once, and only then does the finalizer wait for the
  verdict's commit. `FinalizeTruncatedCrash` is the rename followed by a crash. `FinalizingHasBody`
  is restated with that residue as its one exception (a `finalizing` row with no body and no
  finalizer, until reconcile fails it); `FinalizingAlwaysHasBody` is the old statement, which is
  false today.
- **The static pause sweep (F3 on the static lane).** `PauseSweep` is the pause's task listing
  completing: it supersedes every listed task, a finished one too, and `DidFinishDownloading`
  ignores a superseded task. `HoldsWholeBody` now holds from the moment the last segment has
  finished, not from the moment the working file is whole, so `FinishedBodySurvivesPause` speaks
  about the static lane as well.
- **B12** is the manager's side of a transfer-error handoff, not every callback. Session
  callbacks always check their exact attempt; `FixB12 = FALSE` makes `RebuildFires` look a
  forward-only row up by key, so a handoff from a replaced attempt fails its replacement.
- **Replay** (`FixReplay = FALSE`) is the counter before R2-5: one strike per truncated finalizer
  run, with no outcome IDs in the reducer or in `recordingTruncation`.
- **Admission-A1 (#475).** Reconcile sends a forward-only row with no task, body or checkpoint
  back to `planned`; `AdmissionGranted` is the window granting it again once reconcile is done
  (`DownloadsAdmission` models the window itself). Foreground reconcile in the code skips
  forward-only rows a granted start may own; this model reconciles them too, which only adds
  behaviours.
- **Liveness** assumptions are written out above `Fairness`: the session's own steps run; a
  retried task eventually finishes (the code has retry budgets instead, which the model does not
  count); the manager's main-actor steps run, which a suspended background app does not get.
  `StallDetected` exists only on the forward-only lane in the code; on the static lane it stands
  in for the manager's stale-row recovery, which `DownloadsRangeTrain` models.

## F1 and F3 are fixed

Fixed on `specs/downloads-tla`, pending merge (#472, #474). `DurableCapture` and
`FixPauseKeepsBody` are the shipping behaviour and are `TRUE` in every config except the three
`Faithful-F*-off` ones (`FixProgressKeepsFinished`, from the review below, in every config
except `Faithful-F3-off-Progress`).

- **`DurableCapture` (F1).** `DidFinishDownloading` puts a forward-only body at the attempt's
  capture path and records `bodyCaptured`, so the row is `finalizing` before the queued
  publication. In the model `stash` holds that body too. Reattach keeps it while the row is not
  terminal (the row references the path, so the staging sweep leaves it), `RelaunchFacts`
  reports it as `captured` for a forward-only row, and the reducer's `requestFinalization`
  requeues the publication. Swift: `DownloadStore.forwardOnlyCapturedBodyURL`,
  `capturedBodyRelativePath`, `artifactPathsReferenced`, `observeLifecycleFacts`;
  `BackgroundDownloadSession.requeueCapturedForwardOnlyBody`.
  - The capture and its row change are one step here (index persistence is atomic per action).
    In the code the rename comes first. The reducer covers the gap: an admitted, transferring
    or paused forward-only row with a captured body and no task finalizes on relaunch, and the
    row references the path in every non-terminal lifecycle.
  - A response that fails the HTTP checks is not captured
    (`ForwardOnlyFinishedBodyPolicy.custody`); the model has no such response.
- **`FixPauseKeepsBody` (F3).** `RangeIO` publishes a forward-only body behind a pause halt
  (`ForwardOnlyFinishedBodyPolicy.publication`) and drops that halt, because the finalizer stands
  down for any halt. The reducer finalizes a paused forward-only row whose whole body is at the
  working path, so `RelaunchObserved` has no hand-written branch for it any more;
  `FixPauseKeepsBody = FALSE` hides that body from the reducer, which is what the old clause
  did. On the static lane `PauseSweep` leaves a finished task tracked
  (`StaticRangeFinishedBodyPolicy.pauseSweepDisposition`).
- `Faithful-F1-off` is `DurableCapture = FALSE` alone. `Faithful-F3-off` needs both switches
  off: with the capture on, the row is `finalizing` before a pause can land, and the body
  survives without the F3 rule. `Faithful-F3-off-Static` is `FixPauseKeepsBody = FALSE` on a
  static row.
- `Proposed-F3-PauseKeepsBody` is removed. `Proposed-Forward` and `Proposed-Static` now differ
  from `Current-*` by the F4 proposal only.

## The review of the F1 and F3 fixes

An independent review of the fixes found three orderings they had left open. All three are
fixed on `specs/downloads-tla`, pending merge.

### A progress callback under a pause undid the static pause fix (#474)

`PauseSweep` leaves a finished task tracked. The progress handler did not: under any halt it
dropped the task's tracking, marked it superseded and cancelled it, and the last progress of a
finished task can run between the pause and the finish callback. `HaltedProgress` is that step;
`Faithful-F3-off-Progress` (`FixProgressKeepsFinished = FALSE`) is the trace. The handler now
asks `StaticRangeFinishedBodyPolicy.haltedProgressDisposition`. The range-train notes have the
detail (R3).

### Two publications of one captured body deleted it (#472)

`DownloadsCapturePublication`, `CapturePublication-Faithful-Duplicate-off`:

1. A forward-only transfer finishes. The delegate moves the body to the attempt's capture path.
2. Launch recovery runs before the delegate's next line. It finds a body at the capture path
   that nothing claims, claims it and queues a publication.
3. The delegate writes its claim over that one and queues a second publication.
4. The first publication takes the working path's lease, moves the body there and requests
   finalization.
5. The second takes the lease, clears the working path, finds no capture to move and fails the
   row. The only copy of the body is gone.

Fix, in two halves:

- `FixClaimBeforeCapture`. The delegate claims the body's publication before it moves the body
  to the capture path (`ForwardOnlyPublicationLedger.claim`, keyed by that path). Recovery then
  cannot claim it. If the claim fails, a publication of this attempt's body already exists (a
  body a dead process captured, taken by recovery) and the finish is a second delivery: its temp
  file is dropped and the capture is left alone. `CapturePublication-Faithful-ClaimFirst-off`
  shows two publications without it (`OnePublication`).
- `FixIdempotentPublication`. A publication that holds the lease asks
  `ForwardOnlyFinishedBodyPolicy.publicationStep` before it touches the working path: no body at
  the capture path and a body at the working path is `alreadyPublished`, and it does nothing.

### A lease wait that ran out stranded the body (#472)

`CapturePublication-Faithful-ParkedRetry-off`: the working path is leased by someone else past
the publication's deadline. The publication left with its claim and nothing queued. A lease
release woke only the static lane's health refills, and every later recovery pass saw the claim
and reported success, so the row stayed `finalizing` until the next launch (`ClaimHasOwner`).

Fix (`FixParkedRetry`): the publication is parked in the ledger with what it needs to run again,
and the claim belongs to that retry. Three things run it: the release of a lease on the working
path (`resumeParkedOpaquePublications`), a recovery pass that asks for the same body, and a timer
(`parkedOpaquePublicationBackstop`, 5 s), because other reservations of a path end without a
lease release. A publication that is run again never waits: it publishes if the path is free and
parks again if it is not.

- `RecheckBeforePark`: the timeout's completion tries the lease once more before it parks. A
  lease released between the wait's last poll and the park has already sent its wake;
  `CapturePublication-Mutant-MissedWake` (no recheck, no timer) never publishes.
  `CapturePublication-Liveness-Finish` and `-Redelivery` pass with the recheck and no timer,
  `CapturePublication-Liveness-BackstopOnly` with the timer and no recheck.

Not changed here: the static lane's whole-file replacement (`applyFinishedRangeBody`,
`.replaceWhole`) has the same `case .busy, .timedOut: break` after its own lease wait, and keeps
its claim with nothing queued. Its row is still active and its body is a `tmp/` stash, so the
consequence is different; it was not part of this review and is not modelled.

Tests: `PMSKit/Tests/PMSKitTests/DownloadRecoveryRaceReviewTests.swift` (the ledger, the
publication step, with competing claimers and a wake racing a park) and
`LabstreamTests/DownloadRecoveryRaceTests.swift` (the session: recovery arriving inside the
delegate's capture, two queued publications of one body, and a real lease held past the
deadline, woken by its release, by a recovery pass and by the timer).

| Config | Expect | Result | Distinct states | Time |
| --- | --- | --- | --- | --- |
| `CapturePublication-Current-Finish` | pass | pass | 174 | < 1 s |
| `CapturePublication-Current-Relaunch` | pass | pass | 134 | < 1 s |
| `CapturePublication-Current-Redelivery` | pass | pass | 326 | < 1 s |
| `CapturePublication-Liveness-Finish` | pass | pass | 113 | < 1 s |
| `CapturePublication-Liveness-Redelivery` | pass | pass | 183 | < 1 s |
| `CapturePublication-Liveness-BackstopOnly` | pass | pass | 28 | < 1 s |
| `CapturePublication-Faithful-Duplicate-off` | `BodyKept` violated | violated | stops at first error | < 1 s |
| `CapturePublication-Faithful-ClaimFirst-off` | `OnePublication` violated | violated | stops at first error | < 1 s |
| `CapturePublication-Faithful-ParkedRetry-off` | `ClaimHasOwner` violated | violated | stops at first error | < 1 s |
| `CapturePublication-Mutant-MissedWake` | `EventuallyPublished` (liveness) violated | violated | stops at first error | < 1 s |

`Start` is how the process life begins: a finish delivered to a live process, a body captured by
a process that died, or both (the daemon redelivers the finish too). The module has one body and
no crash; F1 and the capture's durability stay with `DownloadsSessionCore`.

## Configs and results

2026-11-24, tla2tools v1.7.4, `TLC_WORKERS=2 TLC_HEAP=2g` (the rows A1 changed: `TLC_WORKERS=4 TLC_HEAP=4g`; `Deep-TwoStatic` after the F1 and F3 fixes, 2026-11-25: `TLC_WORKERS=6 TLC_HEAP=6g`).

| Config | Expect | Result | Distinct states | Time |
| --- | --- | --- | --- | --- |
| `Current-Forward` | pass | pass | 2,951 | 1 s |
| `Current-Static` | pass | pass | 71,357 | 1 s |
| `Current-TwoForward` | pass | pass | 76,119 | 2 s |
| `Current-TwoRows` | pass | pass | 1,186,217 | 20 s |
| `SessionRowMapCheck-Current-RowMap` | pass | pass | one evaluation | 11 s |
| `Projection-SessionCore` | pass | pass | one evaluation | 14 s |
| `Liveness-Forward` | pass | pass | 8,028 | 3 s |
| `Liveness-Static` | pass | pass | 65,527 | 19 s |
| `Proposed-F4-VerdictBeforeRename` | pass | pass | 2,904 | 1 s |
| `Proposed-Forward` | pass | pass | 2,904 | 1 s |
| `Proposed-Static` | pass | pass | 70,841 | 2 s |
| `Faithful-B02-off` | `NoStartWhileUserPaused` violated | violated | stops at first error | < 1 s |
| `Faithful-B03-off` | `QueuedBodyNotSwept` violated | violated | stops at first error | < 1 s |
| `Faithful-B09-off` | `UserPauseSticky` violated | violated | stops at first error | 1 s |
| `Faithful-B10-off` | `WorkingBodyKept` violated | violated | stops at first error | 1 s |
| `Faithful-B12-off` | `StaleCallbackInert` violated | violated | stops at first error | < 1 s |
| `Faithful-F2-off` | `UserPauseSticky` violated | violated | stops at first error | 1 s |
| `Faithful-Replay-off` | `ReplayedOutcomeIsNoOp` violated | violated | stops at first error | 1 s |
| `SessionRowMapCheck-Mutant-RowDropsCondemned` | `RowMapSound` violated | violated | stops at first error | 3 s |
| `SessionRowMapCheck-Mutant-RowDropsCounted` | `RowMapSound` violated | violated | stops at first error | 3 s |
| `Faithful-F1-off` | `FinishedBodyNotLost` violated | violated | stops at first error | 1 s |
| `Faithful-F3-off` | `FinishedBodySurvivesPause` violated | violated | stops at first error | 1 s |
| `Faithful-F3-off-Static` | `FinishedBodySurvivesPause` violated | violated | stops at first error | 1 s |
| `Faithful-F3-off-Progress` | `FinishedBodySurvivesPause` violated | violated | stops at first error | 1 s |
| `Finding-F4-FinalizingRowWithoutBody` | `FinalizingAlwaysHasBody` violated | violated | stops at first error | 1 s |
| `Finding-F4-VerdictRenameCrash` | `VerdictSurvivesCrash` violated | violated | stops at first error | < 1 s |
| `Deep-TwoStatic` (deep) | pass | pass | 5,517,342 | 74 s (rerun after the review fixes, same count) |

## Findings added in the second round

### F3 on the static lane: a pause supersedes a finished segment

Broadens #474. Fixed with it; `Faithful-F3-off-Static` (was
`Finding-F3-PauseSupersedesFinishedSegment`) keeps the trace: the first segment is durable and the
last one is running; the user pauses; the task finishes in the daemon; the pause's listing still
holds it, so the sweep drops its tracking and supersedes it; its finish callback is ignored. The
range-train notes have the Swift evidence and the verdict (R3: probable; one segment on a train,
the whole remainder on the open-ended fallback). `FixPauseKeepsBody` covers both lanes.

### F4: a crash between the condemn rename and the verdict's commit

Trace (`Finding-F4-VerdictRenameCrash`, `Finding-F4-FinalizingRowWithoutBody`):

1. A body reaches the working path and the row is `finalizing`.
2. The finalizer returns `truncated`. The reducer's verdict (one strike, `bodyCondemned`,
   `failed(.truncated)`) is applied to the row in memory and queued for persistence.
3. The body is renamed to a `condemned-*` staging name at once. The process dies before the
   revision commits.
4. On relaunch the durable row is the old `finalizing` one. The staging sweep removes the renamed
   file. Reconcile finds no body and fails the row as `internalError`.

The body was going to be discarded anyway. What is lost is the verdict: the strike is not
counted, so a source that always truncates needs one more whole download before two strikes
publish it as unverified, and the row shows an internal error instead of a truncation.

Swift evidence: `BackgroundDownloadSession.finalizeTransferredFile`
(`condemnBody(afterCommitOf: ticket)` runs before `await committedAttemptSubmission(verdict, ...)`;
the comment above `condemnBody` states the order is deliberate, so that a failed or wedged commit
cannot leave the body in place); `DownloadStore.condemnWorkingBody` (the rename),
`sweepUnreferencedAttemptStaging` (the renamed file has no row reference);
`DownloadLifecycleReducer.relaunch` (`.finalizing` with `Body.none` fails as `internalError`).

Verdict: real, from reading the code; the app-target path was not executed. Low severity (a
millisecond window; no playable bytes are lost).
Proposed fix (`FixVerdictBeforeRename`, `Proposed-F4-VerdictBeforeRename`): make the verdict
durable before the rename. A commit that fails or wedges then leaves a whole body on a
`finalizing` row, which relaunch finalizes again and which replays the same outcome ID, so the
deliberate property is kept another way.
Pinned by `DownloadsFormalModelFindingsTests.truncationVerdictIsDurableBeforeTheBodyMoves`. Issue #491.
