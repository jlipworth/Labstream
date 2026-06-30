# Holistic downloads refactor plan

This branch treats Downloads as one subsystem, not as a narrow `DownloadManager.swift`
cleanup. The current module already has useful seams (`PMSKit/Downloads` pure policy,
`DownloadStore`, backend-specific manager extensions, side caches, and
`BackgroundDownloadSession`), but the remaining coupling is still spread across identity,
job state, backend source resolution, transfer/recovery, persistence, diagnostics, and UI
snapshot derivation.

## Goals

1. **Make the state machine explicit.** A download should move through named phases:
   enqueue, optional server preparation, transfer, validation, complete/unverified,
   paused, failed, delete/cancel. Today those phases are inferred from a mix of
   `DownloadStatus`, metadata flags, active-job sets, server-poller tasks, and URLSession
   callbacks.
2. **Keep backend quirks modeled, not flattened.** Plex optimize, Jellyfin live-forward
   remux/transcode, Emby PlaybackInfo routing, and Emby convert jobs are different. The
   refactor should isolate those differences behind small planners/adapters rather than
   force one protocol that hides load-bearing behavior.
3. **Move pure decisions to PMSKit.** Identity, routing, retry eligibility, side-asset
   inventory, progress display, completion validation, and range planning should be
   deterministic and unit-tested outside the app target.
4. **Make transfer/recovery the center of gravity.** Static byte-range checkpointing,
   URLSession reattachment, queue pause/resume, retry preservation, validator changes,
   and final-file validation are the highest-risk code paths and should have the clearest
   ownership boundaries.
5. **Preserve durable behavior during migration.** Every slice should build and either be
   behavior-preserving or add tests that pin the intended behavior before changing it.


## Branch implementation status

- **Done: Slice 1 record identity leaf extraction.** `DownloadRecordIdentity` now owns
  backend row-key construction, prefix fallback, and backend-local item-id extraction.
  `DownloadBackendKind`, `OfflinePlaybackDecision`, and the app coordinator delegate to it,
  with PMSKit tests pinning the legacy Plex bare-key and MediaBrowser prefix semantics.
- **Done: Slice 2 first transfer-start seam.** `DownloadTransferStartPlan` now carries the
  shared diagnostic/start-failure contract for all backend transfer handoffs. Backend files
  still resolve sources and preserve their quirks; the common handoff surface is typed for
  the next coordinator extraction.
- **Done: Slice 3 first recovery-policy extraction.** `StaticRangeRecoveryPolicy` now owns
  pure static byte-range recovery decisions: static-lane detection, completed-checkpoint
  finalization eligibility, deferred-resume visible state, queue-paused manual-resume
  gating, retry-handoff demotion, and preservation of validator/adopted-failure restart
  counters. `DownloadManager` still performs store/session side effects, but delegates the
  tested decisions to PMSKit.
- **Done: Slice 4 first backend route-planner extraction.** `JellyfinDownloadRouter` now
  pins the Jellyfin-specific distinction between static original downloads, compatible-remux
  live-forward streams, and transcode live-forward streams. The app backend still owns
  PlaybackInfo calls, request construction, PlaySession keepalive, metadata mutation, and
  side-cache work; only the pure route decision moved.
- **Done: Slice 3b recovery-state tracker extraction.** `StaticRangeRecoveryTracker` now
  groups the stateful, IO-free static-range recovery sets that used to be independent
  `DownloadManager` fields: pending backend-auth resumes, finalization re-entry guards,
  checkpoint-draining pauses, queue-paused per-row manual resumes, and one-shot restart
  counter preservation. This keeps URLSession mechanics separate while preparing the later
  app-layer recovery coordinator.
- **Done: Probe harness for static range recovery.** `scripts/probe-plex-range-drop.sh`
  wraps the existing DEBUG launch-argument probe so a signed-in worktree simulator can
  exercise static byte-range recovery after an injected `NSURLErrorNetworkConnectionLost`
  without committing Plex tokens or hard-coded media ids. It now forces the Plex backend for
  the probe run, uses absolute `simctl launch` stdout/stderr paths, and can target existing
  server-generated Plex versions by media/part index so a pre-optimized MP4 can validate the
  static range lane quickly. This is intentionally a behavior probe, not a replacement for
  PMSKit unit tests or device/background validation.
