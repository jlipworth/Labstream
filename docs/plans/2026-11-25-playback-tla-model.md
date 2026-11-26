# Playback and session-lifecycle formal models (TLA+)

**Status (2026-11-26):** phase 1 (#519) is done; see [Phase 1 results](#phase-1-results-2026-11-26). Phase 2
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

- **Spec authors:** Fable 5.2 agents wrote base, restart, plex and emby; to conserve Fable
  usage the user moved jellyfin, proxy and every fix round to Opus agents (decided 2026-11-25).
  Each task was reviewed by a fresh Opus reviewer before the next started. Spec-authoring agents
  run TLC but do not run simulators.
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

## Phase 1 results (2026-11-26)

Phase 1 is done on `specs/playback-tla`: six modules under `specs/playback/` (base, restart,
plex, emby, jellyfin, proxy), two review rounds, the findings filed and pinned, and the four
error-recovery defects fixed on the same branch (decided by the user on 2026-11-25, after the
design's "find and file only" scope). The per-config results, traces and abstractions live in
each module's README; this section records the program-level outcome.

### How it was built and reviewed

- Each module was written by one agent and reviewed by a fresh Opus reviewer before the next
  dependent module started; every reviewer finding was fixed or ruled on.
- Round 2 (task 8): two independent Opus reviewers read all six models against the Swift. They
  found nine Important model problems (a cancelled reopen always receiving its answer; the
  generation bound disabling Close; restart-budget ghosts reset at the code's own reset points;
  Jellyfin's timed-out-stop gate blocking Retry forever; Plex modelling a URLSession timeout as a
  lost request; Emby's server-recreate switched off; Plex's consent boundary unmodelled; missing
  `\* MODELS:` lines) and coverage gaps. All were fixed and re-reviewed; the fixes surfaced
  #537 to #540.
- Faithfulness: `emby/Faithful-EmbyOverlap-off` reproduces the 2026-10-04 overlap and
  `jellyfin/Faithful-JellyfinReusedIdStop-off` the reused-id stop; every fixed finding keeps a
  `Faithful-*-off` config that still fails with its fix turned off.

### Findings

| Issue | Finding | Kind | Status |
| --- | --- | --- | --- |
| #524 | A restart can install a proxy after cleanup (leaked listener; orphaned playing proxy) | unconditional | open, pinned |
| #525 | Close does not join the cancelled start; a Plex transcode can start after the stop | unconditional | open, not pinnable hermetically |
| #526 | Retry stops responding after a quality change from the error overlay | unconditional | **fixed** |
| #527 | Plex: Close sends no stop after a restart from the error overlay | unconditional | **fixed** |
| #528 | A seek just before a restart's item loads is dropped | unconditional | open, pinned |
| #529 | Plex: a timed-out stop lets the replacement start beside the old transcode | unconditional (pile-up), conditional (kill) | open, pile-up pinned |
| #530 | A restart from the error overlay skips Retry's pending-stop join | unconditional | **fixed** |
| #531 | Jellyfin: a consent request marks a newer session stopped | unconditional | open, pinned |
| #532 | Jellyfin: two quick reopens leave three encoders | unconditional | open, pinned |
| #533 | Proxy handlers keep fetching after the proxy stops | unconditional | open, pinned |
| #534 | The proxy never invalidates its upstream URLSession | unconditional | open, pinned |
| #535 | A reopen while the consent choice shows leaves it undismissable | needs repro | open, pinned |
| #536 | Server behaviours that decide the conditional findings | checklist | open |
| #537 | A reopen cancelled after the server minted its session leaks it | conditional on PlaybackInfo starting an encoder | open |
| #538 | Unattended restarts reset the seek-rebuild budget | unconditional, low | open |
| #539 | Retry's stop join gave up at the request timeout | unconditional (Jellyfin), conditional (Plex) | **fixed** |
| #540 | Plex: the consent choice can show while the copy job runs | unconditional | open |

### The fixes (#526, #527, #530, #539)

- **#527:** `beginStreaming` re-arms the Plex final-stop latch for every new transcode.
- **#530:** a quality, audio or subtitle change from the error overlay joins the failed attempt's
  stop before minting a replacement.
- **#539:** on Plex the failed attempt's exact-session stop goes out on its own client bounded by
  `failedAttemptStopTimeout` (30 s); Jellyfin's acknowledged DELETE keeps its request timeout, and
  on both a timed-out or failed request is never counted as joined. A Retry or overlay restart
  that finds it unconfirmed re-sends it once on a 10 s bound and proceeds only on
  confirmation, otherwise LS-PB-008, and the next attempt re-sends again. The outcome is keyed on
  a failure epoch. A first draft made Retry permanently dead after LS-PB-008; review rejected it
  because a network blip fails the stop at once, and the Emby barrier already re-runs its stop.
- **#526:** the Retry task releases its slot on every uncancelled exit. After #530 no public-API
  route to the wedge remains, so its regression test uses a DEBUG-only seam
  (`advancePlaybackGenerationForTesting`).
- Residual (conditional, #536): a confirmed re-sent stop does not fence a stop the client already
  gave up on under a reused session id (`plex/Finding-RetryRestopDoesNotFence`,
  `jellyfin/Finding-RetryRestopDoesNotFence-ReusedId`).
- Residual (conditional, #536), found by the deep tier after the merges: with two controllers and
  a server that reuses an id once nothing runs under it, a failure stop that failed but was applied
  is re-sent by Retry for an already-ended job, the other playback can be given that id, and the
  re-send ends it (`jellyfin/Finding-RetryRestopKillsOtherPlayback`). `jellyfin/Deep-BackToBack`
  now sets this route aside (`CONSTRAINT NoRestop`).

### Verification

- TLC: every config in `specs/playback/` and `specs/downloads/`, default and deep tiers, on the
  final branch head (see the PR for the run summary); `scripts/check-tla-drift.py` clean.
- Swift: hermetic PMSKit tests; `LabstreamMacTests` 1037 tests and `LabstreamTests` on the iPhone
  simulator 1013 tests. The app targets record 8 known issues from 6 open controller pins (#524's
  pin wraps three expectations, one per proxy stand-up); the two proxy pins (#533, #534) run in
  PMSKit's `swift test`. That is 8 open pins in total; #525 is not pinned. visionOS, iPhone, tvOS and macOS
  builds with Xcode 27.2; an iPhone simulator install and launch smoke (sign-in screen).
- Not done here: live checks on Plex, Jellyfin and Emby (`TESTING-CHECKLIST.md`, "Error-overlay
  recovery"), the #536 server probes, a visionOS simulator smoke (no signed-in golden simulator
  recorded), and hardware.

## Phase 1 implementation plan

> **For agentic workers:** use superpowers:subagent-driven-development. Every spec-authoring
> task (1 to 6) is implemented by a **Fable 5.2** agent (Agent tool, `model: fable`); a fresh
> reviewer checks each task before the next dependent one starts. Steps use `- [ ]`.

**Goal:** TLA+ models of playback restart and cleanup that check the current design, see the
two historical bugs, and turn each of the five suspects into a filed finding or a recorded
refutation.

**Architecture:** a new area `specs/playback/` on the existing runner. `base/` holds the
shared vocabulary (abstract server, controller state and steps as operators); `restart/` is
the backend-agnostic controller core; `plex/`, `emby/` and `jellyfin/` each model one
replacement order over `base/`; `proxy/` models the PMSKit proxy's request handlers.

**Tech stack:** TLA+ with the tla2tools version pinned in `scripts/check-tla-specs.sh`, TLC,
Swift Testing `withKnownIssue` pins.

**Spec:** the sections above.

### Global constraints

- Layout, config kinds, `\* SPEC:` / `\* EXPECT:` / `\* TIER: deep` headers and naming follow
  `specs/README.md` exactly; `Liveness` configs never use `SYMMETRY`.
- Every model module carries `\* MODELS:` lines for each Swift file whose behaviour it
  encodes; `python3 scripts/check-tla-drift.py --list` must show them.
- Each fix or ordering under test is a `BOOLEAN` constant, `TRUE` = shipping behaviour, so
  `Faithful-*-off` and `Mutant-*` configs only flip constants.
- Every safety property has a `Mutant-*` config that violates it (anti-goal: a check that
  cannot fail).
- Default-tier configs finish in under 5 minutes each at `TLC_WORKERS=auto`; larger bounds go
  in `Deep-*` configs.
- Each module defines `Controllers` as a constant set; default configs use one controller,
  `Deep-BackToBack` configs two sharing the server.
- Phase 1 changes no production Swift behaviour. A test-only seam is allowed when a pin cannot
  otherwise reach the code; it must be internal and behaviour-preserving, and then the
  affected-target smoke from `CLAUDE.md` applies.
- Public repo: no hostnames, tokens, titles or local paths in specs, READMEs or issues.
- One `scripts/check-tla-specs.sh` run per module folder at a time; parallel tasks touch only
  their own folder. `specs/README.md` and canonical docs change only in task 9.

### Review focus

Conditions the design implies but no property names directly; each is pinned by a config in
the owning task:

1. A cancelled task that has already passed its last generation check keeps running to
   completion (task 2, `Current-CancelPastCheck`).
2. Old and new sessions share a session id (tasks 3 and 5, `Current-ReusedId`).
3. A stop acknowledgement arrives after the client's bounded wait gave up (tasks 3 and 4,
   `Current-LateAck`).
4. Close while a consent choice is showing (task 4, `Current-CloseAtConsent`).
5. Retry while the previous Retry's cleanup is still pending (task 2, `Current-RetryRetry`).

### Task 1: area base

**Files:** create `specs/playback/base/PlaybackBase.tla`, `PlaybackControllerOps.tla`,
`README.md`, `specs/playback/base/BaseSmoke-Current-Smoke.cfg` (with a tiny smoke spec module if
needed).

**Produces:** constants `Controllers`, `SessionIds`, `MaxGeneration`; the server record
`server[s]` with `state \in {"none","encoding","stopRequested","stopped"}`, `owner`, `gen`;
nondeterministic server actions `ServerAck(s)`, `ServerFail(s)`, `ServerDelay`,
`ServerRecreate(s)` (a job recreated from an already accepted request, flagged
`serverRecreated`); controller variables `gen[c]`, `itemGen[c]`, `item[c]`
(`"none"|"attached"|"detached"`), `task[c]` (current) and `unwinding[c]` (cancelled, still
running), `seekHold[c]`, `budget[c]`, `paused[c]`, `proxy[c]`, `pendingStops[c]`; helper
operators `Owned(c)`, `SentStop(c, s)`, and the shared property `OneEncoder` (at most one
client-owned encoding session per controller, with a `jellyfinWindow` exemption flag). Contract comment at the top, as in
`DownloadsBase.tla`, stating which state is in-memory and what each action abstracts.

- [ ] Write the modules and the smoke config (`EXPECT: pass`) that exercises every server
      action.
- [ ] Add a `BaseSmoke-Mutant-RecreateCountsAgainstClient.cfg` showing that judging
      `serverRecreated` jobs as client-owned violates `OneEncoder`; `EXPECT: violation OneEncoder`.
- [ ] Run `scripts/check-tla-specs.sh specs/playback/base`; every config matches its header.
- [ ] Commit.

### Task 2: controller core (`restart/`)

**Files:** `specs/playback/restart/PlaybackRestart.tla`, configs, `README.md` (model-to-Swift
table with `PlaybackController.swift` function names, bounds, properties, results, traces).

**MODELS:** `PlaybackController.swift`, `PlaybackRestartIntent.swift`,
`PlaybackPositionModels.swift`, `PMSKit/.../Transcode/SeekRestartBudget.swift`,
`PMSKit/.../Transcode/FinalTargetRebuildPolicy.swift`.

**Consumes:** task 1. **Produces:** properties `GenerationFencing`, `SeekHoldFencing`,
`BoundedRestarts` (temporal), `PauseIntent`, `DetachBeforeStop`, `ProxyOwnership`,
`NoOrphans`; actions `UserSeek`, `UserQuality`, `Retry`, `Close`, `Fail`, `StallWatchdog`,
`StartupDeadline`, `AbrSwitch`, `SeekComplete`, `ProxyStandUp` (split at the
`await oldProxy.stop` yield), with backend ordering abstracted to "stop then replace".

- [ ] `Current-Core.cfg`, `Current-CancelPastCheck.cfg`, `Current-RetryRetry.cfg`,
      `Liveness-Core.cfg` (`EXPECT: pass` unless a suspect reproduces).
- [ ] `Faithful-DetachBeforeStop-off.cfg`: `EXPECT: violation DetachBeforeStop`.
- [ ] One `Mutant-*` per remaining property.
- [ ] Suspect 1 (proxy installed after cleanup) and suspect 4 (`stop()` does not join the
      cancelled `playbackTask`; rejected MediaBrowser cleanup not joined): if reproduced,
      `Finding-ProxyAfterCleanup.cfg` / `Finding-StopNoJoin.cfg` with the violated property in
      `EXPECT:` and the shortest trace in the README; if refuted, the reason in the README.
- [ ] Run `scripts/check-tla-specs.sh specs/playback/restart`; all match.
- [ ] Commit.

### Tasks 3 to 5: backend replacement orders (parallel after task 2)

Each: `specs/playback/<backend>/Playback<Backend>.tla`, configs, `README.md`; extends task 1's
operators; checks task 1's `OneEncoder` and adds `StopNeverKillsSuccessor`; includes a
`Deep-BackToBack.cfg` (`TIER: deep`, two controllers).

- **Task 3, `plex/`.** MODELS `PlaybackController.swift` (`stopPreviousTranscode`,
  `sendTranscodeStop`, `startStreaming`). Configs `Current-InPlace`, `Current-ReusedId`,
  `Current-LateAck`, `Liveness-InPlace`, mutants. Suspect 2: `Finding-LateStopKillsReplacement`
  or refutation.
- **Task 4, `emby/`.** MODELS `PlaybackController.swift`, `EmbyReopenStopBarrier.swift`.
  Configs `Current-Reopen`, `Current-LateAck`, `Current-CloseAtConsent`, `Liveness-Reopen`;
  `Faithful-EmbyOverlap-off` (`EXPECT: violation OneEncoder`); invariant `BarrierPreconditions`
  for the two `precondition`s; consent-boundary rejection never attaches.
- **Task 5, `jellyfin/`.** MODELS `PlaybackController.swift`
  (`scheduleDeferredRemoteSessionStop`), `PMSKit/.../Jellyfin/JellyfinPlayback.swift`. Configs
  `Current-Reopen`, `Current-ReusedId`, `Liveness-Reopen`; `Faithful-JellyfinReusedIdStop-off`
  (`EXPECT: violation StopNeverKillsSuccessor`); `ServerRecreate` enabled and not judged against
  the client. Suspect 3: `Finding-DeferredStopUnfenced` or refutation.

For each: run `scripts/check-tla-specs.sh specs/playback/<backend>` and
`scripts/check-tla-specs.sh --deep specs/playback/<backend>/Deep-BackToBack.cfg`; commit.

### Task 6: proxy request handlers (`proxy/`, parallel with 3 to 5)

MODELS `PMSKit/.../MediaSession/MediaSessionProxy.swift`, `LoopbackOrigin.swift`,
`UpstreamConnection.swift`. Variables: listener state, in-flight handlers, upstream fetches,
rotate generation. Properties `NoFetchAfterStop`, `StaleStopIgnored`. Suspect 5:
`Finding-HandlerOutlivesListener` or refutation; a stop during `standUpLoopback`'s await is
modelled. Run the folder; commit.

### Task 7: triage and pins (lead)

- [ ] For each `Finding-*`, re-read the Swift path and confirm the trace is reachable; drop or
      fix the model if not.
- [ ] File one issue per confirmed finding, in the style of #472 to #504 (title names the
      user-visible effect and the finding id).
- [ ] Pin each confirmed finding with a `withKnownIssue` test naming the issue:
      `PMSKit/Tests/PMSKitTests/PlaybackFormalModelFindingsTests.swift` for PMSKit code,
      `LabstreamTests/PlaybackFormalModelFindingsTests.swift` for controller code. Run
      `swift test --package-path PMSKit --no-parallel --skip 'Live.*ProbeTests'`, and the
      `LabstreamMobile` `LabstreamTests` plan on this worktree's iPhone simulator under the
      lease rules if app tests were added.
- [ ] Commit.

### Task 8: independent review

- [ ] A fresh reviewer (not the authoring agents) reads every module against the Swift and
      reports abstractions that hide races, missing `MODELS:` lines and properties weaker than
      their prose.
- [ ] Re-check each claim in Swift and TLC; strengthen models; every strengthened check gets a
      `Mutant-*` that used to slip past. Record the round in this plan.
- [ ] Commit.

### Task 9: docs, results and PR

- [ ] `specs/README.md`: add `playback/` to the layout. `docs/PLAYBACK-ARCHITECTURE.md`: a short
      "Formal model (TLA+)" section linking `specs/playback/` and this plan.
- [ ] Record the full results table (each config, result, states, time) and findings here.
- [ ] Run `scripts/check-tla-specs.sh specs/playback`, `--deep` for the deep configs,
      `python3 scripts/check-tla-drift.py`, the strict MkDocs build, `uv run python
      scripts/check-doc-links.py --site-dir site`, `uv run python scripts/check-docs-mermaid.py`
      and `scripts/ci-hygiene.sh`.
- [ ] Push, open the PR with unresolved gates listed, inspect CI to completion. Do not merge
      without approval.
