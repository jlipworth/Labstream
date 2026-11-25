# DownloadsSideAssets: model notes

`DownloadsSideAssets.tla` models the optional side assets of a download: the poster, chapter
images, the trick-play index (Plex BIF, Emby BIF), Jellyfin trickplay (a playlist and its tiles) and
compatible external text subtitles. It asks one question above the others: can an asset be
forgotten, meaning the server has it, the row is playable, and nothing durable leads to a fetch
that asks for it.

Run it with `TLC_WORKERS=2 TLC_HEAP=2g scripts/check-tla-specs.sh specs/downloads/side-assets`.
The Swift pins are `PMSKit/Tests/PMSKitTests/DownloadsFormalModelSideAssetsTests.swift`.

## What is modelled

| Actor | Actions |
| --- | --- |
| User | `UserPause`, `PauseAll`, `ResumeAll`, `ResumeSameAttempt`, `ResumeFreshAttempt`, `ResumeRefused`, `UserDelete`, `UserAdd`, `SwitchBackend` |
| Main transfer (abstract) | `StartTransfer`, `BodyFinished`, `Finalized`, `TransferFails`, `StorageInterrupt`, `ReleaseKeepingRow` |
| Passes that offer work | the initial pass inside `StartTransfer`; `EarlyPoster`; the pass inside `ResumeSameAttempt`; the completed-row scan: `Edge`, `PassApply`, `PassTimeout`, `PassRerun` |
| Side-asset workers | `Promote` (or `PromoteCheck`, `PromoteRename`, `PromoteConfirm`), `ZombieConfirm`, `LoopNext`, `TilesEnter`, `PlaylistDrop`, `TaskFinish`, `RefreshDone` |
| Fetch coordinator | `Deliver` (a park, unpark or cancel command reaching the coordinator), `Admit` |
| Store | `DeleteFinish` (the row-deletion worker) |
| Server and sessions | `Respond`, `ServerDown`, `ServerUp`, `SessionLost`, `SessionBack` |
| Process | `Crash`, `Quit`, `Relaunch` |

The side-asset kinds, and the request that rediscovers two of them:

| Model kind | Stands for | Shape |
| --- | --- | --- |
| `poster` | the poster on all three backends | one request under its own coordinator owner, which Pause never parks |
| `chapters` | chapter images; Emby BIF has this shape with one request | `NChapters` requests entered together (a task group), prepared one at a time, recorded in one batch |
| `bif` | Plex BIF | one request for the BIF of one part; on a completed row it is found only through a source-metadata refresh |
| `subs` | external text subtitles | `NSubs` requests entered one after the other, recorded in one batch; a completed row always offers a refresh for them |
| `tiles` | Jellyfin trickplay | the playlist request; then `NTiles` tile requests entered together (a task group) and prepared one at a time; then the local playlist. Tiles and playlist are recorded in one batch, and only when the local playlist was written. The completed-row offer is gated by the playlist's budget alone |
| `refresh` | the source-metadata request | one request shared by `bif` and `subs`, with one budget |

Durable state survives `Crash` and `Quit`: the row (a whole reducer state, the attempt ID, the
recorded metadata paths, a pending deletion and the paths it lists), the files at their stable
paths, the Pause All gate, the selected backend and each backend's saved session. In-memory state
does not: the hydrated sessions, the work registry, each request's progress, the coordinator's
parked and cancelled owners and command versions, commands not yet delivered, the retry budget, the
store's publication owners, the early-poster offers, the Pause All exemptions, the running
inventory pass and promotions in flight.

A request moves through `entering` (its fetch-entry command is issued), `queued`, `inflight`,
`ready` (payload in memory), `promoted` (at its stable path, owned in memory) and is then recorded
by its task's one metadata update. `resolved` is an end with nothing to record. With
`FinePromotion` the promotion is the store's three steps: `checked` (the snapshot of the row's
generations), `renamed` (the file is at its stable path) and the confirmation under the lock.

### The completed-row scan

The scan is not a standing loop. An edge (launch, foreground, backend ready or switched, Resume
All) calls `rehydrateMissingOptionalSideAssetsForCompletedRows`, which starts one inventory pass.
The model keeps the three ways a pass can end without scanning a row:

- An edge that arrives while a pass runs is dropped; the running pass observed the rows before it.
- `PassTimeout`: the worker misses its 30 s deadline and the pass dispatches nothing.
- A row whose mutation generation moved while it was observed (`passStale`) is skipped.

`Relaunch`, `ResumeAll`, `SessionBack` and `SwitchBackend` fire the edge themselves, as the code
does. `Edge` is the foreground edge. A pass only scans rows that are complete or unverified and have
an attempt ID.

### Sessions and backends