- **Done: Slice 4b Plex route-planner extraction.** `PlexDownloadRouter` now pins the
  pure Plex route choices: true originals require an AV preflight, existing Plex versions
  are static downloads that skip optimizer/preflight, explicit optimizer targets pass
  through unchanged, and Jellyfin/Emby-style compatible intent maps onto Plex's optimizer
  fallback target.
- **Done: Slice 4c Jellyfin route-planner wiring.** All Jellyfin entry routes now flow
  through `JellyfinDownloadRouter`, including original/static, explicit transcode, and
  compatible-remux fallback. The router now also carries stable diagnostic labels and the
  compatible-remux eligibility needed by the request builder.
- **Done: Slice 5a server-prep attempt tracker.** `ServerPrepAttemptTracker` now owns
  IO-free attempt identities shared by Plex optimize and Emby convert: protected Plex
  queue titles, Plex poller ownership, and Emby convert attempt UUID replacement. The app
  still owns URLSession/tasks and backend requests, but releases server-prep identities
  through one tested model.
- **Done: Slice 7a row display policy extraction.** `DownloadRowDisplayPolicy` now owns
  tested offline-row wording for active lane captions, estimated-vs-exact percentages,
  paused/complete captions, byte strings, and ETA buckets. The app snapshot still supplies
  live state, but repeated UI wording is no longer embedded directly in `DownloadManager`.
- **Done: Slice 7b row status-caption policy extraction.** `DownloadRowStatusCaptionPolicy`
  now owns the explicit tested row phase/caption composition for failed/retrying, paused,
  complete, server-prep, zero-byte static transfer, active transfer, server-paced transcode,
  and local/server finalizing states. `DownloadManager` supplies live dictionaries and
  app-local error text, but the nuanced caption state machine is no longer embedded in the
  coordinator.
- **Done: Slice 7c offline snapshot builder extraction.** `OfflineLibrarySnapshotBuilder`
  now owns the app-layer aggregation from records plus live coordinator facts into rows, mixed
  backend badges, queue toolbar action, and aggregate metrics. `DownloadManager` still owns
  the facts, but the hot UI publication shape has its own seam.
- **Done: Slice 6a range HTTP policy extraction.** `RangeTransferHTTPPolicy` now owns
  tested pure HTTP-header decisions for static byte-range transfer reattachment and validation:
  Range segment classification, durable-checkpoint detection, closed-range length, strong
  `If-Range` validator selection, `Content-Range` start/total parsing, request offset parsing,
  and safe acceptance of URLSession's internally-resumed closed Range temps.
  `BackgroundDownloadSession` still owns URLSession/temp-file side effects, but its parsing
  semantics are pinned in PMSKit.
- **Done: Slice 6b background completion gate extraction.**
  `BackgroundDownloadCompletionGate` now owns the pure state machine for holding app-delegate
  background URLSession completion handlers until durable append/finalization work drains.
  `BackgroundDownloadSession` still calls the app registry and owns locking, but the defer/fire
  semantics are unit-tested outside the delegate.
- **Done: Slice 6c static range task selection policy.**
  `StaticRangeTaskSelectionPolicy` now pins the pure ownership rule for duplicate or racing
  static byte-range URLSession tasks: the furthest checkpoint wins, with in-flight chunk bytes
  breaking ties. `BackgroundDownloadSession` still owns the actual task registry and cancellation,
  but stale progress/finish suppression now delegates the comparison semantics to PMSKit tests.
- **Done: Slice 6d static range retry budget extraction.**
  `StaticRangeRetryBudget` now owns the separate retry counters for validator-change restarts and
  misaligned `Content-Range` retries. These counters are intentionally distinct from generic
  URLSession retry counts because progress callbacks from a bad temp file must not erase them; only
  a real durable append or fresh user start resets the budget.
- **Done: Slice 6e finished range chunk pause policy.**
  `StaticRangeFinishedChunkPolicy` now owns the pure decision for finished chunks that race with
  pause/cancel: hard halts discard the temp, paused rows write then remain paused, and graceful
  checkpoint pauses preserve durable bounded/background chunks without starting the next range.
- **Done: Slice 6f static range segment strategy policy.**
  `StaticRangeSegmentStrategyPolicy` now owns the pure scene/background-event decision for choosing
  foreground bounded checkpoint chunks versus background-owned checkpoint chunks. The app still
  counts live candidates and logs diagnostics, but the off-head strategy/reason semantics are pinned
  in PMSKit.
