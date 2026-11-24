# DownloadsStatus: what the Downloads screen says

`DownloadsStatus.tla` models the status side of downloads: the speed at the top of Downloads, each
row's speed, the bytes a row shows, and its phase and caption. It asks whether those stay true
across headset sleep and wake, pause and resume, staggered callbacks after a wake, silent stalls,
and process death.

It found four things on the current code (S1 to S4 below). S1 and S2 are pinned as known issues in
`PMSKit/Tests/PMSKitTests/DownloadsFormalModelStatusTests.swift`; S3 and S4 have no pure decision
to pin and are recorded as probable.

## What is modelled

| Part | Swift | In the model |
| --- | --- | --- |
| Aggregate speed | `DownloadAggregateRateEstimator`, `OfflineDownloadAggregateStats` | Per transfer, the stage its evidence has reached (`none`, `settling`, `settled`, `window`) and whether it has run out (`aggQuiet`). `Refresh` publishes a number, "Updating speed…" or nothing. |
| Row speed | `DownloadRateEstimator` and its owner code in `DownloadManager.refreshRecords` | The stage (`none`, `baseline`, `window`, `decaying`), the 4 s foreground grace, the first-callback rebaseline and its suppression. |
| Refresh loop | `DownloadManager.updateDownloadWatchdog`, `DownloadWatchdogPolicy`, `DownloadStallRecoveryPolicy` | `refreshPending` (a callback or a store change scheduled one) and `watchdog` (the loop runs). Only forward-only rows have a stall verdict. |
| Bytes | `DownloadLiveRangeProgressPolicy`, `DownloadManager.displayBytes` | A durable count per row (`rec`), an in-memory optimistic watermark for static-range rows (`live`), and bytes the daemon wrote that no callback has reported (`unrep`). |
| Phase and caption | `DownloadRowStatusCaptionPolicy`, `DownloadJobSnapshot`, `OfflineSidebarStatusPolicy`, `DownloadHealthSnapshotPolicy` | `Phase`, `PersistedPhase`, `Caption`, `SidebarActive`, `HealthHasWork` as operators over the row and its live facts. |
| Lifecycle | `DownloadLifecycleReducer` | `Reduce` only. Each row keeps a whole reducer state, so there is no projection config. |

Durable variables (`row`, `rec`, `task`, `flow`, `unrep`, `awake`, `budget`) survive `Crash`.
Everything else is in memory and returns to its `Init` value. Nine ghost variables record what a
published number was built from; no guard reads them.

Time is abstract: an estimator is the stage it has reached. The arithmetic is covered by the
seeded Swift tests listed below.

### Timing assumptions

Each is one guard in the module, marked with its name.

- **A1.** Bytes that piled up while the app could not see them are all reported, and sampled by
  the refresh their callback schedules, within 4 s of the first callback afterwards. How late that
  first callback arrives is not assumed.
- **A2.** A refresh that lands between two callbacks of a flowing row does not zero its rate.
- **A3.** A scheduled refresh (0.5 to 1 s) runs before the user's next tap.

### Bounds

One or two rows, byte counters 0..2, and an interference budget (`EnvBudget`) shared by pause,
resume, sleep, process death, a dropped task, stall and unstall. One-row configs use a budget of
3 to 5; two-row configs use 1 in the default tier and 2 in `Status-Deep-TwoStatic`.

## Properties

| Property | Kind | Says |
| --- | --- | --- |
| `NoPartialSum` | invariant | #379. A published number leaves out no transfer that might be moving. |
| `NoInflatedAggregate` | invariant | #224. A published number never rests on catch-up bytes appended to an older baseline. |
| `NoInflatedRowRate` | invariant | #224. A row's speed never divides catch-up bytes by a post-wake interval. |
| `AggregateMatchesBatch` | invariant | After the scheduled refresh, the top shows a speed or "Updating speed…" exactly when a row is transferring. |
| `NoSpuriousReset` | invariant | #416. A segment boundary never resets the batch. |
| `PhaseNoGhostWork` | invariant | The phase says active work only when a task, queued admission or start, or a finalization exists. |
| `PhaseNeverIdleWhileTaskRuns` | invariant | The phase never reads idle while the row's task runs. |
| `SidebarHonest`, `HealthHonest` | invariant | The sidebar count and the health snapshot agree with the same notion of work. |
| `WaitingReadsAsWaiting` | invariant | pu-33. A row waiting for admission reads as waiting. |
| `BytesMonotone` | action | While the process lives and a row stays downloading, its shown bytes never go down unless a reducer effect reset them. |
| `RelaunchKeepsBytes` | action | The same across a process death. S3 violates it. |
| `UpdatingResolves` | liveness | "Updating speed…" does not stay up for ever while a transferring row's bytes flow. S1 violates it. |
| `SpeedSettlesAfterStall` | liveness | After a stall a transferring row stops showing a speed. S2 violates it. |
| `EventuallyStable` | liveness | The published speeds stop changing once interference stops. |

