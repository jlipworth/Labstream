# Code review — `codex/remediation-nondownloads` (Phases 1–2 of 5)

> **Resolution update (2026-07-12):** The findings below describe the reviewed snapshot at
> `ba583b9`. They were revalidated against `2aa19e9`, then remediated in the subsequent working
> tree. C1/C2, M1–M12, and the listed download/auth/player/tooling minors now have code and focused
> regression coverage. The Phase-1 acceptance text was corrected to reflect the approved pre-v4
> nonterminal reset policy. One conformance statement below was already stale when revalidated:
> exact-attempt finalizer registry integration landed in `813254f`. Physical-device force-quit /
> background-redelivery gates remain open and are not claimed complete by this update.

**Scope:** committed diff `main...HEAD` (40 commits, 104 files, +14,330/−2,172) in
`/path/to/user/labstream-worktrees/remediation-nondownloads`. Uncommitted working-tree
edits excluded per instruction.

**Method:** 50-agent workflow — 9 subsystem reviewers + 2 plan-conformance auditors
(Phases 1 and 2 verified against code, not journal claims), every finding independently
adversarially verified by an agent instructed to refute it by tracing the code.
**Result: 30 unique confirmed findings (2 critical, 9 major, 19 minor); 6 findings refuted
and dropped** — notably all three "committed tests don't compile / fail" claims were traced
to a stale mid-review snapshot; HEAD (`ba583b9`) has the fixes committed.

---

## Verdict: is this an improvement?

**Yes — the architecture is a genuine, verified improvement over main in every area**, and
several long-standing bugs on main are actually fixed:

- `RevisionedPersistenceWriter` correctly fixes main's real lost-update race in
  `DownloadStore.persist()` (older snapshot could win the atomic replace) — interleavings
  traced, no lost update/stale overwrite/deadlock found.
- Attempt-keyed ownership (typed `DownloadAttemptID`/`DownloadAttemptKey`, compare-and-swap
  seeding, compare-and-release trackers) closes the cross-attempt corruption class main had:
  a replacement download can no longer be mutated, failed, or have its file deleted by a
  prior attempt's stragglers.
- The `SystemMediaSessionCoordinator` lease stack fixes real defects on main (video
  unconditionally overwrote music's Now Playing card; command-center enabled bits leaked
  between owners). Every handoff permutation traced clean.
- Auth-attempt unification (six ad-hoc UUIDs → one `activeAuthAttempt`) with
  discover-then-commit eliminates main's mid-discovery partial writes. **Existing signed-in
  users are safe on upgrade** — no keychain key/format changes.
- Phase 2 is fully implemented and wired in (not just scaffolded): narrow store lookups
  replaced every single-key full scan, `BoundedAsyncMap` (cap 4) replaced the sequential
  latest-rail loop, PERF-01/BUILD cleanups verified at call sites. All 1,435 PMSKit tests
  pass at HEAD.

**The systematic weakness:** the new *fail-closed* philosophy was applied to paths main
deliberately kept *best-effort*, without fallbacks or escape hatches. Nearly every critical/
major finding is an instance of this one pattern — a persistence/journal failure or an
ownership guard turning a previously-degraded-but-working path into a silent no-op, a
permanent wedge, or destruction of state main preserved. The ownership model is sound; the
fixes are integration-level, not architectural.

---

## Critical findings

### C1. Startup-admission gate cancels healthy surviving background transfers
`Labstream/Downloads/BackgroundDownloadSession.swift:745` (also flagged independently by the
Phase-1 conformance auditor at :703)

Delegate callbacks that arrive **before startup admission opens** are treated as purged
zombies: the task is permanently rejected and cancelled, and `didFinishDownloadingTo`
**deletes the completed body** — for exactly the healthy current-attempt transfers the purge
policy is supposed to spare. Main adopted these. This is a regression in the branch's
headline scenario (transfer durability across relaunch), and it sits precisely in the
never-run force-quit/background-redelivery device gates Phase 1 lists as open.
**Fix direction:** defer or ignore pre-admission callbacks and re-deliver via reattach —
or open admission before reconnecting the session's event stream — never cancel.

### C2. Migration + reconcile can permanently block ALL downloads
`Labstream/Downloads/DownloadStore.swift:2153`

The v4 branch of `commitLegacyAttemptOwnershipMigration` classifies any ownerless
nonterminal row as `malformedV3Rows`, but the app's **own `reconcile()`** legitimately
produces exactly that state (ownerless terminal row demoted to `.failed`). Result: a
permanent, global downloads-blocked state on every subsequent launch with no in-app
recovery, where main degraded gracefully.

---

## Major findings

### Downloads engine

**M1. Fail-closed persistence guards wedge rows and skip error surfacing under ENOSPC**
`BackgroundDownloadSession.swift:5344` — when the checkpoint-reset persistence fails, the
disk-full completion branch silently returns without failing the row, tearing down the
train, or surfacing `.storageFull` — precisely the condition (disk full) under which that
write is most likely to fail.