- **Done: Slice 6g static range reattach policy.**
  `StaticRangeReattachPolicy` now owns the pure relaunch-adoption decision for surviving static
  byte-range URLSession tasks: requested offsets must match the durable partial checkpoint, and
  duplicate adopted tasks are replaced or suppressed using the same authoritative-task rule as live
  progress/finish handling.
- **Done: Slice 6h background task identity extraction.**
  `BackgroundDownloadTaskIdentity` now owns the pure best-effort mapping from surviving
  background URLSession tasks back to download row keys. It preserves the task-description-first
  contract, legacy Plex/Jellyfin URL fallbacks, and the important Plex `/library/parts/...`
  limitation that cannot infer the source rating key without an explicit task description.
- **Done: Slice 6i background progress policy extraction.**
  `BackgroundDownloadProgressPolicy` now owns transfer-progress decisions that were embedded in
  `BackgroundDownloadSession`: relaunch expected-byte recovery from persisted progress, durable
  range-progress diagnostic throttling, and UI progress refresh throttling while preserving terminal
  completion updates.
- **Done: Slice 6j transient retry policy extraction.**
  `BackgroundDownloadTransientRetryPolicy` now owns the retry gates for transient URLSession errors:
  opaque download retries require OS resume data plus a persisted-resume-safe lane, while static
  Range retries require an in-memory authenticated request and use the same bounded retry budget.
- **Done: Slice 6k pause/cancellation race policy extraction.**
  `BackgroundDownloadPauseCancellationPolicy` now owns the pure pause/cancel race decisions used by
  delayed URLSession callbacks: old cancel callbacks may mark a row paused only when no replacement
  task owns it, and range-start cancellation is suppressed when pause/delete already owns the row.
- **Done: Slice 6l background temp-file cleanup policy extraction.**
  `BackgroundTempFileCleanupPolicy` now owns the pure cleanup boundaries for background transfer
  temps: range chunk stash ownership, CFNetwork temp filename eligibility, nsurlsessiond cache path
  derivation, and the "never delete while URLSession reports live tasks" gate.
- **Done: Slice 6m finalization result policy extraction.**
  `BackgroundFinalizationResultPolicy` now owns the pure mapping from completion-validation outcomes
  to row status/result labels/file-deletion intent: complete rows become `.complete`, truncated files
  fail and are deleted, and probe misses remain `.unverified` while preserving bytes.
- **Done: Slice 6n opaque completion error policy extraction.**
  `BackgroundOpaqueCompletionPolicy` now owns the pure post-retry terminal mapping for opaque
  URLSession download errors: cancellation is non-failure, persisted-resume-safe static lanes pause
  with resume data, forward-only streams fail even if URLSession offers a byte-offset blob, and all
  other non-cancelled errors fail normally.
- **Done: Slice 6o range completion error policy extraction.**
  `BackgroundRangeCompletionPolicy` now owns the pure post-retry terminal mapping for static
  byte-range task completions: successful chunks are handled by the finish callback, cancellations
  are ignored as user/system intent, adopted failed chunks request backend-auth rebuild, and
  in-memory failed chunks become resumable pauses from the durable checkpoint.
- **Done: Slice 6q static range continuation policy extraction.**
  `StaticRangeContinuationPolicy` now owns the pure continuation routing table after durable
  checkpoint advancement, offset-mismatch recovery, and validator-change restarts: halted rows no-op,
  adopted relaunch chunks request backend-auth rebuild, exhausted budgets fail, and live in-memory
  chunks schedule the next Range request directly.
- **Done: Slice 6p server-prep refresh policy extraction.**
  `ServerPrepRefreshPolicy` now owns the pure refresh-time reattachment decisions for server-side
  prep rows: unattached Plex optimize rows require no active poller, persistent Emby convert jobs
  can keep polling while the global queue is paused, and refresh kicks are debounced/countable
  without embedding backend filters directly in `DownloadManager.refreshRecords`.
- **Done: Slice 5b download start slot policy extraction.**
  `DownloadStartSlotPolicy` now owns the admission table for the app-level in-flight slot:
  duplicate active rows are rejected, duplicate active slots with visible rows stay rejected, and
  stale active slots with no store row are recovered before accepting a replacement start.
