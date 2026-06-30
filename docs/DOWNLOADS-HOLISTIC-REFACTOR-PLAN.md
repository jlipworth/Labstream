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
  `If-Range` validator selection, `Content-Range` start/total parsing, and request offset parsing.
  `BackgroundDownloadSession` still owns URLSession/temp-file side effects, but its parsing
  semantics are pinned in PMSKit.

## Target module boundaries

### PMSKit pure download core

- `DownloadRecordIdentity`: backend-aware record keys and item-id extraction.
- Backend route planners:
  - Plex original/existing/optimize intent helpers where decisions are pure.
  - Jellyfin original/live-forward intent helpers.
  - Emby route planner (already partly `EmbyDownloadRouter`).
- `DownloadJobPhase` / `DownloadJobSnapshot` pure model for persisted vs ephemeral state.
- Retry/recovery policy units for static-range, server-prep, and forward-only lanes.
- Existing pure units remain here: `RangeChunkPlanner`, `RangeTransferHTTPPolicy`,
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