**M2. Drain livelock on double persistence failure**
`BackgroundDownloadSession.swift:4042` — `drainHeldRangeSegments` can spin forever when a
held-segment append fails and the manifest-removal persistence also fails, because
`removeHeldRangeSegments` now returns before pruning the in-memory held map.

**M3. Truncation parking budget resets on every retry**
`BackgroundDownloadSession.swift:4954` — keying `truncationFailureCounts` by
`DownloadAttemptKey` resets the JF-F2 budget whenever a retry mints a new attempt,
contradicting the guard's own documented invariant that retries must keep counting.

**M4. `delete()` can silently become a permanent no-op again**
`DownloadManager.swift:2863` — for Jellyfin/Emby rows with cleanup authority, if the
cleanup-intent journal write fails (or the intent can't be built), delete silently does
nothing — reintroducing the exact bug main documents as fixed. Fix: fall back to in-memory
deferred intents when the journal write fails.

**M5. Side-asset work is cancelled on completion and pause**
`DownloadManager.swift:3859` + `DownloadManager+SideCache.swift:49` — poster, text
subtitles, Plex BIF, Jellyfin trickplay, and chapter-image tasks are registered as
attempt-cancellable work, and `releaseInFlight` cancels them on **every** terminal
transition — including `.complete`/`.unverified` and user pause. In-flight side assets are
killed and never re-fetched; main always let these run to completion. Fix: exclude
complete/pause from side-cache cancellation.

**M6. Completed-size integrity audit is dead code**
`DownloadManager.swift:3100` — `durableStaticRangeCheckpointSize(for:)` measures the
attempt **working** file, which is nil'd on terminal promotion, so
`demoteIncompleteCompletedStaticRows` never demotes truncated completed downloads.
(Related trap already in memory: gate byte-completeness on the static range, not
`sourcePartSize`.) Fix: audit the stable file for terminal rows.

**M7. One startup-recovery failure disables downloads for the whole session**
`DownloadManager.swift:359` — every entry point gates on `startupRecoveryState == .ready`,
the error text says "Retry recovery first," but `retryDownloadStartupRecovery()` has **zero
callers** and no UI surfaces the state. Only recovery is relaunch. Fix: wire the retry hook
and auto-retry transient failures.

**M8. Jellyfin container extension is now always "mp4"**
`DownloadManager+Jellyfin.swift:116` — the pre-transfer seed row (localURL `<key>.mp4`) is
what the existing-path lookup reads, defeating the documented container-preservation logic
and changing the server request URL.

**M9. No-blob retry/resume discards durable static partials**
`DownloadManager+Plex.swift:77` (all backends) — re-entering a download entry point (manual
Retry, or auto-resume of a static row without a usable resume blob) mints a new attempt,
which re-derives the attempt-scoped working file and silently discards the previous
attempt's durable partial. Multi-GB downloads restart from byte 0 where main resumed from
the partial's size — and a retained comment still promises the old behavior.

### Auth / Plex flow

**M10. Authorized PIN token discarded when discovery fails**
`AuthManager.swift:486` — `finishLogin` now throws away a successfully authorized Plex PIN
token if server discovery fails, instead of persisting it first as main did. The user
completed auth and ends up signed out.

**M11. Plex restore-failure Retry UI is unreachable**
`LoginView.swift:258` — because `restorePlexSession` no longer sets `appModel.token` before
discovery, the `.failed where appModel.token != nil` `PlexRestoreFailureView` branch can
never trigger; a transient restore failure presents as fully signed-out. (Same root cause
family as M10: fix by persisting/applying the account token before discovery.)

### Player

**M12. Reconnect watchdog silently disarms on every retry**
`PlaybackController.swift:3898` — `armReconnectWatchdog` captures `playbackGeneration` at
arm time, but the retry/reconnect lanes bump the generation twice (beginStreaming +1,
load +1) right after arming, so the 20s watchdog can never fire `surfaceReconnectTimeout`
for that lane. This is the one place the lifecycle-generation policy was blanket-applied to
a watchdog that was deliberately designed to span a recovery reload.

---

## Minor findings

**Downloads**
- `BackgroundDownloadSession.swift:5123` — failed validated-promotion (rename/persistence)
  leaves the row stuck at 100% ".downloading / Verifying…" with no error and no in-session retry.
- `DownloadStore.swift:868` — startup staging sweep can delete a just-admitted attempt's
  side-asset staging file whose write is in flight (only metadata-recorded paths count as referenced).
- `DownloadStore.swift:686` — `promoteValidatedAttempt` holds the store NSLock across a
  synchronous durability wait + rename, blocking every store reader app-wide (also a 1A
  plan-conformance deviation: "keep slow I/O outside NSLock").
- `DownloadManager+EmbyConvert.swift:182` (+347/368/424/753) — convert-lane persistence
  failures guard-return without failing the row or releasing the in-flight slot, leaving a
  `.preparing` row holding `activeJobs` with no poller (the sibling Plex optimize lane
  handles this correctly).
- `DownloadCleanupIntentJournal.swift:179` — one undecodable element permanently wedges the
  whole cleanup journal (load/add/remove all fail); no quarantine/repair path.

**Auth**
- `AuthManager.swift:153` — `restoreSession()` calls `cancelPendingLogin()`, so a
  background-triggered restore (`SystemEntryRouter.ensureBrowseReady`) can silently kill an
  in-progress PIN / Quick Connect / Emby Connect poll while the UI keeps showing the code.
  (Flagged independently by two reviewers.)
- `LoginView.swift:380` — a cancelled `selectEmbyConnectServer` task returns early without
  resetting `selectingEmbyConnectServerID`/`working`, which can permanently disable the Emby
  Connect server picker including its Cancel button.
- `AppServices.swift:18` — `make()` returning nil on any clientIdentifier keychain failure
  turns a previously degraded-but-functional launch into a dead app shell; background
  URLSession relaunch completion handlers are then never drained.
- `AuthManager.swift:212` — Plex restore now requires a successful keychain **write**
  (rewrites synced token + server ID every restore); a transient write failure turns a good
  restore into a signed-out-looking launch.
- `AuthManager.swift:1307` — `refreshServers`/`discoverPlexSession` no longer clears the
  stale Plex runtime selection when no server is reachable, reversing main's documented
  "isBrowseReady honestly reports not-ready" behavior for Settings re-discover.

**Player / media session**
- `VideoNowPlayingCore.swift:124` — a fetched poster is discarded (never cached into
  `artworkImage`) if the video lease is momentarily not current at completion; Now Playing
  card permanently lacks artwork for the session.
- `MusicPlayerController.swift:817` — `pauseForVideo()` bumps the music lifecycle
  generation, invalidating the in-flight artwork fetch; art is never refetched on reclaim.
- `AudioSessionCoordinator.swift:183` — interruption auto-resume is lost if a player-item
  reload happens during an active interruption (`removeObservers()` clears
  `wasPlayingBeforeInterruption` and `load()` reinstalls observers on every item swap).

**Tests / tooling / plan**
- `VideoPlaybackLifecycleTests.swift:12` (cluster) — the player-lifecycle-generation tests
  are tautological: they drive one-line equality guards with test-local closures and never
  exercise the PlaybackController/MusicPlayerController wiring, so reintroducing the stale-
  callback bug class they're named for would not fail them. (Everything else in the new test
  suites is strong — real objects, fault injection, exact ownership semantics.)
