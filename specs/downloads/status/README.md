# DownloadsStatus: what the Downloads screen says

`DownloadsStatus.tla` models the status side of downloads: the speed at the top of Downloads, each
row's speed, the bytes a row shows, and its phase and caption. It asks whether those stay true
across headset sleep and wake, pause and resume, staggered callbacks after a wake, silent stalls,
and process death. `DownloadsStatusPhase.tla` is its helper: the phase rule as a function and as a
table that the Swift tests read.

It has seven findings on the current code (S1 to S7 below). S1, S2, S5, S6 and S7 are pinned as
known issues in `PMSKit/Tests/PMSKitTests/DownloadsFormalModelStatusTests.swift`; S3 and S4 have no
pure decision to pin and are recorded as probable.

## What is modelled

| Part | Swift | In the model |
| --- | --- | --- |
| Aggregate speed | `DownloadAggregateRateEstimator`, `OfflineDownloadAggregateStats` | Per transfer: the stage its evidence has reached (`none`, `settling`, `settled`, `window`), how old its last callback is (`aggAge`: under 3.5 s, 3.5 s to `callbackGap`, longer), and whether that callback lies 0.5 s past the batch's newest baseline (`aggOvl`, `ovlRipe`). `Refresh` publishes a number, "Updating speed…" or nothing. |
| Row speed | `DownloadRateEstimator` and its owner code in `DownloadManager.refreshRecords` | The stage (`none`, `baseline`, `window`, `decaying`), the 4 s foreground grace, the first-callback rebaseline and its suppression. |
| Refresh loop | `DownloadManager.updateDownloadWatchdog`, `DownloadWatchdogPolicy` | `refreshPending` (a callback or a store change scheduled one) and `watchdog` (the loop runs). |
| Stall verdict | `DownloadStallRecoveryPolicy`, `DownloadForwardOnlyStallTracker`, `restartStalledForwardOnlyStreamAsync` | `StallDetect` fails a stalled forward-only attempt and requests a retry, `GrantRetry` and `StartTask` restart it from byte 0, and `stalls` counts restarts up to `MaxStallRestarts`. Forward progress resets the count. Static-range rows have no stall verdict. |
| Bytes | `DownloadStore.submitProgress`, `DownloadLiveRangeProgressPolicy`, `DownloadManager.displayBytes` | Three copies. `disk` is the index file. `rec` is the store's live row: a forward-only progress sample changes it at once and reaches `disk` only with a persistence ticket (a status change, or the 1 s cadence). `live` is the in-memory optimistic watermark of a static-range row. `pubBytes` is what the last refresh put on screen. A process death keeps `disk` only. |
| Segment boundary | `DownloadLiveRangeProgressPolicy.rateSampleBytes`, the range callback in `BackgroundDownloadSession` | `SegmentFinish` puts a finished segment's body in claim debt (`debt`), `AppendLands` moves the checkpoint. A callback during the debt reports a lower train total; the hold makes that invisible to the estimator. |
| Phase and caption | `DownloadRowStatusCaptionPolicy`, `DownloadProgressDisplay.isTransferFinalizing`, `DownloadManager.publishedRowPhase`, `DownloadJobSnapshot`, `OfflineSidebarStatusPolicy`, `DownloadHealthSnapshotPolicy` | `PhaseOf` over the lifecycle, zero bytes, `progress >= 1`, `isActive` (`activeJobs` holds the key, or the row downloads), the route and `isBackendConfigured`. `jobs` is `activeJobs`; `backendOn` is the backend session. |
| Lifecycle | `DownloadLifecycleReducer` | `Reduce` only. Each row keeps a whole reducer state, so there is no projection config. |

Durable variables (`row`, `disk`, `task`, `flow`, `unrep`, `awake`, `backendOn`, `budget`) survive
`Crash`. Everything else is in memory and returns to its `Init` value; `rec` is reloaded from
`disk`. Eleven ghost variables record what a published number was built from; no guard reads them.

Time is abstract: an estimator is the stage it has reached. The arithmetic is covered by the seeded
and the worked-example Swift tests listed below.

### Timing assumptions

Each is one guard in the module, marked with its name.

- **A1.** Bytes that piled up while the app could not see them are all reported, and sampled by
  the refresh their callback schedules, within 4 s of the first callback afterwards. How late that
  first callback arrives is not assumed. `LateCatchUp = TRUE` lifts A1; finding S7 is what follows.