- **Done: Slice 5c download pause policy extraction.**
  `DownloadPausePolicy` now owns the visible-row pause routing table: terminal rows ignore pause,
  preparing rows park immediately, static byte-range rows either checkpoint-drain or park depending
  on live URLSession ownership, opaque/live-forward rows route through URLSession, and global queue
  pause skips persistent Emby convert polling while pausing other active work.
- **Done: Slice 3c static range refresh-cleanup policy extraction.**
  `StaticRangeRefreshCleanupPolicy` now owns the pure refresh-time cleanup predicates for static
  range recovery overlays: terminal finalization keys, manual queue-resume markers that must survive
  retry handoff failed rows, checkpoint-pause liveness, and stale live range-progress overlays.
- **Done: Slice 5d download delete policy extraction.**
  `DownloadDeletePolicy` now owns the delete-time Emby convert cancellation decision: preparing rows
  with a persistent convert job cancel that server job when the persisted Emby lane matches, log a
  skip when the lane is unavailable/mismatched, and otherwise delete purely locally.
- **Done: Slice 5e download retry preparation policy extraction.**
  `DownloadRetryPreparationPolicy` now owns retry-entry predicates for manual queue-paused static
  resumes, paused Emby convert polling reentry, persisted URLSession resume-data continuation,
  paused Plex server-prep reattachment, and async retry-attempt cancellation.
- **Done: Slice 5f backend encoder teardown policy extraction.**
  `DownloadEncoderTeardownPolicy` now owns the terminal cleanup decision for Emby/Jellyfin live
  encoders: transient play sessions stop only against an available matching backend lane, and
  persisted playSession cleanup logs a mismatch instead of firing against the wrong server.
- **Done: Slice 5g resume retry schedule policy extraction.**
  `DownloadResumeRetrySchedulePolicy` now owns the cold-launch/auth-edge retry cadence for server
  prep and static-range resume scanners, including the queue-paused rule that only persistent Emby
  convert polling should resume while the global queue gate remains paused.
- **Done: Slice 5h download watchdog policy extraction.**
  `DownloadWatchdogPolicy` now owns the app-level watchdog predicate/cadence for rows that need
  periodic refreshes despite sparse URLSession callbacks: server-prep `.preparing` rows and
  forward-only MediaBrowser streams that require stall detection.
- **Done: Slice 5i download health snapshot policy extraction.**
  `DownloadHealthSnapshotPolicy` now owns low-frequency health diagnostic counting, work detection,
  throttle cadence, and field names. `DownloadManager` only adapts live runtime/session counts and
  records the already-derived `downloads.health_snapshot` payload.
- **Done: Slice 5j live range progress policy extraction.**
  `DownloadLiveRangeProgressPolicy` now owns ephemeral static-range progress sample merging,
  freshness, and display-byte selection, keeping durable checkpoint accounting separate from
  optimistic URLSession temp-byte UI overlays.
- **Done: Slice 5k terminal release policy extraction.**
  `DownloadTerminalReleasePolicy` now owns the persisted-row predicate for releasing app-level
  in-flight protection, including the retry-handoff failed-row sentinel that must not release early.
- **Done: Slice 5l expected bytes policy extraction.**
  `DownloadExpectedBytesPolicy` now owns expected-total selection for static range UI/ETA, preserving
  precedence across live Content-Length, progress-derived totals, static part size, and transcode
  estimates.
- **Done: Slice 5m Jellyfin keepalive policy extraction.**
  `JellyfinDownloadKeepalivePolicy` now owns the active-row predicate, required persisted
  PlaySession/MediaSource inputs, keepalive cadence, and progress-to-ticks calculation for Jellyfin
  transcoding downloads. The app layer still owns live session matching and request side effects.
- **Done: Slice 5t forward-only stall tracker extraction.**
  `DownloadForwardOnlyStallTracker` now owns the IO-free observation state for Jellyfin/Emby
  forward-only stream recovery: byte-progress timestamps, restart-attempt budgets, stale candidate
  pruning, and restart requests. `DownloadManager` keeps only the cancel/retry side effects.
- **Done: Slice 5n static retry target policy extraction.**
  `DownloadStaticRetryTargetPolicy` now owns source-part matching for static byte-range retries
  after metadata refresh, preserving true-original versus server-prepared/existing-version routing.