- `scripts/compile-audit.py:22` — `TYPECHECK_RE` only matches "function"/"expression"; Swift
  prints "instance method"/"getter"/"initializer"/"closure took Nms" etc., so most real slow-
  type-check warnings are excluded from the tool's headline metric.
- Plan doc `:1057` — Phase 1 acceptance "existing partial/completed downloads survive
  migration and background tasks reattach" **cannot hold**: the implemented v4 policy
  deliberately cancels every pre-v4 nonterminal task and deletes its partials. If the
  discard policy is the approved decision, the acceptance text should be amended.

---

## Plan conformance summary

**Phase 1:** 1D (auth), 1E (media-session lease), 1F (lifecycle generations) genuinely
complete with real tests. 1A partial exactly as journaled (revisioned writer + flush barrier
done; transactional held-body deletion and bounded end-to-end mutation path open by
documented decision). 1B/1C substantially implemented but open at session-finalizer registry
integration and — critically — the never-run force-quit/background-redelivery device gates,
which is exactly where C1 lives. Acceptance text conflicts with the v4 discard policy (see
minor findings).

**Phase 2:** all four subtasks (2A–2D) fully implemented **and wired in** — verified at call
sites, not just that helpers exist. Narrow lookups replaced every single-key store scan;
BoundedAsyncMap cap 4 within spec with order-preserving fold; PERF-01 body-read removal
confirmed; 2D decode/view splits behavior-neutral. Clear net win.

---

## Refuted findings (for the record)

Six findings were killed by adversarial verification — worth knowing what did *not* survive:
- "Reattach/pause do synchronous persistence waits on URLSession queues" — true, but main
  did the identical blocking on the same queues; not a regression.
- "`createAttemptOwnedRecord` can't replace ownerless rows" — mechanically true but
  unreachable: migration stamps every path that could reach it.
- "Legacy encoder teardown permanently skipped" — the launch sweep migrates legacy rows.
- Three test-suite compile/runtime failures — all against a stale mid-review snapshot;
  fixed at committed HEAD `ba583b9`.

---

## Suggested triage order

1. **C1 + C2 before anything ships** — both destroy or block user downloads at relaunch,
   the branch's core promise.
2. The fail-closed cluster as one theme: M1/M2/M4/M7 (+ EmbyConvert minor) all want the same
   pattern — a persistence/journal failure must still surface an error, release slots, and
   keep in-memory truth, with a deferred/retry path.
3. The continuity regressions: M5 (side assets), M6 (dead audit), M8 (Jellyfin container),
   M9 (partials discarded on retry) — old cross-attempt continuity behaviors were
   load-bearing and need carrying over into the attempt model.
4. Auth Plex-flow pair M10/M11 (one fix: persist/apply token before discovery), then M12.
5. Minors opportunistically; amend the Phase-1 acceptance text.
