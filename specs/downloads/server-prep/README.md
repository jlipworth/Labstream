# DownloadsServerPrep: module notes

`DownloadsServerPrep.tla` models server preparation: the Plex optimize and Emby Convert runners,
from the first poll to the hand-off to the static transfer. It follows one row until the render is
handed to the static lane (`DownloadsSessionCore` takes over there), the row fails, or it is
deleted. Run it with:

```sh
TLC_WORKERS=2 TLC_HEAP=2g scripts/check-tla-specs.sh specs/downloads/DownloadsServerPrep.tla
swift test --package-path PMSKit --no-parallel --filter DownloadsFormalModelServerPrepTests
```

## What is modelled

| Actor | Actions |
| --- | --- |
| Poller chain | `Attach`, `PlexPoll`, `EmbyPreflight`, `EmbyRecover`, `EmbyPrepoll`, `EmbyPoll`, `Dispatch`, `Send`, `Respond`, `Handoff`, `HandoffRefused`, `PollFails`, `StaleExit` |
| Server and network | `ServerAccepts`, `ServerRejects`, `RequestLost`, `ResponseLost`, `DropResponse`, `JobFinishes`, `JobFails`, `JobVanishes`, `StrayFinishes` |
| Clocks | `GraceElapses` (Plex create visibility, 180 s), `RecoveryExpires` (Emby adoption deadline, 24 h) |
| User | `UserPause`, `UserResume`, `UserRetry`, `UserDelete` |
| Cleanup runner | `RunnerRuns`, `StrayRunnerRuns` |
| Process | `Crash`, `Relaunch` |

A chain is the async function a poller task runs. Pause, Delete and a failure detach the poller;
the chain that was running keeps its place and ends at its next currency check. Each row has two
or three chain slots, so one or two stale chains run next to the current one.

Durable state survives `Crash`: the index row (existence, the whole reducer state, prep or static
mode, the dispatch record, the job identity), the cleanup intent journal, the two wall-clock
facts, and the server (the job, a job of a replaced identity, the render, the create request in
the network). In memory: the attached poller and each chain's position.

Lifecycle and history change only through `Reduce`. The model keeps the whole reducer state per
row, so it needs no projection config. Two places build a row without the reducer: a replacement
attempt, which is a new row (`InitialState`), and the mutant hand-off.

Where the two backends differ in the Swift, they differ in the model:

- A Plex prep row is persisted `admitted` (shown queued). An Emby row is `serverPrep` once its
  seed is written.
- Plex records that a create was dispatched, and later that it was confirmed. Emby records an
  ambiguous dispatch and replaces it with the job ID on adoption.
- Retry of a failed Plex prep row replaces the attempt and its queue title. Retry of a failed
  Emby row that still names a job polls or recovers that job.
- An Emby row that a failed recovery parked is reattached by the scanner without a Retry, until
  the 24 h deadline hands its identity to cleanup.

The app never submits `prepHandoff`: the Plex hand-off is a metadata rewrite plus
`transferStarted`, and the Emby hand-off replaces the attempt. The model follows the app.

## Bounds

One row per config, Plex or Emby. Rows do not interact in this model, so a second row only
multiplies the state space (a Plex row with an Emby row did not finish in ten minutes and was
dropped). Poller IDs are model values under `SYMMETRY PollerSymmetry`, except in the liveness
configs. Counters stop at 2.

## Properties

| Property | Kind | Meaning |
| --- | --- | --- |
| `CreateDecisionSeesNoRender` | action | The app never decides to create a job in a poll that saw a matching render (B35). |
| `OneCreatePerIdentity` | invariant | A dispatched create is never sent again, across relaunch, Pause and Resume, and repeated absent reads. |
| `HandoffAtMostOnce` | invariant | A row is handed to the static lane at most once. |
| `HandoffOnlyWhenActive` | action | A hand-off commits only for a row that is still being prepared, never a paused, failed or deleted one. |
| `ParkedRowHasNoPoller` | invariant | A parked, failed, handed-off or deleted row has no poller attached. |
| `DeletedPrepHasCancelIntent` | invariant | Once a prep row is deleted, an unfinished job of its identity, or a create that may still produce one, has a durable cancel intent (B28, D2). |
| `ClaimedJobNotCancelled` | action | The app never cancels a job that a live prep row still names (B47). |
| `ReplacedPrepHasCancelIntent` | invariant | An unfinished job whose attempt was replaced has a durable cancel intent (S1). |
| `HandedOffJobHasCancelIntent` | invariant | A handed-off row leaves no unfinished job of its own, and no create that may still produce one, without a durable cancel intent (S1). |
| `PrepSettles` | liveness | Under `FairSpec`, once the environment stops, every row is handed off, failed, paused or deleted (B37). |