- **Done: Slice 5o storage estimate policy extraction.**
  `DownloadStorageEstimatePolicy` now owns source-sized vs bitrate-derived media estimates,
  backend sidecar estimates, per-chapter image estimates, and total-byte combination for storage
  preflight.
- **Done: Slice 7d side-asset selection policy extraction.**
  `DownloadSideAssetPolicy` now owns offline poster preference, Plex BIF source-part selection,
  synthetic Jellyfin/Emby chapter-image key parsing, and chapter-image fanout throttling decisions.
- **Done: Slice 7e download job snapshot extraction.**
  `DownloadJobPhase` and `DownloadJobSnapshot` now provide a shared PMSKit vocabulary for durable
  row status plus metadata-derived backend/lane/resume facts. Row captions and health diagnostics
  can now count/classify jobs through the same explicit phase model.
- **Done: Slice 5p shared download choice model extraction.**
  `DownloadIntentChoice` now lives in PMSKit with `DownloadChoicePolicy` owning diagnostic labels,
  persisted lane mapping, and server-prepared-version flagging. `DownloadManager.DownloadChoice`
  remains as a compatibility alias for app call sites.
- **Done: Slice 5q offline metadata builder extraction.**
  `DownloadOfflineMetadataBuilder` now owns the pure durable metadata snapshot for new download
  rows: copied item fields, source part id/size, per-job backend session identity, lane fallback,
  resume mode, and server-prepared display flag.
- **Done: Slice 5r preset/profile policy extraction.**
  `DownloadPresetPolicy` now owns the shared download quality catalog and pure mapping semantics:
  Original-quality aliases, custom bitrate ladder settings, visible picker filtering, offline row
  resolution labels, storage-estimate source sizing, Jellyfin transcode caps, compatible-remux size
  estimates, and Plex fallback tag/settings.
- **Done: Slice 4d Jellyfin transcode request de-duplication.**
  Jellyfin bitrate-transcode downloads now reuse PMSKit's tested
  `JellyfinLibrary.transcodedDownloadRequest` builder for the server-minted PlaybackInfo
  PlaySession path instead of carrying an app-layer duplicate URL/header builder.
- **Done: Slice 5s backend retry intent extraction.**
  `DownloadBackendRetryIntentPolicy` now owns the pure metadata-to-retry-intent mapping for
  Jellyfin and Emby failed/paused rows: compatible-remux intent preservation, Jellyfin default
  preset fallback for Original-quality labels, Emby server-prepared existing-version retries,
  source override propagation, and media/part index rehydration.
- **Done: Slice 4e Plex original-validation fallback policy.**
  `PlexOriginalFallbackPolicy` now owns the pure guard for retrying a failed true-original Plex
  validation as a compatible server-prepared copy, including backend ownership, transcode-loop
  suppression, server-prep ownership, Plex session availability, and fallback target selection.
- **Done: Slice 4f Jellyfin source-plan extraction.**
  `JellyfinDownloadSourcePlan` now owns the pure post-PlaybackInfo transfer semantics for
  Jellyfin: static original source sizing, bitrate-transcode expected bytes, compatible-remux
  source-sized plans, compatible fallback-to-transcode lane restamping, negotiated MediaSource and
  PlaySession propagation, and byte-range-vs-forward-only route selection.
- **Done: Slice 4g Emby route-action plan extraction.**
  `EmbyDownloadRoutePlan` now owns the pure post-router action table for Emby downloads: start
  transfer, reroute live transcodes into persistent Convert jobs, fail static-only rows closed when
  they negotiate a forward-only stream, choose server-session/range-checkpoint semantics, and keep
  route-specific diagnostic choice labels stable.

## Target module boundaries

### PMSKit pure download core

- `DownloadRecordIdentity`: backend-aware record keys and item-id extraction.
- `DownloadIntentChoice` / `DownloadChoicePolicy`: shared user-intent model plus pure persistence and
  diagnostic mapping for choices.
- `DownloadOfflineMetadataBuilder`: pure durable row-metadata snapshot builder for enqueue paths.
- `DownloadPresetPolicy`: shared preset/profile catalog and pure mapping for picker labels,
  backend transcode caps, storage estimates, display labels, and Plex fallback settings.