- **A2.** A refresh that lands between two callbacks of a flowing row does not zero its rate.
- **A3.** A scheduled refresh (0.5 to 1 s) runs before the user's next tap.
- **A4.** A row whose bytes flow calls back at least every 3.5 s. A row in `SlowRows` may not;
  finding S6 is what follows.

`GrantRetry` waits for the pending refresh as well. That one is code order, not an assumption:
`restartStalledForwardOnlyStreamAsync` calls `refreshRecords` before it asks for admission.

### Bounds

One or two rows, byte counters 0..2 (0..1 in the two-row default-tier runs), a restart cap of 2
(the code's), and an interference budget (`EnvBudget`) shared by the kinds of interference listed
in `Env`: pause, resume, stall, unstall, a nap or a long sleep, process death, a dropped task, and
the backend session going away or coming back. One-row configs use a budget of 2 to 5; two-row
configs use 1 or 2 and, where the run would leave the default tier, a subset of `Env`.

## Properties

| Property | Kind | Says |
| --- | --- | --- |
| `NoPartialSum` | invariant | #379. A published number leaves no transfer out of the sum, whether it is warming up or has gone quiet. |
| `NoUnsharedWindow` | invariant | #379. A published number is measured over an interval every counted transfer shares. |
| `NoInflatedAggregate` | invariant | #224. A published number never rests on catch-up bytes appended to an older baseline. |
| `NoInflatedRowRate` | invariant | #224. A row's speed never divides catch-up bytes by a post-wake interval. |
| `AggregateMatchesBatch` | invariant | After the scheduled refresh, the top shows a speed or "Updating speed…" exactly when a row is transferring. |
| `NoSpuriousReset` | invariant | #416. A segment boundary never resets the batch. |
| `PhaseNoGhostWork` | invariant | The phase says active work only when a task, queued admission or start, or a finalization exists. |
| `PhaseNeverIdleWhileTaskRuns` | invariant | The phase never reads idle while the row's task runs. |
| `PhaseBackendHonest` | invariant | "Waiting for <backend>" is said only of a row with no session and no task. |
| `SidebarHonest`, `HealthHonest` | invariant | The sidebar count and the health snapshot agree with the same notion of work. |
| `WaitingReadsAsWaiting` | invariant | pu-33. A row waiting for admission reads as waiting. |
| `StallRestartsCapped` | invariant | The tracker never restarts a stream more often than its cap between two forward bytes. |
| `BytesMonotone` | action | While the process lives and a row stays downloading, its shown bytes never go down unless a reducer effect reset them. |
| `RelaunchKeepsBytes` | action | The first snapshot published after relaunch reconcile shows, for every row reconcile left as it was, at least what the last snapshot before the death showed. A row whose callback already arrived is not judged. S3 violates it. |
| `UpdatingResolves` | liveness | "Updating speed…" does not stay up for ever while a transferring row's bytes flow. S1 and S5 violate it. |
| `SpeedSettlesAfterStall` | liveness | After a stall a transferring row stops showing a speed. S2 violates it. |
| `ForwardStallGetsVerdict` | liveness | A forward-only stream that has stopped moving does not stay `transferring` for ever. S5 violates it. |
| `EventuallyStable` | liveness | The published speeds stop appearing and disappearing once interference stops. S6 violates it. |

`BytesMonotone` is narrower than "bytes never go backwards": leaving `downloading` drops the
optimistic overlay on purpose, so a paused or failed row shows its resumable bytes
(`OfflineDownloadAggregateStats` says so). In this model every reducer reset effect coincides with
leaving `downloading`.

`EventuallyStable` sees a speed only as "a number" or "none". It is about a figure coming and
going, not about its value; the values are the Swift tests' side.

The ghost behind `NoPartialSum` counts a member as left out when it neither contributes to the sum
nor is counted as zero by the proposed S1 rule. Before round 2 it excused every quiet member, so a
mutation that dropped quiet members from the sum passed.

## Configs

Run with `TLC_WORKERS=2 TLC_HEAP=2g scripts/check-tla-specs.sh specs/downloads/status`. The
figures are from that command on a 14-core Mac with other checks running; the default tier takes
about 13 minutes in all, and the three deep configs about 86 minutes.

| Config | Expect | Distinct states | Seconds |
| --- | --- | ---: | ---: |
| `Current-Backend` | pass | 225,336 | 6 |
| `Current-Mixed` | pass | 3,021,944 | 142 |
| `Current-OneForward` | pass | 723,186 | 17 |
| `Current-OneStatic` | pass | 333,165 | 8 |
| `Current-Planned` | pass | 73,864 | 4 |
| `Current-TwoStatic` | pass | 1,306,832 | 65 |
| `Liveness-Flow` | pass | 116,964 | 36 |
| `Liveness-FlowOneForward` | pass | 27,824 | 5 |
| `Liveness-FlowOneStatic` | pass | 38,703 | 6 |
| `Liveness-FlowStall` | pass | 101,234 | 36 |
| `Liveness-Settle` | pass | 110,277 | 18 |
| `Liveness-Static` | pass | 140,869 | 20 |
| `Faithful-B09-off` | violation `PhaseNoGhostWork` | 54 | 1 |
| `Faithful-pu33-off` | violation `WaitingReadsAsWaiting` | initial state | 0 |
| `Mutant-I224-NoSettling` | violation `NoInflatedAggregate` | 1,362 | 1 |
| `Mutant-I224-NoWakeReset` | violation `NoInflatedAggregate` | 5,848 | 0 |
| `Mutant-I379-NoOverlap` | violation `NoUnsharedWindow` | 249 | 0 |
| `Mutant-I379-PartialSum` | violation `NoPartialSum` | 2,918 | 1 |
| `Mutant-I379-QuietOmitted` | violation `NoPartialSum` | 27,677 | 2 |
| `Mutant-I416-SegmentNoHold` | violation `NoSpuriousReset` | 132 | 0 |
| `Finding-S1-SilentMemberHidesSpeed` | violation `UpdatingResolves` (reported as `TEMPORAL`) | 151,651 | 48 |
| `Finding-S2-StaleRowSpeed` | violation `SpeedSettlesAfterStall` (reported as `TEMPORAL`) | 19,641 | 3 |
| `Finding-S3-RelaunchDip` | violation `RelaunchKeepsBytes` | 1,206 | 1 |
| `Finding-S3-RelaunchDipForward` | violation `RelaunchKeepsBytes` | 1,722 | 1 |
| `Finding-S4-LateCallbackInflatesRow` | violation `NoInflatedRowRate` | 1,313 | 1 |
| `Finding-S5-StallCapHidesSpeed` | violation `UpdatingResolves` (reported as `TEMPORAL`) | 66,743 | 20 |
| `Finding-S5-StallCapNoVerdict` | violation `ForwardStallGetsVerdict` (reported as `TEMPORAL`) | 266,115 | 38 |
| `Finding-S6-SlowMemberFlapsSpeed` | violation `EventuallyStable` (reported as `TEMPORAL`) | 44,743 | 17 |
| `Finding-S7-LateBacklogInflatesRow` | violation `NoInflatedRowRate` | 1,156 | 1 |
| `Finding-S7-LateBacklogInflatesTotal` | violation `NoInflatedAggregate` | 2,806 | 1 |
| `Proposed-LivenessFlow` | pass | 186,071 | 64 |
| `Proposed-LivenessSettle` | pass | 246,656 | 36 |
| `Proposed-LivenessStallCap` | pass | 187,703 | 30 |
| `Proposed-LivenessStallCapFlow` | pass | 86,162 | 29 |
| `Proposed-Mixed` | pass | 2,364,584 | 109 |
| `Proposed-OneForward` | pass | 525,071 | 13 |
| `Deep-LivenessFlow` (deep) | pass | 1,066,742 | 419 |
| `Deep-Mixed` (deep) | pass | 66,650,051 | 3195 |
| `Deep-TwoStatic` (deep) | pass | 30,480,049 | 1543 |

The `Current` configs leave out what an open finding violates: none lets a static-range row stall
silently (S1, S2), none checks `RelaunchKeepsBytes` (S3), `NoInflatedRowRate` is checked only
where no forward-only row exists (S4), no forward-only row may stall more often than the cap in a
liveness run (S5), `SlowRows` is empty (S6) and A1 holds (S7). TLC does not name a violated
temporal property, so the liveness findings declare `EXPECT: violation TEMPORAL` and list one
property each.

### Faithfulness

Two historical bugs from `docs/evidence/2026-10-17-downloads-overhaul-bugs-vs-main.md`:

- **pu-33 off.** A row waiting for admission takes its caption from the phase, which is "queued":
  it reads as active work with no transport.
- **B09 off.** A progress callback queued before Pause promotes the paused row. It reads as an
  active transfer, and the sidebar counts it, with no task. This restores the late-progress part
  of B09 only; how an OS cancellation is classified is the session model's.

Mutants for protections that are not in that audit. Each removes one thing (`Mutant` in the
module):

- **`partialSum`** (#379). The top speed is the sum of whichever estimates exist. One row's
  estimate is published while the other is still warming up. This is a membership example, not
  the pre-#379 estimator's arithmetic.
- **`quietOmitted`** (#379). A member whose evidence ran out is dropped from the sum. One row
  stalls and the other's speed is published as the batch speed.
- **`noOverlap`** (#379). No common 0.5 s window is required. A number is published before 0.5 s
  have passed since the newest baseline.
- **`noWakeReset`** (#224). Foreground does not reset the aggregate estimator. After a nap shorter
  than `callbackGap`, the bytes that piled up are appended to the pre-nap window.
- **`noSettling`** (#224). The first callback after a wake reports part of what piled up and
  becomes the baseline at once; the rest is appended to it.
- **`segmentNoHold`** (#416). A callback that lands while a finished segment's body awaits its
  append reports a lower train total. Without the hold the estimator reads a regression and resets
  the batch, by its own rule (`bytes < last.bytes`).

Two more switches exist and have no config, because nothing in the model depends on that
protection alone:

- **`noGapReset`** (#224). With the wake reset in place, every sleep the model has is reset at
  foreground before the callback-gap rule is asked. `Current-OneStatic` and `Current-OneForward`
  pass with it (333,165 and 723,186 states). The rule is the only protection when neither wake
  hook runs; the seeded Swift batch test covers that with its unhinted wakes.
- **`noGrace`** (#224). The first-callback rebaseline starts its own grace, for a static-range row
  and for a forward-only row under the proposed S4 fix. The one violation TLC finds with it
  (`NoInflatedRowRate`, two long sleeps in a row, 5,463 states on `Current-OneStatic`) rests on
  the taint ghost not knowing how long the second sleep was, so it is not kept. Without the S4
  fix the grace is all a forward-only row has, and S4 is the gap in it.

## Findings

### S1: a silent transfer hides the batch speed for as long as it is silent (real, medium)

Issue: #487.

Two static-range rows are transferring. One gets no bytes: it stalled, or never received its
first byte. No error arrives, so no callback arrives, and nothing takes a static-range row out of
`transferring` (only forward-only streams have a stall verdict). The other row keeps moving. The
aggregate needs fresh evidence from every member, so it has no answer, and the top of Downloads
says "Updating speed…" until the silent row moves or leaves.

- `DownloadAggregateRateEstimator.swift:80-89`: `rate(at:)` returns nil when any active transfer
  lacks two observations or a callback inside `callbackGap`.
- `OfflineDownloadAggregateStats.swift:53`: `isUpdatingSpeed` is "a row is transferring and there
  is no speed".
- `DownloadStallRecoveryPolicy.swift:23-29`: stall recovery covers forward-only streams only.
  `StaticRangeTaskHealthPolicy` can reissue one slow background-created task once; it does not
  change the row's lifecycle. How long the silence lasts is bounded only by URLSession's own
  timeouts.
- `DownloadAggregateRateEstimatorTests.swift:107` (`silentMember`) pins the first seconds of this
  on purpose, because a silent member may be about to deliver catch-up bytes. The finding is that
  the hidden state has no end.

Pin: `silentTransferDoesNotHideBatchSpeedForever`. Proposed in the model
(`SilentCountsAsZero`): a member silent for `callbackGap` in a process that stayed awake counts as
zero, and its next sample still resets the batch.

### S2: a stalled static-range row keeps showing a speed (real, medium)

Issue: #488.

A row's speed is recomputed only inside `refreshRecords`. After a static-range row's last
callback, the only refreshes left come from the watchdog loop, and that loop stops at the first
refresh that finds the aggregate without an answer. The aggregate loses its answer 3.5 s after the
last callback (its 4 s window less the 0.5 s minimum). The row's own window needs about 4 s of
quiet refreshes to empty. So the last refresh leaves a decayed but non-zero speed and its ETA on
the row, with "Updating speed…" above it, until some other event refreshes the screen. When the
aggregate is hidden already (settling after a start, a wake or a new batch member, or hidden by
S1) no loop runs at all and the row keeps its full last speed.

- `DownloadManager.swift:4878-4909`: the only place a row's estimator is sampled and
  `downloadSpeed` is written.
- `DownloadManager.swift:5015-5038`: the loop runs only while
  `DownloadWatchdogPolicy.requiresWatchdog(records:)` or `aggregateRateEstimator.rate(at:) != nil`.
- `DownloadWatchdogPolicy.swift:11-14`: forward-only streams and preparing rows only.
- `DownloadAggregateRateEstimator.swift:89`: the `minimumWindow` guard.

The model first assumed the row decays before the aggregate expires. A seeded Swift test of that
margin failed for 89 of 100 stalls, so the assumption was removed and the test became the pin:
`stalledStaticRowStopsShowingSpeed`. Proposed in the model (`WatchdogCoversTransfers`): the loop
runs while any row is transferring.

### S3: after a process death a row shows fewer bytes than before (probable, low)

Issue: #490.

Trace (`Finding-S3-RelaunchDip`): a callback raises the row's bytes, a refresh publishes them, the
process dies while the background task keeps running, relaunch reconcile leaves the row
downloading with no reducer reset, and the first refresh after it publishes less.

For a static-range row what is lost is the optimistic total, which lives in memory
(`liveRangeProgress`). The row shows its durable checkpoint until the first callback arrives, and
for a single continuous remainder the checkpoint can be zero.

- `DownloadManager.swift:389`: `liveRangeProgress` is an in-memory dictionary.
- `DownloadManager.swift:5256-5272` and `DownloadLiveRangeProgressPolicy.swift:134`: the row shows
  the live sample or the persisted `resumeDisplayBytes`, whichever is larger.
- `DownloadStore.swift:4055`: `resumeDisplayBytes` is written only when a resume blob is published.

For a forward-only row (`Finding-S3-RelaunchDipForward`) what is lost is every progress sample
since the last persistence ticket. `submitProgress` changes the live row at once and asks for a
ticket only when the status changes or 1 s has passed since the last persisted sample, and that
clock is one for the whole store.

- `DownloadStore.swift:5149-5184`: `shouldPersist`, and `ticket` nil otherwise.
- `DownloadStore.swift:696`: `progressPersistInterval` is 1 s.
- `BackgroundDownloadSession.swift:4250`: the forward-only callback's `submitProgress`.

So the static dip can be the whole in-flight remainder and the forward-only dip is at most about a
second of transfer, plus whatever the index writer had not flushed. Until round 2 the model kept
every forward-only sample across a death and `Current-OneForward` passed `RelaunchKeepsBytes`;
that was wrong. The model also compared against a computed value where it now compares against
the last published snapshot.

The behaviour follows from the code. Whether it matters depends on how long the first callback
takes on a device, and there is no PMSKit decision to pin. `throttledProgressHasNoPersistenceTicket`
checks the `submitProgress` rule the model relies on against the source.

### S4: a forward-only row's late first callback after a wake inflates its speed (probable, low)

Issue: #489.

On foreground every downloading row gets a 4 s grace in which each refresh replaces its estimator
with a one-sample baseline. A static-range row is also marked so that its first callback
re-baselines it, however late. A forward-only row is not. If its first callback arrives after the
grace, the baseline holds the pre-sleep bytes and the callback's total is divided by the few
seconds since then. The same holds after a relaunch, where callbacks start only once the session
has reattached.

- `DownloadManager.swift:2239-2257`: the grace is set for every downloading row; the pending
  marker only for static-range keys.
- `DownloadManager.swift:776-791`: the first-callback rebaseline lives in `onRangeLiveProgress`.
- `DownloadManager.swift:4880-4889`: the grace branch.

`catchUpBytesNeedAnOwnerRebaseline` shows the arithmetic on the estimator alone. Whether a
forward-only stream survives a sleep long enough, with a first callback later than 4 s, needs a
device. Proposed in the model (`ForwardFirstCallbackRebaseline`).

### S5: past its two restarts a stalled forward-only stream has no verdict (real, medium)

Issue #497.

Trace (`Finding-S5-StallCapNoVerdict`): the stream starts and stalls with no bytes; `StallDetect`
fails the attempt and requests a retry; admission grants it and it starts again from byte 0; it
stalls again and is restarted a second time; it stalls a third time. Now
`shouldRestartForwardOnlyStream` answers no, a restart is the only verdict the tracker has, and
nothing else looks at the row. It stays `transferring` with a task that delivers nothing. The
watchdog keeps refreshing every 15 s and finds the same thing each time.

With a second row (`Finding-S5-StallCapHidesSpeed`) the capped row is a silent member of the
batch, so the top of Downloads says "Updating speed…" while the other row flows. That is S1 for a
forward-only row, which the stall verdict was thought to rule out. Round 1's model had a fair
`StallDetect` with no cap, so `Liveness-Flow` passed.

- `DownloadStallRecoveryPolicy.swift:14` and `:31-42`: the cap of 2, and `restartAttempts <
  maxRestartAttempts` in the guard.
- `DownloadForwardOnlyStallTracker.swift:62-99`: `detectRestarts` returns restarts only. The count
  goes back to 0 only when the row's bytes move forward.
- `DownloadManager.swift:4967-5011`: the restart path. It seeds the count back after
  `releaseInFlight` wipes it, so the cap binds.

The cap is deliberate: restarting for ever would restart the encoder from byte 0 every 90 s. What
is missing is the step after it. Pin: `stalledForwardOnlyStreamGetsVerdictPastTheCap` (an hour at
zero bytes, 3,405 s after the second restart, with no restart and no failure). Proposed in the
model (`StallCapFails`): past the cap the row fails with the stall reason and waits for the user.

### S6: fresh evidence without a common 0.5 s window hides the total (real, low)

Issue #498.

`rate(at:)` measures every transfer over one common interval inside the last 4 s and needs that
interval to be at least 0.5 s. So a transfer counts only while its last callback is at most 3.5 s
old, although its evidence is treated as fresh for `callbackGap` (6 s), and a batch whose windows
do not overlap yet has no answer although every member is settled and fresh.

Trace (`Finding-S6-SlowMemberFlapsSpeed`): two rows flow. One calls back every 3.5 to 6 s. Each
time its last observation leaves the window the total goes to "Updating speed…"; its next callback
brings the number back. This repeats for as long as the batch lasts.

- `DownloadAggregateRateEstimator.swift:80-89`: `start = max(start, first.time)`, `end = min(end,
  last.time)`, `guard duration >= minimumWindow`.
- `DownloadAggregateRateEstimator.swift:25-31`: window 4 s, minimum 0.5 s, gap 6 s.

Pins: `freshNonOverlappingWindowsHideTotal` (the reviewer's case: observations at 0 and 4 s for
one transfer, 0.1, 4.09 and 4.11 s for the other, no total at 4.11 s) and
`slowMemberMakesTotalFlap` (a 4.5 s cadence: 60 of 361 refreshes have no total, and never a wrong
one). Whether a stream reports that rarely on a device is open; a server-paced transcode is the
candidate. Round 1's model let evidence run out only when a row had stopped flowing, and required
no common window, so it could not see this.

### S7: a backlog reported after the 4 s windows is published as live speed (probable, low)

Issue #499. Related: #224, #489.

This is what follows when A1 does not hold. The first callback after a wake starts the aggregate's
4 s settling window, and a static-range row's rebaseline and 4 s grace. Both treat everything
after those 4 s as live. If the rest of what piled up during the sleep is reported later than
that, or reported inside the grace and sampled after it, it is divided by the seconds since the
last baseline.

Traces: `Finding-S7-LateBacklogInflatesTotal` (wake, first callback with part of the backlog,
settling runs out, second callback with the rest, a number is published) and
`Finding-S7-LateBacklogInflatesRow` (the rest is reported in the grace, the grace runs out, the
refresh samples it).

- `DownloadAggregateRateEstimator.swift:60-68`: a sample at or after `settlingUntil` is appended.
- `DownloadManager.swift:4880-4889`: the grace branch replaces the estimator only while
  `now < graceUntil`.

Pins: `lateBacklogAfterSettlingIsNotPublishedAsSpeed` (the reviewer's records (0, 0), (1, 100),
(2, 200), (3, 300), (4.1, 100000): 90,636 B/s for a transfer moving 100 B/s),
`lateBacklogAtTheEndOfTheGraceIsNotPublishedAsRowSpeed` (143,857,143 B/s for a row moving
1,000,000 B/s) and the known-issue halves of the two seeded batch tests, which now draw backlogs
that outlast the settling window (the worst answer is 10.7 times the true total). The estimator
cannot tell a late backlog from a burst, so a fix belongs to the owner. Whether URLSession ever
reports a backlog that late needs a device.

## Modelling artefacts, fixed in the model

- **A refresh held across pause, sleep, wake and resume.** A scheduled refresh could be delayed
  until a paused row had been resumed, leaving the old attempt's flags on the new one. A3 now
  orders a scheduled refresh before the user's next tap, and `Refresh` clears grace, pending and
  suppression for rows that are not downloading, as `refreshRecords` does.
- **A refresh held across a stall restart.** The same, for a restarted forward-only attempt.
  `GrantRetry` waits for the refresh that the restart path runs itself.
- **A2 as first written** (the row decays before the aggregate expires) was not an artefact but a
  wrong assumption: see S2.
- **"Catch-up remainder sampled after the grace"** was listed here in round 1 and covered by A1.
  It is real arithmetic (the row pin of S7 shows it), so it is now part of what A1 assumes and
  S7 lifts.

## Swift tests

`DownloadsFormalModelStatusTests` (22 tests; nine of them carry known issues, 11 in all). The
seeded ones use a fixed-seed SplitMix64 generator.

- Aggregate speed, steady batch across sleeps, staggered and late first callbacks, partial
  catch-up reports, hinted and unhinted wakes: every answer equals the batch's true total, and a
  number returns within 20 s of every transfer flowing. A quarter of the lagging wakes report
  their backlog up to 6 s after the settling window; those answers are the S7 known issue.
- Aggregate speed with stalls and changing rates: no answer exceeds the sum of the peak rates
  (the same split).
- Aggregate speed under arbitrary samples, clock steps, byte regressions, resets and membership
  changes: every answer has settled, fresh, two-observation evidence from every active transfer.
- Row speed: finite, never above the true peak, nil after a backwards sample, inside the
  suppression window and `stallTimeout` into a stall; ETA positive or nil.
- Row speed: catch-up bytes inflate the rate unless the owner re-baselines on them.
- Live range bytes: the merged watermark never goes down; a dip is held only when bodies awaiting
  append explain it; the optimistic total never reads complete before the durable file is.
- #416 end to end: a held boundary dip keeps the batch's speed, the same dip unheld costs it, and
  a loss the debt does not explain still reaches the estimator. The session's call into the hold
  is checked by text, since the delegate is app code.
- Progress fraction, the sidebar and toolbar percentage (fail closed on any unknown total).
- Phase: `DownloadRowStatusCaptionPolicy.phase` equals `PhaseTable` in
  `DownloadsStatusPhase.tla`, row for row (288 rows: nine lifecycles times five facts). TLC checks
  the same table against `PhaseOf` whenever it loads the module. `publishedRowPhase` is checked
  by text for the two inputs the manager computes.
- Phase for every combination of row facts (the older property checks); persisted phase, health
  snapshot and watchdog policy; the admission-waiting caption.
- `StaticRangeTaskHealthPolicy` and `BackgroundDownloadProgressPolicy` gates.

## Not covered

- Server preparation, its captions and phases.
- Background execution: a suspended app runs nothing in the model, so the background-wake reset
  (`onBackgroundWakeAuthorized`) is not exercised, and a wake with neither hook is left to the
  Swift batch test.
- A persistence ticket that has not reached the file when the process dies: a ticketed write is
  durable at once in the model.
- A static-range row's index bytes: its checkpoint is the file, and the model treats it as
  durable when the append lands.
- What a returning backend session resumes: a row parked by a blocked start stays parked.
- Delete, a user retry of a forward-only row, parallel segment trains beyond "a finished segment
  awaits its append", a loss the claim debt does not explain, and the foreground reconcile race
  (F2, in `DownloadsSessionCore`).
- The percentage arithmetic and side-asset bytes, which the Swift tests cover instead.
- `OfflineActiveTransferPercentage`, `StaticRangeTaskHealthPolicy` and
  `BackgroundDownloadProgressPolicy` have Swift tests only, so the module does not list them on
  its `MODELS` lines.