Fairness for `PrepSettles`: every chain step, the cleanup runner and `Relaunch` are weakly fair,
the server answers every create and ends every job, and both clocks run out. The user, crashes,
lost responses, vanishing jobs and poll failures are not fair and are capped by `EnvBudget`.

## Results (tla2tools v1.7.4, `TLC_WORKERS=2 TLC_HEAP=2g`)

| Config | Expectation | Result | Distinct states | Time |
| --- | --- | --- | --- | --- |
| `ServerPrep-Current-Plex` | pass | pass | 19,555 | 1 s |
| `ServerPrep-Current-Emby` | pass | pass | 26,598 | 2 s |
| `ServerPrep-Current-PlexThreePollers` | pass | pass | 38,126 | 2 s |
| `ServerPrep-Current-EmbyThreePollers` | pass | pass | 60,392 | 4 s |
| `ServerPrep-Liveness-Plex` | pass | pass | 6,919 | 2 s |
| `ServerPrep-Liveness-Emby` | pass | pass | 8,861 | 1 s |
| `ServerPrep-Proposed-S1-AbandonJournalsCancel` | pass | pass | 16,346 | 1 s |
| `ServerPrep-Faithful-B28-off` | `DeletedPrepHasCancelIntent` violated | violated | stops at first error | 1 s |
| `ServerPrep-Faithful-B35-off` | `CreateDecisionSeesNoRender` violated | violated | stops at first error | < 1 s |
| `ServerPrep-Faithful-B37-off` | `PrepSettles` violated (reported as `TEMPORAL`) | violated | 487 | 1 s |
| `ServerPrep-Faithful-B47-off` | `ClaimedJobNotCancelled` violated | violated | stops at first error | 1 s |
| `ServerPrep-Mutant-HandoffUnchecked` | `HandoffOnlyWhenActive` violated | violated | stops at first error | 1 s |
| `ServerPrep-Finding-S1-RetryOrphansRender` | `ReplacedPrepHasCancelIntent` violated | violated | stops at first error | 1 s |
| `ServerPrep-Finding-S1-HandoffLeavesJob` | `HandedOffJobHasCancelIntent` violated | violated | stops at first error | 1 s |

The whole module runs in under a minute. There is no deep config.

`ServerPrep-Current-Plex` checks every safety property except the two that S1 breaks. The Emby
configs and the proposed-fix config check all of them. The runner prints a liveness violation as
`TEMPORAL` whatever the property is called, so `Faithful-B37-off` declares
`EXPECT: violation TEMPORAL`; it lists `PrepSettles` as its only property.

## Faithfulness: the model sees the fixed bugs

- **B28 off.** A create is in flight when the user deletes the row. Delete journals nothing, and
  its best-effort cancel cannot see a job that has not landed. The same config also reaches the
  paused case: a paused prep row is deleted and its job keeps rendering.
- **B35 off.** A matching render exists. A fresh Plex prep attaches and decides to create a job
  before it looks for the render.
- **B37 off.** The create request is lost. The error is swallowed and the poll continues with no
  job on the server and nothing that will fail the row. With the fix on, the surfaced error or the
  180 s grace fails it, and `ServerPrep-Liveness-Plex` passes.
- **B47 off.** A Convert create is accepted; the user pauses before the response arrives; the
  stale chain cancels the job while the paused row keeps the dispatch identity that named it.
- **Mutant, unchecked hand-off.** A chain finds the render; the user pauses; the chain hands off
  anyway and starts the transfer of a paused row. There is no historical bug for the hand-off, so
  this one is injected.

## Finding S1: Retry of a failed Plex prep row orphans its running optimize job

Issue: #478.

