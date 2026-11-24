# DownloadsSideAssets: model notes

`DownloadsSideAssets.tla` models the optional side assets of a download: the poster, chapter
images, the trick-play index (Plex BIF, Emby BIF, Jellyfin trickplay) and compatible external text
subtitles. It asks one question above the others: can an asset be forgotten, meaning it is missing,
nothing left will fetch it, and nothing records why.

Run it with `TLC_WORKERS=2 TLC_HEAP=2g scripts/check-tla-specs.sh specs/downloads/side-assets/DownloadsSideAssets.tla`.
The Swift pins are `PMSKit/Tests/PMSKitTests/DownloadsFormalModelSideAssetsTests.swift`.

## What is modelled

| Actor | Actions |
| --- | --- |
| User | `UserPause`, `PauseAll`, `ResumeAll`, `ResumeSameAttempt`, `ResumeFreshAttempt`, `ResumeRefused`, `UserDelete`, `UserAdd` |
| Main transfer (abstract) | `StartTransfer`, `BodyFinished`, `Finalized`, `TransferFails`, `StorageInterrupt`, `ReleaseKeepingRow` |
| Passes that offer work | the initial pass inside `StartTransfer`; `EarlyPoster`; the pass inside `ResumeSameAttempt`; `Repair` (the completed-row scan on every foreground, backend-ready and Resume All edge) |
| Side-asset workers | `Promote`, `LoopNext`, `TaskFinish`, `RefreshDone` |
| Fetch coordinator | `Deliver` (a park, unpark or cancel command reaching the coordinator), `Admit` |
| Server and session | `Respond`, `ServerDown`, `ServerUp`, `SessionLost`, `SessionBack` |
| Crash | `Crash`, `Relaunch` |

The side-asset kinds are abstracted to four shapes, plus the request that rediscovers two of them:

| Model kind | Stands for | Shape |
| --- | --- | --- |
| `poster` | the poster on all three backends | one request under its own coordinator owner, which Pause never parks |
| `chapters` | chapter images | `NChapters` requests entered together, prepared one at a time, recorded in one batch |
| `bif` | Plex BIF | one request; on a completed row it is found only through a source-metadata refresh |
| `subs` | external text subtitles; the Jellyfin trickplay tile loop has the same shape | `NSubs` requests entered one after the other, recorded in one batch; a completed row always offers a refresh for them |
| `refresh` | the source-metadata request | one request shared by `bif` and `subs`, with one budget |

Emby BIF and the Jellyfin trickplay playlist are fetched directly on a completed row. That is the
`chapters` shape with one request, so they have no kind of their own.

Durable state survives `Crash`: the row (a whole reducer state, the attempt ID, the recorded
metadata paths), the files at their stable paths, and the Pause All gate. The server and the
session are outside the process. In-memory state does not survive: the work registry, each
request's progress, the coordinator's parked and cancelled owners and command versions, commands
not yet delivered, the retry budget, the store's publication owners, the early-poster offers and
the Pause All exemptions.

A request moves through `entering` (its fetch-entry command is issued), `queued`, `inflight`,
`ready` (payload in memory), `promoted` (renamed to its stable path) and is then recorded by its
task's one metadata update. `resolved` is an end with nothing to record.

## Bounds

One row in most configs and two interchangeable rows in one, with `SYMMETRY`. Kinds are chosen per
config, because the pipelines of different kinds multiply: one kind explores up to about 0.6
million states with every environment switch on, all four need the environment capped at two
steps. `MaxDispatch` (5 in the code) is 1 or 2, `MaxConcurrent` (2 in the code) is 2, or 1 with two
rows, attempts are 1 to 2, and at most one or two user commands wait for delivery per row.

Each environment action sits behind a switch (`AllowCrash`, `AllowPauseAll`,
`AllowCancelKeepingAttempt`, `AllowRefusedResume`, `AllowStoragePark`, `AllowSessionLoss`,
`AllowServerOutage`), so a config can leave out the trigger of a known finding and still check
everything else.

## Properties

