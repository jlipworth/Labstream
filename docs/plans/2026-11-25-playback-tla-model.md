# Playback and session-lifecycle formal models (TLA+)

**Status (2026-11-25):** design approved for phase 1 (#519). Nothing is modelled yet. Phase 2
(#521) and phase 3 (#522) are filed; the progress-reporting latch is #523.

**Scope:** model checking of the parts of Labstream outside downloads where independent
asynchronous events race: playback restart and cleanup first (#519), then SharePlay, then
audio and Now Playing ownership across music, video and sign-in. Specs live in `specs/<area>/`
beside `specs/downloads/`, use the same runner (`scripts/check-tla-specs.sh`) and drift guard
(`scripts/check-tla-drift.py`), and follow the conventions in `specs/README.md`.

## Why

The downloads model (#505) found dozens of real ordering defects in code that unit tests
considered correct. The goal here is the same: find serious bugs in the other race-prone
parts of the app. It is not to put the whole code base into TLA+.

Playback has already shipped two such bugs
([Emby reopen overlap](../evidence/audits/2026-10-04-emby-reopen-session-overlap.md),
[Jellyfin terminal cleanup](../evidence/audits/2026-09-17-jellyfin-terminal-cleanup.md)), and
its load-bearing rules exist only as prose in `docs/PLAYBACK-ARCHITECTURE.md`
("Seeking and restart budgets", "Restart and cleanup principles").

## Goals, non-goals, anti-goals

- **Scope of fixes:** phase work finds and files defects; it does not fix them. Each fix lands
  on its own branch with the cross-backend checks `CLAUDE.md` requires for playback changes.
- **Goal:** each model checks the current design, can see the historical bug it is meant to
  prevent (a `Faithful-*-off` config), and turns each real defect into a filed issue with a
  `Finding-*` config and, where the Swift allows, a `withKnownIssue` test that pins it.
- **Non-goal:** full coverage of `PlaybackController`, AVFoundation internals, codec, HDR or
  Dolby Vision decisions, or the server's encoder-process exit (an acknowledgement does not
  prove it).
- **Anti-goals:** a model that passes because its abstraction hides the race (every abstraction
  must be listed and justified, and every property must be shown to fail on a mutation); a
  finding reported without re-checking it in the Swift; specs that drift from the Swift with no
  guard.

## Approaches considered

- **A. One area at a time, playback first (chosen).** Build, run and triage one model before
  starting the next. Findings are confirmed while the context is fresh, as downloads did.
- **B. Three areas in parallel.** Faster, but three batches of unconfirmed findings land at
  once for review.
- **C. One combined session-lifecycle model.** Catches cross-area bugs (sign-out during
  playback) but is much harder to keep equal to the Swift. A small cross-area model can follow
  later if the separate models point at a seam.

## How the work is done

- **Spec authors are Fable 5.2 agents** (Claude Agent tool, `model: fable`), one per module,
  working in the `specs/playback-tla` worktree. Spec-authoring agents run TLC but do not run
  simulators.
- The lead agent re-checks every finding in the Swift and in TLC before an issue is filed, and
  an independent review agent reads each finished model against the Swift (round 2 in the
  downloads plan) before merge.
- Run one `scripts/check-tla-specs.sh` at a time in the worktree (shared `build/tla/` paths).
- Pinning tests that need an app simulator follow the simulator lease rules in `CLAUDE.md`.
  Prefer pure PMSKit policies or controller seams that `swift test` can reach.

## Phase 1: playback restart and cleanup (#519)

### Model boundary

Model `PlaybackController`'s MainActor steps as atomic actions with each `await` as a yield
point. Inside the boundary:

- the playback generation, item generation, `PlaybackSeekHold` generation and deadline, and the
  final-target rebuild generation;
- `playbackTask` slots: the current task and cancelled tasks still unwinding;
- `failureRetryTask`, `finalTargetSettleTask`, `pendingStopTasks`, deferred Jellyfin stops,
  detached Plex stops, and the reconnect, stall, preparation and Dolby Vision watchdogs as
  abstract timers;
- `SeekRestartBudget`, `FinalTargetRebuildPolicy`, `PlaybackRestartIntent` and its plan;
- the remote HLS proxy slot (`remoteHLSProxy`), proxy start/stop, and in-flight proxy request
  handlers;
- an abstract server per backend holding encoding sessions keyed by session id, with
  nondeterministic acknowledgement, latency, failure and session-id reuse;
- the Emby reopen transaction tail and `EmbyReopenStopBarrier`;
- user events (seek, quality or track change, Retry, Close), playback failure, and the
  player item attach, detach and fail.

Each backend's replacement order is its own module over the shared controller and server
vocabulary:

- **Plex:** stop the superseded transcode with a bounded wait, then restart under the reused
  session id.
- **Emby:** detach, await an acknowledged exact-session stop, then negotiate; an unconfirmed
  stop fails with `priorSessionStopUnconfirmed` and blocks the new encoder.
- **Jellyfin:** detach, replace, attach, then defer the prior stop, skipping it if the session
  id was reused.

The builder chooses the exact module split, constants and bounds.

### Properties

- **One encoder:** at most one server encoding session the client still owns per playback,
  except Jellyfin's documented replace-then-clean-up window; every session the client stops
  owning eventually receives a stop.
- **No orphans:** after Close, a surfaced failure or Retry, every negotiated session is
  attached or stopped, and a rejected consent-boundary session is never attached.
- **Proxy ownership:** at most one live proxy listener, and none after Close or a surfaced
  failure.
- **Stop never kills the successor:** a stop for a superseded session never ends the current
  session, including with reused session ids and late acknowledgements.
- **Generation fencing:** a stale seek completion never releases a newer seek hold; a stale
  replacement never attaches over a newer intent.
- **Bounded restarts:** an exhausted budget stops recovery and shows Retry; restarts with no
  user action (stall, startup deadline, adaptive bitrate) are bounded.
- **Pause intent:** a resume-seek completion resumes only if the item is still current and the
  user has not paused; Retry preserves pause intent.
- **Detach before stop:** on Close, the player item is detached before server stops go out.
- **Unreachable traps:** the `precondition`s in `EmbyReopenStopBarrier.begin` are unreachable.

### Faithfulness

- `Faithful-EmbyOverlap-off`: Emby negotiates before the prior stop is acknowledged (the
  2026-10-04 audit).
- `Faithful-JellyfinReusedIdStop-off`: the deferred Jellyfin prior stop runs without the
  reused-session-id skip (`94a9ca4e`), so it ends the replacement.
- `Faithful-DetachBeforeStop-off`: terminal stop sends server stops before detaching the item
  (the client ordering from #327).

The 2026-09-17 audit describes a server race with no client fix: Jellyfin recreates a job from
an HLS request it accepted before acknowledging the stop. The abstract server may do this. It
counts against the server, not the client: properties judge what the client sent and owns,
and the model records that such a job exists without failing on it.

### Decisions made while writing this up

- **"Receives a stop" means the client sends one.** Safety properties judge what the client
  sent and owns. Liveness configs assume weak fairness on request delivery and acknowledgement;
  a stop that fails or times out is allowed, and only a stop never sent is a violation.
- **Back-to-back controllers are in scope.** Close does not block UI teardown, so a closing
  controller can overlap the next playback against the same server. Phase 1 adds a deep-tier
  config with two controller instances sharing the abstract server.
- **Suspect 5 is in scope** as a small module for the proxy's per-request handler lifecycle
  (`LoopbackOrigin`, `MediaSessionProxy`, `UpstreamConnection`), with its own `\* MODELS:`
  lines.

### Suspects to check first

The pre-model survey (read-only, unconfirmed) named these; each becomes a `Finding-*` config if
the model reproduces it, or is recorded as refuted with the reason:

1. A new proxy is installed after `stop()` or `surfaceFailure` has already cleared the slot
   (`PlaybackController.swift`, the Plex and MediaBrowser proxy stand-up after
   `await oldProxy.stop`), leaking a loopback listener.
2. `stopPreviousTranscode` gives up after 2 s and the restart reuses the session id, so a late
   Plex stop can end the replacement (proxy review finding C, 2026-06-14).
3. The deferred Jellyfin stop is unfenced, not cancelled by `stop()` and not joined by
   `retry()`.
4. `stop()` does not join the cancelled `playbackTask`, so a start already in flight can reach
   the server after the stop; rejected MediaBrowser cleanup is not covered by
   `waitForPendingStopRequests`.
5. In-flight `LoopbackOrigin` handlers keep fetching upstream after the listener stops (proxy
   review finding D).

## Later phases

Each has its own issue and gets its own design section here before it starts; phase 2 starts
only after phase 1's findings are filed.

- **Phase 2: SharePlay (visionOS), #521.** `WatchTogetherCoordinator` session, epoch, route, attach
  and leave. Suspects: the player captures `playerLaunchEpoch` after launch, so a stale player
  can attach or the real one never does; a `leave()` during `activate()` makes the user's own
  share arrive as an incoming invite.
- **Phase 3: audio and Now Playing ownership with sign-in, #522.** Both `AudioSessionCoordinator`s,
  the lease stack, music's `suspendedForVideo` and pending queue intent, video stop and
  Picture in Picture, sign-out and backend switch. Suspects: unowned `setActive(false)` from
  either player; a queue fetch that lands after video starts plays music over it; overlapping
  backend switches clear `isSwitchingBackend` early; sign-out does not stop a running video.

## Outside TLA+

- `TimelineSendCoalescer.hasFinalStoppedTimeline` is a one-way latch on a per-controller
  timeline, so after a surfaced failure and Retry, or play-to-end followed by scrubbing back,
  no progress or final stop is reported. A unit test can reproduce it; tracked in #523 on its
  own branch.

## Left to the builder

Module split and names under `specs/playback/`, constants and bounds, which waits are modelled
as nondeterministic versus bounded, the default/deep tier split, and how findings map to
pinning tests.

## Verification gates for this plan

- `scripts/check-tla-specs.sh specs/playback` results match every config's `EXPECT:` header.
- `scripts/check-tla-drift.py` passes with `\* MODELS:` headers on the new modules.
- Hermetic PMSKit tests, and app tests for any pinned finding.
- Strict MkDocs build, `scripts/check-doc-links.py`, `scripts/check-docs-mermaid.py` and
  `scripts/ci-hygiene.sh` after doc changes.