- `DownloadStartSlotPolicy`: app-level in-flight admission/recovery decision table.
- `DownloadPausePolicy`: pure row/queue-pause routing decisions before app-side store/session
  effects.
- `DownloadDeletePolicy`: pure delete-time backend cleanup decision table for Emby convert jobs.
- `DownloadRetryPreparationPolicy`: pure retry-entry gates before backend-specific retry dispatch.
- `DownloadBackendRetryIntentPolicy`: pure backend metadata-to-choice retry rehydration for
  Jellyfin and Emby rows.
- `DownloadEncoderTeardownPolicy`: pure terminal encoder teardown/skip decision table for
  Jellyfin and Emby play sessions.
- `DownloadResumeRetrySchedulePolicy`: pure cold-launch retry cadence and queue-paused resume
  scanner routing.
- `DownloadWatchdogPolicy`: pure refresh-watchdog predicate and cadence for server-prep/forward-only
  rows.
- `DownloadHealthSnapshotPolicy`: pure health diagnostic counts, throttling, and field derivation.
- `DownloadLiveRangeProgressPolicy`: pure merge/freshness/display policy for ephemeral static-range
  progress overlays.
- `DownloadTerminalReleasePolicy`: pure terminal-row release predicate for active slots/pollers.
- `DownloadExpectedBytesPolicy`: pure expected-total byte selection for range progress and ETA.
- `JellyfinDownloadKeepalivePolicy`: pure Jellyfin transcoding keepalive candidate/cadence/tick
  decisions.
- `DownloadForwardOnlyStallTracker`: IO-free forward-only stream progress observation and bounded
  auto-restart tracking for Jellyfin/Emby live downloads.
- `DownloadStaticRetryTargetPolicy`: pure static retry source-part and original/existing-version
  target selection.
- `DownloadStorageEstimatePolicy`: pure storage preflight estimates for media bytes and sidecars.
- Backend route planners:
  - Plex original/existing/optimize intent helpers where decisions are pure.
  - Plex original-validation fallback guards.
  - Jellyfin original/live-forward intent helpers, source plans, and tested stream request builders.
  - Emby route planner and post-route action policy.
- `DownloadJobPhase` / `DownloadJobSnapshot`: pure model for persisted row state, metadata-derived
  backend/lane/resume facts, and shared app-observed phase labels.
- Retry/recovery policy units for static-range, server-prep, and forward-only lanes.
- Existing pure units remain here: `RangeChunkPlanner`, `RangeTransferHTTPPolicy`,
  `DownloadSideAssetPolicy`,
  `BackgroundDownloadCompletionGate`, `StaticRangeTaskSelectionPolicy`,
  `StaticRangeRetryBudget`, `StaticRangeFinishedChunkPolicy`,
  `StaticRangeSegmentStrategyPolicy`, `StaticRangeReattachPolicy`,
  `BackgroundDownloadTaskIdentity`,
  `BackgroundDownloadProgressPolicy`,
  `BackgroundDownloadTransientRetryPolicy`,
  `BackgroundDownloadPauseCancellationPolicy`,
  `BackgroundTempFileCleanupPolicy`,
  `BackgroundFinalizationResultPolicy`,
  `BackgroundOpaqueCompletionPolicy`,
  `BackgroundRangeCompletionPolicy`,
  `StaticRangeContinuationPolicy`,
  `ServerPrepRefreshPolicy`,
  `StaticRangeRefreshCleanupPolicy`,
  `DownloadCompletionValidation`, `DownloadRateEstimator`, aggregate stats, file inventory,
  text subtitle parsing.

### VisionPlay Downloads app layer

- `DownloadManager` becomes the coordinator: owns the user-facing observable snapshot,
  queue pause state, and delegates to narrower services.
- Backend files remain separate, but each moves toward returning a concrete
  `DownloadSourcePlan` / `ServerPrepPlan` instead of directly mutating every cross-cutting
  structure.
- `DownloadStore` owns durable index/file-side effects only; it should not encode backend
  routing policy.
- `BackgroundDownloadSession` becomes the transfer engine. It can still hide URLSession
  details, but range task adoption, checkpoint append, completion validation, and retry
  signaling should be split into smaller collaborators once their contracts are pinned.
- Side-cache code remains a service with backend-specific request builders and a shared
  atomic write/persist tail.

## Behavior probes