| Property | Kind | Meaning |
| --- | --- | --- |
| `NeverForgotten` | liveness | Once the environment is calm (process alive, server reachable, session present, queue not paused, no more environment steps), every eligible asset of a complete or unverified row ends cached or accounted for by this launch's retry budget. |
| `AvailableEventuallyCached` | liveness | The stronger reading: an asset the server has is cached without a relaunch. Only the S3 finding config checks it. |
| `RepairWithinRateLimit` | invariant | Every request, the refresh included, is inside the coordinator's concurrency cap and the per-launch budget (B25). |
| `ControlsApplyInRequestOrder` | invariant | No park, unpark or cancel takes effect after a later-requested one (B32). |
| `PausedRowNotFetching` | invariant | Once every command for a user-paused row has landed, none of its parked payloads is on the network. The poster is exempt by design. |
| `NoOrphanAfterDelete` | invariant | A deleted row leaves no side-asset file. |
| `PayloadsBounded` | invariant | At most `PayloadLimit` chapter payloads wait in memory for preparation (#394). |
| `WorkIsRegistered`, `TypeOK` | invariant | Model sanity. |

`NeverForgotten` counts an exhausted budget as an account of the asset. The code keeps no durable
record of a failed side asset: the completed-row inventory re-derives what is missing from the
metadata and the files, and the budget (in memory, per launch) is the only thing that stops a
retry. A new launch starts the budget afresh. Fairness for the liveness runs: the transfer, the
coordinator, the server and the workers keep going, `Repair` keeps coming back, and a dead process
is relaunched. User actions, crashes, outages and session changes are not fair and are capped.

## Faithfulness

| Config | What it restores | Property violated |
| --- | --- | --- |
| `Faithful-B25-off` | The completed-row repair refetches source metadata outside the coordinator and its budget. | `RepairWithinRateLimit` |
| `Faithful-B32-off` | The coordinator applies commands in arrival order: a Pause's park lands after the Resume's unpark. | `ControlsApplyInRequestOrder` |
| `Faithful-B32-off-PausedFetch` | The consequence of the same bug: the paused row's chapter image goes out on the network. | `PausedRowNotFetching` |
| `Mutant-DeleteSkipsPublished` | An injected bug: Delete ignores the in-memory publication owners. | `NoOrphanAfterDelete` |

## Findings

Each was checked against the Swift before it was recorded. None is fixed here.

### S1: a cancelled poster owner stays cancelled for the launch (real)

Issue: #482.

Trace (`Finding-S1-PosterOwnerStaysCancelled`): a row is released with the default
`releaseInFlight` mode and keeps its attempt; the release cancels both of the attempt's coordinator
owners; the row later completes under the same attempt; the repair pass offers the poster; the
fetch throws at the coordinator's entry because the poster owner is cancelled; no budget is
charged, so the next pass offers it again, and it fails again.

Why it is real: a cancelled owner is reopened only by a fetch-entry command
(`applyDownloadControl(..., registration: true)`), and `fetchOptionalSideAsset` sends one for every
kind except the poster, which has had its own owner since #450. `releaseInFlight(for:)` is called
in its cancelling mode by paths that keep the row and the attempt, for example the Plex prep
poller's `plexSessionUnavailable` handler, which says it keeps the row for the prep scanner to
reattach. The row is poster-less until the next launch.

Proposed in the model (`FixPosterReregisters`): a poster fetch reopens its owner.
`Proposed-NeverForgotten-Poster` passes with it.

Pin: `DownloadsFormalModelSideAssetsTests.posterFetchReopensItsCancelledOwner`.

### S2: Pause All can strand a completed row's side assets (real)

Issue: #483.

Trace (`Finding-S2-PauseAllStrandsCompletedRow`): a row completes while its subtitle
task is still fetching; a foreground edge runs the repair pass, which queues a source-metadata
refresh; the user taps Pause All, which sends a completed row no command; the subtitle task moves
on to its next stream, and that fetch entry parks the attempt's owner because the queue is paused;
the user taps Resume All; the repair pass runs again and starts nothing, because the refresh and
the subtitle task are both still registered. Nothing enters a new fetch, so nothing unparks the
owner.

Why it is real: `fetchOptionalSideAsset` computes `parked` from the queue gate for any lifecycle;
`resumeQueue` re-admits paused and failed rows only and has no unpark of its own; the only unpark
is in `retryRecordAsync`; and every repair entry point is `startIfAbsent`. The row heals when some
other kind that is not registered enters a fetch, or at the next launch.

Proposed in the model (`FixResumeAllUnparks`): Resume All unparks every row that is not paused.
`Proposed-NeverForgotten-Subs` and `-ChaptersSubs` pass with it.

Pin: `DownloadsFormalModelSideAssetsTests.resumeAllUnparksCompletedRows`.

### S3: an outage spends the launch's retry budget (probable, a design limit)

Issue: #484.

Trace (`Finding-S3-OutageExhaustsBudget`): the server is unreachable; a poster dispatch
fails and is charged; the server comes back; the budget for that poster is spent, so nothing
offers it again in this launch.

The budget is charged at transport admission whatever the outcome, and its stated purpose is an
asset the server can never produce. With the real budget of five, five foreground edges away from
the server exhaust it for every asset a completed row is missing. A park of an in-flight request
also costs a dispatch, because the request is cancelled, requeued and charged again. A relaunch
restores the budget, so `NeverForgotten` holds. Whether a transient failure should count is a
product decision, so this is not pinned.

### S4: a refused Resume leaves a paused row unparked (probable, low)

Issue: #485.

Trace (`Finding-S4-RefusedResumeUnparks`): the user pauses a row; the user taps Resume;
`retryRecordAsync` unparks the side assets before its own guards; the storage cap or a missing
backend refuses the resume; the row stays paused and its chapter images go out on the network.

`Proposed-S4-UnparkOnAccept` passes with the unpark moved behind the guards. Not
pinned: the unpark may sit before the guards on purpose, since it is the only unpark there is.

### Known deferred items the model reproduces

- **st-39, orphan reclamation.** `Finding-st39-CrashOrphanAfterDelete`: the process
  dies between a side asset's rename and its metadata record. After relaunch only the in-memory
  publication owners knew the file, so Delete leaves it behind. If the row is kept instead, the
  repair pass fetches the asset again and overwrites the file.
  `Finding-st39-ReplacedAttemptOrphan` reaches the same end without process death: a
  retry replaces the attempt between the rename and the record, the replacement retires only the
  recorded paths, and the publication owner belongs to the old attempt.
- **#394, payload queueing.** `Finding-394-PayloadsBehindPreparation`: three chapter
  payloads wait behind one preparation. `Proposed-394-Window` passes with a window of
  two from fetch through promotion.

Neither has a Swift pin here: both are already tracked, and neither has a pure decision to pin.

## Results (2026-11-24, tla2tools v1.7.4, `TLC_WORKERS=2 TLC_HEAP=2g`)

| Config | Expectation | Distinct states | Time |
| --- | --- | --- | --- |
| `Current-Poster` | pass | 237,712 | 8 s |
| `Current-Chapters` | pass | 366,248 | 12 s |
| `Current-Subs` | pass | 631,068 | 21 s |
| `Current-Bif` | pass | 546,668 | 16 s |
| `Current-ChaptersSubs` | pass | 270,251 | 7 s |
| `Current-TwoRows` (symmetry) | pass | 613,726 | 22 s |
| `Current-Delete` | pass | 119,928 | 4 s |
| `Current-AllKinds` | pass | 2,406,345 | 62 s |
| `Liveness-PosterChapters` | pass | 25,740 | 3 s |
| `Liveness-Discovered` | pass | 74,751 | 9 s |
| `Proposed-NeverForgotten-Poster` | pass | 23,354 | 3 s |
| `Proposed-NeverForgotten-Subs` | pass | 33,993 | 5 s |
| `Proposed-NeverForgotten-ChaptersSubs` | pass | 19,575 | 3 s |
| `Proposed-394-Window` | pass | 24,593 | 2 s |
| `Proposed-S4-UnparkOnAccept` | pass | 1,133 | under 1 s |
| `Deep-AllKinds` (deep tier) | pass | 14,221,199 | 377 s |
| the four `Faithful` and `Mutant` configs | violation, as named above | stop at the first error | 1 s or less |
| the seven `Finding` configs | violation, as named above | stop at the first error | 1 s or less |

The `Current-*` configs check every safety property except the ones the findings break:
`NoOrphanAfterDelete` is checked only by `Current-Delete`, which has no process death and no
replacement attempt (st-39), and no `Current-*` config allows a refused Resume (S4). The two
`Liveness-*` configs are the code as it stands with crashes, outages, storage parking and session
loss, and without the triggers of S1 and S2.

## A modelling artefact, fixed in the model

The first draft reset a cancelled task's requests without recording what the task had already
promoted. The S3 counterexample showed a poster renamed, its task cancelled by a failed transfer,
and the record lost with no process death. The code does not do that: nothing checks for
cancellation between a rename and the metadata update, so a cancelled poster, BIF or chapter task
still records what it promoted. The subtitle loop is the exception, because it returns at its next
cancellation check and drops the tracks it has collected; the files stay and are fetched again.
`RecordedAfterCancel` now says so.

## Not covered

- Request pacing (one start per second) and round-robin between owners. The concurrency cap and
  the budget are modelled.
- A second coordinator owner waiting on the same request (coalescing), and playback's use of the
  same coordinator.
- A change of side-asset source inside one attempt (Plex optimize hand-off, Convert) and the
  store's source fence. A replacement attempt is modelled; a lagging task of an old attempt is
  assumed fenced.
- Staging files and the startup staging inventory. Disk-full writes: a failed write behaves like
  a failed fetch.
- Resumes that do not go through `retryRecordAsync`. Reconcile promoting a user-paused row (F2)
  would leave the owner parked on a running row.
- The inventory worker's 30-second deadline and its reuse cache. `Repair` is one step per row.
- The unverified terminal state: rows end `complete`. Both are playable and treated alike.
- `OrderedAsyncWorkCoordinator`: its guarantee (one row's manager operations run one at a time,
  in submission order) is assumed, since each user action is one step.
- The Delete journal (`DownloadsCleanup`), admission after Resume All (`DownloadsAdmission`) and
  storage accounting (`DownloadsStorage`).