A session is a hydrated session for the row's own backend that matches the server and user the row
was downloaded from (`BackendSession.matchesPersistedServer`). A session for another server or
user of the same backend is no session, so `SessionLost` also stands for signing in as someone
else. `creds` is the saved session and `session` its in-memory copy. `Relaunch` hydrates the
selected backend, plus any other backend that owns active work or (S6, #494) a completed row that
misses an asset, which is what `runLaunchDownloadRecovery` does. Rows in `OtherBackendRows` are on the backend that is not
selected at the start.

### Source drift and asset identity (#503, #504)

The model used to identify an asset by its recorded path and the presence of its file, and to
enumerate each row's asset slots from the config, independently of what the row saved. Neither the
wrong source behind a present file nor an asset missing from the saved inventory could be seen.
`Drift` (fixed for a run) says how the server's item differs from the saved row:

- `reordered`, `reorderedBare`: Plex reordered the item's media after the download. The initial
  pass uses the item the transfer starts from; a refresh (`RefreshDone`) looks the downloaded part
  up in the refreshed item, by index before the #503 fix (`RepairHitsOther`), so a task it starts
  (`misaddr`) fetches the other part's asset. The ghost `foreign` records which files at their
  stable paths hold another part's asset; `Correct` is `Have` minus those. With `reorderedBare` the
  other part advertises nothing, so nothing is fetched.
- `lateChapters`: the row was saved without chapter thumbnails (`seedChapters`, durable), so the
  initial pass and the inventory have no chapter images to offer. With `FixSourceInventory` a
  successful refresh saves the thumbnails and starts the chapter task.
- `emptyThumb`: the item's primary artwork field is `""` and the next one is valid. Before the fix
  the selector returned `""`, so the poster is in no inventory (`InInventory`).

### Delete

`UserDelete` stages the deletion: the store appends a durable intent that lists the paths the row
references (recorded, or published in memory by a rename), every store fence rejects the row from
then on, and the manager cancels the row's tasks. `DeleteFinish` removes the listed files and the
row. A rename that was in flight when its row was staged for deletion, replaced or had its task
cancelled is kept as a `zombie` and meets the store's confirmation (`ZombieConfirm`), which removes
a file no row references.

## Bounds

One row in most configs and two in four. Kinds are chosen per config, because the pipelines of
different kinds multiply. `MaxDispatch` (5 in the code) is 1 to 3, `MaxConcurrent` (2 in the code)
is 1 to 3, attempts are 1 to 2, and at most one or two user commands wait for delivery per row.

Each environment action sits behind a switch (`AllowCrash`, `AllowQuit`, `AllowPauseAll`,
`AllowCancelKeepingAttempt`, `AllowRefusedResume`, `AllowStoragePark`, `AllowSessionLoss`,
`AllowServerOutage`, `AllowPassTimeout`, `AllowBackendSwitch`), so a config can leave out the
trigger of a known finding and still check everything else. `FinePromotion` turns on the three-step
promotion and `TrackEdges` the ghost that records repair edges; both cost states and are on only
where a property needs them. `Mutation` injects one bug for a `Mutant` config.

## Properties

| Property | Kind | Meaning |
| --- | --- | --- |
| `NeverForgotten` | liveness, `DurableFairSpec` | While it stays quiet, every asset the server holds for a complete or unverified row ends cached. |
| `MissingIsDurablyOwed` | invariant | A missing asset the server holds is durably owed: the row has an attempt ID, the inventory of a fresh launch offers the work that fetches it, and that fetch asks for the resource that holds it. |
| `CachedThisLaunch` | liveness, `FairSpec` | The stronger reading: the asset is cached without a relaunch, as long as repair edges keep coming. |
| `NoEdgeLost`, `NoEdgeOutsidePass` | invariant | Every repair edge is followed by a pass that scans the row as it is after the edge, or by a note to run one (S5). |
| `CachedBifIsForChosenPart` | invariant | A cached Plex BIF is the index of the part that was downloaded (S7). |
| `CachedAssetIsForDownloadedPart` | invariant | Asset identity: no file at a stable path holds an asset of a part other than the one the row downloaded (#503). |
| `ServedAssetInInventory` | invariant | Source inventory: every asset the server holds for a playable row that is not discovered from the server is in the inventory derived from the saved row, or a fresh launch's refresh adds it there (#504). |
| `PromotionNotLostToRace` | invariant | No promotion of a live row is dropped because another write to the row came between its snapshot and its confirmation (S8). |
| `RepairWithinRateLimit` | invariant | Every request, the refresh included, is inside the coordinator's concurrency cap and the per-launch budget (B25). |
| `ControlsApplyInRequestOrder` | invariant | No park, unpark or cancel takes effect after a later-requested one (B32). |
| `PausedRowNotFetching` | invariant | Once every command for a user-paused row has landed, none of its parked payloads is on the network. The poster is exempt by design. |
| `NoOrphanAfterDelete` | invariant | A deleted row leaves no side-asset file, once every rename in flight has met the store's fence. |
| `PayloadsBounded` | invariant | At most `PayloadLimit` payloads of one task group (chapter images, trickplay tiles) wait in memory for preparation (#394). |
| `WorkIsRegistered`, `TypeOK` | invariant | Model sanity. |

### What "never forgotten" means

`Quiet` is: the server answers, the queue is not paused, and every row's own server and user has a
saved session. It reads durable and outside facts only. It does not mention the process, the
retry budget, or how many environment steps are left.

`NeverForgotten` is `Quiet ~> (every served asset of every owned playable row is cached \/ ~Quiet)`.
It is checked under `DurableFairSpec`, where the only repair edge assumed is the one each launch
fires, and launches keep coming: `Quit` ends a process that has nothing left to do, with strong
fairness, and `Relaunch` starts the next one with an empty retry budget, an empty registry and a
fresh coordinator. Under that fairness nothing in memory can satisfy the property. An exhausted
budget, a cancelled or parked owner and a dropped pass all end a launch with the asset missing, and
the next launch has to bring it back from durable state alone. The asset is cached in the end, or
the property fails.

`MissingIsDurablyOwed` is the same claim as a state invariant, so a violation shows up without a
liveness run. It holds when the durable record exists; `NeverForgotten` shows the record leads to a
cached file. Both count an asset as cached only when it is the downloaded part's own (`Correct`,
#503), and an asset missing from the saved inventory as owed only through a refresh that learns it
(#504).

Both are scoped to rows with an attempt ID (`Mutant-UnownedRow` below).

The first version of this property was `Calm ~> (every asset cached or its budget spent)`. It
counted a spent in-memory budget as an account of the asset, counted the shared refresh budget for
every asset behind it, and `Calm` required every environment step to be used up. Two injected bugs
passed it: a refresh that never starts the kinds it discovers (49,392 states), and asset requests
that never return a payload (41,655 states). Both now fail (`Mutant-NoDiscoveryDispatch`,
`Mutant-PayloadsFail`), and they fail in a run where no environment step is ever taken.

### Fairness

`SystemFair`: the transfer, the coordinator, the server, every task and every promotion (one by
one), the pass and the deletion worker keep going, and a dead process is relaunched. User actions,
crashes, outages, session changes and pass timeouts are not fair and are capped by `EnvBudget`.

- `DurableFairSpec` adds `SF_vars(Quit)`. It assumes no foreground edge.
- `FairSpec` adds `WF_vars(Edge)`: the foreground edge keeps coming. It has no `Quit`.

## Faithfulness and mutants

| Config | What it restores or injects | Property violated |
| --- | --- | --- |
| `Faithful-B25-off` | The completed-row repair refetches source metadata outside the coordinator and its budget. | `RepairWithinRateLimit` |
| `Faithful-B32-off` | The coordinator applies commands in arrival order: a Pause's park lands after the Resume's unpark. | `ControlsApplyInRequestOrder` |
| `Faithful-B32-off-PausedFetch` | The consequence of the same bug: the paused row's chapter image goes out on the network. | `PausedRowNotFetching` |
| `Faithful-S1-off` | The poster fetch sends no registration (before #482), so a kept-attempt cancel keeps its owner closed. | `CachedThisLaunch` |
| `Faithful-F3-finish-off-Chapters` | A body that finishes behind a user pause sends no unpark (before the #474 follow-up): the completed row's chapter images stay parked. | `CachedThisLaunch` |
| `Faithful-S2-off-Subs`, `-Tiles` | Resume All sends no unpark (before #483): a completed row's late fetch entry stays parked. | `CachedThisLaunch` |
| `Faithful-S6-off` | Launch hydrates only active-work backends (before #494), so a completed row on another backend stays cold. | `NeverForgotten` |
| `Faithful-503-off-WrongPartSubs`, `-WrongPartBif` | The Plex repair looks the part up by index (before #503); after a media reorder it caches the other part's subtitle or BIF. | `CachedAssetIsForDownloadedPart` |
| `Faithful-503-off-SubsNeverFetched` | The same, and the other part has no subtitles: the downloaded part's subtitle is never reached. | `MissingIsDurablyOwed` |
| `Faithful-504-off-LateChapters` | A refresh does not save chapter thumbnails the row lacked (before #504). | `ServedAssetInInventory` |
| `Faithful-504-off-EmptyThumb` | The artwork selector returns the empty primary field (before #504). | `ServedAssetInInventory` |
| `Mutant-NoDiscoveryDispatch` | The refresh never starts the kinds it discovers. | `NeverForgotten` |
| `Mutant-PayloadsFail` | No asset request ever returns a payload. | `NeverForgotten` |
| `Mutant-PayloadsFail-ThisLaunch` | The same, against the this-launch property. | `CachedThisLaunch` |
| `Mutant-DeleteSkipsPublished` | Delete ignores the in-memory publication owners. | `NoOrphanAfterDelete` |
| `Mutant-PromoteConfirmUnfenced` | A rename that lost its row to Delete keeps its file. | `NoOrphanAfterDelete` |
| `Mutant-WindowChaptersOnly` | The #394 payload window covers chapter images and not tiles. | `PayloadsBounded` |
| `Mutant-UnownedRow` | A malformed row: complete, with no attempt ID. | `MissingIsDurablyOwedAnyRow` |

`Mutant-UnownedRow` is not a product finding. Every side-asset entry point needs an attempt ID
(`CompletedSideAssetInventory.observe`, `attemptKey(for:)`), so such a row is never repaired. But a
row without a top-level attempt ID is not a supported legacy state: the store classifies it as
malformed (`startupIndexAdmission`), blocks download startup, and on load deletes its cached bundle
on purpose (`corruptSideAssetBundleOwnerFailsClosedOnLoad` asserts that). Indexes from before
attempt IDs are reset as a whole. The mutant shows the properties' scope is load-bearing.

## Findings

Each was checked against the Swift before it was recorded. S1, S2 and S6 are fixed on
specs/downloads-tla (pending merge); the rest are open.

### S1: a cancelled poster owner stays cancelled for the launch (real, fixed)

Issue: #482.

Trace (`Faithful-S1-off`, was `Finding-S1-PosterOwnerStaysCancelled`, `CachedThisLaunch`): a row
is released with the
default `releaseInFlight` mode and keeps its attempt; the release cancels both of the attempt's
coordinator owners; the row later completes under the same attempt; the repair pass offers the
poster; the fetch throws at the coordinator's entry because the poster owner is cancelled; no
budget is charged, so the next pass offers it again, and it fails again.

Why it is real: a cancelled owner is reopened only by a fetch-entry command
(`applyDownloadControl(..., registration: true)`), and `fetchOptionalSideAsset` sends one for every
kind except the poster, which has had its own owner since #450. `releaseInFlight(for:)` is called
in its cancelling mode by paths that keep the row and the attempt, for example the Plex prep
poller's `plexSessionUnavailable` handler.

`NeverForgotten` holds with this trigger on: the cancelled owner is in memory, and the next launch
fetches the poster.

Fixed (`FixPosterReregisters`, now `TRUE` in every config but `Faithful-S1-off`): the poster
branch of `fetchOptionalSideAsset` delivers `.park(false)` as a fetch-entry (registration)
command, so a poster fetch reopens its owner like every other kind. The poster is still never
parked. `Current-S1-PosterReregisters` (was `Proposed-S1-PosterReregisters`) passes;
`Faithful-S1-off` still fails with the fix switched off.

Pin: `posterFetchReopensItsCancelledOwner` (no longer a known issue).

### S2: Pause All can strand a completed row's side assets (real, fixed)

Issue: #483.

Trace (`Faithful-S2-off-Subs`, was `Finding-S2-PauseAllStrandsCompletedRow`, `CachedThisLaunch`):
a row completes; a repair
pass queues a source-metadata refresh; the user taps Pause All, which sends a completed row no
command; the subtitle task moves on to its next stream, and that fetch entry parks the attempt's
owner because the queue is paused; the user taps Resume All; the repair pass runs again and starts
nothing, because the refresh and the subtitle task are both still registered. Nothing enters a new
fetch, so nothing unparks the owner.

Trickplay has the same exposure (`Faithful-S2-off-Tiles`, was
`Finding-S2-TilesParkedBehindPauseAll`): the tiles enter their
fetch after the playlist is parsed, and behind Pause All that entry parks the owner of a finalizing
or completed row. Any fetch entry that comes late in a task does it. The Plex BIF, which enters
when the refresh returns, heals in the model as long as the refresh has budget left: the next pass
starts a new refresh, and its fetch entry unparks the owner.

Why it is real: `fetchOptionalSideAsset` computes `parked` from the queue gate for any lifecycle;
`resumeQueue` re-admits paused and failed rows only and has no unpark of its own; the only unpark
is in `retryRecordAsync`; and every repair entry point is `startIfAbsent`.

`NeverForgotten` holds with this trigger on: the next launch starts with nothing parked.

Fixed (`FixResumeAllUnparks`, now `TRUE` in every config but the two `Faithful-S2-off-*`):
`resumeQueue` sends `setOptionalSideAssetHydrationParked(false, ...)` for every row whose
lifecycle is not `paused`, before its repair pass. A paused row is left to `retryRecordAsync`,
which unparks it when its resume is admitted. `Current-S2-ResumeAllUnparks-Subs`,
`-ChaptersSubs` and `-Tiles` (were `Proposed-S2-*`) pass; the `Faithful-S2-off-*` configs still
fail with the fix switched off.

Pin: `resumeAllUnparksCompletedRows` (no longer a known issue).

### S3: an outage spends the launch's retry budget (probable, a design limit)

Issue: #484.

Trace (`Finding-S3-OutageExhaustsBudget`, `CachedThisLaunch`): the server is unreachable; a poster
dispatch fails and is charged; the server comes back; the budget for that poster is spent, so
nothing offers it again in this launch.

The budget is charged at transport admission whatever the outcome, and its stated purpose is an
asset the server can never produce. With the real budget of five, five foreground edges away from
the server exhaust it for every asset a completed row is missing. A park of an in-flight request
also costs a dispatch, because the request is cancelled, requeued and charged again.

Trickplay is hit harder (`Finding-S3-TilesBehindPlaylistBudget`):
`DownloadSideAssetRepairInventory.retryResources` returns only `"playlist"` for trickplay, so the
offer is gated by the playlist's budget alone. Once the playlist's dispatches are spent, no tile is
retried in that launch, whatever budget the tiles have left, and every pass that repairs one tile
costs a playlist dispatch.

A relaunch restores the budget, so `NeverForgotten` holds. Whether a transient failure should count
is a product decision, so this is not pinned.

### S4: a refused Resume leaves a paused row unparked (probable, low)

Issue: #485.

Trace (`Finding-S4-RefusedResumeUnparks`): the user pauses a row; the user taps Resume;
`retryRecordAsync` unparks the side assets before its own guards; the storage cap or a missing
backend refuses the resume; the row stays paused and its chapter images go out on the network.

`Proposed-S4-UnparkOnAccept` passes with the unpark moved behind the guards. Not pinned: the unpark
may sit before the guards on purpose, since it is the only unpark there is.

### S5: a dropped repair pass is not run again (real, low)

Three traces, one cause: the scan runs once per edge and keeps no note of an edge it could not
serve.

- `Finding-S5-BusyEdgeDropped` (`NoEdgeOutsidePass`): row 1 completes and an edge starts a pass
  that observes it; row 2 completes; a second edge arrives while the pass runs and returns at
  `guard !isQueuePaused, completedSideAssetInventoryWorker == nil else { return }`. The pass that
  runs never saw row 2.
- `Finding-S5-PassTimeoutNoRerun` (`NoEdgeLost`): the inventory worker misses
  `work.observe(deadline: .after(30))`; the pass returns and dispatches nothing.
- `Finding-S5-StaleRowSkipped` (`NoEdgeLost`): the row's own poster is promoted while the pass
  observes the row; `inventory.matches(self.store)` fails on the mutation generation and the row is
  skipped.

The rows wait for the next edge, which only the user causes: another foreground, a backend switch,
Resume All or a relaunch. No edge fires when a row completes. `NeverForgotten` holds, because the
launch edge of a later launch scans the row.

Proposed in the model (`FixPassReruns`): a pass that was asked for while one ran, that timed out
or that skipped a row runs again. `Proposed-S5-PassReruns` and `-Stale` pass with it.

Pin: `droppedRepairEdgeRunsAgain`. Issue #493.

### S6: a completed row on a backend that is not selected is never repaired (real, fixed)

Trace (`Faithful-S6-off`, was `Finding-S6-InactiveBackendStaysCold`, `NeverForgotten`): a row on
the other backend
completes with its poster missing (here an outage spent the budget); the app is terminated and
relaunched; launch restores the selected backend, finds no active work on the other one and leaves
it without a session; the launch pass scans the row and starts nothing; every later launch does the
same.

Why it is real: `runLaunchDownloadRecovery` hydrates only backends with `status.isActiveWork` rows
or journaled cleanup, and its comment says completed rows stay cold until their "side-asset
dispatch edge". That edge is `rehydrateMissingOptionalSideAssets`, which looks the session up with
`appModel.backendSession(for:)` and returns when there is none. Nothing hydrates a session for it.
The row is repaired only when the user switches to that backend (`backend_switched`).

This is the one finding where the durable property fails on a supported path with nothing
malformed: the record is durable, but no launch acts on it.

Fixed (`FixHydrateCompleted`, now `TRUE` in every config but `Faithful-S6-off`): launch also
restores the saved session of a backend that has a completed row with a missing side asset.
`DownloadManager.backendsOwingCompletedSideAssets` observes completed rows on a store worker with
the same `CompletedSideAssetInventory` the repair pass uses, and `runLaunchDownloadRecovery`
adds those backends to the ones it hydrates. The repair still requires the saved session to match
the row's own server and user (`matchesPersistedServer`), which is what the model's `Quiet`
assumes. `Current-S6-HydrateCompleted` (was `Proposed-S6-HydrateCompleted`) passes;
`Faithful-S6-off` still fails with the fix switched off.

Pin: `launchHydratesBackendsOfCompletedRowsMissingAssets` (no longer a known issue). Issue #494.

### S7: the Plex BIF is taken from the first part, not the downloaded one (real, fixed)

Fixed on `specs/downloads-tla`, pending merge (#495). The configs below are now
`Faithful-S7-off-*`: the fix switched off (`FixBifChosenPart = FALSE`) must still violate.

- `Faithful-S7-off-BifOfChosenPartNeverAsked` (`NeverForgotten`) and `-NotOwed`
  (`MissingIsDurablyOwed`): the user downloads the second part of a multi-part item, and only that
  part has a BIF. The initial pass and every refresh look at the first part, see no index and
  start nothing. The trick-play index is never requested, in any launch.
- `Faithful-S7-off-WrongPartBifCached` (`CachedBifIsForChosenPart`): the first part has a BIF. It is
  fetched and cached under the row, for a file it does not describe.

Why it was real: the transfer uses `chosenMedia?.part[safe: partIndex]`, and the part index comes
from the download options sheet. `cachePlexBIF(for:item:mediaIndex:server:token:)` took no part
index, at either call site, and `DownloadSideAssetPolicy.selectedPlexBIFPart` returned
`selectedMedia.part.first`. The subtitle repair already used `part[safe: partIndex]`.

The fix (`FixBifChosenPart`): `cachePlexBIF(for:item:mediaIndex:partIndex:server:token:)` is
called with the row's part index from the initial pass and the completed-row repair, and
`selectedPlexBIFPart(from:mediaIndex:partIndex:)` selects `part[partIndex]` (nothing when the media
has no such part). `Current-S7-BifChosenPart` passes. The other `Current-*` configs download the
first part (`ChosenPartIsFirst = TRUE`), where the switch has no effect, so they leave it `FALSE`.

Test: `plexBIFComesFromTheDownloadedPart` (behavioural, on the PMSKit policy; passes). Issue #495.

### S8: a promotion gives up on any concurrent write to its row (real, low)

Trace (`Finding-S8-PromotionLostToRowMutation`, `PromotionNotLostToRace`): the poster's payload
arrives; the store snapshots the row's mutation generation; the transfer writes the row's lifecycle;
the pre-rename check sees a different generation and the promotion returns `.staleOrMissingOwner`.
The row is live, with the same attempt and source.

Why it is real: `setRowLocked` advances `rowMutationGenerations` on every row write, and
`promoteAttemptStagingFile` compares it between the snapshot and the rename. After the rename it
compares `sideAssetGeneration`, which another side asset's confirmation advances, and removes the
file it just renamed. Each `DownloadStoreWork` runs on its own queue, so two promotions of one row
do overlap. No caller retries: the payload is dropped, the dispatch stays charged, and the asset
waits for the next repair edge. The window is a file-existence check and a rename wide, so this is
rare. It is a retry that is missing, not a fence that is wrong.

Not proposed in the model. Pin: `promotionSurvivesAnUnrelatedRowWrite`. Issue #496.

### #503: the Plex repair looks the downloaded part up by index (real, fixed)

Fixed on `specs/downloads-tla`, pending merge. Raised by the round 2 re-review and confirmed in the
source. A Plex row is downloaded from part A; its subtitle (or BIF) is missing. Plex later reorders
the item's media so another part sits at A's old index. The completed-row repair refreshed the item
and took `currentItem.media?[safe: mediaIndex]?.part[safe: partIndex]` for subtitles and
`selectedPlexBIFPart(from:mediaIndex:partIndex:)` for the BIF, so it fetched the other part's
subtitle and BIF (`Faithful-503-off-WrongPartSubs`, `-WrongPartBif`), or nothing when that part has
none (`Faithful-503-off-SubsNeverFetched`), on every launch, although the row persists A's
`sourcePartID` (`DownloadOfflineMetadataBuilder`). The S7 fix (#495) chose the right index but not
the right identity. The model could not see it: a file for the wrong source satisfied
`MissingIsDurablyOwed` and `NeverForgotten`.

The fix (`FixRepairByPartID`): both repairs resolve the part by the persisted `sourcePartID`
(`DownloadSideAssetPolicy.plexRepairPart`, `selectedPlexBIFPart(...sourcePartID:)`); an ID the
refreshed item no longer has selects nothing, and only a row that stored no ID falls back to the
indexes. The initial pass keeps the indexes into the item the transfer starts from.
`Current-503-RepairByPartID` and `-Bare` pass. Pin: `plexRepairResolvesThePartByItsPersistedID`.

### #504: assets missing from the saved inventory are never fetched (real, fixed)

Fixed on `specs/downloads-tla`, pending merge. Raised by the round 2 re-review and confirmed in the
source. Two cases:

- **Late chapter thumbnails** (`Faithful-504-off-LateChapters`): the row was saved without chapter
  thumbnails. `DownloadSideAssetRepairInventory.missingKinds` derives the inventory from the saved
  chapters, so it never offers `.chapterImages`, and the source refresh that did return thumbnails
  skipped the chapter cache call because `.chapterImages` was not among the offered kinds. Fix: a
  successful refresh on any backend calls `adoptRefreshedChapterImages`, which persists the
  chapters it learns (`DownloadSideAssetPolicy.learnedOfflineChapters`) and fetches their images
  against the persisted indexes; every later inventory then owes them.
  `Current-504-LateChapters` passes.
- **Empty Plex thumb with a valid art** (`Faithful-504-off-EmptyThumb`): `offlinePosterRef`
  returned `thumb ?? art`, which is `""`; the fetch declined it and the inventory, which asks the
  same selector, omitted the poster. Fix: the selector skips empty and blank fields. Jellyfin and
  Emby go through the same selector (their poster fetch already fell back to `art` when the
  request could not be built, but their inventory did not). `Current-504-EmptyThumb` passes.

The model could not see either: it enumerated asset slots from the config, not from the saved row.
Pins: `refreshedChapterThumbnailsJoinTheInventory`, `emptyArtworkFieldFallsBack`.

### Known deferred items the model reproduces

- **st-39, orphan reclamation (#401).** `Finding-st39-CrashOrphanAfterDelete`: the process dies
  between a side asset's rename and its metadata record. After relaunch only the in-memory
  publication owners knew the file, so Delete leaves it behind. If the row is kept instead, the
  repair pass fetches the asset again and overwrites the file.
  `Finding-st39-ReplacedAttemptOrphan` reaches the same end without process death: a retry replaces
  the attempt between the rename and the record, the replacement retires only the recorded paths,
  and the publication owner belongs to the old attempt. The trickplay task adds a third way to hold
  unrecorded files: it records its tiles only with the local playlist, so tiles that were promoted
  before a failed playlist write stay owned in memory alone.
- **#394, payload queueing.** `Finding-394-PayloadsBehindPreparation`: three chapter payloads wait
  behind one preparation. `Finding-394-TilePayloadsBehindPreparation`: the trickplay tile group has
  the same shape. `Proposed-394-Window` passes with a window of two from fetch through promotion
  over both groups, and `Mutant-WindowChaptersOnly` shows that a window over chapter images alone
  leaves tiles unbounded.

Neither has a Swift pin here: both are already tracked, and neither has a pure decision to pin.

### F3 on this model: a body that finishes behind a user pause (real, fixed)

Found while fixing F3 (#474). `PausedBodyFinished` (`AllowPausedFinish`): a forward-only
transfer finishes as a user pause lands, the body is captured and the paused row finalizes and
completes. The pause parked the attempt's owner and left its tasks registered. A finished row
has no Resume, and the repair pass starts nothing for a registered kind, so chapter images (a
kind with no discovery refresh to enter a new fetch) stayed parked until relaunch
(`Faithful-F3-finish-off-Chapters`, `CachedThisLaunch`). A discovered kind escapes by the
pass's source-metadata refresh, whose fetch entry unparks the owner.

Fix (`FixFinishUnparks`, in the code): the publishing finalizer's admission unparks the row
(`DownloadManager.unparkOptionalSideAssetsForFinishedBody`,
`DownloadSideAssetParkPolicy.finishedBodyUnparks`), unless Pause All holds it, in which case
Resume All does (S2). `Current-F3-FinishUnparks-Chapters` passes. Pins:
`DownloadsFormalModelSideAssetsTests.finishedBodyUnparksSideAssets`,
`P7SideAssetOrderingTests.finishedBodyUnparksTheOwnerItsPauseParked`. Every other config has
`AllowPausedFinish = FALSE`.

## Delete, checked against the store

`Current-Delete` runs the staged deletion against the three-step promotion and finds no orphan
without process death or a replaced attempt. The store's fences carry that result, and each has a
mutant or a pin:

- the deletion intent lists paths a rename has published but metadata has not recorded
  (`Mutant-DeleteSkipsPublished`);
- a promotion checks the row again under the lock after its rename, and removes the file when the
  row is gone or being deleted (`Mutant-PromoteConfirmUnfenced`);
- a metadata update is refused while a deletion is pending.

`deleteFencesTheModelAssumes` pins all three in the store's source. `OrderedAsyncWorkCoordinator`
is not what makes Delete safe here, and the model no longer leans on it: side-asset tasks are not
submitted to it.

## Results (2026-11-24, tla2tools v1.7.4, `TLC_WORKERS=2 TLC_HEAP=2g`)

Run one `check-tla-specs.sh` at a time in a worktree: two runs over the same folder share the log
and state directories and report wrong results.

| Config | Expectation | Result | Distinct states | Time |
| --- | --- | --- | --- | --- |
| `Current-AllKinds` | pass | pass | 3,629,869 | 136 s |
| `Current-Bif` | pass | pass | 25,512 | 1 s or less |
| `Current-Chapters` | pass | pass | 29,385 | 3 s |
| `Current-ChaptersSubs` | pass | pass | 67,804 | 5 s |
| `Current-Delete` | pass | pass | 181,188 | 8 s |
| `Current-Poster` | pass | pass | 85,656 | 4 s |
| `Current-S1-PosterReregisters` | pass | pass | 3,675 | 2 s |
| `Current-S2-ResumeAllUnparks-ChaptersSubs` | pass | pass | 42,585 | 10 s |
| `Current-F3-FinishUnparks-Chapters` | pass | pass | 370 | 1 s |
| `Current-S2-ResumeAllUnparks-Subs` | pass | pass | 12,228 | 4 s |
| `Current-S2-ResumeAllUnparks-Tiles` | pass | pass | 8,580 | 5 s |
| `Current-S6-HydrateCompleted` | pass | pass | 27,162 | 10 s |
| `Current-Subs` | pass | pass | 44,023 | 2 s |
| `Current-Tiles` | pass | pass | 42,107 | 2 s |
| `Current-TwoBackends` | pass | pass | 124,766 | 6 s |
| `Current-TwoRows` | pass | pass | 276,741 | 12 s |
| `Liveness-Durable-Discovered` | pass | pass | 128,540 | 32 s |
| `Liveness-Durable-PosterChapters` | pass | pass | 108,919 | 31 s |
| `Liveness-Durable-Tiles` | pass | pass | 48,069 | 11 s |
| `Liveness-ThisLaunch-Discovered` | pass | pass | 22,862 | 5 s |
| `Liveness-ThisLaunch-PosterChapters` | pass | pass | 7,439 | 2 s |
| `Liveness-ThisLaunch-Tiles` | pass | pass | 4,666 | 2 s |
| `Proposed-394-Window` | pass | pass | 282,392 | 11 s |
| `Proposed-S4-UnparkOnAccept` | pass | pass | 608 | 2 s |
| `Proposed-S5-PassReruns-Stale` | pass | pass | 1,474 | 1 s or less |
| `Proposed-S5-PassReruns` | pass | pass | 299,686 | 15 s |
| `Current-S7-BifChosenPart` | pass | pass | 16,441 | 2 s |
| `Current-503-RepairByPartID` | pass | pass | 128,540 | 34 s |
| `Current-503-RepairByPartID-Bare` | pass | pass | 17,409 | 5 s |
| `Current-504-LateChapters` | pass | pass | 6,521 | 2 s |
| `Current-504-EmptyThumb` | pass | pass | 15,859 | 4 s |
| `Faithful-B25-off` | violation of `RepairWithinRateLimit` | violated | 131 | 1 s or less |
| `Faithful-B32-off-PausedFetch` | violation of `PausedRowNotFetching` | violated | 187 | 1 s or less |
| `Faithful-B32-off` | violation of `ControlsApplyInRequestOrder` | violated | 48 | 1 s or less |
| `Faithful-S1-off` | violation of `CachedThisLaunch` | violated | 275 | 1 s or less |
| `Faithful-F3-finish-off-Chapters` | violation of `CachedThisLaunch` | violated | 328 | 1 s |
| `Faithful-S2-off-Subs` | violation of `CachedThisLaunch` | violated | 5,761 | 2 s |
| `Faithful-S2-off-Tiles` | violation of `CachedThisLaunch` | violated | 1,262 | 1 s or less |
| `Faithful-S6-off` | violation of `NeverForgotten` | violated | 518 | 1 s or less |
| `Faithful-503-off-WrongPartSubs` | violation of `CachedAssetIsForDownloadedPart` | violated | 559 | 1 s or less |
| `Faithful-503-off-WrongPartBif` | violation of `CachedAssetIsForDownloadedPart` | violated | 575 | 1 s or less |
| `Faithful-503-off-SubsNeverFetched` | violation of `MissingIsDurablyOwed` | violated | 44 | 1 s or less |
| `Faithful-504-off-LateChapters` | violation of `ServedAssetInInventory` | violated | 33 | 1 s or less |
| `Faithful-504-off-EmptyThumb` | violation of `ServedAssetInInventory` | violated | 31 | 1 s or less |
| `Mutant-DeleteSkipsPublished` | violation of `NoOrphanAfterDelete` | violated | 267 | 1 s or less |
| `Mutant-NoDiscoveryDispatch` | violation of `NeverForgotten` | violated | 3,861 | 2 s |
| `Mutant-PayloadsFail-ThisLaunch` | violation of `CachedThisLaunch` | violated | 2,531 | 2 s |
| `Mutant-PayloadsFail` | violation of `NeverForgotten` | violated | 2,567 | 2 s |
| `Mutant-PromoteConfirmUnfenced` | violation of `NoOrphanAfterDelete` | violated | 502 | 1 s or less |
| `Mutant-UnownedRow` | violation of `MissingIsDurablyOwedAnyRow` | violated | at the initial state | 1 s or less |
| `Mutant-WindowChaptersOnly` | violation of `PayloadsBounded` | violated | 2,923 | 1 s or less |
| `Finding-394-PayloadsBehindPreparation` | violation of `PayloadsBounded` | violated | 2,939 | 1 s or less |
| `Finding-394-TilePayloadsBehindPreparation` | violation of `PayloadsBounded` | violated | 3,132 | 1 s or less |
| `Finding-S3-OutageExhaustsBudget` | violation of `CachedThisLaunch` | violated | 600 | 1 s or less |
| `Finding-S3-TilesBehindPlaylistBudget` | violation of `CachedThisLaunch` | violated | 1,580 | 1 s or less |
| `Finding-S4-RefusedResumeUnparks` | violation of `PausedRowNotFetching` | violated | 474 | 1 s or less |
| `Finding-S5-BusyEdgeDropped` | violation of `NoEdgeOutsidePass` | violated | 509 | 1 s or less |
| `Finding-S5-PassTimeoutNoRerun` | violation of `NoEdgeLost` | violated | 65 | 1 s or less |
| `Finding-S5-StaleRowSkipped` | violation of `NoEdgeLost` | violated | 59 | 1 s or less |
| `Faithful-S7-off-BifOfChosenPartNeverAsked` | violation of `NeverForgotten` | violated | 11 | 1 s or less |
| `Faithful-S7-off-BifOfChosenPartNotOwed` | violation of `MissingIsDurablyOwed` | violated | 46 | 1 s or less |
| `Faithful-S7-off-WrongPartBifCached` | violation of `CachedBifIsForChosenPart` | violated | 164 | 1 s or less |
| `Finding-S8-PromotionLostToRowMutation` | violation of `PromotionNotLostToRace` | violated | 124 | 1 s or less |
| `Finding-st39-CrashOrphanAfterDelete` | violation of `NoOrphanAfterDelete` | violated | 811 | 1 s or less |
| `Finding-st39-ReplacedAttemptOrphan` | violation of `NoOrphanAfterDelete` | violated | 962 | 1 s or less |
| `Deep-AllKinds` (deep tier; not rerun after the S1, S2 and S6 fixes) | pass | pass | 16,294,270 | 577 s |

The violation runs stop at the first error, so their state counts are not totals.

The `Current-*` configs check every safety property except the ones the findings break:
`NoOrphanAfterDelete` is checked only by `Current-Delete`, which has no process death and no
replacement attempt (st-39); no `Current-*` config allows a refused Resume (S4), records edges
(S5), uses the three-step promotion outside `Current-Delete` (S8). Only `Current-S7-BifChosenPart`
downloads a part other than the first (S7, fixed). Only the `Current-503-*` and `Current-504-*`
configs set a `Drift`; the others keep `Drift = "none"` with both fixes on, where they have no
effect. The `Liveness-Durable-*` configs are the code as it stands with every environment
switch on. The `Liveness-ThisLaunch-*` configs leave out the triggers of S1, S2 and S3 and give the
budget more dispatches than the environment can spend; the S1 and S2 triggers are checked against
the fixed code by `Current-S1-*` and `Current-S2-*`.

## Modelling artefacts, fixed in the model

- The first draft reset a cancelled task's requests without recording what the task had already
  promoted. The code does not do that: nothing checks for cancellation between a rename and the
  metadata update, so a cancelled poster, BIF or chapter task still records what it promoted. The
  subtitle loop is the exception, because it returns at its next cancellation check and drops the
  tracks it has collected. `RecordedAfterCancel` says so.
- Worker fairness was one `WF` over every worker step. S1's poster task restarts on every edge
  without being charged, and that one task's steps satisfied the fairness of all the others, so a
  chapter task that was ready to record never had to. Fairness is now per task and per promotion.

## Not covered

- Request pacing (one start per second) and round-robin between owners. The concurrency cap and
  the budget are modelled.
- A second coordinator owner waiting on the same request (coalescing), and playback's use of the
  same coordinator.
- A change of side-asset source inside one attempt (Plex optimize hand-off, Convert) and the
  store's source fence. A replacement attempt is modelled.
- Source drift other than `Drift`'s cases: a part ID that disappears from the server, chapters
  that change after thumbnails were cached, and a refresh that loses thumbnails the row saved.
- Staging files and the startup staging inventory. Disk-full writes: a failed write behaves like
  a failed fetch.
- A recorded file that disappears from disk, and with it the path-lease exclusion between a
  promotion and the deletion worker on a path the deletion lists.
- A task cancelled in the middle of a promotion: the model sends the rename to the store's
  confirmation as a zombie, where the code lets the task finish and record it.
- Resumes that do not go through `retryRecordAsync`. Reconcile promoting a user-paused row (F2)
  would leave the owner parked on a running row.
- The inventory's reuse cache. The snapshot a pass takes is the row set and each row's generation.
- The unverified terminal state: rows end `complete`. Both are playable and treated alike.
- An offline launch in which the selected backend's session is not restored. `Relaunch` hydrates
  the selected backend whenever it has a saved session.
- The Delete journal for server cleanup (`DownloadsCleanup`), admission after Resume All
  (`DownloadsAdmission`) and storage accounting (`DownloadsStorage`).