Trace (`ServerPrep-Finding-S1-RetryOrphansRender`): the poller creates the optimize job and the
server starts rendering. The row then fails while the job runs on, here because the credential is
rejected three polls in a row (`failAuthDead`); a create whose response was lost has the same
effect. The user signs in again and taps Retry. Retry removes the row and starts a new attempt
under a new queue title. Nothing is journaled for the old title, so the server holds an unfinished
job that no row names and no intent covers.

What follows (`ServerPrep-Finding-S1-HandoffLeavesJob`): the new attempt finds no finished render
and no item under its own title, so it creates a second job for the same item and target. The
first job is cancelled only if that create's stale sweep manages to list the queue. If the first
job finishes before then, the new attempt adopts its render and is handed off, and the second job
keeps rendering, owned by nothing. A handed-off row owes no cancel on Delete, and the sweep skips
finished items, so the second render stays on the server.

Why it is real: `retry()` routes a failed Plex prep row to the replacement path and calls
`removeAttempt(..., context: "retry_replace")` with no cleanup intent. The new attempt's metadata
carries no queue title, so `runOptimizeAndDownload` mints a new one. The only cancel is
`cleanStaleOptimizeJobs`, which runs inside `triggerOptimize` (so only when a create happens) and
gives up silently when the queue list fails. Delete of the same failed row would have journaled
the cancel (`DownloadDeletePolicy.plexOptimizeCleanupQueueTitle` covers failed prep rows), and the
Emby lane resumes a failed row's job instead of abandoning it
(`DownloadRetryPreparationPolicy.shouldResumePausedEmbyConvert`).

Verdict: real. Cost: the server discards or duplicates a render that can take hours, and a spare
optimized version can remain. No download is lost.

`ServerPrep-Proposed-S1-AbandonJournalsCancel` shows one sufficient design: Retry journals the
cancel of the job it abandons, and a hand-off that adopts a render other than the row's own
finished job journals the cancel of the create it dispatched (what Emby already does for B50).
Reattaching the failed row to the job it still names, as Emby does, would also avoid the second
job; that variant is not modelled.

Pin: `DownloadsFormalModelServerPrepTests.retryOfFailedPlexPrepKeepsOrCancelsItsJob`. The decision
is inline in app code, so the test pins the shape of the Plex retry branch.

## Modelling artefacts fixed along the way

- An Emby chain was first allowed to send its create after Delete, because the model had no
  currency check between the dispatch write and the request. The Swift has one:
  `persistEmbyAttemptRecord` checks the action fence after its write, and the request follows
  without suspending. `Send` now requires currency for both backends.
- `DeletedPrepHasCancelIntent` first counted a create response still on its way back as a job that
  might appear. An accepted create is already a job, so only a request still on its way out counts.
- The Emby adoption deadline could fire between the dispatch write and the request. Expiry now
  waits until no create request or response is outstanding (24 h against a request timeout).

## Abstractions and what is not covered

- The server holds at most one job for the row's current identity and at most one unfinished job
  of a replaced identity. A finished job makes the render visible in the same step: Plex's
  metadata indexing gap (`PlexOptimizeCompletionPolicy`) and Emby's source indexing lag are not
  modelled.
- A render exists from the start or comes from one of the row's own jobs. Other clients do not
  create renders, and `EmbyConvertedSourcePolicy`'s choice among sources is one fact: a matching
  render is visible or it is not.
- The 24 h Plex render deadline (`PlexOptimizeDeadlinePolicy`) is left out on purpose. A day
  counts as forever here, which is what makes B37 visible.
- The poll-health budgets are one step (`PollFails`), not counters.
- A replacement attempt starts only after the old attempt's chains have ended and no create
  request or response is outstanding. Retry while an old create is still in flight is not
  explored.
- The Plex duplicate-create response (HTTP 400) is treated as any other refusal.
- Index and journal writes are atomic per action. Journal failure, the deletion barrier and its
  capsule, and the cleanup runner's backoff belong to `DownloadsCleanup`.
- Pause All, the prep-lane cap, the wait for a static transfer slot (#414) and a session that is
  signed out or points at another server are not modelled.
- The Emby Convert coordinator that serializes recovery against cleanup (B49) is not modelled.
- Pause of an Emby row before its seed is written is not modelled.