`BytesMonotone` is narrower than "bytes never go backwards": leaving `downloading` drops the
optimistic overlay on purpose, so a paused or failed row shows its resumable bytes
(`OfflineDownloadAggregateStats` says so). In this model every reducer reset effect coincides with
leaving `downloading`.

## Configs

Run with `TLC_WORKERS=2 TLC_HEAP=2g scripts/check-tla-specs.sh specs/downloads/DownloadsStatus.tla`.

| Config | Expect | Distinct states | Seconds |
| --- | --- | ---: | ---: |
| `Status-Current-OneStatic` | pass | 46,465 | 2 |
| `Status-Current-OneForward` | pass | 33,922 | 1 |
| `Status-Current-Planned` | pass | 160,198 | 6 |
| `Status-Current-TwoStatic` (symmetry) | pass | 2,143,236 | 81 |
| `Status-Current-Mixed` | pass | 2,803,017 | 97 |
| `Status-Liveness-Flow` | pass | 96,197 | 20 |
| `Status-Liveness-Settle` | pass | 16,334 | 3 |
| `Status-Liveness-Static` | pass | 22,532 | 3 |
| `Status-Faithful-pu33-off` | violation `WaitingReadsAsWaiting` | initial state | 1 |
| `Status-Faithful-B09-off` | violation `PhaseNoGhostWork` | 44 | 1 |
| `Status-Mutant-I379-PartialSum` | violation `NoPartialSum` | 2,152 | 1 |
| `Status-Mutant-I224-NoCatchUpGuard` | violation `NoInflatedAggregate` | 543 | 1 |
| `Status-Mutant-I416-SegmentDip` | violation `NoSpuriousReset` | 28 | 1 |
| `Status-Finding-S1-SilentMemberHidesSpeed` | violation `UpdatingResolves` (reported as `TEMPORAL`) | 145,425 | 30 |
| `Status-Finding-S2-StaleRowSpeed` | violation `SpeedSettlesAfterStall` (reported as `TEMPORAL`) | 4,361 | 1 |
| `Status-Finding-S3-RelaunchDip` | violation `RelaunchKeepsBytes` | 282 | 1 |
| `Status-Finding-S4-LateCallbackInflatesRow` | violation `NoInflatedRowRate` | 579 | 1 |
| `Status-Proposed-OneForward` | pass | 28,396 | 1 |
| `Status-Proposed-Mixed` | pass | 2,087,451 | 74 |
| `Status-Proposed-LivenessFlow` | pass | 152,544 | 35 |
| `Status-Proposed-LivenessSettle` | pass | 38,297 | 5 |
| `Status-Deep-TwoStatic` (deep, symmetry) | pass | 8,434,679 | 334 |

The `Current` configs leave out what an open finding violates: none lets a static-range row stall
silently (S1, S2), `RelaunchKeepsBytes` is checked only for a forward-only row (S3), and
`NoInflatedRowRate` only where no forward-only row exists (S4). TLC does not name a violated
temporal property, so the two liveness findings declare `EXPECT: violation TEMPORAL` and list one
property each.

### Faithfulness

Two historical bugs from `docs/evidence/2026-10-17-downloads-overhaul-bugs-vs-main.md`:

- **pu-33 off.** A row waiting for admission takes its caption from the phase, which is "queued":
  it reads as active work with no transport.
- **B09 off.** A progress callback queued before Pause promotes the paused row. It reads as an
  active transfer, and the sidebar counts it, with no task.

Three mutants for protections that are not in that audit:

- **#379 off.** The top speed is the sum of whichever estimates exist. One row's estimate is
  published as the batch speed while the other is still warming up.
- **#224 off.** No wake reset, callback-gap reset, settling or foreground grace. Bytes from a
  sleep are appended to a baseline and published.
- **#416 off.** A finished segment's dip resets the batch at every boundary.

## Findings

### S1: a silent transfer hides the batch speed for as long as it is silent (real, medium)

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

### S3: after a process death a static-range row shows fewer bytes than before (probable, low)

The optimistic total of a static-range row lives in memory (`liveRangeProgress`). The process dies
while the background task keeps running. After relaunch the row is still downloading, with no
reducer reset, and shows its durable checkpoint until the first callback arrives. For a single
continuous remainder the checkpoint can be zero.

- `DownloadManager.swift:389`: `liveRangeProgress` is an in-memory dictionary.
- `DownloadManager.swift:5256-5272` and `DownloadLiveRangeProgressPolicy.swift:134`: the row shows
  the live sample or the persisted `resumeDisplayBytes`, whichever is larger.
- `DownloadStore.swift:4055`: `resumeDisplayBytes` is written only when a resume blob is published.

The behaviour follows from the code. Whether it matters depends on how long the first callback
takes on a device, and there is no PMSKit decision to pin.

### S4: a forward-only row's late first callback after a wake inflates its speed (probable, low)

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

## Modelling artefacts, fixed in the model

- **Catch-up remainder sampled after the grace.** The first counterexample to `NoInflatedRowRate`
  let the 4 s grace run out between a callback and the refresh it schedules within a second. A1
  now covers that refresh.
- **A refresh held across pause, sleep, wake and resume.** A scheduled refresh could be delayed
  until a paused row had been resumed, leaving the old attempt's flags on the new one. A3 now
  orders a scheduled refresh before the user's next tap, and `Refresh` clears grace, pending and
  suppression for rows that are not downloading, as `refreshRecords` does.
- **A2 as first written** (the row decays before the aggregate expires) was not an artefact but a
  wrong assumption: see S2.

## Swift tests

`DownloadsFormalModelStatusTests` (14 tests, 4 known issues). The seeded ones use a fixed-seed
SplitMix64 generator.

- Aggregate speed, steady batch across sleeps, staggered and late first callbacks, partial
  catch-up reports, hinted and unhinted wakes: every answer equals the batch's true total, and a
  number returns within 20 s of every transfer flowing.
- Aggregate speed with stalls and changing rates: no answer exceeds the sum of the peak rates.
- Aggregate speed under arbitrary samples, clock steps, byte regressions, resets and membership
  changes: every answer has settled, fresh, two-observation evidence from every active transfer.
- Row speed: finite, never above the true peak, nil after a backwards sample, inside the
  suppression window and `stallTimeout` into a stall; ETA positive or nil.
- Row speed: catch-up bytes inflate the rate unless the owner re-baselines on them.
- Live range bytes: the merged watermark never goes down; a dip is held only when bodies awaiting
  append explain it; the optimistic total never reads complete before the durable file is.
- Progress fraction, the sidebar and toolbar percentage (fail closed on any unknown total).
- Phase for every combination of row facts; persisted phase, health snapshot and watchdog policy;
  the admission-waiting caption.
- `StaticRangeTaskHealthPolicy` and `BackgroundDownloadProgressPolicy` gates.

## Not covered

- Server preparation, its captions and phases.
- Background execution: a suspended app runs nothing in the model, so the background-wake reset
  (`onBackgroundWakeAuthorized`) is not exercised.
- Naps shorter than `callbackGap`, and callbacks slower than one per 3.5 s.
- An evidence run-out and a callback-gap reset are one flag, so a stall of 3.5 to 6 s resets the
  batch in the model where the code would append.
- Delete, retries and resume of a forward-only row, parallel segment trains beyond "a segment
  finished", and the foreground reconcile race (F2, in `DownloadsSessionCore`).
- The percentage arithmetic and side-asset bytes, which the Swift tests cover instead.
- `DownloadProgressDisplay`, `OfflineActiveTransferPercentage`, `StaticRangeTaskHealthPolicy` and
  `BackgroundDownloadProgressPolicy` have Swift tests only, so the module does not list them on
  its `MODELS` lines.
