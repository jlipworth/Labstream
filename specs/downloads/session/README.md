# DownloadsSessionCore: module notes

`DownloadsSessionCore.tla` is the pilot model: one row from `admitted` to a terminal lifecycle
through the session, the finalizer, the stash sweep and relaunch recovery, with process death. Its
design, properties and the F1 to F3 traces are in
[docs/plans/2026-11-24-downloads-tla-model.md](../../../docs/plans/2026-11-24-downloads-tla-model.md).
This page holds what the second review round changed and the current results.

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
- **Liveness** assumptions are written out above `Fairness`: the session's own steps run; a
  retried task eventually finishes (the code has retry budgets instead, which the model does not
  count); the manager's main-actor steps run, which a suspended background app does not get.
  `StallDetected` exists only on the forward-only lane in the code; on the static lane it stands
  in for the manager's stale-row recovery, which `DownloadsRangeTrain` models.

## Configs and results

2026-11-24, tla2tools v1.7.4, `TLC_WORKERS=2 TLC_HEAP=2g`.

| Config | Expect | Result | Distinct states | Time |
| --- | --- | --- | --- | --- |
| `Current-Forward` | pass | pass | 6,501 | 1 s |
| `Current-Static` | pass | pass | 99,262 | 2 s |
| `Current-TwoForward` | pass | pass | 251,834 | 8 s |
| `Current-TwoRows` | pass | pass | 2,720,900 | 80 s |
| `SessionRowMapCheck-Current-RowMap` | pass | pass | one evaluation | 9 s |
| `Projection-SessionCore` | pass | pass | one evaluation | 14 s |
| `Liveness-Forward` | pass | pass | 14,513 | 7 s |
| `Liveness-Static` | pass | pass | 71,451 | 36 s |
| `Proposed-F3-PauseKeepsBody` | pass | pass | 5,367 | < 1 s |
| `Proposed-F4-VerdictBeforeRename` | pass | pass | 6,449 | < 1 s |
| `Proposed-Forward` | pass | pass | 3,129 | < 1 s |
| `Proposed-Static` | pass | pass | 70,841 | 3 s |
| `Faithful-B02-off` | `NoStartWhileUserPaused` violated | violated | stops at first error | < 1 s |
| `Faithful-B03-off` | `QueuedBodyNotSwept` violated | violated | stops at first error | < 1 s |
| `Faithful-B09-off` | `UserPauseSticky` violated | violated | stops at first error | 1 s |
| `Faithful-B10-off` | `WorkingBodyKept` violated | violated | stops at first error | 1 s |
| `Faithful-B12-off` | `StaleCallbackInert` violated | violated | stops at first error | < 1 s |
| `Faithful-Replay-off` | `ReplayedOutcomeIsNoOp` violated | violated | stops at first error | 1 s |
| `SessionRowMapCheck-Mutant-RowDropsCondemned` | `RowMapSound` violated | violated | stops at first error | 3 s |
| `SessionRowMapCheck-Mutant-RowDropsCounted` | `RowMapSound` violated | violated | stops at first error | 3 s |
| `Finding-F1-StashCrash` | `FinishedBodyNotLost` violated | violated | stops at first error | 1 s |
| `Finding-F2-PauseReconcile` | `UserPauseSticky` violated | violated | stops at first error | 1 s |
| `Finding-F3-PauseDiscardsFinishedBody` | `FinishedBodySurvivesPause` violated | violated | stops at first error | < 1 s |
| `Finding-F3-PauseSupersedesFinishedSegment` | `FinishedBodySurvivesPause` violated | violated | stops at first error | 1 s |
| `Finding-F4-FinalizingRowWithoutBody` | `FinalizingAlwaysHasBody` violated | violated | stops at first error | 1 s |
| `Finding-F4-VerdictRenameCrash` | `VerdictSurvivesCrash` violated | violated | stops at first error | < 1 s |
| `Deep-TwoStatic` (deep) | pass | pass | 8,228,854 | 287 s |

## Findings added in the second round

### F3 on the static lane: a pause supersedes a finished segment

Broadens #474. `Finding-F3-PauseSupersedesFinishedSegment`: the first segment is durable and the
last one is running; the user pauses; the task finishes in the daemon; the pause's listing still
holds it, so the sweep drops its tracking and supersedes it; its finish callback is ignored. The
range-train notes have the Swift evidence and the verdict (R3: probable; one segment on a train,
the whole remainder on the open-ended fallback). `FixPauseKeepsBody` now covers both lanes
(`Proposed-Static`).

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
Pinned by `DownloadsFormalModelFindingsTests.truncationVerdictIsDurableBeforeTheBodyMoves`.