- Static Plex byte-range recovery in the simulator: sign in to Plex in the worktree
  simulator, then run `VISIONPLAY_PROBE_QUERY='<title or Show S01E02>'
  scripts/probe-plex-range-drop.sh` (or set `VISIONPLAY_PROBE_RATING_KEY`). The script
  builds and launches the DEBUG app with `--vp-probe-range-drop-after-bytes`, captures
  `DownloadProbe`/`Downloads` logs under `build/probes/plex-range-drop/`, and refuses to
  run without an explicit media selector. Add `--pause-resume` when specifically checking
  manual pause/resume on the same static lane. Add `--existing-version --media-index N`
  to use a known playable/pre-optimized Plex version for quick static-range validation.
- Current signed-in simulator evidence (2026-06-30, worktree sim only):
  - Plex `Flight` existing-version media index 1 (`mp4`) started a static range transfer,
    injected `NSURLErrorNetworkConnectionLost` at ~1 MB, retried once from durable checkpoint
    0, and resumed range progress through tens of MB before cleanup.
  - Jellyfin `Flight` original/static lane started, transitioned queued -> downloading, and
    reported bounded range progress before cleanup.
  - Emby `Flight` original dry-run correctly negotiated transcode for the MKV source; the
    optimize lane reused an existing converted MP4, handed off to the static range lane, and
    reported bounded range progress before cleanup.
- Live request-shape probes remain in `scripts/live-*.sh` and require gitignored
  `scripts/*-live.env` files. They validate server API behavior but do not prove
  headset/off-head background transfer behavior.

## Migration slices

### Slice 1: record identity leaf extraction

Move backend record-key construction and prefix parsing into PMSKit. This removes one of
`DownloadManager`'s lingering pure responsibilities and makes UI routing, retry routing,
offline playback, probes, and future planners share the same identity rules. This is the
first implemented slice on this branch.

### Slice 2: transfer-start plan object

Introduce an app-layer `DownloadTransferStartPlan` so Plex static, Plex optimize handoff,
Jellyfin, and Emby all enter `BackgroundDownloadSession` through the same diagnostic,
start-failure, transcode-sourced, play-session, and range-checkpoint contract. Keep the
backend files responsible for source resolution; only the cross-cutting transfer tail moves.

### Slice 3: explicit resume/recovery coordinator

Extract static-range recovery state from `DownloadManager` into a `DownloadRecoveryCoordinator`:
`pendingStaticRangeResumeKeys`, restart-counter preservation, finalization guards, manual
queue-paused resumes, and live-range overlays. Start with pure policy tests for “what should
resume/finalize/defer” before moving URLSession calls.

### Slice 4: backend source planners

For each backend, separate “resolve what to download” from “start the transfer”:

- Plex: original preflight / existing version / optimize handoff source plan.
- Jellyfin: static original vs live-forward transcode/remux source plan and keepalive needs.
- Emby: PlaybackInfo route plan, convert handoff, reusable converted source plan.

These planners can share typed outputs but should not collapse backend-specific polling,
cleanup, or server-prep semantics into one mega-engine.

### Slice 5: server-prep attempt model

Unify the attempt-identity surface for Plex optimize and Emby convert without forcing their
pollers together. The common part is attempt ownership, durable row phase, relaunch resume,
queue-pause behavior, and stale async suppression. The backend-specific part is job creation,
progress interpretation, cancellation, reuse, and handoff.

### Slice 6: transfer engine decomposition

Split `BackgroundDownloadSession` internally after the above contracts are stable:

- opaque URLSession task registry;
- static-range task registry/adoption;
- range HTTP parsing/policy (started with `RangeTransferHTTPPolicy`);
- range checkpoint append/finalize worker;
- static range continuation/retry/restart routing;
- background completion handler gate;
- final-file validation bridge.

This should be done only with focused tests/probes because this layer carries the off-head
reliability behavior.

### Slice 7: UI snapshot builder

Move remaining pure caption/progress/sort/snapshot derivation out of `DownloadManager` into
tested PMSKit/app-layer builders so `OfflineLibraryView` observes a stable value without the
coordinator owning every formatting decision.

## Non-goals

- Do not merge Plex/Jellyfin/Emby server-prep into one abstract class that hides real route
  differences.
- Do not change the persisted index format casually; add compatibility tests before schema
  changes.
- Do not make simulator behavior the source of truth for off-head/background behavior.
