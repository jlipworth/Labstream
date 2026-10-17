# Downloads manager overhaul

**Status:** design checkpoint, revision 2. This revision takes in an independent second review
(GPT-6-Astra). Apart from one opt-in live probe, no code has changed yet.

**Branch:** `downloads/manager-overhaul`, rebased on `main` at b63d1757 (includes #363).

**Scope:** `Labstream/Capabilities/Downloads/`, the related PMSKit `Downloads/` policies, and the offline
player entry points. visionOS, iOS/iPadOS and macOS share the engine; tvOS must keep compiling
without it.

## Maintainer decisions (2026-10-16)

| # | Decision |
|---|---|
| Scope | Holistic and bottom-up, not prioritized by platform. One design checkpoint, then one PR per phase. |
| D1 | v5 keeps `complete` and `unverified` downloads. It journals row-owned server obligations and resets in-flight work. A full destructive reset is acceptable only as the fallback. |
| D2 | Deleting a paused or in-prep row cancels its server job: on Plex, and on Emby where the server supports it. Completed server versions stay on the server, and the UI says so. |
| D3 | The Jellyfin Ping-only keepalive is decided by a live A/B test that Claude runs headlessly. The probe is `PMSKit/Tests/PMSKitTests/LiveJellyfinDownloadKeepaliveProbeTests.swift`: opt-in, Quick Connect auth, and it never mutates watch state. |
| D4 | These are out of scope and get separate issues: offline progress and watched-state sync-back, offline Up Next, season grouping in the Offline list, and Emby Premiere detection. |
| D5 | The cellular toggle also governs constrained (Low Data Mode) and expensive (personal hotspot) networks. |
| D6 | The media title in a code comment is removed from the tree in P1. Public history is not rewritten, because the risk is low and a rewrite would break clones and worktrees. |

## Why another pass, and why not a rewrite

The module is about 29k lines of app Swift. Three files hold 17.7k of them:

| File | Lines |
|---|---|
| `BackgroundDownloadSession` | 7.0k |
| `DownloadStore` | 5.4k |
| `DownloadManager` | 5.3k |

There are also 109 PMSKit policy files. `DownloadManager.swift` has 295 commits, and the engine has
been rewritten three to four times.

The bugs are a mix of two kinds. Appendix A records the classification for every bug that was
traced.

- **Regressions, where a later change broke working handling:**
  - B00 (`a96db730`): transport moved to staging files, and the stale-row detector kept reading
    the published path.
  - B44 (`651e7929`): the launch cleanup sweep began deleting Emby Convert jobs that failed rows
    deliberately keep.
  - B45 (`9f782b4e`): a tier gate was added with the wrong source id.
  - B16 (`6eb1042c`): a whole-store rejection replaced partial salvage.
  - B54 (`a96db730`): truncated parking was left in staging when promotion moved.
- **Never handled, where the original change was incomplete:** B01, B10, B24, B54 (relaunch
  persistence), B55, B63, B73 and B74.
- **Dropped on purpose:** the launch-surge cap (`59c9c81a`, then `1535ce09`) and the graceful
  "finish the chunk, then pause" (`5cab1fa8`, an explicit decision, not an accident).

No headline bug turned out to rest on a wrong *earlier* diagnosis. Two of *our* findings were wrong
or overstated, and are corrected below:

- **B64 is misdiagnosed.** Pause with no live task does persist `.paused`; only a race remains.
- **B65 is overstated.**

The common root cause is still that the lifecycle is derived ad hoc, in more than ten places, from:

- `status`, byte and progress values, and `resumeMode`;
- optional server-job fields;
- the pending-admission flag;
- eight in-memory manager sets.

So this plan **does not propose a fourth rewrite**. It keeps the proven mechanisms and fixes how the
lifecycle is represented and changed.

## Method

A nine-agent archaeology workflow ran first. Eight area agents worked from the code, `git log
--follow`/`-S`/`-G`, and the PR and issue threads:

1. background session;
2. store;
3. storage and delete;
4. Plex;
5. Emby;
6. Jellyfin;
7. planner and row UX;
8. offline playback.

An adversarial skeptic then re-checked the high-severity claims and looked for gaps between areas.

**Second review.** An independent GPT-6-Astra pass then:

- traced the history of 13 headline bugs;
- spot-checked 13 more;
- sampled the edge-case inventory;
- critiqued the design.

**Results:**

- 329 edge cases, of which 299 must be preserved. 164 of the required cases cite no test.
- 86 bug rows: 81 from the first pass, B81 from the second review, and B82–B85 from the build-1506 field report.
- 63 confirmed bugs, 1 refuted (B29) and 1 misdiagnosed (B64).

The full result is kept outside git at `build/downloads-overhaul/archaeology.json`.

## What stays as it is (load-bearing, proven)

These mechanisms are kept. Their *behavioural* tests must stay green, but tests that exercise
obsolete seams may be ported.

- **Static segment train.** 512 MiB closed ranges, at most two per row, and the `lbs-segment:v3`
  exact-attempt markers. Stash, assemble and append alignment. Bodies held out of order, with their
  validators. Resume data only for the open-ended unknown-size fallback.
- **Background-completion gate.** Exact-token handler batches (SAFE-10) and activation-neutral
  registration. The persistence barrier before release is a **bounded** flush that records a
  committed, failed or timed-out outcome; it is not a guarantee of durability, and replay recovers
  the latter two. The rebuild-grace concept (#169/#212) stays.
- **Startup admission.** A dormant session until the index is admitted, current-owner-only purge,
  and the two-empty-pass drain before a destructive reset.
- **Finalization order:**
  1. write into the attempt staging file;
  2. rewrite `hev1` to `hvc1`;
  3. run the completion and probe validation;
  4. promote the validated file.

  `unverified` keeps playable bytes (#98). (Revision 1 wrongly said promotion came before the
  fixup.)
- **Platform specifics.** Per-bundle macOS session identifiers, and observing rather than deleting
  CFNetwork temp files.
- **Plex.** The `OptimizedVersionMatch` tier rule, and `X-Plex-Client-Profile-Name=Generic`, which
  is untouched by Downloads.
- **Emby.** Ping-only keepalive, and the Convert route and snapshot semantics (with the fixes below).
- **Offline launch.** The #259/#355 typed session-restore gate.

## Target design

### 1. Lifecycle state plus separate durable facts, changed only by one reducer

Revision 1 proposed a single `DownloadPhase` enum carrying all the data. The second review showed
that this would *lose* authority. For example, `paused(reason)` forgets whether it paused a planned
row, a static checkpoint, a forward-only stream or a row that owns a server job, and truncation
strikes on `unverified` cannot survive the failed attempt before it.

So in v5 each attempt record holds **separate, independently persisted facets**:

| Facet | Holds | Changes when |
|---|---|---|
| **Identity** (immutable per attempt) | backend, item, exact media source/version, requested profile, lane (`staticRange` / `serverPrepThenStatic` / `forwardOnly`) | never (a new attempt is minted instead) |
| **Artifacts** | staging body, published file, durable checkpoint, held bodies, resume blob, side assets, pending promotion and deletion intents | by lifecycle intents only |
| **Server obligations** | Jellyfin/Emby play session, Emby Convert job (`dispatchAmbiguous` or `owned(jobID)`), Plex optimize queue item | created at dispatch; retired only by a terminal cleanup intent |
| **History** | truncation strikes, storage-full park, last failure reason, retry intent | appended by the reducer |
| **Lifecycle** | `planned` → `admitted` → `serverPrep` → `transferring` → `finalizing` → `complete` / `unverified`, plus `paused` and `failed` (which carry no payload, because the other facets hold the facts) | by the reducer |

**One transition reducer** (pure, in PMSKit) is the only way to change lifecycle and history. It
takes `(record, event, attempt/generation)` and returns either `rejected(stale | illegal)` or a new
record plus an ordered list of effects. Effects are always persisted before they run, and every
effect is idempotent.

- **Events:** user pause, resume, retry and delete; admission granted; prep progress and ready;
  transfer started, progressed, completed and failed; finalize outcome; relaunch-reconcile
  observation; backend unavailable and available; storage measured.
- **Call sites switch on its result.** Pause, Resume All, retry, delete, the launch sweep, stale
  recovery, admission, captions and the stall watchdog all go through it. Exhaustive switches alone
  would not stop them from disagreeing about transitions; the reducer does.
- **Reconcile** becomes reducer events built from (record facets, live tasks, files, pending
  intents, admission state). It no longer deletes files directly under the lock.
- **`DownloadStatus` is derived** from lifecycle for UI and diagnostics compatibility.
- **`finalizing` covers both lanes** and is persisted. Relaunch then re-validates a complete
  forward-only body instead of deleting it (B10). Static finalization is covered too.

### 2. One admission coordinator, with explicit resource semantics

Every start goes through one lane-aware window: single-item taps, season rows, manual Resume and
Resume All, launch recovery, backend-ready drains and the server-prep scanner. The lanes are static
2, server-prep 1, live-forward 1, total 3, with a global cap on concurrent static trains, which
restores the dropped launch-surge protection.

**Permits:**

- **Admission grants one permit.** A server-prep permit converts to a transfer permit at handoff
  rather than being released and re-acquired.
- **`finalizing` holds no network permit** but counts toward the global verification limiter.
- **`paused` and `failed` release their permits.**

**Pause interactions:**

- **Global pause** blocks the coordinator.
- **Manual resume during global pause** is allowed for that row only, and is shown as such.
- **Rows paused while still planned** return to planned on resume, not straight to a start.

**Scheduling:** the coordinator is event-driven, replacing the 2 s poll, and counts in-flight starts
at admission (B72).

**Fixes:** B62, B63, the admitting key that #363 holds for hours, and the B64 race (behind a race
test written first).

### 3. One server-prep runner per backend, always a registered poller

Plex optimize and Emby Convert each become one routine: reconcile → adopt existing → create if
absent → poll → hand off. It runs as a registered poller task, never inline in the caller's `await`.

- **Each handoff URL** is minted from the live lane (B33).
- **Plex creates only after the adopt-existing check** (B35).
- **A silent create failure** is bounded by an "item never appeared" grace (B37).
- **One code path** replaces Emby's inline fresh chain, which was the root of #362.

### 4. Cleanup foundation: one durable journal for all three backends

One journal holds three operations:

- `activeEncoding` (Jellyfin and Emby encoders);
- `embyConvert(knownJob | ambiguousCreate)`;
- `plexOptimize(queueTitle)`.

The journal is written through the same durable committer as the index (temp write, full fsync,
rename, directory sync), in an authority directory with explicit protection and backup exclusion
(B18).

- **When intents are written.** Only for rows that were *deleted or abandoned*, including paused
  prep rows (D2). Never for failed rows that still own a resumable job (B44/B49).
- **Cancels.** Every server cancel is journaled first (B28/B50).
- **Deleted:** the legacy `EmbyConvertCleanupJournal` tombstone engine.
- **Ordering.** This lands **before** the v5 migration, which depends on it.

### 5. One storage-admission policy, with explicit accounting

- **Cap usage** counts each row's retained bytes once, plus the reserved remaining bytes of
  admitted rows (B24).
- **Free space required** is the remaining bytes, plus the append or copy peak (a stash body is
  copied onto the partial), plus held bodies not yet appended, plus the fixed headroom (B01).
- **Unknown size.** An unknown media size is **unknown**, never "extras only" (B81). Jellyfin gets
  `MediaSource.Size` from PlaybackInfo (B56). Unknown-size items need explicit confirmation and
  carry a conservative reservation.
- **One formula, every gate.** The same policy drives the sheet preview, the season aggregate, the
  cap check, the start preflight, the continuation preflight and the auto-resume park (B41).

### 6. Transport and store consolidation (behaviour-preserving)

**Session:**

- **One rebuild primitive.** A single attempt-keyed `requestRebuild(key, reason)` that the reducer
  refuses for paused or halted rows replaces nine hand-written sequences (B04, B12).
- **One gated retry.** One gate-holding `scheduleRangeRestart` with backoff replaces three
  `asyncAfter` copies (B04, B08).
- **Per-attempt state.** One `RangeAttemptState` struct replaces seven parallel dictionaries.
- **Owned-work snapshot.** One snapshot, which includes stashes whose append is still queued,
  drives both reattach adoption and the sweeps (B03, B22).
- **Dead code removed.** The opaque-lane resume-data path (the opaque lane is always forward-only)
  and DEBUG fault injection, which moves out of the 7k-line file.

**Store:**

- **Attempt-keyed APIs only.** Delete about 30 test-only and rating-key-only APIs, and port their
  tests to the production paths.
- **One `DurableFS` seam.**
- **Submit and resolve only**, with the synchronous main-thread wrappers removed.
- **Typed ticket outcomes** (B17).
- **One startup-inventory-gated orphan sweep** and one name grammar that also feeds the audit
  (B19, B20).
- **File split.** Split by ownership last.

**Blocked admission.** When admission is blocked, completed rows load **read-only** for offline
playback. Retry Recovery re-probes storage. The indeterminate-commit block gets its own reason
(B16, B21).

### 7. MediaBrowser, offline playback and row presentation

- **Shared negotiation.** One Jellyfin/Emby PlaybackInfo negotiation helper with currency and
  exact-source checks (B59).
- **One keepalive loop** with an `isTrackingTransfer` gate (B60); its request content is settled by
  D3.
- **One offline-playback launch factory** keyed by `DownloadAttemptKey`, used by both Detail and the
  Offline library:
  - the attempt-bound playhead sink applies on both surfaces (B73, B75);
  - a separate "playback observed" event is the only thing that promotes an `unverified` row, and
    never one parked for truncation (B74);
  - playhead writes are coalesced and non-blocking (B76);
  - the resume rewind applies;
  - the backend is resolved from metadata.
- **One row presentation** for the Offline list, the iOS/visionOS sheet and the macOS sheet, driven
  by lifecycle, with the missing accessibility labels added.

## Migration (v4 → v5): restartable steps

The v5 binary still parses v4, because v4 is today's schema. Each step is durable before the next
one starts, and the migration resumes from the last completed step after a crash or a full disk.

1. **Close admission.** The session stays dormant and no transfers start.
2. **Drain transport.** Cancel OS tasks with the existing two-empty-pass drain. Callbacks delivered
   after enumeration are rejected by the current-owner rule.
3. **Inventory.** Read every v4 row, its pending artifact intents (promotion and deletion), and the
   files on disk. Resolve pending promotions and deletions first, using the v4 rules.
4. **Preserve server obligations.** Write every row-owned obligation into the v5-format cleanup
   journal, which already exists from the cleanup-foundation phase:
   - Jellyfin/Emby `playSessionID`;
   - the Emby job or crash-window identity;
   - the Plex queue title.

   Each obligation is marked *abandoned by migration*.
5. **Commit v5.**
   - **`complete` rows** keep their published file, side-asset references, local playback position
     and exact ownership.
   - **`unverified` rows** do too, and also keep their reason. A v4 truncation park whose bytes
     never left staging is published in this step if its body is present. If the reason cannot be
     recovered, the row is kept as `unverified(reason: migrated_unknown)`. Its bytes are never
     discarded and no clean verification history is invented for it.
   - **In-flight, paused, failed and planned rows** are dropped.
6. **Reclaim.** Delete staging bodies, partials, held bodies and resume blobs that no v5 row
   references.

**Failure handling:**

- **Before step 5:** a journal or index failure leaves the v4 index authoritative and the store
  blocked with a typed migration reason.
- **Unparseable v4 index:** falls back to today's destructive reset.
- **Downgrade:** a v4 binary opening a v5 index sees an unsupported schema. It must quarantine
  rather than reset. This needs a v4-side check, which may require a final v4 point release, or the
  risk is documented.

## Pinned integration tests to add before structural phases

Policy tests alone missed the regressions above. These end-to-end boundaries are each pinned, with
behavioural assertions, **before** the phase that changes them:

1. staging → finalization → relaunch (B10, B54);
2. pause → delayed rebuild or auth callback → resume (B02, the gap 2 class);
3. failed Convert → launch cleanup sweep → retry (B44/B49);
4. atomic season commit → every resume entry point: manual, Resume All, launch, backend-ready, and
   the prep scanner (B62/B63);
5. journal/index crash boundaries, including a migration interrupted at each step;
6. playback from both launch surfaces (B73–B75);
7. protected data unavailable at launch, then unlocked.

`DownloadStorageEstimatePolicyTests.swift:45` currently pins a wrong contract (B81) and changes with
P5.

## Phases (one PR per phase)

Each phase has two hard rules:

- add the integration pins above, and pinning tests for any untested required Appendix B case it
  touches, before changing behaviour;
- run the full CLAUDE.md verification before the PR: hermetic PMSKit tests, `ci-hygiene.sh`,
  `native-test-matrix.py affected`, clean builds of visionOS, iOS, macOS and tvOS (tvOS without
  Downloads), app tests, and serialized simulator smokes.

Cross-backend live acceptance (Plex, Jellyfin and Emby) for shared behaviour stays an **open
maintainer gate**. It is never claimed as passed.

| Phase | PR | Content |
|---|---|---|
| **P1** | Small endpoint fixes and containment | Only fixes that the later structure keeps, plus minimal containment for actively destructive regressions. Includes the B44/B49 sweep exclusion, publishing the B54 parked body, and the B01 remaining-bytes preflight. Each comes with a regression test. Also scrubs the media title, and adds the D3 probe and its result. |
| **P2** | Cleanup foundation | Section 4. |
| **P3** | Facets, reducer and v5 migration | Sections 1 and the migration; read-only offline load when admission is blocked. |
| **P4** | Admission coordinator and server-prep runners | Sections 2 and 3. |
| **P5** | Transport and storage consolidation | Sections 5 and 6 (session). |
| **P6** | Store internals | Section 6 (store). |
| **P7** | MediaBrowser, offline playback and row UX | Section 7. Its last commit bumps the marketing version to **1.8.0** for every platform target (maintainer request, 2026-10-17), with the matching `docs/RELEASES.md` note. |

Bug counts and estimated line removal (roughly 5–8k net) are indicators, not acceptance criteria.
Acceptance is a phase's pins and inventory rows staying green.

## Progress journal

- **2026-10-17 — P6.4 delegate lane implemented** on `downloads/p6-wake-lane`. Pins 06–09 and
  the session half of Amendment 3 are green: the registry retains startup generations and receipt
  deadlines (including a no-registration fallback); every production hold captures an idempotent
  operation handle; one 25-second wake remains supervised through a covering persistence proof,
  with 20-second operation/grace watchdogs and up to five seconds for persistence. Normal release
  requires finish-events, settled required work and proof of its resulting boundary. Timeout claims
  exact tokens without cancelling physical workers, releasing their leases or discarding bodies,
  checkpoints or durable intents. Session submissions use deadline-aware async resolvers in both
  contexts; network resumes wait for committed prerequisites and recheck attempt/train/halt/retry
  authority on the range queue. Append reserves source/destination through handle closure and
  revalidates exact ownership and file identity. The existing wake/session tests now observe proof
  or timeout rather than assuming synchronous release. No store-contract delta or lead implementation
  edit; Retry/reconcile's lease participation and remaining store/manager pins stay with the lead.
  Validation: PMSKit 1,615 tests (one existing expected issue); hygiene 386 tooling tests plus strict
  documentation/link/Mermaid checks passed. Clean full Mac-host run: 897 test entries, zero
  unexpected failures, 15 lead-owned expected failures and two disabled manager tests; all 14
  dedicated wake functions and the session-only lease function pass. The Mac run disables parallel
  test execution to avoid the deliberately held workers starving unrelated callbacks. No simulator,
  push, PR or merge was performed; physical-device background acceptance remains open.

- **2026-10-16 — P1 implemented** on `downloads/manager-overhaul`. These were fixed with
  regression tests: B00 (plus a rebuild-grace ownership guard), B01, B02, B05, B07, B09, B11, B15,
  B25, B26, B34, B36, B38, B39, B42, B43, B44/B49 (containment), B45, B46, B47, B48, B52, B54
  (publication), B58, B59, B60, B68, B70, B71, B77 and D5.
  - **B53 is not a bug.** A retry without negotiated media cannot take the static route, so it
    fails closed; it is pinned by a router test.
  - **Still open from P1:** the B02 foreground-recovery capture race, B09 parking as Paused with
    no automatic resume, and a B54 park that a re-probe can still delete after relaunch (P3).
  - **Live A/B pending:** the Jellyfin keepalive reports a fixed position of 0 until D3 decides.
  - **Test fixtures:** PMSKit fixtures still use media-like titles outside Downloads; this is left
    to a separate hygiene pass.
- **2026-10-17 — P1 after-review (GPT-6.1-Sol, high).** It reported six findings, and all six were
  valid.
  - **B00:** ownership gaps at the tracking handoff. Fixed: a finish hold is taken under the
    extraction lock, and live plus pending ownership are read together.
  - **B09:** a park left sibling segments running. Fixed: the whole train parks.
  - **B07:** a failed activation aborted owned holds. Fixed: a live transport now releases wakes
    through finish-events.
  - **B39:** a job explicitly naming another item could still be attributed. Fixed: such jobs
    are never attributed.
  - **D3 probe:** it misclassified its own teardown. Fixed: the verdict comes from a snapshot
    taken before cleanup.
  - **Docs:** they overclaimed the keepalive interim. Reworded.
  - **Pins:** each lifecycle fix has a behavioural pin, and each pin fails with its fix removed.
  - **Deferred to P7:** the B70 test is still a source-text check. A behavioural test for a
    mounted sheet needs view-inspection infrastructure.

- **2026-10-17 — P2 implemented** on `downloads/p2-cleanup`, stacked on P1, in four commits that
  follow the reviewed order. Changes:
  - durable journal commits (B18);
  - Plex identity, provenance and the store disposition API;
  - one cleanup runner, with tombstone migration and the expiry cutover;
  - every remaining cancel journaled first (B28, B50, superseded encoders, the stale sweep),
    plus the D2 delete note.
  - Deviations from revision 3.1:
    - The foreground trigger was dropped. The runner's own timer resumes as soon as the app
      does, and the scene-phase plumbing lives outside the downloads module.
    - Executor coverage below the runner is policy-level: claims, eligibility and the Plex
      outcomes. No hermetic test drives the network executors end to end.
    - Plex states counted as cancellable are an explicit list. Any other state is retained.
  - A P1 test race was found and fixed (B00 pin outliving its URLSession) and carried to #371.
  - **After-review round 1** (GPT-6.1-Sol, high) returned "not ready" with nine findings. All
    were fixed and pinned:
    - Claims and eligibility are re-read after every awaited GET, immediately before the
      DELETE.
    - An intent's own attempt keeps its claim while its row is active, so a visible-but-failed
      abandonment write cannot cancel a resource the producer kept.
    - Claims are scoped to the persisted server and user.
    - Producer sessions never rebind captured work to another user.
    - Seed removal uses persisted authority and kicks after the commit.
    - The launch barriers re-run on every recovery pass, and an unreadable directory fails
      closed.
    - Every waiting intent keeps a 2-minute local recheck.
    - Session hydration covers backends that owe cleanup but have no intent journaled yet.
    - Only an unresolved Plex create can expire.
    - Launch-sweep journaling runs off the main actor.
  - **After-review round 2** returned "not ready" with five findings. All were fixed and pinned:
    - **Abandonment authority.** An abandonment runs only once its origin row no longer
      references the resource in persisted metadata. Producers clear their own reference only
      after the intent commits; encoder release now clears the persisted PlaySessionId this way.
      So a write that looked failed (the row kept, and later parked, its job) can never cancel
      the job. Row status was not proof of a handoff.
    - **Runner deadlines.** Consumed deadlines are pruned, so a failed load cannot spin on an
      expired one.
    - **Migration barriers.** They run before every runner pass and keep a wake while
      unfinished.
    - **Hydration.** It also counts legacy quarantine files.
  - **After-review round 3** found that an encoder abandonment could still be stranded when an
    interrupted handoff left the origin's persisted PlaySessionId in place. A forward-only
    encoder is never resumed, so for `activeEncoding` the origin claims only while its transfer
    is active. The executor's exact clear after the stop then replays the handoff. Convert and
    Plex keep the stricter reference rule.
  - **Remaining deviation:** one-off producers (delete, expiry, abandonments) still commit their
    single intent on the main actor, as before P2. Moving them off-main changes their ordering
    contracts and belongs with the store-internals work in P6.

- **2026-10-17 — P3a implemented** on `downloads/p3-lifecycle`, stacked on P2.
  - **Persisted lifecycle and history.** Rows carry an authoritative lifecycle and attempt
    history as additive v4 fields; `status` is derived from them. Rows written by older binaries
    are rebuilt structurally on load.
  - **One reducer.** Every production status change goes through `DownloadLifecycleReducer`: the
    session's ~40 writes, the manager's and extensions' writes, the store's own promotion and
    progress writes, and reconcile. Reconcile's file deletions now run outside the store lock.
    `ci-hygiene` rejects legacy status writes and direct row-status assignment.
  - **Bugs fixed:** B09, B10, B54 (cross-relaunch half), B16, B21 and B61.
  - **Conversion work.** The session and manager call sites were converted by two parallel
    agents. Their four reducer gaps were closed with reducer rules: `requeued`, Plex prep landing
    on `admitted`, planned rows retrying like failed ones, and a complete body re-entering
    finalizing.
  - **Season admission stays authoritative in the legacy flag.** A planned row leaves through
    Retry and stays visibly failed meanwhile. P4's admission coordinator owns `admissionGranted`.
  - **Deviations from revision 2.1:**
    - The pins that need the new store API landed with the commits that made them expressible,
      not up front.
    - Not yet written:
      - the B02 pause-during-rebuild pin;
      - the season commit → every resume entry point pin (B62/B63);
      - a P1/P2 re-encode pin with pending artifact effects.
    - Durable effects are executed by the existing call sites, chosen by the reducer, rather than
      through a new effect queue. Every effect maps onto an existing artifact recipe, or onto
      reconcile's post-lock deletions.
- **2026-10-17 — P3a after-review, round 1 (GPT-6.1-Sol, high): not ready, 8 findings.** All
  eight were valid. Each fix below has a pin, red-checked against the unfixed code where a pin
  can express it.
  - **Pause stranded a finalizing row.** The reducer kept it finalizing while the manager
    cancelled its finalizer. Pause now leaves a finalizing body and its finalizer alone.
  - **Reconcile could delete a static checkpoint.** A resume manifest masked the durable
    partial, and a manifest counted even when its blob was gone. The pre-P3a precedence is
    restored: the static partial comes first, and a blob counts only while it exists.
  - **Plex Retry lost truncation strikes.** That path removes the failed row before seeding its
    replacement, so there was nothing to inherit from. A non-user removal now hands its strikes
    to the replacement in memory, matching the pre-P3a session counter. Delete and cancel never
    carry strikes.
  - **A relaunch could count one truncated body twice.** The outcome ID now names the body
    (attempt and byte count) rather than the finalizer run. A working-body truncation goes
    through the reducer's `finalizeOutcome`, so the strike, the verdict and the lifecycle
    commit in one revision.
  - **Probe-miss and repeated-truncation publication skipped `unverifiedReason`.** Both now
    record it through `finalizeOutcome` before the promotion.
  - **B10 capture.** P3a.6 is implemented in a reduced form:
    - The attempt working path (`.attempt-stage-v1-<digest>.stage`) is attempt-unique and named
      by the row, so it serves as the capture path, and steps 1 and 3 collapse into one rename.
    - The parent directory is fsynced after the rename.
    - `bodyAtWorking` must be accepted, and in the foreground committed, before validation
      starts; a stale owner stops. While a background completion handler is pending, acceptance
      is admission-only, as for every other session write, and the completion gate owns the
      bounded outcome.
    - Not built: a separate capture file and the pins for a crash at each step.
  - **Reconcile deletions** now run only after the demotion commits. A failed index write keeps
    the bytes with the row. They are still not journaled artifact intents; that is P3b, with the
    v5 effect records.
  - **The hygiene guard matched nothing.** BSD `git grep -E` has no `\b`. The guard now uses an
    explicit identifier pattern and also rejects any lifecycle assignment that is not a reducer
    result. Whole-row replacement is not guarded.
  - **Still open:**
    - the session-level pin for the replayed-outcome path (pinned at the store/reducer level only);
    - the B02, B62/B63 and re-encode pins listed above;
    - B16 protected-data and concurrent-recovery coverage;
    - B21 with a real indeterminate candidate commit.
- **2026-10-17 — P3a after-review, round 2: not ready, 4 findings (all P2).** All four were valid.
  Round-1 responses 1 and 2 were confirmed.
  - **Truncation deletion without commit proof.** The working body is deleted only once the
    `finalizeOutcome` verdict has committed, using the same acceptance check as every other
    finalize write.
  - **Reconcile deletion race.** Moving deletion after the commit opened a window in which
    in-flight Range I/O could move the attempt on. Each deletion now records its owner and the
    condemned lifecycle. After the commit it runs under the store lock, only while the row is
    still that exact owner in that lifecycle with no artifact head.
  - **Relaunch replay erased `truncatedRepeated`.** `bodyAtWorking` on a row that is already
    finalizing keeps its history. A reducer pin covers re-entry, replay rejection and the
    promotion keeping the reason.
  - **Delete could stash strikes.** Only Retry's `submitRemoveForRetry` stashes them. Clearing
    the stash is fenced by attempt.
  - **Still open:** a deterministic pin for the reconcile race (closed in round 3), and the
    session-level crash/replay pin.
- **2026-10-17 — P3a after-review, round 3: not ready, 2 findings (P2).** Round-2 responses 3 and 4
  were confirmed by inspection.
  - **Reconcile could still delete newly written bytes.** Range I/O writes files outside the
    store lock, and progress keeps a failed row failed, so an owner-and-lifecycle check cannot
    see a write. Reconcile now records each condemned file's identity (inode, size,
    modification time) and deletes only a file that is unchanged. A file that is new, changed or
    gone is left for the row's Retry or Delete. This exposure predates P3a, since Range I/O never
    took the store lock. A deterministic pin writes through a DEBUG hook between the commit and
    the deletion.
  - **Background handler.** Under a pending background completion handler, a truncation verdict
    is only admitted. The working body is now deleted only when the verdict was resolved without
    a pending handler, which proves the commit. Otherwise the body is kept
    (`downloads.truncated_body_kept_unproven`) for the failed row's Retry or Delete, and a
    relaunch re-finalizes it if the verdict was lost.
- **2026-10-17 — P3a after-review, round 4: not ready, 2 findings (P2).** Both were in the round-3
  background-handler response, so that response was replaced rather than patched. The
  reconcile identity fence was confirmed.
  - **A handler snapshot is not commit evidence.** A handler could arrive between the snapshot
    and the resolution. The truncated body is now deleted by
    `DownloadStore.deleteCondemnedWorkingBody`, but only after the verdict's own persistence
    ticket commits, and only while the attempt still owns a failed row whose working path and
    file identity are unchanged. This holds whether or not a handler made acceptance
    admission-only. A failed or timed-out commit keeps the body
    (`downloads.truncated_body_kept`).
  - **A kept body could seed a Retry.** A truncation failure now records the distinct reason
    `truncated` instead of `validation`. Retry never clones such a body as a static checkpoint,
    so it downloads again from zero. The strike itself is still inherited. Pins cover a blocked
    commit (body kept, Retry starts at zero with no working file) and a committed verdict
    (exactly that body deleted; no ticket, no deletion).
- **2026-10-17 — P3a after-review, round 5: not ready, 2 findings (P2).** The verdict-ticket
  commit evidence was confirmed. Both findings came from keeping a condemned body at its working
  path, where its condemnation depended on mutable row state. That design was dropped.
  - **Condemn by rename.** A truncation verdict now takes the body off its working path at once:
    `condemnWorkingBody` atomically renames it to a fresh attempt-staging name that no row
    references. A later failure reason, a pause or a Retry therefore can never see it as a
    checkpoint, a recovery source or a clone source. The `.truncated` reason and the inheritance
    exclusion remain as a second guard.
  - **Prompt reclamation.** `deleteCondemnedBody` waits up to 30 s for the verdict's commit and
    then deletes the condemned file whatever the outcome, provided its identity is unchanged.
    The next launch's staging sweep is the backstop for a crash. An unproven commit is logged
    (`downloads.truncated_verdict_unproven`).
  - **Accepted cost:** a crash before any index commit can lose that one strike, as before P3a.
    The same bytes can never be counted twice.
  - **Pins:** a blocked commit followed by an overwriting `retryRejected` still leaves Retry at
    0 bytes with no working file while inheriting the strike, and the space is freed. A
    committed verdict deletes exactly the condemned body. A stale owner cannot condemn the path.
- **2026-10-17 — P3a after-review, round 6: not ready, 2 P2s and 1 P3.** Relaunch handling after
  a successful rename was confirmed. The fixes make the rename hygiene rather than the fence.
  - **Persisted condemnation fence.** `DownloadAttemptHistory.bodyCondemned` is set by the
    reducer in the same revision as a failing truncation verdict, whether through
    `finalizeOutcome` or `transferFailed(.truncated)`. Nothing within the attempt clears it, and
    a replacement attempt does not inherit it.
  - **What the fence blocks.** A Retry clone, a checkpoint fact, and `bodyAtWorking` re-entry
    into finalization. A later failure reason (for example `retryRejected`) cannot reopen the
    body.
  - **Rename before any wait.** The body is renamed as soon as the verdict applies in memory,
    before any persistence wait, so a failed or wedged foreground commit cannot leave it at the
    working path. Its deletion is scheduled at once.
  - **Rename failure** is logged (`downloads.condemn_rename_failed`) and falls back to deleting
    in place, as before P3a.
  - **Deletion** of the renamed file retries up to three times, then is logged
    (`downloads.condemned_body_delete_failed`).
  - **Pins:**
    - reducer: fence set, survives a reason overwrite, blocks re-entry, is not inherited, and
      the legacy path also condemns;
    - store: an unmoved condemned body is not a checkpoint and does not seed a Retry.
  - **Still open:** a session-level pin with a blocked writer (the sequencing is covered at the
    store and reducer levels).
- **2026-10-17 — P3a after-review, round 7: not ready, 2 P2s and 1 P3.** Round 6's ordering
  (rename before any wait) and its bounded deletion retries were confirmed. Both P2s required
  the rename and the in-place delete to fail together.
  - **Same-attempt readers bypassed the fence.** The fence now sits at the single choke point:
    `workingRelativePath(for:key:)` returns nil for a condemned row. Checkpoint sizing,
    checkpoint reset and write, durable-partial evidence, recovery finalization and validated
    promotion all go through it and see no body. Only condemnation itself uses the unchecked
    path. A condemned attempt's Retry ignores a surviving resume blob and takes the replacement
    path from zero.
  - **Rejected `bodyAtWorking` no longer continues.** Only a published body under revalidation
    may proceed without entering finalizing. Any other rejection stops before probing or
    publication (`downloads.finalize_refused`).
  - **The downgrade loss** of the fence is now stated next to the strike and reason loss.
- **2026-10-17 — P3a after-review, round 8: one blocking P2, two P3s.** No `serverPrep` or
  `planned` completion is stranded by the finalization refusal, and side-asset and deletion paths
  are unaffected.
  - **Deferred Retry lost its intent** (blocking; it needed no filesystem failure). A
    checkpoint reset on a condemned current owner now returns `condemned`, which resolves to
    `applied(bytes: 0)` after zeroing the row's progress. It never reads or rewrites the bytes.
    Offline Retry therefore keeps its restart-from-zero intent, and the backend-ready path
    starts a replacement.
  - **Layout API** (P3, done): `attemptWorkingFileLayout`/`attemptWorkingFileURL` now derive
    from the fenced path. The pin asserts that both return nil and that the checkpoint reset
    returns `applied(0)` without touching the bytes.
  - **Reclaiming a surviving condemned body on replacement** (P3, journaled for P3b). It occurs
    only after both the rename and the in-place delete failed. The next launch's staging sweep
    reclaims it, and P3b's journaled artifact effects own retired-body cleanup.
- **2026-10-17 — P3a after-review, round 9: one blocking P2.** The checkpoint reset kept the
  deferred intent, but the backend-ready handoff (`resumeStaticRangeWhenReady`) still read
  `durableStaticRangeCheckpointSize`, which returned nil for a condemned owner, so it gave up.
  That function now returns 0 for a condemned current owner, an empty usable checkpoint. Every
  caller treats 0 as "start fresh", so the replacement starts from zero. The layout change had no
  other blocking regression.
- **2026-10-17 — P3a after-review, round 10: ready.** The round-9 blocker is resolved. A review
  of every caller of the checkpoint size found no regression: integrity audits read the
  published body first, and stale-partial eligibility still needs the fenced working URL.
  - **Journaled, open:** a manager-level pin for condemned Retry while the backend is
    unavailable, then backend-ready, then a replacement that starts at byte zero.
  - **Verification on c6c87d79.** These passed:
    - Linux PMSKit, and the visionOS, iOS, tvOS and macOS builds;
    - iOS hosted (719);
    - the iOS UI smoke;
    - the visionOS smoke (alive, no faults, Plex browse UI).

    One run of the iOS hosted lane failed in
    `SideAssetFetchCoordinatorTests.testTaskCancellationWinsWhenSuccessfulCompletionRacesCancellation`.
    That test is unchanged from `main`, the overhaul does not touch the coordinator, and the test
    bounds its wait by 1,000 `Task.yield()` calls. Two immediate reruns of the lane passed, so it
    is recorded as a pre-existing timing flake.
- **2026-10-17 — P3b implemented** on `downloads/p3b-v5`, stacked on P3a. The plan reached
  revision 10 after eight before-review rounds (approved).
  - **Maintainer decision on D1:** keep partials. Complete, unverified and paused static-range
    rows survive the upgrade.
  - **Codec.** v4 and v5 both load. Each snapshot carries its version, so v4 stays v4 until the
    stamp. A fresh or reset index is v5.
  - **Delete fixes** (pre-existing bugs found by the review):
    - exact-attempt halt, including untracked OS tasks;
    - immediate release of prep pollers and keepalive;
    - a handoff result returned to the caller;
    - an optimize create that re-checks admission right before the server call;
    - a post-deletion progress clear that never touches a replacement.
  - **Work admission.** `attemptAdmitsWork` (no barrier, no capsule) gates the session's start,
    resume, finalize and revalidate entries; retry continuation; season admission; and optimize
    polling. Start chains use the phase-aware check.
  - **Upgrade pass.** It runs between activation and `.ready`. The candidate set is fixed when
    the pass starts and a candidate is rescued only by completion. Each candidate goes through
    Delete; the pass records a notice union, stamps v5, then publishes `.ready`.
  - **Deviation:** the notice persists in UserDefaults rather than in the authority directory.
    It is a UX record whose idempotence comes from attempt-ID sets.
  - **Open:**
    - a session-level test for `haltForDeletion` against real OS tasks;
    - tests for a deletion racing a suspended start, prep or optimize continuation (the guards
      are in place);
    - the paused-queue checkpoint-ordering test;
    - the P5 item for a paused-static body finishing before reattach;
    - live and physical acceptance.
- **2026-10-17 — P3b after-review, round 1: not ready, 4 P2s and 2 P3s.** All six were valid.
  - **Season transaction.** It now validates retry rows with the lock-held work-admission
    predicate, so a deleting row is never re-planned. The test (red-checked) shows the
    transaction stays atomic.
  - **Capsule halt.** `haltForPendingDeletion` takes the exact key and cancels marked OS tasks
    as well, keeping held artifacts. Callback admission and the activation purge use
    `attemptAdmitsWork`, so a capsule's surviving daemon tasks are rejected and cancelled.
  - **Full-key marker match.** Tasks are matched on rating key and attempt ID together. The test
    (red-checked) covers a legacy attempt ID shared across keys, for both marker formats.
  - **More tests:**
    - the candidate matrix: existing deletion, paused static kept, paused forward-only dropped
      (the legacy-promotion exclusion is code-reviewed, not tested);
    - a crash after committed barriers but before the stamp, which reclassifies only what
      remains;
    - a pre-P3a v4 row without lifecycle fields, classified structurally.
  - **Still not tested:** delayed v4 snapshots crossing the stamp (the version is captured
    structurally under the lock at enqueue); deletion racing a suspended start, prep or optimize
    step (guards in place); Retry Recovery during the pass (guarded by `startupRecoveryInFlight`);
    season A→B replacement. All are journaled.
  - **Notice.** It moved to `schema-upgrade-notice.json` in the authority directory, written by
    atomic replace with file and directory fsync before the stamp is enqueued. This replaces
    the UserDefaults deviation.
  - **Docs and comments** now say that a crash before the stamp leaves the latest committed v4
    state, and the next launch reclassifies what remains.
- **2026-10-17 — P3b after-review, round 2: ready with fixes (2 P3s).** It found no blocking
  transport or capsule-recovery regression.
  - **The stamp waits for a durable notice.** If the save fails, the index stays v4 and the next
    launch repeats the pass. The entries are parked in a UserDefaults fallback that the next
    load merges.
  - **Full attempt keys.** Notice entries now use the full attempt key, so two items sharing a
    legacy attempt ID count twice.
  - **Test:** a failed save, the fallback merge, and shared legacy IDs.
  - **Noted, still open:** the crash test does not suspend artifact execution at the barrier.
- **2026-10-17 — P4 plan co-review, round 1: rework (3 blockers, 13 majors).**
  - **Blockers:**
    - granting before `retry` broke the parked-only retry modes;
    - permit ownership across attempt replacement was unspecified;
    - a registered Emby chain would cancel itself at handoff.
  - **Majors:**
    - the relaunch barrier;
    - the season commit barrier and rollback;
    - deferral busy-loops and stranded rows;
    - lane changes before a create;
    - the queue-pause exemption and emby-33;
    - stale pause forwarding (pu-24);
    - legacy-flag precedence over paused rows;
    - `userRequested` breaking P3b decoding;
    - Plex `.preparing` ripple effects;
    - admission release vs resource teardown;
    - the typed queue lookup;
    - insufficient pins;
    - commit boundaries.
  - **Minor:** one code-map claim was wrong; handed-off Plex rows already count as static.
  - **Response, revision 2:**
    - occupancy is observed from persisted lifecycle, plus reservations keyed by rating key and
      generation (no permit table);
    - grants run the existing start path without `admissionGranted`;
    - typed start outcomes with backoff;
    - recovery and season barriers;
    - `mayEnter` before reroute creates;
    - a row-scoped pause exemption;
    - exact-attempt pause kept;
    - existing intents only;
    - Plex `serverPrep` dropped;
    - typed queue lookup and a separate persisted 3 min grace;
    - one non-cancelling Emby handoff with its own poller token;
    - 25 pins;
    - activation in a single commit.
  - **Shape:** P4 ships as one PR, per the maintainer's pace decision.
- **2026-10-17 — P4 plan co-review, round 2: approve with changes.**
  - **Resolved:** R1.3, 9, 10, 11, 12, 13, 17 and 18.
  - **Partially resolved, amended in revision 3:** supervision until start completion, retry
    routing from facts, durable waiting seeds, the reducer sources, orphan normalization, atomic
    lane switches and the pump wake, exemption threading, the Emby scanner set, the Emby handoff's
    task-map removal, the persisted dispatch grace, and the extra pins.
  - **No further plan round.** Implementation starts on revision 3, per the maintainer's pace
    decision.

- **2026-10-17 — P4 server-prep runners implemented** on `downloads/p4-runners`.
  Plex fresh/resume share adoption, typed queue inspection, durable dispatch grace and live-lane
  handoff; Emby fresh/relaunch use registered Convert pollers and one non-cancelling static
  handoff, with injectable HTTP/cadences. Runner pins 18–24 and relaunch-inside-grace were
  red-checked against the original runner bodies with transport, timing and task-inspection seams. Pin 25
  (Convert continues through Pause All and parks its static handoff) is retained and green.
  Pure policy tests also cover metadata-inspection gating, tier/playability/source exclusion,
  persisted grace and stale Emby poller removal. Admission wiring and live/device gates remain
  with their respective owners.
- **2026-10-17 — P4 implemented (admission half, lead).**
  - **Coordinator.** `DownloadAdmissionPolicy` (PMSKit) and `DownloadAdmissionCoordinator` plus
    `DownloadManager+Admission`. Occupancy is observed from lifecycle plus live work (slot, prep
    poller, session transfer); residue without live work frees its lane (amendment 5 met by the
    occupancy rule rather than a separate normalization pass). Starts are supervised by generation
    until their async work finishes (`retry(record:)` now returns its spawned Task), then
    classified: started, deferred with backoff, refused, or superseded.
  - **Paths.** Season rows and over-capacity taps are `planned` seeds that start through
    `startPlannedRecord`. Resume All, a capacity-delayed row Resume or Retry, static auto-resume
    and the stalled-stream restart wait as paused or failed rows with a `retryRequested` intent,
    so retry keeps routing from facts (amendment 2 met without reducer changes to retry).
  - **Pause.** A planned or task-less admitted row parks synchronously; Pause withdraws a waiting
    retry and keeps a first-start intent. Pause and delete end supervision.
  - **Flag.** The legacy flag is absorbed on load and on insert; season rollback restores intents
    conditionally.
  - **B69.** A failed probe plans the episode instead of failing it as unsupported.
  - **pu-33.** Waiting rows read "Waiting for a download slot…" or "Waiting — downloads paused".
  - **Pins (red by construction against the old code, not executed against it):** Resume All
    caps (B63), the scanner skips planned rows (B62), refresh outage defers (B67), a tap over
    capacity waits and starts, pause while waiting resumes to planned (B65), plus coordinator
    units (stale generation, invalidation, backoff, exemptions) and reducer/policy units. B64 and
    B72 are covered by the ported season integration tests.
  - **Not yet pinned:** the Pause All exemption end to end, a lane-full reroute, relaunch
    grandfathering over the caps, and a finalizing row freeing its lane (policy-level only).
- **2026-10-17 — P4 after-review, round 1: not ready (2 P1, 8 P2). All fixed:**
  1. **Paused forward-only rows.** A paused Jellyfin or Emby stream restarts fresh before
     dispatch. A granted start that leaves a user-paused row unchanged withdraws its request, so
     it is not re-granted.
  2. **Range rebuilds.** A row that already holds a lane continues under its own admission
     (`admissionHasRoom`).
  3. **Lane switches.** A supervised lane switch wins over row metadata until the route is
     stamped.
  4. **Taps.** A tap with an existing parked row waits through that row's retry; any other tap
     while lanes are full is refused visibly. A failed waiting-seed save shows an error and never
     starts directly.
  5. **Deferral writes.** Backoff is recorded even when the deferral write fails.
  6. **Pause All exemption.** Static admission honours the row exemption and the manual-resume
     marker; the pump's drain check is capacity-only.
  7. **Transient failures.** A start failing with `server` or `network` waits with backoff, up to
     6 deferrals; other failures stay definitive.
  8. **Emby scanner.** The crash-window scanner skips rows waiting for admission.
  9. **B69.** An unresolved Original-quality route is persisted (`admissionRouteUnresolved`) and
     re-planned at admission through the shared `SeasonDownloadOriginalQualityPolicy.resolve`,
     with a lane check.
  10. **Legacy flag.** Absorption ignores rows with start evidence (bytes, a resume blob, held
      bodies, a Plex queue item, an Emby job or identity, a server-prepared handoff).
  - **Pins:** the evidence fixture and the route-resolution policy. The others are code-reviewed
    only.
  - **Flaky test:** `BackgroundDownloadStartupAdmissionTests.unsupportedSchemaIsOpaqueUntilTaskDrainThenRootIsQuarantined`
    failed once and passed 3/3 reruns. It is pre-existing and P4 does not touch that code.
- **2026-10-17 — P4 after-review, round 2: ready with fixes (5 P2). All fixed; no further round,
  per the pace decision:**
  1. **Static drain.** It skips rows waiting for admission and honours deferral backoff. The pump
     wakes at the earliest backoff of any request, including a deferred static resume.
  2. **Exemption.** A row's Pause All exemption also marks the static manual-resume set
     (`markRowResumedDuringQueuePause`), so an exempt Convert handoff's later range rebuild is not
     parked.
  3. **B69 probe.** The re-plan is fenced by the supervision generation and an `admitted`
     lifecycle after the probe's await.
  4. **Late prep attach.** After startup recovery, the Plex and Emby prep scanners attach a row
     the coordinator never counted only with prep-lane room. Startup reattach is still
     grandfathered.
  5. **Missing items.** A refresh that proves the item gone (HTTP 404/410, no metadata item) fails
     the planned row as source-missing; other refresh errors defer.
  - **Pin:** missing-item classification. The others are code-reviewed only.
- **2026-10-17 — P5 plan co-review, round 1: rework (1 blocker, 14 majors, 1 minor).**
  - **Blocker:** the owned-work snapshot conflated retained files with live transport.
  - **Majors:**
    - sweep claim boundaries;
    - rebuild authorisation and generations;
    - the B08 reset watermark;
    - the admission continuation contract;
    - the free-space formula double-counting held bodies;
    - cap reservation atomicity;
    - unknown-size consent semantics;
    - blob resumes bypassing gates;
    - B06 and B13 release safety;
    - paused-body finalization;
    - B56 precedence;
    - the regression gate and integration ownership.
  - **Response, revision 2:**
    - targeted fixes only: B01, B03, B04, B08, B12, B14, B24, B41, B56, B81 and pu-13;
    - corrected physical and cap formulas, with the concurrent-start residual stated;
    - a claim set for stashes;
    - epoch-checked, operation-held delayed retries;
    - a durable-advance budget reset;
    - blob-resume preflights;
    - an informational unknown-size note;
    - deferred: the rebuild primitive, `RangeAttemptState`, the owned-work snapshot, opaque
      removal, the DEBUG move, B06, B13 and the paused-finish item;
    - the lead owns the contracts and manager edits.
- **2026-10-17 — P5 plan co-review, round 2: approve with changes (4 major, 1 minor).** The
  changes amend revision 2 and were sent to the transport delegate while it worked:
  1. **B03.** It covers both the tmp sweep and the durable-held sweep. Destinations are claimed
     before either rename, the claim survives through manifest publication, and the claim check
     and the deletion share one lock.
  2. **Delayed retries.** Each carries a per-attempt delayed-retry generation that pause, cancel
     and explicit restart invalidate. It is checked when the timer fires and again when
     replacement work registers. The held operation ends only after the successor registers, or
     after a suppressed return.
  3. **Blob resume.** It returns a typed outcome. A storage refusal keeps the blob and its
     watermark, reports `.storage`, and never falls back to a restart, on both the persisted
     path and the transient path.
  4. **B56 (lead, done).** An Emby static original or converted handoff persists the negotiated
     MediaSource size as `sourcePartSize`. A remux keeps the negotiated size only as its estimate.
  5. **B14.** Valid 64-bit box sizes are supported with checked bounds; only malformed or
     truncated lengths stop the walk. HEVC is assigned to the delegate.
  - **Also:** the append peak is the largest upcoming planned append. The B08 reset covers
    ordinary and held appends, ignores zero-byte advances, and resets at start only for an
    explicit user start or resume.

- **2026-10-17 — P5 session transport implemented** on `downloads/p5-transport` from the P5
  contract base. Session starts/continuations, blob resumes and manager storage-full parking use
  the physical storage policy without changing its semantics. Typed blob outcomes preserve authority
  on storage refusal; callbacks carry exact attempts; delayed retries hold the wake gate and check
  attempt, epoch and pause/restart generation through task registration. Transport drops get four
  retries (1/2/4/8 seconds), reset only by positive ordinary/held appends or explicit user resume.
  Both stash sweeps re-check locked claims, including the durable rename-to-manifest window; HEVC
  fixup walks bounded top-level boxes (including extended/zero sizes) and scans every `moov`.
  Red-checked pins 2, 7–12 by restoring the original affected behaviors behind the test seams;
  pin 13 failed against the original HEVC implementation. The durable sweep's existing legacy-name
  filter remains narrow; current attempt-stage files are not added to orphan deletion authority.
  Validation: 1,614 hermetic PMSKit tests; 785 Swift Testing + 66 XCTest Mac tests; hygiene
  (386 tooling tests and strict documentation/link/Mermaid checks). No simulator or live gate run.
- **2026-10-17 — P5 implementation review, round 1: approve with fixes (5 P2, 1 P3).** All fixed
  with pins that fail on the reverted code:
  1. **Auth retries (delegate).** They carry their generation through the manager hop, the
     backend rebuild and successor registration.
  2. **Held bodies (delegate).** Consumed claims retire before continuation admission, and
     checkpointed or overlapping ranges get no second credit.
  3. **Blob Resume (lead).** It passes the self-excluding cap projection first, and a refusal
     keeps the blob.
  4. **Cap rows (lead).** They count `max(durable checkpoint, bytes)`, in the season retry
     projection as well.
  5. **Side assets (delegate).** Every physical gate charges the side assets still to be cached.
  6. **Pins (lead).** The validation fallback refuses an over-cap optimize create. Both fallback
     sites share one check, `rejectOptimizeFallbackOverStorageLimit`. A season commit charges its
     retried rows' remaining bytes.


- **2026-10-17 — P5 after-review session fixes (findings 1, 2 and 5).** Rebuild callbacks now
  carry the timer's epoch/generation through the main-actor hop and backend Tasks. The exact
  committed successor seed hands off that fence and the wake hold; post-await guards and task
  registration re-check it. A backend rebuild cannot clear a newer Pause/Resume halt or acquire
  fresh user-Resume authority. Manager edits are limited to callback/start/seed plumbing.
  Consumed append claims retire before continuation admission; already-checkpointed,
  checkpoint-straddling and overlapping bodies receive no duplicate network-byte credit.
  The shared start/continuation/blob/parking preflight now adds the duration/chapter side-asset
  estimate less bytes already cached, floored at zero. Current storage guidance reflects this.
  Nine new pins were red-checked by restoring the old callback/fence behavior, claim accounting
  and zero future-side-asset input: four auth/manager handoff pins, two consumed/overlap pins and
  three side-asset admission pins all failed. The backend pin also proves a current successor
  can start after an attempt re-seed. No simulator or live acceptance was run in this lane.

## P2 detailed plan — cleanup foundation

*Revision 3.1 (2026-10-17). The round-3 co-review approved it with three changes, applied here:
terminal-release eligibility after deletion, retention of unresolved Plex creates, and the expiry
cutover moved into commit 3.*
- *Two "before" co-review rounds by GPT-6.1-Sol: round 1 (rework, 10 findings) and round 2
  (rework, 7 findings). All findings are incorporated.*
- *Scope was narrowed on the reviewer's advice:*
  - *physical deletion of the tombstone engine moves to P6;*
  - *quarantine recovery is limited to the Plex compatibility case.*

Today seven kinds of server cleanup exist. Only three are journaled:

| Cleanup | Record today |
|---|---|
| Jellyfin/Emby `activeEncoding` | journaled |
| Emby Convert `knownJob` | journaled |
| Emby Convert `ambiguousCreate` | journaled |
| Emby 24-hour expiry | separate tombstone file |
| Plex optimize removal on delete (B28) | none (fire-and-forget) |
| The two `cancelEmbyConvertJob` sites (B50) | none (fire-and-forget) |
| The superseded-negotiation encoder stop | none (fire-and-forget) |

The Plex `cleanStaleOptimizeJobs` DELETE loop is a fourth unjournaled path.

**Invariant.** No step clears or replaces the last durable authority for a server resource until
its successor authority has committed.

**Documented residual windows**, where the invariant does not fully hold:

- **Emby stale-create cancel and superseded encoder stops.** When their `ensure` fails, they fall
  back to a best-effort, unrecorded cancel. These windows exist today. A process death in them
  leaks the resource, and a diagnostic records each occurrence.
- **Plex GET → DELETE race.** A render that completes between the GET and the DELETE is deleted
  by the queue-item DELETE. PMS has no conditional cancel. This is an explicit exception to D2,
  and the UI note says the cancel happens "where possible".

### P2.1 Durability semantics (B18)

- **Committer.** Both journals write through `DownloadIndexFileCommitter`: an exclusive temp
  file, full fsync, rename, and directory fsync.
- **What "committed" means.** A write is `.committed` only when the full sequence succeeds.
  - If the write throws after the rename, the journal retries the directory sync, or recommits
    the same bytes.
  - If that still fails, the result is `.ambiguous`, which callers treat as a failure.
  - Re-reading the file is never treated as proof that the write is durable.
  - `ensure` that finds an existing entry also confirms the directory sync.
- **Protection and backup exclusion** are applied to:
  - the authority directory, whether it is new or already exists;
  - every journal write;
  - quarantine and evidence files.
- **Protected data unavailable.** A read refused because of data protection is `unreadable`,
  never `empty`.
- **Temps.** `cleanupAbandonedTemps` also sweeps the authority directory.
- **Locking.** The journal has its own lock and stays independent of the index (st-41).
- **Full volume.** The pin asserts that a delete on a full volume fails safely. It does not
  assert that space is reclaimed.

### P2.2 Schema, identity and store disposition

- **New operation:** `Operation.plexOptimize(queueTitle:, create:)`. `create` records the create
  evidence:
  - `.confirmed` when the PUT returned success, or the item has been seen in the queue;
  - `.unresolved` when the PUT's outcome is unknown.
  - The create request is a **PUT**.
- **Provenance.** Every intent gains a `provenance`:
  - `.rowDeletion`: written by delete.
  - `.terminalRelease`: written by the launch sweep for a handle held by a terminal row.
  - `.abandonment(originAttempt)`: stale-create, a duplicate job, a superseded encoder, expiry, or
    seed removal.
  - **Legacy entries** (no provenance) are classified once at load:
    - committed-absent row → `.rowDeletion`;
    - present terminal row → `.terminalRelease`;
    - anything else → retained, and re-checked on each pass.
- **Identity.**
  - **Plex** is server-scoped. Identity is the persisted `backendServerID`, falling back to the
    normalized URL on legacy rows; there is no user ID.
    - Binding to the account was rejected: `matchesPersistedServer` also gates resume, so an
      account binding would break resume after a Plex Home switch.
    - The cleanup matcher is separate from the resume policy.
  - **Jellyfin/Emby** compare users with `MediaBrowserUserIdentity.sameUser`.
  - The currently selected server is never substituted for a missing persisted identity.
- **Store disposition API.** `store.cleanupDisposition(for: attemptKey)` returns one of:
  - `.present(row)`;
  - `.retiring`, which covers a pending deletion, a removal whose terminal commit is still in
    flight, and a failed removal;
  - `.committedAbsent`, which requires `startupRecoveryState == .ready` and no in-flight
    row-deletion intent.
  - An in-memory removal, as at `DownloadStore.swift:5122`, is reported as `.retiring` until the
    terminal revision commits.
- **Downgrade (Plex only).**
  - Before the runner starts, any `download-cleanup-intents-quarantine-*` file is scanned for
    elements whose `operationType == plexOptimize`. Only those are re-imported.
  - Each one is `ensure`d by ID. Elements that conflict or still don't decode stay in the file.
  - The file is then renamed to `…-imported-*`, which is the import receipt.
  - The runner starts only after this barrier.
  - **Why this cannot resurrect work.** Plex intents in a quarantine file existed at downgrade
    time, and the older build could not execute them. A crash before the rename re-imports by
    ID, which is idempotent.

### P2.3 Eligibility and ownership, evaluated by the runner per pass

**Eligibility by provenance:**

- `.rowDeletion` runs only on `.committedAbsent`.
- `.terminalRelease` runs while the row is present and terminal, unless the operation-specific
  protection holds. A failed Convert row with `shouldKeepEmbyConvertAuthorityForRetry` is
  protected (B44); its intent is retained and re-checked.
  - It also runs on `.committedAbsent`. Delete can reuse an existing terminal-release intent
    through `ensure`, and after the row is removed that intent must still run.
  - It is blocked while `.retiring`.
- `.abandonment(origin)` runs whenever the ownership recheck passes. The originating attempt does
  not count as an owner.

**Ownership recheck, immediately before DELETE.** The runner collects every resource claimed by a
live row on the same backend, server and user, excluding the intent's own origin:

- job IDs;
- PlaySessionIds;
- queue titles;
- **live Emby recovery identities**: baseline, fingerprint and time window. Any job that
  `EmbyConvertRecoveryPolicy` would match for a live row counts as claimed (B49).

Ambiguous Convert cleanup and Convert crash-window recovery are serialized on one per-server
`EmbyConvertJobCoordinator`, so recovery adoption and cancellation cannot interleave.

**Plex outcomes.** The queue decodes to one of:

- `.malformed`: retain.
- `.absent`: retire only when `create == .confirmed`.
  - An `.unresolved` create is **retained**, and each pass re-runs the GET.
    - After 24 h its backoff grows to 6 h.
    - It is retired with a diagnostic only after 7 days. A PUT that becomes visible more than 7
      days late is treated as out of scope.
  - The stale sweep only runs on the next optimize kickoff, so it is not relied on as a follow-up.
- `.completed`: retire; the render stays on the server (D2).
- `.cancellable(id)`: requires a unique title match and a known non-terminal state. An unknown
  state is retained.

### P2.4 Producers

- **Delete.** The flow is unchanged:
  1. `prepareForDestructiveDeletion`;
  2. the deletion barrier;
  3. execution through the runner.
  - The Plex candidate joins the other intents, and the fire-and-forget `Task` goes away.
  - Paused prep rows are included (D2).
- **Plex seed removal.** `ensure` runs first, and the row is kept if it fails.
- **Emby stale-create (`+EmbyConvert.swift:458`).** `ensure` an `.abandonment` intent, then
  trigger the runner. If `ensure` fails, a best-effort DELETE is sent (a residual window).
- **Emby duplicate job (`:621`).**
  - `ensure` an `.abandonment` intent first.
  - If it fails, the **whole reuse handoff is skipped**: the row keeps its job and continues
    polling it.
- **Superseded encoder stops.** These use the captured `BackendSession` and the originating
  attempt. If `ensure` fails, they fall back to best-effort (a residual window).
- **Emby 24-hour expiry** (lands in commit 3, with the cutover).
  - `ensure` an `ambiguousCreate` `.abandonment` intent, and clear the identity and fail the row
    only after it commits.
  - If it fails, the row stays `.preparing` and retries on the next pass.
  - P2 stops writing tombstones.
- **`cleanStaleOptimizeJobs`.** Each discovery is `ensure`d as a `.abandonment` `plexOptimize`
  intent with `create: .confirmed`; the item was seen. The runner executes it. Live-title
  protection is part of the ownership recheck.

### P2.5 Tombstone migration (the engine is deleted in P6)

- **Migration key.** Each tombstone becomes an intent with:
  - its UUID kept as the intent ID;
  - the attempt key `(ratingKey, legacy-tombstone-<uuid>)`;
  - provenance `.abandonment`.
- **Migration receipt.** The runner skips any intent whose ID is still present in the tombstone
  file, so retained tombstones cannot recreate intents that have already drained. Unrelated
  intents stay runnable.
  - An unreadable tombstone file blocks every migrated intent. It is never read as "absent".
- **Preserved, not dropped:**
  - an unreadable legacy file is kept;
  - tombstones that cannot be converted are moved to an evidence file.
- **Parity.** The tombstone tests are ported to cover the full `cleanupAction` matrix. The
  legacy executor and preamble are removed from the call graph; the types and the reader stay
  until P6.

### P2.6 Runner

- `CleanupIntentRunner` is an actor that owns journal I/O, off the main actor.
- **Triggers.** It coalesces these into one pass:
  - launch-ready, after the P2.2 quarantine barrier and P2.5 migration;
  - `backend_ready`, a backend switch, and a session change;
  - foreground;
  - producer kicks.
- **Self-scheduling.** It schedules its own timer for the earliest backoff deadline, so it
  makes progress without row refreshes.
  - `refreshRecords` never triggers it.
- **Limits:**
  - concurrency of 2;
  - per-intent backoff from 30 s to 30 min;
  - backoff reset when the auth generation changes;
  - single flight per ID (emby-38).
- **Session mismatch** puts the intent into backoff.
- **Session hydration.** `ContentView` hydrates sessions for backends that have intents.
- **Fallback capsule.** `deferredCleanupIntents` remains only as the capsule fallback (st-26).

### P2.7 Launch sweep, logout and UI

- **`CleanupObligationPolicy` (PMSKit)** decides which terminal rows produce `.terminalRelease`
  intents:
  - Jellyfin/Emby play sessions;
  - Convert jobs, except protected failed ones;
  - Plex never.
- **Logout** does not journal.
- **D2 UI note.** The delete confirmation for a prep row says that:
  - a job still in prep is cancelled where possible;
  - completed server versions stay.

### Commit order (each commit adds its pins first and builds on its own)

1. **Durability (P2.1).** Pins:
   - a real directory-sync failure, and a rename followed by a throw;
   - a protection-unavailable read;
   - protection and exclusion on an existing directory and on quarantine files;
   - delete on a full volume failing safely.
2. **Schema, identity and disposition (P2.2).** Pins:
   - Plex identity, including legacy rows;
   - `cleanupDisposition` during an in-flight removal, a failed removal, a pending deletion, and
     before startup is ready;
   - legacy provenance classification;
   - quarantine re-import: a completed known entry next to an unknown Plex entry, mixed
     unsupported elements, and a crash before the rename.
3. **Runner, eligibility, ownership, migration and the expiry cutover** (P2.3, P2.5, P2.6, the
   P2.7 policy, and P2.4's expiry producer). After this commit no code writes or executes a
   tombstone. Pins:
   - eligibility by provenance;
   - ownership recheck, including a recovery-identity claim under a different attempt key and a
     migrated synthetic attempt;
   - Emby coordinator serialization;
   - Plex outcomes, including a 24-hour unresolved create;
   - backoff and the self-scheduled timer without refreshes;
   - single flight;
   - both startup orderings;
   - migration: partial, a removal failure, the receipt, and an unreadable legacy file;
   - parity;
   - expiry ordering;
   - Emby coordinator serialization spanning the awaited DELETE through the durable commit of
     the adoption.
4. **Remaining producers and UI (P2.4, P2.7 UI).** Pins:
   - for each producer, journal failure followed by process death;
   - the duplicate-job skip;
   - the stale-create fallback;
   - a superseded stop whose row is gone;
   - stale-sweep routing;
   - launch sweep → failed cleanup → delete reuses the intent → committed removal → cleanup
     runs;
   - a late Plex create with no new kickoff.

### Out of P2

- Facets and the v5 migration (P3). The journal survives a root reset, but row-only authority
  does not, so P3's migration must journal it.
- Prep-poller registration (P4).
- Physical deletion of the tombstone engine (P6).

## P3 detailed plan — lifecycle, history, reducer and v5 migration

*Revision 2.1 (2026-10-17).*
- *Round 1 (GPT-6.1-Sol): "rework", nine findings, folded into revision 2.*
- *Round 2: "approve with changes", seven changes, applied here and marked (R2-n).*

P3 now ships as **two PRs**:

- **P3a — lifecycle, history and the reducer.** Additive fields inside the v4 envelope;
  call-site conversion.
- **P3b — schema v5 and migration.** A transaction protocol that starts only once P3a's authority
  exists.

Physical facets remain a P6 concern. In P3 the facets are typed read views plus constrained
mutation APIs.

### What the code map changed about the design

- **History is not persisted today.**
  - Truncation strikes are in memory, keyed by ratingKey, and deliberately span attempts.
  - The unverified reason appears only in diagnostics.
  - Storage-full parks live in `lastError`.
  - Finalizing is inferred from `.downloading` with progress ≥ 1.
- **`.failed` also means "planned"** for season rows.
- **`submitProgress` silently promotes** queued, paused and failed rows to downloading (B09).
- **About 75 production status writes;** reconcile deletes files under the lock.
- **Unreadable or malformed indexes block today.** Only `.unsupported` resets. P1's downgrade
  guard classifies a newer schema as unreadable.

---

## P3a — lifecycle, history and reducer (inside v4)

### P3a.1 Additive v4 fields (authoritative once written)

`Row` gains `lifecycle: DownloadLifecycle?` and `history: DownloadAttemptHistory?`. Both are
optional on decode.

- A row without them is a legacy row. Its lifecycle is derived from `status` plus facts by the
  same reducer rule, `relaunchObserved`, the first time the store loads it after an upgrade.
- An older binary that re-encodes the row drops both fields. The next newer load re-derives
  them. Strikes, reasons and a `bodyCondemned` fence lost that way restart; this is a stated,
  bounded downgrade loss, and the B54 containment still keeps published bodies. A lost fence
  matters only if both the rename and the in-place delete of that body failed, and older
  binaries never had the fence.
- `status` is still written, derived from lifecycle, so older binaries and diagnostics read a
  consistent value.
- **(R2-3) Rollback compatibility.** P1/P2 binaries must keep working on a P3a index.
  - Every authority that older binaries enforce keeps its legacy projection throughout P3a.
    `seasonPlannerPendingAdmission` is still encoded from `history.admissionIntent`.
  - No new case is added to the existing `ArtifactIntentOperation` enum. An older decoder would
    fail the whole row, and that makes the index unreadable.
  - New durable effects use only existing operation cases (see P3a.5), or a separate optional
    field that older binaries ignore.
  - Pin: P3a writes planned rows and pending effects, a P1/P2 store re-encodes them, P3a reloads,
    and everything except strikes and reasons survives.
- **(R2-6) Structural derivation only at load.**
  - The store derives a missing lifecycle structurally (status → lifecycle, no effects) when it
    loads.
  - Recovery effects and fact-dependent corrections wait for the authoritative task enumeration
    in `relaunchObserved`.
  - A row with a lifecycle but no history, or the reverse, is completed structurally; it is never
    treated as malformed.
  - Pin: a pre-P3a v4 index upgrades straight to the P3b binary, skipping P3a.

### P3a.2 Types

**`DownloadLifecycle`:**

| Case | Meaning |
|---|---|
| `planned` | Created, not admitted (season rows; `planned` is shown as `queued`). |
| `admitted` | Admission granted; no transfer has started yet. |
| `serverPrep` | A Plex optimize or Emby Convert job is in progress. |
| `transferring` | URLSession work is live or being rebuilt. |
| `finalizing` | The body is complete and validation or promotion is pending. |
| `complete` | |
| `unverified` | |
| `paused` | |
| `failed` | |

**`DownloadAttemptHistory`:**

- `truncation: TruncationHistory?`
  - Holds `strikes`, a `sourceKey`, and `lastOutcomeID` (dedupes replayed finalize outcomes).
  - `sourceKey` is server and account identity, backend, item, media source or part, and
    requested profile. Strikes carry across attempts with the same `sourceKey`, preserving
    today's per-item behaviour.
  - **(R2-5) Inheritance:**
    - History moves to the new owner in the same store transaction that replaces the row
      (`createAttemptOwnedRecord` replacement).
    - An *unknown* component, such as a part not yet resolved during negotiation, is not
      treated as a change. Only a proven difference resets the strikes.
    - Outcome IDs are `(attemptID, finalizerRequestID)`, which are stable across replay. They are
      applied in commit order, and a replay of an already-recorded ID is a no-op.
  - They reset on `complete`, on a delete, and on a proven source or profile change.
- `unverifiedReason`: `probeMiss(String)`, `truncatedRepeated`, `backgroundProbeDeferred`,
  `migratedUnknown`.
- `lastFailure`: a bounded enum.
- `storagePark: StoragePark?`: the bytes needed and when it was measured.
- `pauseCause`: `user`, `queuePaused`, `systemInterrupted`, `awaitingSession`, `storage`,
  `deferredResume`.
- `admissionIntent`: `seasonPlanned` or `retryRequested`. Today this is
  `seasonPlannerPendingAdmission`; the field moves here, and the old field is read on load.

### P3a.3 Typed facts (computed per call, not persisted twice)

`DownloadRowFacts` is built from the row and live session state at the moment of the call:

- **Route:** `staticRange`, `plexPrep(queueTitle, createConfirmed)`, `embyConvert(job: known(id)
  | crashWindow | none)`, `forwardOnly`.
- **Checkpoint:** `none`, `durablePartial(bytes)`, `resumeBlob`, `heldBodies(count)`.
- **Body:** `none`, `workingComplete`, `published(path)`.
- **Pending artifact ownership:** the head intent kind, or none. This includes legacy
  `pendingValidatedPromotionStatus`.
- **Deletion pending.**
- **Live session state:** live task, rebuild grace, halt kind, finalizer claim, and a
  generation for each.
- **Snapshot eligibility** (reconcile).

The reducer takes `(lifecycle, history, facts, event)`. These facts are exactly the distinctions
today's reconcile table and retry policies use; Sol's finding 6 asked for this.

### P3a.4 Events and the call-site transition matrix

The matrix goes into the plan before implementation, as `docs/plans/p3a-transition-matrix.md`.
It lists every one of the ~75 status writes and reconcile branches, with its event and its
expected lifecycle result. Notable rows:

| Today | Event | Rule |
|---|---|---|
| reattach adopts a live Range task | `taskAdopted(generation)` | → transferring, only if the task gate allows it |
| rebuild grace begins or expires | `transferRebuilding`, then `rebuildExpired` | expiry with no task → paused(`deferredResume`) |
| held-drain halt | `checkpointAdvanced(bytes)` then `pause(cause)` | checkpoint accounting never changes lifecycle (Sol 7) |
| Convert → static replacement | `prepHandoff(newRoute)` | serverPrep → admitted on the same attempt |
| season admission | `admissionGranted` | planned → admitted; clears `admissionIntent` |
| legacy promotion recovery | `promotionRecovered(terminal)` | resolved before any other event |
| duplicate start suppressed | none | no state change |
| progress | `transferProgress` | legal only in admitted or transferring; elsewhere the bytes are recorded through `checkpointAdvanced` and the lifecycle is kept |
| revalidating a published body | `publishedBodyRevalidated(outcome, revalidationID)` | complete or unverified results apply; a truncation result keeps the body and stays unverified (B54); empty means failed with the body deleted |
| retry | `retry(mode)` | modes: `freshAttempt`, `resumeBlob`, `staticCheckpoint`, `prepReattach(plex)`, `convertResume(knownJob \| crashWindow)`, chosen by `DownloadRetryPreparationPolicy` from facts (Sol 5) |

### P3a.5 Durable effects

A transition's effects are **persisted in the same index revision as the state change**, as
existing artifact intents where one fits:

**(R2-2)** The mapping, with terminal semantics:

| Effect | Durable form | Row afterwards |
|---|---|---|
| `deleteBody(working)` (a truncation strike, an empty body) | the existing `heldBodyDeletion` operation with the working path, which deletes the body only | the row and its history stay |
| `deleteBody(published)` (empty published body on revalidation) | `heldBodyDeletion` with the published path, plus a constrained `clearPublication` | the row stays, failed, with its history |
| publish (complete or unverified) | the existing `validatedPromotion` recipe | the lifecycle stays `finalizing` until the terminal snapshot commits, then becomes the terminal |
| `clearResumeBlob` | `clearResumeBlob` | unchanged |
| held bodies | `heldBodyDeletion` | unchanged |
| `requestFinalization` | the persisted `finalizing` lifecycle (relaunch re-requests it) | — |
| server cleanup | P2 journal intents, committed before the index revision under the P2 rule | — |

`rowDeletion` is used only to delete a whole row.

Effects that are not durable (UI refresh, diagnostics) are marked transient.

Every artifact intent carries the attempt and generation fence it already has. Retries and
retirement follow the existing artifact lifecycle coordinator. **No effect executes before its
revision commits.**

### P3a.6 B10 move/marker boundary

Today the body is moved into the attempt working path (BDS ~3261), and only then is finalization
recorded (~3296).

**(R2-4)** The URLSession temp file is system-owned and expires once the delegate returns, so it
can never be a replay source. The protocol, inside the delegate callback:

1. **Move to an attempt-owned path.** Before returning, move the temp file to an attempt-owned,
   uniquely named capture path. The name is
   `.attempt-capture-<attemptID>-<finalizerRequestID>`, so the attempt owns it exactly and no
   pre-existing file can be mistaken for it. Then fsync the directory.
2. **Record the capture.** Submit `finalizing(capture: path)`. If that persistence fails, keep the
   capture file. The startup staging sweep recognizes a capture file only through its row record,
   so an unrecorded capture is orphaned and swept, which is the same loss as today.
3. **Promote the capture** to the working path. A pre-existing working file is replaced only if
   the row record names it as this attempt's working body; otherwise the row fails and keeps
   both files as evidence. Then submit `finalizing(bodyAtWorking)`.

On relaunch:

- a recorded capture path that still exists → resume from step 3;
- the working body named by the record → re-request finalization;
- neither → failed.

Pins: the temp file has expired, a pre-existing destination exists, persistence fails after
capture, and a crash happens after each step.

### P3a.7 Store API

- `store.apply(_ event:, for key:, generation:) -> ApplyResult` runs the reducer under the lock.
  It persists lifecycle, history and the durable effects in one revision, and returns the
  committed effects to execute.
- **Constrained mutators** replace whole-record writes. Each changes only its own field, keeps
  identity, and is attempt-fenced:
  - `checkpointAdvanced(bytes)`;
  - `setObligation(...)`;
  - `recordSideAsset(...)`.
- **Retired by the end of P3a:**
  - `submitStatus` and `setStatus`;
  - status inside `upsert` or `createAttemptOwnedRecord` (creation takes an initial lifecycle);
  - implicit promotion in `submitProgress`.
- A temporary `.legacy(status)` shim exists only while the conversion is in progress. A hygiene
  check fails on any shim use, any direct `row.status =` assignment, or whole-record replacement
  by the final P3a commit.

### P3a.8 Reconcile

`reconcile` builds facts and applies `relaunchObserved` or `foregroundObserved` per row. Its file
deletions become durable effects executed outside the lock, which closes st-41 for reconcile. The
P6 rows st-28 to st-31 and st-41 are re-tagged P3a for reconcile.

### P3a.9 B16, B21, B61

- **B16 — Retry Recovery re-probes.** It re-runs `startupProbe`, then reloads in process, instead
  of reusing the cached `startupIndexAdmission()` result. An indeterminate season commit becomes
  its own recovery state, `.seasonCommitIndeterminate`, distinct from `.unreadable`.
- **B21:** to be confirmed against Appendix A when the matrix is written. Mapped rows are fixed or
  re-tagged explicitly.
- **B61 — the stall watchdog.** It classifies from lifecycle and facts (`transferring` with no
  progress for N seconds and no rebuild grace) through `DownloadStallRecoveryPolicy`. It no longer
  depends on the display classifier.

### P3a.10 Pins written first

1. B10 move/marker boundary: three crash points.
2. B54 strikes: truncate → Retry → relaunch → truncate → park; the body is kept.
3. A replayed finalize outcome is deduplicated and never double-counted.
4. Progress cannot promote a paused or failed row, while held-drain bytes are still recorded.
5. Pause during delayed rebuild or auth callback, then resume (B02 class).
6. A failed Convert row's Retry resumes its job (`convertResume`); B44/B49 pins exist.
7. Season commit → each resume entry point (B62/B63).
8. Retry Recovery re-probes after the index is repaired (B16).
9. Protected data unavailable at launch, then unlocked: no reset, and rows available after unlock.
10. Rejected events produce no I/O.

### P3a commits

1. Pins, plus the transition matrix doc.
2. PMSKit: types, facts, derivation and reducer, with exhaustive tests.
3. Store:
   - additive fields with legacy derivation;
   - `apply` and the constrained mutators;
   - durable effects;
   - the shim.
4. Session conversion, including B10.
5. Manager and extension conversion; reconcile as events; B16 and B61; shim removal plus the
   hygiene check.
6. Docs.

---

## P3b — schema v5 and migration (after P3a)

A v4 index written by P3a already carries authoritative lifecycle and history. For P3b,
migration therefore means:

- applying D1, which drops non-terminal rows;
- journaling dropped rows' obligations;
- bumping the version.

### P3b revision 7 (2026-10-17): Delete every dropped row at ready, then stamp

**Maintainer decision (2026-10-17, refining D1).** P3a made lifecycle authoritative inside v4, so
the upgrade no longer has to reset everything that is not terminal. The maintainer chose "keep
partials only":

- **Kept:** `complete`, `unverified`, and every **paused static-range** row (a durable
  checkpoint, even at zero bytes).
- **Dropped:** every other row. That is planned (season) rows, admitted, serverPrep,
  transferring, finalizing, failed, and paused rows on a non-static route.

Rounds 3 and 4 of the before-review asked for rework of revisions 5 and 6. Both kept dropped
rows alive while the app ran (pre-activation waits, then a durable retirement list), and so had
to invent a new gate on Retry, starts, callbacks, finalization and season admission. That gate
already exists: **Delete's row-deletion barrier.** Every one of those paths must already respect
it, because a user can press Delete at any moment. Revision 7 performs exactly what a user
pressing Delete on each dropped row at launch would do, and then stamps v5. It replaces
revisions 4–6; where it conflicts with P3b.1 or P3b.2, it wins.

1. **Codec.**
   - Envelopes with version 4 or 5 decode; 1–3 reset; newer is unreadable.
   - The row shape and envelope shape are unchanged: no new envelope fields.
   - The store encodes each snapshot with the version captured when it is enqueued; that
     includes the season-plan submission and its candidate encoding.
2. **At `.ready`, in one MainActor turn.** When `activateDownloadsForCurrentStore` succeeds on a
   store whose committed schema is v4, the manager does the following before publishing
   `.ready` and before reattach.
   1. **Classify** rows by the maintainer decision.
      - **Kept as is:** a row with a legacy `pendingValidatedPromotionStatus`. Its body is being
        published and becomes complete.
      - **Left in place:** a row that is already deletion-pending, or that has a pending
        row-deletion intent. Its deletion is already under way.
   2. **Record the notice** (round 4, finding 5; round 3, finding 6). The upgrade notice file is
      a small JSON in the authority directory, written with the P2 committer. It gets the
      union of the dropped attempt IDs and the IDs whose server identity cannot be represented.
      The union is computed deterministically from the rows, before any deletion, so a crash
      and redo is idempotent. Nothing is added to the index envelope (round 4, finding 4).
   3. **Delete each dropped row** through `delete(record:)`.
      - Its synchronous part journals obligations first, keeping a capsule if the journal is
        unavailable, then installs the row-deletion barrier, halts session work and cancels
        exact cancellable work.
      - Its asynchronous part removes the files through the existing artifact queue.
      - Rows with earlier artifact heads get the deletion queued after them.
   4. **Stamp.** `store.stampSchemaV5()` fills `migratedUnknown`, switches the encoding version
      to 5 and enqueues the snapshot. The stamp is not awaited.

   Then the manager publishes `.ready` and runs reattach.
3. **Why there is no other gate.**
   - **Barriered rows.** After step 3, every dropped attempt either has a row-deletion barrier,
     so `ownsAttempt` is false and callbacks are rejected and cancelled on their next arrival,
     or is a capsule (`deletionPending`). Both are states every Retry, start, finalizer and
     season path must handle for a user Delete.
   - **Hardening.** Where a path checks only `isDeletionPending`, it gains `ownsAttempt`. Retry
     (`DownloadManager` ~2321) and the season selection are examples. This closes a window
     that exists for user Delete today (round 4, findings 1–2).
   - **Nothing to prune** (round 4, finding 3). There is no retirement list, so there is no
     committed-absence proof to make.
   - **Accurate counts** (round 4, finding 5). Rescue cannot happen, so the notice counts real
     deletions.
4. **Crash and retry.**
   - **Before the stamp commits:** v4 stays on disk. It may already carry committed barriers or
     capsules from step 3, and v4 recovery executes those. The next launch reclassifies the
     remaining rows and repeats the phase, and the notice union absorbs the repeat.
   - **After the stamp:** v5 is current, and in-flight deletions finish through ordinary
     recovery.
   - **Every snapshot after the stamp is v5.** A v4 index on disk therefore never contains a
     row created after the upgrade.
   - **Interrupted replacement:** this leaves a readable v4 or v5.
5. **Notice UI.** The Offline library shows "N in-progress downloads were removed during an
   update", plus a cleanup-gap line when there are gaps, until it is dismissed. Dismissing it
   deletes the file.
6. **Out of scope.**
   - **The paused-static finish-before-reattach race** predates P3b. It is journaled for P5.
   - **New artifact-intent cases** stay in P6.
7. **Tests** (written first):
   - kept/dropped matrix, including paused static at zero bytes, paused forward-only, a legacy
     promotion row and a row already deletion-pending;
   - every dropped row is barriered or a capsule before `.ready` is observable;
   - Retry, start and season admission on a dropped attempt are refused;
   - snapshots after the stamp are v5, including a v4 enqueue delayed across the stamp;
   - a crash after barriers commit but before the stamp commits redoes the upgrade
     idempotently, with the notice counted once;
   - a journal-unavailable capsule;
   - a pre-P3a v4 index upgrades directly;
   - v5 loads as current; 1–3 reset; 6 is unreadable.

### P3b revision 8 (2026-10-17): amend revision 7 by fixing Delete itself

The round-5 review accepted revision 7's snapshot ordering, its startup recovery of committed v4
barriers, and its removal of the retirement list and the envelope metadata. Its two P1 findings
describe **existing defects in the user Delete path**, and they affect users today. Delete
during Plex optimize preparation can still create the server job. Delete's `session.cancel` is a
no-op once its own barrier is installed. The migration relies on Delete, so P3b fixes Delete
rather than working around it. The rest of revision 7 stands, with the following amendments.

A. **Delete quiescence** (round 5, finding 1; a pre-existing bug).
   - `delete(record:)` captures the exact attempt key before submission. After an accepted
     submission it calls a new `session.haltForDeletion(attemptKey:)`, which does not consult
     `ownsAttempt`:
     - it installs the halt fence for that attempt;
     - it cancels tracked task IDs;
     - it enumerates `getAllTasks` and cancels every OS task whose marker carries that exact
       attempt, including untracked daemon tasks before reattach.
   - Manager-owned work (pollers, keepalive, server-prep tasks) is stopped at once through the
     exact-attempt release, while server-cleanup authority stays with the journaled intents.
   - The capsule-persistence-failure branch performs the same quiescence and reports
     `persistenceFailed`. It never claims a durable reservation.
   - Delete reports its outcome through a returned value, used by the migration, while the UI
     keeps ignoring it: `barriered`, `capsule`, `stale` or `persistenceFailed`.
B. **One work-admission predicate** (round 5, finding 2; a pre-existing bug).
   - `store.attemptAdmitsWork(key)` holds only for the exact owner with no row-deletion barrier
     and no capsule.
   - It replaces bare `ownsAttempt`/`isDeletionPending` checks at work-admission and
     continuation boundaries:
     - `acquireStartAttempt`, `acquireInFlightSlotForStart`, `startAttemptStillCurrent`,
       `retryAttemptCanContinue`;
     - season `admitSeasonPlannerRowsOnce`, `seasonAdmissionStillCurrent`, and the retry-row
       validation inside `applySeasonPlanAtomically`, which happens under the store lock;
     - `assertCurrentOptimizeAttempt`, `resumeOptimizePollerIsCurrent`, and
       `pollForOptimizedPart`;
     - `triggerOptimize`, immediately before the server create;
     - the session's start, resume, range-resume and fresh-finalizer entry points.
   - Publication paths keep their existing store fences.
   - **Tests:** delete during a suspended start, prep continuation and optimize trigger; and
     capsule admission refused at each boundary.
C. **Notice after handoff** (round 5, finding 3).
   - The notice union is written in the same MainActor turn, **after** the deletions return.
     It contains only attempts whose Delete returned `barriered` or `capsule`, which are
     confirmed handoffs that nothing can rescue.
   - **Residual cost:** a crash between handoff and the notice write can undercount, never
     overcount. This is journaled.
   - **Upgrade blocked:** `persistenceFailed` or `stale` outcomes are left for the next launch,
     and the stamp still runs. A capsule that never persisted is a row that v4 or v5 recovery
     reclassifies.
D. **Startup cost** (round 5, finding 4).
   - Only rows with server obligations journal anything, and that means rows in server prep or
     with an active encoder, which the queue's concurrency bounds. Every other dropped row costs
     one in-memory barrier plus a coalesced index snapshot.
   - The journal entries for all dropped rows are prepared in **one** batched journal write
     (`ensure` over the batch) before the per-row barriers. This bounds the MainActor turn to a
     single durable journal write plus in-memory work.

### P3b revision 9 (2026-10-17): phase-aware admission, async upgrade pass

Round 6 judged revision 8's approach feasible, with two corrections. Revisions 7 and 8 stand,
amended as follows.

1. **Phase-aware admission** (round 6, P1). `acquireStartAttempt` mints attempt B before the
   store owns it, so a single predicate cannot cover the whole start.
   - **Before the seed** (`acquireStartAttempt`, `acquireInFlightSlotForStart`, the
     `startAttemptStillCurrent` call inside `persistAttemptSeed` before create):
     - keep the existing token and slot validation;
     - additionally require that the store holds either no row for the key, or the exact
       expected previous owner;
     - reject a row that carries a row-deletion barrier or a capsule.

     The store's compare-and-swap in `createAttemptOwnedRecord` stays authoritative.
   - **After the seed:** every continuation requires `attemptAdmitsWork(B)`.
   - **Tests:** a successful fresh start and a successful A→B replacement, alongside the
     deletion-race cases.
   - **Season planner:** `applySeasonPlanAtomically` uses a lock-held variant of the
     predicate, so it never calls a locking method under the store lock.
2. **An async upgrade pass replaces the single MainActor turn** (round 6, P2). The upgrade runs
   as an async sequence after activation succeeds and before `.ready` is published. Startup
   stays `.preparing`, so no user action and no queue, season or runner work can start. For
   each candidate:
   - **Reclassify at its turn.** A row that healthy transport completed meanwhile is now kept.
   - **Otherwise** `await` the row's Delete, then `Task.yield()`.

   Each row costs what one user Delete costs. The MainActor is free between rows, so no
   batching is required.
   - Encoder release: the early process-work release uses a path that does not re-ensure
     encoder intents the row's deletion has already sealed.
   - `persistenceFailed` leaves the dirty capsule in memory. The stamp snapshot carries it, and
     if no commit ever succeeds, v4 stays on disk and the upgrade runs again.
   - The notice counts only confirmed handoffs (`barriered` or `capsule`) and is written after
     the pass.
   - The stamp follows the pass, then `.ready`, then reattach.
3. **Implementation notes from round 6.**
   - **Exact cancellation:** match the full `(ratingKey, attemptID)`, both for tracked entries
     and for task markers. Never use the rating-key-wide removal.
   - **Delayed cleanup:** guard rating-key-wide cleanup that runs after asynchronous deletion
     (such as `clearOptimizeProgress`) by ownership.
   - **Finalization and revalidation:** apply admission before revalidation's destructive
     prechecks as well as before finalizer admission.
   - **Existing paths:** deletion execution and recovery of committed promotions keep their
     dedicated authority checks.

### P3b revision 10 (2026-10-17): rescue only by completion

*Approved in round 8 of the before-review (GPT-6.1-Sol, high), with no blocking findings. The tests must exercise both orderings: checkpoint submitted before the barrier, and a deferred submission after it.*

Round 7 confirmed that revision 9 resolves round 6. It found one P2: while the pass awaits a
Delete, a refresh with the queue paused can park an unprocessed static candidate as paused, and
reclassification would then keep it.

- **Rescue rule.** The candidate set is fixed when the pass starts. At a candidate's turn, it is
  kept only if transport has since **completed** it, meaning it is now complete or unverified.
  Any other change, including a pause applied during the pass, does not rescue it: the
  candidate is deleted. This makes reclassification independent of refresh, so refresh needs no
  extra fence.
- **Startup state.** `startupRecoveryInFlight` stays true through the pass, the notice and the
  stamp. Its success-path clear moves after the await, so Retry Recovery and the transient
  retry cannot start a second activation. `.alreadyPurging` remains a coalesced wait and never
  launches a second pass.
- **Accepted interruption.** Background finish-events may release the OS handler and interrupt
  the pass. The v4 redo, together with barrier and capsule recovery, makes that safe.
- **Additional tests:**
  - a paused-queue startup with an unprocessed transferring static checkpoint, which must be
    deleted, not kept;
  - season A→B replacement;
  - retry-after-removal.

### P3b.1 Probe

`currentSchemaVersion = 5`, with a new `.migratable(from: 4)` probe case.

- **Kept fail-closed and blocking, never reset:**
  - unreadable bytes;
  - malformed current rows;
  - invalid ownership;
  - unparseable v4 (this corrects revision 1, where it reset).
- **Reset:** only explicitly unsupported schemas (1–3).
- **Newer than the binary:** unreadable (the P1 guard).

### P3b.2 Transaction protocol

- **Identity:** `migrationID` (a UUID) and `sourceDigest`, a SHA-256 of the v4 bytes, recorded in
  `migration-v5.json` in the authority directory and written with the P2 committer.
- **(R2-1) Digest progression:**
  - Every canonical replacement the migration makes (step 3's artifact recovery) is journalled
    in the receipt as `(beforeDigest, afterDigest)` before the write.
  - Ordinary writers and session callback mutations are frozen for the whole migration. Admission
    is closed, and the store rejects every mutation except the migration's own.
  - The candidate's digest is persisted in the receipt **before** its rename.
  - Recovery accepts the canonical index if its digest is any recorded `afterDigest`, the
    `sourceDigest`, or the candidate digest. Only an unrecorded digest is indeterminate.
- **Steps, each with a receipt:**
  1. `begin(migrationID, sourceDigest)`.
  2. **Drain transport.** A drain primitive is extracted that neither resets nor activates. Every
     process restart drains again before it continues.
  3. **Inventory.** It resolves each of these under the v4 rules, and blocks the migration if any
     cannot be resolved:
     - pending promotions;
     - legacy `pendingValidatedPromotionStatus`;
     - queued artifact intents;
     - `deletionPendingCleanupIntents`;
     - B54 staging publication, with replayable rename ownership and a cross-row path check.

     It writes a candidate v5 index to a sibling file.
  4. **Journal obligations of dropped rows** as abandonments. They stay *ineligible* while the
     migration is incomplete; see the runner gate below.
  5. **Commit.** The candidate is renamed over `index.json`, and the commit is proven by its
     digest.
  6. **Reclaim** unreferenced bodies, partials, held bodies and blobs.
  7. `end`.
- **Recovery precedence on launch:**
  1. If the canonical index is v5 and its digest equals the recorded candidate, the commit
     happened, whatever step the receipt says. Resume reclaim, then end.
  2. If the canonical index is v4 and its digest equals `sourceDigest`, resume from the last
     receipt.
  3. If the digests mismatch, block as `.migrationIndeterminate` with the bytes untouched.
  4. An ambiguous post-rename commit failure is settled by the digest comparison above.
- **(R2-7) Runner gate:** `rowState` is `.unknown` for every intent from `begin` until the v5
  commit is proven and the store has loaded the committed rows.
  - Cleanup then reopens.
  - Reclaim resumes independently; a reclaim failure never holds back server cleanup.
  - The runner's resource-ownership rechecks still apply.
- **Unverified rows:** the reason recovered from P3a history is kept; `migratedUnknown` is used
  only when it is absent.
- **Read-only blocked load:** this only takes effect once the index can be read. While protected
  data is unavailable, startup waits for the unlock (pin 9).

### P3b pins

A failure at each step, plus:

- post-rename ambiguity;
- the journal written but the index not;
- a stale receipt alongside a committed v5;
- a reclaim failure that resumes;
- legacy promotion recovery that blocks the migration;
- a runner blocked before the commit.

### P3b commits

1. Pins.
2. Probe and the drain primitive.
3. Protocol and steps.
4. Runner gate and read-only load.
5. Docs.

### Downgrade guard (P1)

Shipped in #371: a newer schema is classified unreadable and kept. **Release limitation:** it only
protects downgrades to builds that contain it, so it must be in a released build before any v5
build ships.

### Out of P3

- Admission coordinator (P4).
- Storage policy (P5).
- The physical facet split and remaining off-lock I/O (P6).
- UI (P7).

## P4 detailed plan — admission coordinator and server-prep runners

**Status:** revision 3 (2026-10-17): revision 2 plus the round-2 amendments below. Revision 2 was written after the first co-review. That review returned **rework**,
with 3 blockers and 13 majors; the findings and responses are in the progress journal.

**Shape:** P4 ships as **one PR**. The maintainer wants to reach P7 quickly, and the two halves share
the reservation model.

### Why revision 2 is simpler

Revision 1 kept an in-memory **permit table keyed by attempt**. Retry mints a new attempt,
pause→resume can reuse an attempt, and a handoff releases its slot before it restarts. Every one of
those moves had to thread the permit through by hand, and the review found three blockers and most of
its majors in exactly that threading.

Revision 2 takes ownership out of the coordinator:

- **Occupancy is observed, not owned.** A row occupies a lane exactly while its persisted
  lifecycle is `admitted`, `serverPrep` or `transferring` and it is not deletion-pending. Its lane is
  read from the row's current metadata. A handed-off Plex row is already stamped `.original`, so it
  counts as static.
- **Release is automatic.** It happens when the row leaves those states: pause, failure,
  finalizing, a terminal state, or deletion. P3a's reducer already makes every one of those
  transitions durable.
- **There is no permit lifecycle to leak.** The only in-memory state is a **reservation** for a
  start that the coordinator has spawned but whose row is not yet observable as active.

**Revision 1 decisions that are dropped:**
- **Attempt-keyed permits, and the permit gate in `acquireStartAttempt`.**
- **Plex prep entering `serverPrep`/`.preparing`** (review finding 12). It fixes no listed bug and
  ripples through the assertion helpers, the policies, the UI and older rows. Plex prep stays
  persisted as `admitted`/`.queued`.
- **Forwarding a stale Pause to the current attempt** (finding 9). The exact-attempt fence (pu-24)
  stays.
- **A new `userRequested` intent** (finding 11). A P3b build cannot decode it.

### P4.1 Policy (PMSKit, pure)

`DownloadAdmissionPolicy` replaces `SeasonDownloadAdmissionPolicy`. Lanes stay 2/1/1, total 3.

**Inputs:**
- observed occupancy by lane;
- live reservations by lane;
- waiting requests, each with an origin, a request time and an eligibility time;
- the queue gate;
- per-row pause exemptions.

**Output:** an ordered list of rows to start.

**Rules:**
- **Ordering.** Requests from explicit user actions (a tap, or a row's Resume or Retry) come
  before automatic ones (season plan, Resume All, recovery). Within each class, oldest first.
  Origin is in-memory only, so after a relaunch every waiting row is the same class.
- **Caps.** A request is granted only if both its lane and the total stay within caps, counting
  occupancy and reservations together.
- **Queue pause.** While the queue is paused, only exempt rows are granted (P4.6).
- **Handoff overflow (open question 4).** A server-prep row that hands off to a static transfer
  becomes static occupancy in place. Static occupancy can therefore reach 3 for that whole
  transfer. While it is over, nothing new is granted in that lane. This is documented, not "brief".
- **Grandfathered occupancy.** A row the OS or a poller already owns at relaunch counts, even
  when that puts a lane over its cap. Nothing new is granted until occupancy is back under the cap.

### P4.2 Coordinator (manager-owned, `@MainActor`)

`DownloadAdmissionCoordinator` holds three things:

- **Reservations:** `[ratingKey: Reservation {generation: UUID, lane, origin}]`. A reservation is
  keyed by the row, not the attempt, so attempt replacement inside a start chain needs no handoff.
- **Waiting requests:** `[ratingKey: Request {origin, intent, requestedAt, eligibleAt, backoffStep}]`.
- **Pause exemptions:** `[ratingKey]` (P4.6).

**Grant.**
1. Insert the reservation and spawn the start Task.
2. The coordinator never awaits a start chain. This retires the admitting key that was held for
   hours.
3. The start path is the existing one for that row:
   - a parked or planned row → `retry(record:)`, whose own retry transitions already accept
     `planned`, `paused` and `failed`;
   - a fresh tap → the backend `download*` call.

   No `admissionGranted` is submitted before `retry` runs. This answers finding 1: each retry mode
   keeps its own transition, checkpoint, blob, obligation and history rules.

**Reservation end.** A reservation ends in one of three ways:
- **Observed:** the row becomes active, so occupancy takes over.
- **Deferred:** the start Task finishes and the row is not active (P4.4).
- **Superseded:** a newer generation for the same row, or a delete or pause of the row.

The start Task closes its reservation only if the generation still matches. A stale continuation can
never release or defer a successor's reservation (finding 2).

**Pump.** One coalesced Task, triggered by:
- a request;
- a reservation ending;
- any store refresh in which an occupying row has left the active states;
- queue resume;
- startup recovery complete;
- backend ready;
- the earliest `eligibleAt` timer, from an injectable clock.

The 2 s `seasonPlannerAdmissionTask` loop is deleted.

**Barriers.** The pump grants nothing:
- while `seasonPlanCommitsInFlight > 0` (pu-05/06, finding 5);
- until startup recovery has classified rows and reattached tasks (finding 4).

### P4.3 Entry points

| Entry | P4 |
|---|---|
| Single tap (Plex, Jellyfin, Emby) | Request with user origin. If granted, the existing `download*` chain runs. Otherwise the seed row is persisted `planned` + `retryRequested` and shown waiting; it starts later through `retry`. |
| Season commit | Rows `planned` + `seasonPlanned`, then pump. The commit barrier is kept, and season rollback restores lifecycle and history as well as rows (finding 5). |
| Resume All (B63) | Each parked row gets a new reducer event `admissionRequested(intent)` (`paused`/`failed` → `planned`, intent `retryRequested`), then pump. |
| Row Resume or Retry | Request with user origin. Granted immediately when there is capacity. While the queue is paused it is exempt (P4.6). |
| Launch: `resumeInterruptedStaticByteRangeDownloads`, backend-ready static drains, `resumeStaticRangeWhenReady` | Request with automatic origin instead of calling `retry` directly. A static train restarted after relaunch is admitted, not grandfathered (finding 4). |
| Launch: rows the OS or a poller still owns (reattached tasks, Emby convert polls, Plex prep reattach) | Grandfathered occupancy; no request. |
| Prep scanner (B62) | Skips `planned` rows and rows holding the `seasonPlanned` intent. Only `admitted` prep rows reattach. |
| Stalled-stream restart, the Plex original→optimize fallback | Stay inside the same row's start. The row is already occupying, so no new request is made; see P4.5 for lane changes. |

### P4.4 Deferral and backoff (B66, B67, finding 6)

**Classification.** When a start Task ends with its row still not active, the coordinator looks at
the row and the start's typed result:

| Outcome | What happens |
|---|---|
| **Unavailable:** no session, a network or refresh failure, the backend not ready | `admissionDeferred(intent)`: `admitted`/`failed` → `planned`, intent kept. The request is re-queued with backoff 1, 5, 15, 30, 60 s (capped at 60), and also woken by backend-ready. |
| **Definitive:** item gone, unsupported, storage refused | The row fails, as it does today. |
| **Stale:** the generation is superseded, or the row is paused, deleting or owned by a newer start | Release the reservation only. The row is not rewritten. |
| **Duplicate:** the slot is already held by a live chain | Release the reservation only. |

**Typed start results.** Each start path returns a small `StartOutcome` enum instead of `Void`,
so classification never infers from a missing row.

**What this fixes:**
- **B66:** the season flag is no longer cleared before the start is proven. The intent is lifecycle
  history, and `admissionDeferred` restores it.
- **B67:** a cold launch or unreachable server defers the row with backoff instead of failing it.

### P4.5 Lane changes before a server create (finding 7)

A row admitted in one lane can turn into server-prep or encoder work. Examples:
- a Plex original that fails preflight falls back to optimize;
- an Emby negotiation reroutes to Convert.

Before the create, the chain calls `coordinator.mayEnter(lane, ratingKey)`.

- **Lane full.** The row is persisted `planned` + `retryRequested` with its negotiated route, and
  the start ends **unavailable**.
- **Cleanup authority.** Anything already negotiated keeps its cleanup authority through the
  existing obligations: a live encoder goes through the ActiveEncoding intent, as today.
- **Lane free.** The reservation's lane is updated in place.

### P4.6 Pause (B64, B65, emby-33, finding 8)

- **Synchronous pause.** Pausing a `planned` row, or an `admitted` row with no task, submits
  `.pause(.user)` synchronously, before `session.pause`. The start chain re-checks currency
  immediately before `beginBackgroundTransfer` and before every server create. Its guard already
  rejects `.paused`. This closes B64 and the "paused during PlaybackInfo" gap. The exact-attempt
  fence is unchanged.
- **Intent survives pause.** `history.admissionIntent` is kept through a pause. Resuming a row
  that was paused while waiting re-requests it with that intent. This retires B65.
- **Row exemption.**
  - A row Resume or Retry while the queue is paused adds the row to the exemption set. The set is
    keyed by rating key, so it survives attempt replacement and handoff.
  - Another Pause All, or a delete, revokes the exemption.
  - Retry gets the same exemption as Resume, because both are explicit row actions.
- **emby-33 is preserved.** Convert polling continues during Pause All. The static handoff parks
  unless the row is exempt.

### P4.7 Planner and presentation (B69, pu-33)

- **B69.** The planner tells a probe failure apart from a definitive unsupported verdict. A probe
  failure becomes a `planned` row that is re-probed at admission.
- **pu-33.** A `planned` row shows "Waiting for a download slot", or "Waiting — queue paused", and
  keeps Pause and Remove. Fuller row UX is P7.

### P4.8 Legacy flag and downgrade (findings 10, 11)

**Writes.** `seasonPlannerPendingAdmission` is no longer written.

**Precedence on load:**
- A flagged row that is `.queued` or `.failed` with no transfer evidence → `planned` +
  `seasonPlanned`.
- A flagged `.paused` row stays `paused` and gains the `seasonPlanned` intent.
- Deletion capsules, finalizing rows, handed-off static metadata and every other authoritative
  lifecycle win over the flag.

**Intents.** Only the existing intents, `seasonPlanned` and `retryRequested`, are written, so a
P3b build decodes every P4 index.

**Downgrade cost, stated in the PR.** A P3b build shows a waiting row as failed with Retry.

**Fixture.** A P4-written index containing completed rows and waiting rows of both intents must
decode under the P3b codec and model.

### P4.9 Server-prep runners

**Plex (one routine for fresh and resume).** Each step is idempotent and gated on currency.

1. **Reconcile.** Seed the deadline.
2. **Adopt existing (B35).** Adopt a tier-matching, locally playable Plex Version before any
   create, and say so in the logs.
   - Source exclusion and the explicit exact-Part choices (plex-04/05) are preserved.
   - This answers open question 3.
3. **Typed queue lookup (finding 14).** The result is `present`, `inspectedAbsent` or
   `unavailable`.
   - Fresh: create only on `inspectedAbsent`.
   - Resume: recreate only on `inspectedAbsent` (plex-19).
   - `unavailable` never implies absence.
4. **Create (B37, plex-28).**
   - An HTTP 400 duplicate re-runs step 2.
   - Any other error is reported, not swallowed.
   - A **create-visibility grace** starts at dispatch: 3 minutes, persisted
     (`plexOptimizeCreateDispatchedAtEpochSeconds`). If the queue item is `inspectedAbsent` past the
     grace and no version is adoptable, the row gets `prepFailed(.server)`.
   - The grace is separate from the 120 s completion grace and the 24 h deadline. Status-flap
     disarming, metadata-inspection gating, the auth-dead budget and the bounded bg-key retries
     are all kept.
5. **Poll.** It returns the Part together with the live lane it was observed on.
6. **Hand off (B33).** Build the URL from the live lane. Commit the exact Part, size, resume mode
   and provenance before the transfer, as today.

**Plex fresh chain.** It is still a registered Task, but the caller no longer awaits it. The
coordinator's start returns once the Task is registered.

**Emby (emby-49).**
- **Registration.** The fresh Convert chain runs as a registered poller Task with its own Emby
  token: `beginEmbyConvertPoller` and `endEmbyConvertPoller`. The relaunch Tasks use the same
  token, which fixes the Plex-token mismatch (finding 3).
- **One handoff operation, used by all four handoff branches** (fresh reuse, refreshed reuse,
  resume reuse, completed conversion):
  1. `endEmbyConvertPoller` without cancelling.
  2. Release prep bookkeeping with `releaseInFlight(…, cancellationMode: .excludingCurrentPoller)`.
     This is a new mode that skips cancelling the current poller Task.
  3. Start the static leg through `downloadEmby(.existingVersion)` as today.
  - The reservation is keyed by rating key, so it is unaffected.
- **Cancellation.** Sleeps honour cancellation.
- **Currency.** The checks add `attemptAdmitsWork`.
- **Testing seam.** Emby HTTP goes through an injectable `URLSession`, and the poll intervals can
  be injected for tests.

**Removed.** `retryPausedPlexOptimize`, which is dead code.

### Answers to the open questions

1. **Single taps wait.** User origin changes ordering, not caps.
2. **The flag is retired.** P4.8 resolves the paused-row precedence and the decodability concerns.
3. **Adopt existing Plex output,** with source exclusion, the tier and playability gates, and exact
   Part choices.
4. **In-place static conversion,** counted accurately. Static occupancy can be 3 for a whole
   transfer, and nothing new is granted in that lane meanwhile.
5. **A persisted 3-minute create-visibility grace,** separate from the completion grace.

### Pins (written first; each fails on the current code unless marked "retained")

**Admission:**
1. Resume All with five parked rows grants at most the caps (B63).
2. The prep scanner skips `planned` rows (B62).
3. A start in flight, before its row is active, counts through its reservation (B72).
4. An early return defers the row to `planned` with its intent (B66).
5. A cold-launch refresh failure defers with backoff, does not fail, and does not busy-loop (B67).
6. A pause between the grant and the start never starts the row (B64), and the same holds for a
   pause during PlaybackInfo.
7. A tap over capacity waits, then starts when a lane frees.
8. Relaunch: grandfathered occupancy over the caps grants nothing new, and restarted static trains
   are admitted.
9. A finalizing row frees its lane.
10. A row paused while waiting resumes to `planned`.
11. A row Resume during Pause All starts that row only. The exemption survives a retry, and another
    Pause All revokes it.
12. A stale generation cannot release its successor's reservation.
13. The season commit barrier holds, and rollback restores lifecycle.
14. Lane full at a reroute: the row waits without losing its route.
15. A granted retry succeeds through each mode: resume blob, static checkpoint, Plex prep
    reattach, Emby known job and Emby ambiguous job.
16. Legacy flag precedence: paused stays paused.
17. Downgrade fixture.

**Runners:**
18. Plex fresh with an adoptable version: no POST.
19. Queue `unavailable` ≠ absent: no recreate and no grace failure.
20. A failed create fails within the grace; a 400 duplicate adopts.
21. The handoff URL uses the live lane's token.
22. The fresh Plex and Emby starts return before the render completes.
23. All four Emby handoffs start the static leg, and none cancels itself.
24. Deleting during the fresh Convert poll cancels it and no handoff follows.
25. Pause All during Convert: polling continues and the handoff parks (emby-33).

**Retained.** Existing coverage for the untouched planner rows is kept as is: watched filtering,
drafts, serialized probes, the probe transport, storage confirmation and presentation.

### Commits

The pins are added in each commit together with the code they cover. They are not added red, so
every commit builds and passes.

1. **Policy, reducer events and codec.**
   - Policy: `DownloadAdmissionPolicy`.
   - Reducer events: `admissionRequested`, `admissionDeferred`.
   - Codec: legacy-flag precedence and the downgrade fixture.
2. **Coordinator, all entry points, typed start outcomes and pause changes,** activated together.
3. **Plex routine:** typed queue lookup, grace, adopt, live-lane handoff.
4. **Emby:** registered chain, handoff operation, injectable HTTP.
5. **Planner B69 and the waiting captions.**
6. **Docs.**

### Revision 3 amendments (co-review round 2: approve with changes)

These amendments override the sections above where they differ.

1. **Supervision until start completion** (round 2, items 2, 20).
   - Every grant has a generation, and the coordinator **supervises** it until the start's async
     work returns its typed `StartOutcome`.
   - Each row is counted once: as observed occupancy while it is active, otherwise through its
     supervised reservation.
   - Pause, delete, and a newer generation invalidate the generation.
   - `retry(record:)` and the `download*` entry points return an outcome that reflects their
     nested async work, so the start Task awaits it. The coordinator itself still never awaits a
     start.
   - The stalled-stream restart goes through admission as an automatic request.
2. **Retry routing from facts** (item 1).
   - The retry mode is chosen from lifecycle, route and retained facts, and `planned` counts like
     `paused`. Retained facts mean a checkpoint, a resume blob, an Emby job id, or a Plex queue
     title before handoff.
   - `DownloadRetryPreparationPolicy` accepts a `planned` Plex prep row for reattachment.
   - A paused forward-only Jellyfin or Emby row gets an explicit fresh-restart transition before its
     async continuation guard.
3. **Two waiting kinds, both durable** (items 5, 22).
   - **First starts** use intent `seasonPlanned`, which now means "a first start from a planned
     seed": season rows and taps that are over capacity. A waiting tap persists the same seed shape
     a season row uses, and both start through `startPlannedRecord`. That function is
     `startSeasonPlannedRecord` generalized, so it keeps the refresh and the exact source
     validation. The static container comes from that validation, never from a placeholder.
   - **Parked rows** use intent `retryRequested`: Resume All, and a row Resume or Retry delayed by
     capacity. They start through `retry(record:)`.
   - Every waiting request is a committed `planned` row. The coordinator's request list is rebuilt
     from planned rows at launch, and after a relaunch every origin is automatic.
   - A request is enqueued only after its `planned` transition commits. A failed or indeterminate
     commit is not enqueued and is reported.
   - Season rollback undoes only the transaction's own unchanged mutations, including lifecycle and
     history. A concurrent pause or delete wins.
4. **Reducer** (items 6, 23).
   - `admissionDeferred` is legal from `admitted`, `serverPrep`, `failed` and `planned`. From
     `planned` it is idempotent.
   - It is never applied to a paused, deleting, finalizing, terminal or superseded row; the manager
     checks the generation and deletion state first.
   - Server job and checkpoint metadata are untouched, so a later retry still resumes the job.
   - A repeated `admissionRequested` on a `planned` row only updates the intent.
5. **Orphan normalization** (items 4, 19).
   - Before admission opens at startup, and whenever a supervised start or a registered poller
     ends, the manager classifies every active-looking row:
     - a live session task, an attached poller, or a supervised start → occupying;
     - otherwise → `admissionDeferred` with its route intent.
   - Job and cleanup authority is kept.
   - Unavailable sessions defer with backoff instead of staying active forever.
6. **Lane changes** (items 7, 21).
   - `coordinator.switchLane(ratingKey, generation, to:)` is atomic. It excludes the row's own
     contribution, checks the generation, and installs the new lane before the create yields.
   - The pump also wakes whenever the occupancy vector changes, including the Plex prep → static
     handoff.
7. **Exemption reaches existing gates** (item 8). The row exemption is honoured by:
   - `ServerPrepRefreshPolicy` parking and the prep scanner;
   - static recovery;
   - the Emby handoff park.

   Convert polling continues during Pause All.
8. **Scanner set** (item 24).
   - The scanner reattaches admitted Plex prep, `serverPrep` Emby Convert, and the failed
     crash-window Emby recovery. It excludes `planned` rows.
   - Lanes come from the metadata table, and the handoff stamps are kept.
9. **Emby handoff** (item 3). The Emby poller end compare-removes its own
   `serverPrepPollerTasks` entry before any release, so `releaseInFlight` cannot cancel the running
   handoff.
10. **Plex create grace** (items 14, 25).
    - The dispatch time is persisted **before** the POST.
    - While that dispatch's grace is open, absence means "keep inspecting": no POST, and no
      timestamp reset.
    - After the grace, an `inspectedAbsent` queue item plus a successful metadata inspection with
      no adoptable version fails the dispatch.
    - A legacy row without dispatch evidence keeps today's recreate rule, stamping the dispatch
      first.
11. **More pins** (item 16):
    - active → unavailable completion;
    - orphan occupancy at relaunch;
    - the lane-change wake;
    - a planned Plex prep row reattaches;
    - Resume of a paused forward-only row;
    - waiting-seed relaunch and the container of a non-MP4 Jellyfin original;
    - an admission persistence failure;
    - a relaunch inside the create grace.
12. **Final gate** (item 17). The final commit is the combined regression gate: the full matrix
    plus every pin. Intermediate commits build, but they claim no behaviour beyond their own pins.

### Out of P4

- Reuse-fidelity heuristics, multi-part items, Premiere detection.
- Storage reservations (P5) and transport consolidation (P5).
- Fuller row UX (P7).
- Plex `serverPrep` lifecycle. It can be revisited in P7 if row presentation needs it.

## P5 detailed plan — storage admission and session transport

**Status:** revision 2 (2026-10-17). Revision 1 got **rework** from the co-review. Revision 2 cuts
P5 down to the confirmed, still-reproducing bugs, with the formulas the review corrected. The
optional consolidation is deferred, as the review suggested, so the overhaul can reach P7.

**Shape:**
- One PR.
- The lead owns the storage half, the PMSKit policy contracts and every manager-side edit.
- A delegate owns the transport fixes inside `BackgroundDownloadSession.swift`, including the
  session side of the attempt-keyed callbacks, against a policy and callback contract the lead
  commits first.
- The PR closes with one combined regression gate.

### Deferred out of P5 (journaled; not dropped silently)

| Item | Why it is deferred |
|---|---|
| The single rebuild primitive replacing the 12 restart sites | No listed bug needs it. Consolidating safely needs operation generations, halt-aware authorisation and epoch serialisation (round-1 findings 3–4). |
| `RangeAttemptState` packaging of the eight dictionaries | Behaviour-neutral. |
| A unified owned-work snapshot | B03 gets a targeted claim set instead (round-1 findings 1–2). |
| Deleting the opaque resume-data path | Still reachable for legacy rows without metadata. |
| Moving DEBUG fault injection out of the session file | Behaviour-neutral. |
| B06, the late OS handler | Uncertain. A safe fix needs startup-state distinctions (finding 11). |
| B13, the leaked-operation timeout | Uncertain. A safe fix needs identified operation handles (finding 12). |
| The P3 carry-over: a paused body that finishes before reattach | `writeThenPause` already preserves validated bytes. Finalizing needs whole-file rules (finding 13). |

These are candidates for P6, or for separate issues if P6 does not reach them.

**Field report (2026-10-17, build 1506, visionOS).** The app terminated soon after it relaunched
with background downloads that had completed while the headset slept. The redacted report holds no
termination signature. Its ring buffer shows a recovery burst of six starts and twelve range starts,
and no completion or handler events. The ranked causes are:

1. a watchdog termination from recovery fan-out plus synchronous persistence on the main actor;
2. an unbounded background wake;
3. a reattach/append ownership race.

Coverage:

- **Fixed in the stack:** P4 caps new starts. B11 is fixed in P1. B03, B04, B08 and B12 are fixed
  in P5.
- **Planned for P6:** the synchronous store wrappers (§6, B20) remain. B06 and B13 move from
  "candidate" into P6 scope, and B82–B85 are new.
- **Still open:** the root cause, until the matching `.ips` (Analytics Data) is captured.

### P5.1 Storage policy (PMSKit, pure) — lead, committed first as the contract

**`DownloadStorageAdmissionPolicy`**

- **`requiredAdditionalFreeBytes`**
  - **Inputs:** `expectedBytes: Int?`, `durableCheckpointBytes`, `heldBodyBytes`,
    `largestPendingAppendBytes`, `futureSideAssetBytes`, `headroom = 500 MB`.
  - **Result:**

    ```
    remainingNetworkBytes = max(0, expected − checkpoint − heldBodyBytes)
    required = remainingNetworkBytes + largestPendingAppendBytes + futureSideAssetBytes + headroom
    ```

    This is the physical timeline (finding 7): bytes already on disk, held bodies included, are
    never counted again. Only the append duplication peak, the largest single body being copied,
    is added.
  - **Unknown size.** An unknown `expected` requires the append peak, future side assets and
    headroom only, which is today's behaviour. Reactive ENOSPC handling stays.
  - **Measurement.** It stays purgeable-inclusive (sd-01). An unavailable measurement fails open,
    as it does today.
- **`capUsage(rows:)`**
  - Each row counts once: the larger of its durable checkpoint and `bytes`, plus its side-asset
    bytes (B24).
  - **Retry self-exclusion.** `capProjection(adding:replacingRow:)` subtracts the replaced row's
    own current contribution before adding its full estimate (B24).
  - **Reservations.** Admitted, server-prep and transferring rows with a known estimate add their
    remaining bytes, `max(0, estimate − counted)`.
  - **Unknown estimates** add nothing. They are surfaced by the unknown-size UI (P5.3).
  - **Residual.** Two starts that pass the cap concurrently, before either publishes its size, are
    not fenced. P4 admission caps concurrency at 3, and reactive ENOSPC and the cap's next check
    bound the overshoot. This is a stated residual (finding 8).
- **`DownloadStorageEstimatePolicy.totalBytes`.** An unknown media size stays unknown, whatever the
  side assets (B81). The wrong test is replaced.

### P5.2 Gates using it — lead (manager and UI), delegate (session preflights)

- **Manager cap check (lead).** It uses `capProjection(replacingRow:)` for every start, including
  retries.
- **Before any server-prep create (B41, lead).** The Plex original → optimize fallback and the
  fallback after an original fails validation both get a cap check before the create.
- **Session preflights (delegate).** The start, continuation and storage-full park checks call
  `requiredAdditionalFreeBytes` with held-body and append-peak inputs from session state. Both
  blob-resume entry points (`adoptBlobResumedRangeTask`) get the same preflight (finding 10).
  - **On refusal**, the checkpoint and blob authority are preserved, and the row fails or parks
    with `.storage` exactly as the existing storage-full path does.
- **Season commit (lead).** The projection includes the retry rows' remaining estimates.

### P5.3 Sizes and unknown sizes — lead

- **B56.** Decode `Size` in the MediaBrowser item `MediaSource` DTO into `Part.size`.
  - **Precedence.** The negotiated PlaybackInfo size keeps priority wherever it already applies:
    Jellyfin remux, and Emby original and remux. A remux size is an estimate.
  - **Jellyfin Original.** It uses the decoded item size.
- **pu-13, single-item sheet.** An unknown size shows "Size unknown — not counted toward the
  storage limit." This is informational: no persisted consent and no reservation. The season sheet
  keeps its confirmation, which now actually triggers because B81 is fixed.

### P5.4 Transport fixes — delegate (`BackgroundDownloadSession.swift`)

1. **B04.**
   - The move-failure rehydrate begins the rebuild grace.
   - The move-retry and HTTP 52x/503 delayed retries hold a background completion operation
     (`begin/endPendingBackgroundCompletionOperation`) from scheduling until the closure has run
     its currency check. The auth rehydrate already holds its grace.
   - Each closure re-checks attempt **and train epoch**, so an old timer after a same-attempt
     Pause → Resume does not fire (finding 4).
2. **B08.**
   - The transport-drop retry budget resets only when the durable checkpoint advances (the
     append path), never on `didWriteData`.
   - Internal rebuilds preserve the budget; a user start or resume resets it (bg-48).
   - The transport-drop retry gets backoff (1, 2, 4, 8 s) through the same gated delayed path.
3. **B12.**
   - `onError` and `onRangeRequestNeeded` carry the `DownloadAttemptKey`.
   - The manager handlers ignore a stale attempt. Owned continuations keep going through
     `resumeStaticRangeWhenReady`, which P4 already admits as a continuation. `onError` stays an
     error and presentation callback.
4. **B03.**
   - A stash URL is claimed in a locked set when it is created, synchronously in the delegate, and
     released after its append or discard.
   - The tmp sweep re-checks the claim set under the same lock immediately before deleting each
     path, so a stash created after enumeration is never deleted (finding 2).
5. **B14.** HEVC: walk the top-level boxes to locate `moov`, and scan the whole `moov` with
   bounded reads, in addition to the windows. Malformed or extended box sizes stop the walk
   safely.

### Pins (each fails on the current code)

**Storage:**
1. B81: an unknown size plus side assets is unknown.
2. B01 numeric:
   - a held-only completion needs the append peak plus headroom;
   - future segments;
   - side assets.
3. B24:
   - a retried partial is counted once;
   - an admitted row's remaining bytes are reserved;
   - a failed row counts its bytes only.
4. B41: the fallback create is refused over the cap.
5. B56: the item DTO decodes `Size` (large, missing and null values).
6. The season projection includes retries.
7. A blob resume refused for space keeps its blob.

**Transport:**
8. B04: the move rehydrate holds the grace; a delayed retry holds an operation.
9. An old timer after the same attempt's Pause → Resume does nothing.
10. B08: repeated identical segment prefixes exhaust the budget.
11. B12: a stale-attempt callback is ignored.
12. B03: a stash created after enumeration survives.
13. B14: an out-of-window `hev1` is rewritten when another sample entry was found in a window.

**Retained.** The behaviour of the handled-but-unpinned rows that P5 touches is preserved:
bg-19, bg-27, bg-29, bg-30, bg-33, bg-34, bg-35, bg-48. Named coverage is added only where a
P5 edit touches the row.

### Commits

1. **Policy contract** (lead): PMSKit `DownloadStorageAdmissionPolicy`, B81, and the callback
   signatures.
2. **Storage gates** (lead): manager, UI, B56, season.
3. **Transport fixes** (delegate).
4. **Integration** (lead).
5. **Docs**, then the combined matrix.

## P6 detailed plan — store responsiveness and bounded background wakes

**Status:** design draft, 2026-10-17, based on `downloads/p5-storage-transport` at `01565133` (P5 head). Source inspection only; no tests, builds, simulator actions, tracked edits or Git mutations were performed to prepare this draft.

**Shape:** one PR, with a lead and one delegate working in disjoint files after the API contract is agreed. Finish the remaining correctness work needed to reach P7; no performance baseline, profiling campaign, actor conversion or general store rewrite is a prerequisite. This draft is an insertion candidate for the existing overhaul plan, not a second canonical plan.

**Priority:** remove store persistence waits from the MainActor and callback queues; move filesystem operations out of the store lock without weakening ownership; release every OS wake within an explicit application budget; remove the persisted-row duplicate-key trap. Add the small audit and failed-head bookkeeping fixes while those paths are open. Explicitly defer the rest.

### Pins — write these first

These are proposed tests, not claimed results. Each numbered pin has a specific red assertion on this head. A missing future API or a compile failure does not count as a red test. First add only the minimal clock/filesystem scheduling hooks needed to exercise the existing production entry points; record the failure, then change behaviour. Use held semaphores, dedicated readers and a fake monotonic clock, following `DownloadStoreAttemptOwnedCheckpointTests.staticCheckpointStatRunsOffStoreLock`; do not use throughput thresholds or `Task.yield()` counts as a performance baseline. Always arrange a test-side cleanup release from outside the MainActor so a broken implementation cannot wedge the test process.

| Pin | Fixture and required assertion | Why it fails at `01565133` | Owner / test home |
|---|---|---|---|
| P6-pin-01 | Hold the injected index committer. Drive a real manager lifecycle action and a separate MainActor acknowledgement. The acknowledgement runs before the committer is released; dependent transport/server work remains absent until commit, then is attempted only after a fresh authority check. Repeat with commit failure and attempt replacement while awaiting. | `applyLifecycleEvent` calls `resolveSynchronously` at `DownloadManager.swift:2080`; that MainActor cannot acknowledge while the write is held. | Lead; new `LabstreamTests/P6ManagerPersistenceTests.swift`. |
| P6-pin-02 | Hold an index/artifact worker indefinitely. Resolving a mutation, promotion, checkpoint or deletion reaches its supplied deadline with the appropriate typed timeout; a later commit can still complete the original operation, and cannot complete a different epoch's waiter. | The synchronous resolvers and the async wrappers around them wait without a deadline. The latter merely move the unbounded wait onto a global queue. | Lead; new `LabstreamTests/P6StoreResolutionTests.swift`. |
| P6-pin-03 | Hold a Retry checkpoint clone inside `createAttemptOwnedRecord`. An unrelated exact-owner lookup completes before clone release. Race a Delete/replacement and verify that the obsolete clone cannot install its owner or delete the replacement; a failed candidate commit retains the old checkpoint. | The current clone/stat/remove/copy runs with `lock` held at store lines 3446–3452. The red assertion is the independent lookup, with race assertions retained beside it. | Lead; new `LabstreamTests/P6StoreIOTests.swift`. |
| P6-pin-04 | Parameterize slow blob read, existence/stat used by lifecycle facts, side-asset publication, condemned rename/fallback removal, and staging enumeration/removal. While each actual filesystem operation is held, an independent row lookup completes. Re-check row/source/file identity after the hold before applying the result. | All listed operations still occur under the store lock; see the code map. This supplements, rather than duplicates, the already-green off-lock `submitStaticRangeCheckpointReset` pin. | Lead; `P6StoreIOTests.swift`. |
| P6-pin-05 | Reconcile an eligible interrupted non-resumable row with a resume blob. After successful cleanup, its resume path/display authority is cleared durably; an injected removal failure retains recovery authority. Hold cleanup I/O and prove another row remains readable. Add a second row referencing the selected path and require its bytes survive. | Reconcile deletes under the lock at 5552–5565, leaves resume metadata unchanged, and has no full cross-row path reservation at this step. A fixture requiring cleared references is independently red. | Lead; new `LabstreamTests/P6ReconcileCleanupTests.swift`; retain the existing same-attempt file-identity race pin. |
| P6-pin-06 | Block startup recovery before transport construction, finish its failure release, then supply another OS handler. Also store before session registration and register after the failure. Every exact token fires once without constructing a URLSession. A merely deferred initial activation is allowed to activate normally. | Failure release is an edge, not remembered terminal startup state. `noteBackgroundCompletionHandlerStored` only stores the late token, and `ensureSessionReady` is a dormant no-op. | Delegate; new `LabstreamTests/P6BackgroundWakeTests.swift`, with real registry/session wiring. |
| P6-pin-07 | Begin operation A and finish events; advance past its operation deadline. That wake becomes release-eligible. Start operation B/new wake, then deliver A's stale or duplicate end/timer. B's hold remains. Do the same for rearmed grace. | Gate operations have no identities or deadlines, only a count; there is no operation-expiry path. | Delegate; `P6BackgroundWakeTests.swift` and `BackgroundDownloadWakeCoordinatorTests.swift`. |
| P6-pin-08 | Repeatedly start and finish individual operations before each operation timeout while keeping a wake continuously occupied. Include a blocked append, slow index commit, missing finish-events, and a flush already in flight. At the one absolute wake deadline, the original tokens become release-eligible exactly once; no additional 5-second flush starts then. | The existing 5-second persistence bound starts only after operations drain. Balanced operations and missing finish-events can delay reaching it indefinitely (B82). | Delegate; `P6BackgroundWakeTests.swift` plus `BackgroundCompletionPersistenceBarrierTests.swift`. |
| P6-pin-09 | Timeout a wake while a body worker remains physically active. Its attempt/train ownership and body claim remain installed; no successor appends concurrently. A late completion/end cannot consume a new wake's token or operation. Committed checkpoint bytes and pending artifact intent survive reinitialization. | There is no timeout transition today. Exercise the proposed deadline via a test scheduling hook over the existing gate; the current gate retains the original handler beyond it, which is the red assertion. The ownership assertions prevent an unsafe implementation of expiry. | Delegate; `P6BackgroundWakeTests.swift`. |
| P6-pin-10 | A small source safety assertion rejects a trapping `Dictionary(uniqueKeysWithValues:)` in persisted-row ingestion. Pair it with identical-key and different-attempt duplicate v4/v5 fixtures through real store initialization and Retry Recovery: admission stays blocked, no winner is guessed, bytes and files are unchanged, and repairing the file permits recovery. | **Only the source safety assertion is red:** `load` still uses the trapping initializer at 5839. `classifyIndex` already rejects duplicate keys at 854–859, so an ordinary duplicate-file launch is already blocked and must not be advertised as a new crashing reproduction. | Lead; new `LabstreamTests/P6StoreLoadSafetyTests.swift`; no forced private-loader bypass. |
| P6-pin-11 | Repeatedly fail and explicitly retry one durable artifact head 600 times, without ever completing it. Live coordinator entries are proportional to live intents/current epochs, not attempts; retired unclaimed failures are capped at 512. An unrelated successful row commit does not launch that failed head again. A relevant dirty-prepared-revision recovery and an explicit same-row successor still restart it. | Failed epochs accumulate in `entries`; store failure drops its ticket and generic successful persistence repeatedly calls `recoverPendingArtifactIntents`. Existing retirement tests only cover completion/abandonment, not a permanently failing head. | Lead; new `LabstreamTests/P6ArtifactRetryTests.swift`. |
| P6-pin-12 | Audit a fixture with hidden working/held staging files, generation resume files, an index commit temp, a pending promotion/deletion path and a foreign file. Every byte in the Downloads directory is accounted for once; owned pending paths are referenced/protected, and infrastructure/foreign files are never sweep candidates. Audit does not delete anything. | `directoryFileSnapshots` skips hidden files (2981), referenced accounting omits the working path and pending-intent paths, and the filename classifier does not recognize hidden staging. | Lead; `OfflineDownloadFileInventoryTests.swift` plus new `LabstreamTests/P6StoreInventoryTests.swift`. |

**Retained coverage is separate from red pins.** D1 migration, unsupported-root drain, duplicate admission, existing crash-replay, ENOSPC and ownership tests are regression gates, even when already green. Do not relabel them as failing tests. Extend touched required/unpinned inventory cases before merge (especially st-02, st-23 and st-38); do not invent a failure for a case this head already handles.

### Current code map

All line numbers below refer to this exact head. `Core/` means `Labstream/Capabilities/Downloads/Core/`. A file followed by several line numbers denotes distinct call sites, not a line range. This is a map of production blocking paths, with test-only wrappers listed separately.

#### Store wait funnel and synchronous facade

| File:line | Current path / implication |
|---|---|
| `Core/DownloadStore.swift:177`, `:186`, `:197`, `:203`, `:225` | Mutation/resume/artifact synchronous resolvers; index or lifecycle condition waits. |
| `Core/DownloadStore.swift:1143`, `:1218`, `:1240` | Promotion wrapper and sync resolver; the async resolver dispatches that same unbounded resolver to a global queue. |
| `Core/DownloadStore.swift:1795`, `:2131`, `:2174`, `:2242`, `:2279`, `:2303`, `:2363` | Legacy attempt-scoped held-body mutation/purge paths still wait for persistence. New production submissions already exist at 1833 and 1873. |
| `Core/DownloadStore.swift:3161`, `:3211`, `:3231` | Atomic season apply waits for both candidate and conditional rollback, with exact canonical-byte proof after ambiguity. The manager already executes this work detached. |
| `Core/DownloadStore.swift:3322`, `:3494` | Attempt seed/replacement waits before returning its committed result; additionally clones under the lock. |
| `Core/DownloadStore.swift:3521`, `:3537`, `:3549`, `:3585`, `:3677`, `:3829`, `:4947`, `:5061`, `:5295`, `:5343` | Playback position, PlaySession set/compare-clear, size, resume replace/clear, metadata, progress, status fixture shim, and unverified promotion wrappers. Their attempt results imply a synchronous durability wait. |
| `Core/DownloadStore.swift:4439`, `:4448` | Retry Recovery can synchronously wait for a season-indeterminate recommit; re-probe/startup tail also performs filesystem work. |
| `Core/DownloadStore.swift:4520`, `:4604`, `:4631` | Checkpoint sync facade; async facade dispatches an unbounded wait. The underlying submitted checkpoint's filesystem work is already off-lock. |
| `Core/DownloadStore.swift:5466`, `:5540`, `:5571`, `:5580`, `:5670`, `:5699` | Reconcile waits; row-deletion sync facades; row-deletion async facade dispatches an unbounded wait. |
| `Core/DownloadStore.swift:5892`, `:5906`, `:5931`, `:5960`, `:5984` | Load-time normalization can call blocking `persist`; all private persistence waits funnel through 5931. Existing async bounded index/lifecycle flush is at 5960/5984 and should be reused. |
| `Core/RevisionedPersistenceWriter.swift:77`, `:91`, `:100` | Bounded async flush already exists. Compatibility `waitSynchronouslyForOutcome` has an unbounded condition wait. Keep blocking internals confined to known workers while migrating callers. |
| `Core/DownloadArtifactLifecycleCoordinator.swift:59`, `:96`, `:200`, `:204`, `:208` | Register/finish, synchronous ticket/watermark waits, and async watermark flush. Failed per-ticket epochs are retained after repeated failure; no async deadline-aware exact-ticket resolver exists. |
| `Core/DownloadStore.swift:231`, `:3074`, `:3312`, `:3641`, `:3813`, `:4475`, `:4900`, `:5032`, `:5272` | Test/legacy entry points and rating-key mutation shims. Removal is not a prerequisite; keep fixture adapters DEBUG-only where needed, and port only tests touched by the new API. |

#### Manager callers that reach synchronous waits

| Caller file:line | Call |
|---|---|
| `Core/DownloadManager.swift:706` | `reprobeBlockedIndex` directly on MainActor. |
| `Core/DownloadManager.swift:1018`, `:1969` | `reconcile` from reattach completion handling. |
| `Core/DownloadManager.swift:1126`, `:4783`, `:4826`; `Core/DownloadManager+CleanupRunner.swift:424` | `clearPlaySessionID`; compare-clear proof must still precede clearing cleanup authority. |
| `Core/DownloadManager.swift:1315`, `:5243` | `updateMetadata`. |
| `Core/DownloadManager.swift:1637`, `:3525`; `Core/DownloadManager+Plex.swift:257`; `Core/DownloadManager+PlexOptimize.swift:405`; `Core/DownloadManager+Jellyfin.swift:325`; `Core/DownloadManager+Emby.swift:499` | `createAttemptOwnedRecord`; committed seed precedes external work. |
| `Core/DownloadManager.swift:2080` | `applyLifecycleEvent` resolves synchronously; this is the shared high-fan-out bottleneck. |
| `Core/DownloadManager.swift:2657` | `clearResumeData` after opaque blob resume. |
| `Core/DownloadManager.swift:4115`, `:4118` | Unverified promotion and playback position persistence. Remove the blocking mechanism here in P6; attempt-bound playback sinks and playback-observed semantics remain P7 (B73–B76). |
| `Core/DownloadManager+Jellyfin.swift:348`, `:376`, `:540` | `setPlaySessionID`, metadata persistence. |
| `Core/DownloadManager+Emby.swift:477`; `Core/DownloadManager+EmbyConvert.swift:783`, `:800`, `:818`; `Core/DownloadManager+PlexOptimize.swift:684` | Backend helpers call blocking metadata persistence. |
| `Core/DownloadManager+SideCache.swift:330`, `:503`, `:557`, `:608`, `:751` | Side-asset metadata publication; retain exact source checks and post-commit retirement. |
| `Core/DownloadManager+SeasonPlanner.swift:172` | Atomic season apply is **already detached** by `persistPlannedSeeds` (170); preserve that working barrier rather than redesigning season transactions. |
| `Core/DownloadManager.swift:1083`, `:2019`, `:2146`, `:3983`; `Core/DownloadManager+PlexOptimize.swift:388` | Existing **async** deletion/checkpoint resolvers: these already release MainActor, but currently hide unbounded worker waits. Migrate their deadline contracts, not their execution context. |

The shared lifecycle helper's call graph also has to be migrated, not just the explicit `resolveSynchronously` spelling:

| File | `applyLifecycleEvent` / failure-helper callers |
|---|---|
| `Core/DownloadManager.swift` | 1748, 1788, 1796, 1801, 2114, 2124, 2206, 2213, 2219, 2590, 2625, 2674, 2706, 2715, 2750, 2794, 2933, 2961, 2984, 3031, 3053, 3191, 3226, 3258, 3538, 3614, 3641, 3771, 4065, 4072, 4161, 4587. |
| `Core/DownloadManager+Admission.swift` | 166, 196, 199, 201, 215, 221, 233, 240, 245, 286, 445. |
| `Core/DownloadManager+SeasonPlanner.swift` | 216, 258. |
| `Core/DownloadManager+Plex.swift` | 271. |
| `Core/DownloadManager+PlexOptimize.swift` | 111, 233, 256, 277. |
| `Core/DownloadManager+Jellyfin.swift` | 317, 338, 356, 380. |
| `Core/DownloadManager+Emby.swift` | 157, 198, 282, 353. |
| `Core/DownloadManager+EmbyConvert.swift` | 753, 771. |

#### Session callers and wake control

| File:line | Current path / implication |
|---|---|
| `Core/BackgroundDownloadSession.swift:1168`, `:1190`, `:1336`, `:1350` | Submission helpers synchronously resolve when a stored OS handler is absent. The presence of a handler currently selects persistence semantics; that is not an executor guarantee. A handler arriving late does not make a blocked foreground call safe. |
| `Core/BackgroundDownloadSession.swift:1366` | Held-lifecycle waiter is already off the range queue but unbounded; ordered completion returns to `rangeIOQueue`. |
| `Core/BackgroundDownloadSession.swift:1663`, `:2054`, `:2823`, `:3036`, `:3135`, `:5612` | Checkpoint sync facade. `:2071` also explicitly resolves lifecycle synchronously. Preserve the individual queue/ordering contracts when replacing them. |
| `Core/BackgroundDownloadSession.swift:1727` | Legacy validated-promotion recovery is already dispatched off delegate delivery; retain its startup classification ordering. |
| `Core/BackgroundDownloadSession.swift:7248` | Blob-resume path clears resume data synchronously. |
| `Core/BackgroundDownloadSession.swift:6280` | Existing async validated-promotion resolver releases the caller but has no bounded exact-ticket outcome. |
| `Core/BackgroundDownloadSession.swift:1511`, `:1515`; `Core/BackgroundDownloadWakeCoordinator.swift:67`, `:73` | Anonymous begin/end gate operations; no operation token or upper bound. |
| `Core/BackgroundDownloadSession.swift:852`/`:861`, `:4087`/`:4092`, `:4110`/`:4116`, `:4476`/`:4479`, `:5469`/`:5501`, `:7440`/`:7445` | Production operation acquisition/release pairs to convert to captured handles. DEBUG helper pair is 796/800. Grace begin/end is separately owned by the coordinator. |
| `Core/BackgroundDownloadSession.swift:1519`, `:1529`, `:1574` | Store-handler, one-shot startup failure release, then 5-second index/lifecycle flush **after** gate drain. No whole-wake deadline. |
| `Core/BackgroundDownloadCompletionRegistry.swift:32`, `:51`, `:77` | Registration replays pending tokens; store records tokens even with no session; release drains exact tokens. No terminal-startup memory or registry-side deadline exists. |
| `PMSKit/Sources/PMSKit/Downloads/BackgroundDownloadCompletionGate.swift:beginOperation`, `:endOperation`, `:abortAwaitingHandlers` | Count-only state. Abort zeroes all operations; it must not be reused as a live-wake timeout. |

#### Filesystem work held under the store lock

| Store file:line | Work | P6 treatment |
|---|---|---|
| `DownloadStore.swift:1553`, `:1565`, `:1569` | Side-asset staging existence check and rename while ownership/source check holds the lock. | Reserve paths and source generation, perform publication on worker, then revalidate; do not just unlock around rename. |
| `DownloadStore.swift:1588`, `:1599`, `:1606`, `:1662`, `:1672` | Startup staging enumeration, resource reads and removals. | Immutable init inventory, off-lock scan, then path reservation against complete current references. |
| `DownloadStore.swift:2311`, `:2339`, `:2340` | Legacy deferred-held cleanup existence/removal. | Route touched production work through existing held lifecycle worker; retain latest-revision and cross-row proofs. |
| `DownloadStore.swift:2708`, `:2720` | Reusable side-asset stat/type/size. | Snapshot owner/source/cache generation, stat off-lock, compare before returning. |
| `DownloadStore.swift:2816`, `:2819`, `:2824`, `:2831`, `:2838`, `:2846`, `:2860` | Local/BIF/playlist/chapter existence checks. | Snapshot then off-lock read; invalidate/reject on changed authority. Do not turn them into UI-wide async APIs in this PR. |
| `DownloadStore.swift:3446`, `:3449`, `:3450`, `:3452` | Retry handoff stat, destination exists/remove, potentially multi-GB copy. | Worker handoff with source/destination reservation and compare-and-swap; highest-cost lock hold. |
| `DownloadStore.swift:3755`, `:3760`, `:3774`, `:3778` | Exact-attempt resume blob read/existence. | Snapshot and read on worker for main-actor callers, then exact-owner/path/generation validation. |
| `DownloadStore.swift:4458`, `:4460` | Retry Recovery's `stagingInventory` directory read is invoked inside `lock.withLock`. | Compute inventory off-lock before installing it. |
| `DownloadStore.swift:4478`, `:4490` | Legacy rating-key checkpoint reset stats the stable file while locked. | No mapped production caller uses this overload; keep any retained fixture adapter DEBUG-only or route touched tests to the attempt-keyed submission. |
| `DownloadStore.swift:4807`, `:4816`, `:4823`, `:4877`, `:4889`, `:4893` | Exact-attempt durable checkpoint/recovery-evidence stat/existence. | Snapshot and observe off-lock; validate results before use for mutation/work. |
| `DownloadStore.swift:5158`, `:5178`, `:5191`, `:5199` | Lifecycle facts stat working bytes, resume existence and published existence under lock. Called by normal submissions and inside reconcile's outer lock. | Separate immutable row facts from filesystem observations; capture a process mutation generation and validate before reduction. |
| `DownloadStore.swift:5396`, `:5403`, `:5407` | Condemned-body rename; removal fallback on rename error. | Serialize with actual range writers, retain condemned fence, do I/O off-lock with a path reservation. |
| `DownloadStore.swift:5467`, `:5487`, `:5490`, `:5507`, `:5512`, `:5552`, `:5562`, `:5563` | Reconcile gathers stat/file identities under lock, waits off-lock, then **re-takes the lock** for identity stat and deletion. | Off-lock observation and cleanup, with reservations plus owner/lifecycle/file-identity checks. The historical comment that reconcile I/O moved off-lock does not describe this final loop. |
| `DownloadStore.swift:5822`, `:5883` | Load normalizes rows and removes retired side assets while locked. | Normalize from immutable decoded values; publish rows under lock; reserve and retire unreferenced safe paths off-lock after admission is proven. No blocking load-time normalization persist. |

Already-off-lock work to preserve: index encode/commit on the revisioned writer; prepared/terminal artifact workers; the submitted checkpoint's clone/stat path; most resume replacement/clear workers; row-deletion file operations; side-asset hydration's size scan. Cleanup journals have their own lock/durability domain; inspection found no current journal file operation to move out of the store lock. Their worker-private waits do not automatically block the MainActor, but a caller must not wait on those workers synchronously. Startup classification/directory protection and the audit scan also run outside the store lock; they can still be synchronous callers' disk work. Do not claim this PR removes every synchronous filesystem syscall in the app.

### P6.1 Contract and red pins — lead, committed first

**Owned files:** `Core/DownloadStore.swift`, `Core/RevisionedPersistenceWriter.swift`, `Core/DownloadArtifactLifecycleCoordinator.swift`, the existing `Core/Download*Filesystem.swift` seams only as needed, and the lead's new P6 test files. The delegate can author its new test file concurrently, but waits for this contract before modifying session call sites.

1. Keep the lock-owning store; it has cheap exact-attempt **submit** operations and bounded asynchronous **resolve** operations. No conversion of the store to an actor.
2. Agree the overload signatures for mutation, resume, artifact, promotion, checkpoint, row deletion, compare-clear and seed/replacement outcomes. Inputs carry the exact ticket/epoch and a monotonic deadline or remaining timeout; results retain the current typed success/stale/failure distinctions. Timeout is an existing `PersistenceFlushResult.timedOut` where the result already embeds it; artifact resolutions use their typed timed-out result. Never translate timeout or a discarded result into `.applied`/`.removed`.
3. Use the existing bounded writer flush and add an exact-ticket bounded lifecycle wait. Do not replace exact ticket outcomes with a watermark-only success: unrelated earlier failures and later retry outcomes must not be misattributed.
4. Async resolvers release the executor while waiting. Keep worker-private blocking implementation details where necessary, but make the production facade unable to call them synchronously. Do not delete `RevisionedPersistenceWriter.waitSynchronouslyForOutcome` while artifact workers still need it; confine/document it as worker-only. Full waiter/continuation machinery is unnecessary for this PR.
5. Agreement includes async worker adapters for seed/replacement, re-probe and reconcile, and completion adapters where session APIs must remain callback-based. The immutable submitted snapshot's schema version and revision remain captured under the lock.
6. Do not change side effects into fire-and-forget work. Submission only proves acceptance. Commit-before-network, commit-before-artifact deletion, cleanup absence proofs, and season compensation remain real barriers.
7. Test scaffolding may expand an existing filesystem seam enough to block `stat/read/rename/remove` deterministically. Defer a universal `DurableFS` rewrite. No new persisted artifact operation/phase, lifecycle value or envelope field is introduced in P6.

**Exit:** documented callback/result signatures and behavioural red pins are reviewable before either implementation lane depends on them.

#### P6.1 implementation handoff (2026-10-17)

P6.1 freezes additive interfaces and executable red evidence only. Existing production call sites,
blocking waits, lock-held filesystem work, and wake-release behavior remain for P6.2/P6.3/P6.4.
The deadline overloads are explicitly documented **compatibility adapters**: they compile and
preserve current typed results but do not yet enforce expiry. Do not migrate a caller and claim
bounded waiting until its owning phase replaces the adapter. No persisted field or filename changes.

Contract locations (all under `Labstream/Capabilities/Downloads/Core/`):

- `DownloadStoreAsyncContract.swift`: monotonic `DownloadStoreDeadline`; exact-epoch
  `DownloadStoreWork<Result>`; deadline-aware signatures for mutation, resume, artifact mutation,
  exact artifact ticket, promotion, checkpoint, row deletion, seed/replacement, compare-clear,
  lifecycle observation, re-probe and reconcile. Existing `submit*` methods remain the submitted
  revision/ticket authority. `DownloadStoreCallback.resolve(returningOn:operation:completion:)`
  adapts every result family back onto the session's existing serial queue. Timeouts must use
  typed persistence failure, artifact `.timedOut`, or the observation's epoch-tagged timeout;
  timeout must never become stale, success, cancellation or implicit lease release.
- `DownloadPathLease.swift` and `DownloadStore.tryAcquirePathLease`, `acquirePathLease`,
  `releasePathLease`: reserve every source/destination against the **existing** artifact path
  reservation table. Exact lease release is idempotent. Physical completion owns release,
  independently of persistence-waiter expiry. Session append joins in P6.4; side-cache writes and
  remaining store I/O join in P6.3. No session/range lock may be held while acquiring a lease;
  capture/revalidate owner, source generation and file identity before the actual syscall.
- `DownloadWakeBudgetContract.swift`: registry receipt instants, wake/operation identity,
  25/20/5-second injectable budget, captured persistence boundary, the three-part normal-release
  predicate, startup-generation notification signatures, timer registration and terminal-claim
  acknowledgement hooks. `BackgroundDownloadWakeCoordinator` exposes identified begin/end and
  receipt adapters. Its injected timers currently acknowledge scheduling only; timer callbacks
  intentionally preserve the old behavior. P6.4 supplies expiry and terminal acknowledgement.
- `DownloadStoreFilesystem.swift`: narrow stat/read/copy/rename/remove/enumeration scheduling
  hooks and removal/rename fault injection. Existing protection, backup exclusion, sync and
  persistence ordering are unchanged. Session append's hook sits after handles are opened and
  before seek/write, so held-append tests cover the physical I/O section. Artifact resolution
  exposes a pre-consumption hold; store submission exposes a DEBUG acknowledgement.

Lead owns the store contract, filesystem/lease implementation and lead pins. Delegate owns the
wake contract/receivers, session append participation and the dedicated
`P6BackgroundWakeTests.swift` / `P6PathLeaseTests.swift`; it does not edit lead test files.
`P6TestSupport.swift` is shared fixture scaffolding; coordinate any edits there first.

Red evidence is recorded by executing real entry points with `withKnownIssue("P6 red pin: …")`.
An annotation becomes an unexpected-pass failure when its issue disappears; remove that annotation
with its fix. The manager suite is additionally `.disabled("P6 red pin: P6.2 …")` after its isolated
red run, so deliberate MainActor holds cannot interfere with unrelated hosted tests; remove that
suite trait to reproduce its two functions / five cases (five expected known issues). Dedicated semaphore readers and independent cleanup releases bound broken runs.
The green lease-lifetime seam test is separate from the red pins. Duplicate-file conservation,
exact-token idempotence, retained checkpoint bytes and replay assertions are green companions,
not claims of additional regressions.

| Pin | Fix owner / test file | Observed red assertion |
|---|---|---|
| 01 | Lead P6.2; `P6ManagerPersistenceTests` | MainActor acknowledgement cannot run while lifecycle commit is held, including commit failure and successor installation; a held lifecycle stat also blocks a manager heartbeat. |
| 02 | Lead P6.3; `P6StoreResolutionTests`, `P6ArtifactRetryTests` | All eight facade families ignore the supplied deadline. Delayed promotion A reads B's success; delayed checkpoint A reads B's later result and consumes B's slot. A registered exact waiter loses its failure after 600 retirements exceed the 512 cap. Late physical commit and checkpoint-result cleanup are retained controls. |
| 03 | Lead P6.3; `P6StoreIOTests` | A held Retry copy blocks an independent lookup and competing Delete/replacement fence. The clone installs before that fence can linearize. Failed candidate commit retains the original checkpoint bytes (green). |
| 04 | Lead P6.3; `P6StoreIOTests` | Independent lookup blocks for all seven held operations: blob read, lifecycle stat, side publication rename, condemned rename, fallback removal, staging enumeration and staging removal. |
| 05 | Lead P6.3; `P6ReconcileCleanupTests` | Successful cleanup leaves the durable resume reference; a second row's reference does not protect the blob; held failing cleanup blocks lookup. Injected removal failure retains bytes/references (green). |
| 06 | Delegate P6.4; `P6BackgroundWakeTests` | Late and pre-registration handlers remain pending after terminal startup failure (zero deliveries); no transport was constructed. Exact-token duplicate drain still fires once (green). |
| 07 | Delegate P6.4; `P6BackgroundWakeTests` | Operation/grace expiry leaves handlers pending; A's stale/duplicate identified end consumes B's anonymous hold. Rearmed grace rejects A's stale generation (green). |
| 08 | Delegate P6.4; `P6BackgroundWakeTests` | Balanced work, a blocked append after successful flush, absent finish-events, and an already-running slow index flush outlive the absolute deadline. Replaying a receipt at second 10 schedules second 35 rather than 25; a second-24 operation schedules 44 rather than the wake cap 25. |
| 09 | Delegate P6.4; `P6BackgroundWakeTests` | A physically active body keeps the original OS token beyond expiry and has no terminal timeout acknowledgement. Attempt/body claim, committed three-byte checkpoint and pending resume-artifact replay survive (green). |
| 10 | Lead P6.3; `P6StoreLoadSafetyTests` | Only the source guard is red: `load` still contains the unique-key trapping initializer. Same/different-attempt v4/v5 duplicate fixtures remain wholly blocked, unchanged and repairable (green). |
| 11 | Lead P6.3; `P6ArtifactRetryTests` | 600 failed retries of one intent leave 600 live entries; an unrelated row commit increases artifact attempts from one to two. |
| 12 | Lead P6.3; `P6StoreInventoryTests`, shared `OfflineDownloadFileInventoryTests` | Audit omits hidden/infrastructure bytes and working/pending-promotion authority; the classifier rejects the existing hidden staging grammar. Held/generation-resume references and report-only/no-foreign-sweep assertions are retained. |
| Amendment 3 | Delegate append / lead Retry-reconcile; `P6PathLeaseTests` | A lease is granted while append has an open writer. Retry clones three bytes before the fourth is appended; paused non-resumable reconcile removes the active destination. A timed-out lease waiter must leave the physical writer's exclusion installed. |

Focused red run: 27 Swift Testing functions / 50 cases, 70 expected known issues and zero
unexpected failures before the final contract documentation pass. The package classifier adds a
separate expected known issue. Final checks: PMSKit 1,615 tests with one expected known issue;
Mac host 66 XCTest tests plus 820 Swift Testing tests with 65 expected known issues and the two
manager functions disabled; isolated manager run two functions / five cases with five expected
known issues. After strengthening pin 11 to retry the real durable store head and observing its
worker without invoking another recovery trigger, the four affected test functions passed with
seven expected known issues. Repository hygiene passed 386 tooling tests plus strict docs/link/
Mermaid and public-redaction checks. No simulator was booted. P6 does not claim hardware wake
timing or background continuation.

### P6.2 Nonblocking manager callers — lead

**Owned files:** all `Core/DownloadManager*.swift`, lead P6 tests and touched existing store/manager tests. The delegate never edits these files.

- Replace `applyLifecycleEvent` and its server-prep/failure adapters with submit plus bounded async resolve; migrate their full call graph in the map. Already-async starts await them. Synchronous UI/callback entries capture exact authority, install immediate pause/delete/admission fences, and schedule a continuation using the existing ordered coordinator pattern; they return without waiting for disk.
- Preserve order for same-attempt actions; unrelated rows may continue. Do not let a new `Task` reorder Pause, Resume, Retry, Delete or same-attempt metadata updates. Do not put an immediate Delete/halt fence behind an older persistence waiter.
- At **every new suspension**, check the exact attempt, start-chain generation/reservation, delete/capsule barrier, and relevant source or train generation before external work. An in-memory `.applied` revision can be superseded while awaiting; commit success never re-authorizes an obsolete start. Cleanup compares both attempt and exact expected server handle.
- Migrate seed/create, metadata, PlaySession set/compare-clear and resume clear callers in the map. Keep retired side-asset cleanup after the corresponding successful durability proof; replacing `updateMetadata` with bare `submitMetadata` alone loses that behaviour.
- Run Retry Recovery's filesystem re-probe on a worker; apply the result only for the current startup-recovery generation. Preserve manual retry, transient retry limits and the separate season-indeterminate reason. Do not construct transport before current admission.
- Keep `persistPlannedSeeds`' existing detached transaction and `seasonPlanCommitsInFlight` barrier. Its internal wait is not currently a main-thread stall. Preserve exact candidate-byte proofs, conditional rollback and in-process indeterminate recovery; do not gratuitously rebuild the season transaction around the new facade.
- Move playback position/unverified persistence onto the same ordered asynchronous machinery. **Only remove blocking here.** Keep current public calls and semantics; P7 still owns binding the sink to the actual playing attempt and requiring observed playback (B73–B75). Record B76's persistence-mechanism portion as fixed, not all playback bugs.
- Remove the production synchronous store facades once no mapped production caller uses them. Port touched tests to submit/resolve; untouched fixture shims may stay DEBUG-only. A final call-site search must include backend and side-cache extensions, not just `DownloadManager.swift`.

**Exit:** pin 01 passes; held index I/O does not stop MainActor handling; no dependent start happens before proof or after its authority was withdrawn.

### P6.3 Filesystem outside the lock and targeted store safety — lead

**Owned files:** store/writer/artifact coordinator and existing filesystem seams; `PMSKit/Sources/PMSKit/Downloads/OfflineDownloadFileInventory.swift` and its tests; lead P6 tests. The delegate consumes these APIs without editing their implementation.

#### Observation and reservations

- Make locked sections read/mutate in-memory values and submit snapshots only. Capture exact owner, path set, source identity, lifecycle and an in-process row mutation generation; observe files outside the lock; compare before using observations to mutate. Increment the generation at every relevant mutation. Generation is in memory, not a new v5 field.
- A filesystem snapshot is not deletion permission. Reserve paths against publication/adoption and serialize with **actual range writes**, which occur outside the store lock already. Check file identity on the worker immediately before destructive I/O. All writers that could reuse the path must respect the reservation or be fenced/serialized by the session's existing per-attempt range queue. Keep lock order consistent; never await a range queue or journal while holding the store lock.
- Extend the existing path-reservation system, rather than adding a second generic transaction engine. Reject unsafe one-level paths before any I/O; use `artifactPathsReferenced(by:)` for cross-row protection, including pending intents, resume/held manifests, staging and side assets. A manifest-only reference set is insufficient.
- Retry checkpoint handoff reserves the exact old source and new attempt-private destination, copies on a worker using the existing durable-copy seam, then compare-and-swaps the captured old owner. Keep the source until the successor snapshot is proven committed. A failed/ambiguous candidate cannot delete that source. Release reservations on every outcome, and never let a stale copy retire a newer body's path.
- Side-asset rename must reserve both source and destination while retaining exact source-generation authority. A same-attempt source change cancels the old publication logically; retirement cleans its obsolete result without deleting the new source's bundle. Preserve hydration-cache invalidation.
- For lifecycle facts/reconcile, do not apply a reducer decision based on stale filesystem observations after a row mutation. Retry a bounded number of times, then defer to the next recovery edge; do not spin under heavy progress.

#### Reconcile (B20 and the remaining st-41 work)

1. Snapshot eligible rows; skip capsules, row-deletion barriers and pending artifact heads as today. Collect bytes/existence/file identities on a worker. Revalidate row generation before applying `relaunchObserved` and submitting the demotion snapshot.
2. Resolve demotion off the caller executor. On failed/timeout proof, keep files and recovery references. Preserve the current same-attempt lifecycle/file-identity checks; a new failed-row body with the same owner must survive.
3. Reserve destructive paths after proof, checking other rows' **complete** artifact references and coordinating with live range writers. Perform stat/rename/remove off-lock. A replacement, changed identity, or conflicting reference causes conservative deferral, not deletion.
4. Use existing resume-clear lifecycle submission for blob retirement, so clearing references and deleting the blob retains the existing durable intent/replay protocol. Do not manually unlink a blob and leave its manifest live. Clear display bytes only when the matching authority is retired.
5. For a non-resumable working body, keep the condemned-body identity/fencing model and remove it off-lock. Do not reinterpret a partial as a complete body, convert failed rows into user-paused rows, or expose the stable path as a nonterminal checkpoint.
6. **Bounded claim:** this closes lock-held I/O, stale resume references and cross-row deletion hazards in B20. A new universal durable reconcile-effect recipe is deferred below. If a working-body cleanup cannot complete, retain the row/path authority for Retry/Delete and report a deferred cleanup; do not claim guaranteed replay of every abandoned working-body deletion.

#### Inventory and audit (B19)

- Enumerate hidden files for the report. Count every regular file once, while explicitly separating index/infrastructure/temp bytes from media candidates. Reference `artifactPathsReferenced(by:)`, not only published media and metadata. Include pending promotion, deletion, clear and checkpoint-temp paths.
- Teach the shared pure inventory/name classifier the **existing** staging grammar (`.attempt-stage-v1-<64 lowercase hex>.stage`) and existing generation/temp forms needed by the audit; keep filenames byte-for-byte compatible. The classifier describes ownership, not permission to delete.
- Startup deletion stays conservative: only recognized staging entries inventoried at this Store's initialization, still unreferenced and unclaimed at reservation time, are eligible. Include file identity when practical so a replacement at an old pathname is not mistaken for the old orphan. Do not broaden this into stable-media or foreign-file deletion.
- Reattach's held-body sweep keeps P5's claim protection and startup-inventory constraint. Add named st-23 coverage if edits touch that sweep; current-process new files and queued appends survive. Never delete CFNetwork temp files.
- Keep the audit report-only. This plan requires no settings redesign, new dashboard or profiling baseline.

#### Duplicate load and failed artifact epochs

- B84: preserve `classifyIndex`'s current whole-index duplicate rejection. Replace the unique-key initializer in `load` with checked insertion that can return failure before publishing any partially built dictionary or normalization side effects. Reuse the unreadable/block path; no new persisted reason or arbitrary first/last-wins salvage policy. Use the exact probed bytes (B15), including Retry Recovery. The duplicate fixtures are conservation gates, not proof of a new startup crash.
- B17: on retry registration, supersede the previous **failed** epoch for the same intent in the live coordinator table; retain exact results for registered waiters and the existing capped retired history. Current retryable intents still gate boundaries; unrelated failures remain visible. Do not abandon durable cleanup authority to make a boundary green.
- Stop a permanent artifact I/O failure from being retried by every unrelated successful snapshot. Retry triggers are explicit startup/recovery, an explicit same-row successor, or resolution of that intent's previously failed prepared persistence revision. Track the trigger/attempt epoch so the terminal write of another row is not another retry opportunity. Preserve the existing same-process failed-head/successor recovery tests.
- Leave the broader typed-ticket/retired-result API redesign deferred. This change targets live-table growth and retry churn, with the existing 512 history policy preserved and live waiters never silently losing their outcome.

**Exit:** pins 02–05 and 10–12 pass; the mapped production filesystem operations execute outside the store lock; copy/retire failure paths conserve ownership and bytes.

### P6.4 Identified operations and a bounded wake — delegate, parallel with P6.2/P6.3

**Owned files:** `Core/BackgroundDownloadSession.swift`, `Core/BackgroundDownloadWakeCoordinator.swift`, `Core/BackgroundDownloadCompletionRegistry.swift`, `Core/BackgroundCompletionPersistenceBarrier.swift`, `PMSKit/Sources/PMSKit/Downloads/BackgroundDownloadCompletionGate.swift`, and only their wake/registry/gate/P6 session tests. The lead does not edit these files during this lane.

#### Startup distinctions (B06)

- Remember whether startup is (a) not yet attempted/deferred, (b) actively purging/activating, (c) blocked before transport construction, or (d) failed after transport construction with healthy owned callbacks still possible. Dormant alone cannot distinguish these cases.
- Publish blocked/failed state to the registry/session even if no token exists yet. A late handler in terminal pre-construction blocked state takes the explicit failed-startup release path immediately, without constructing or reattaching URLSession. A handler stored before registration retains its arrival time and is handled when the session registers, or by registry fallback if registration never occurs.
- Initial deferred activation can still progress normally. A runtime season-indeterminate block while the session is active/purging must preserve live operations and grace (B05). Post-construction failure uses owned-callback drain plus the whole-wake deadline (B07), not `abortAwaitingHandlers`.
- Manager startup notifications and signatures are part of P6.1; lead implements manager calls, delegate implements receivers. No cross-file edits between owners.

#### Operation handles (B13)

- `beginOperation` returns an opaque handle with unique sequence, wake/generation membership, start instant and a bounded diagnostic kind (append, held-lifecycle, finalization, delayed retry, grace). End requires that exact handle and is idempotent; old ends cannot decrement new work.
- Capture handles at every mapped begin/end pair, including nested lifecycle holds and delayed retry closures. Grace rearm keeps one hold, advances only its timer generation, and remains exact-attempt/train fenced.
- Separate **wake waiting** from **physical work ownership**. Expiring an operation ends its permission to hold an OS completion indefinitely; it does not remove a pending-range-work count, drop a stash claim, declare an artifact durable, cancel arbitrary tasks, or authorize a replacement writer.
- Use a **20-second** per-operation watchdog capped by the owning wake deadline; existing 20-second grace remains generation-fenced. Expiry begins the remaining-budget durability/release path. Operations begun without a handler must still have handles; a subsequently arriving wake observes outstanding work. Expired handles remain physically owned until their real completion, and cannot become new anonymous holds through a stale callback.

#### One absolute budget (B82)

- Choose explicit application constants for this PR: **25 seconds from the first handler's registry receipt**, with the final **up to 5 seconds reserved for persistence**. These are engineering bounds, not a claim that every Apple OS grants 25 seconds. Inject clock and durations in tests.
- Additional handlers, operations, grace rearms, retries and successive balanced completions do **not** slide an open wake's deadline. A new generation is created only after the previous exact token set has been handed off for release. A later handler must not be swept into an already-claimed normal-release batch.
- Begin the drain/flush at `deadline - min(5 seconds, remaining)`; normal early finish may flush sooner. Once winding down, defer new optional validation, side-asset repair and range-refill work; already admitted URLSession tasks may remain daemon-owned. Do not restart a paused row or revoke an independently healthy foreground transfer merely to meet a wake timer.
- Track release ownership through awaiting events, deferred operations **and flushing** until delivery is acknowledged. Starting a normal flush must not remove tokens from deadline supervision. At deadline, claim remaining original tokens once; registry token drains make races with normal completion idempotent. Missing finish-events is explicitly covered.
- Capture the exact index revision and artifact watermark for a normal flush; run index/lifecycle flush concurrently using **remaining** time. If new required durable work arrives, supervise it under the same deadline, not a fresh budget. At hard expiry, fire/claim the batch without adding another flush interval.
- Do not implement the deadline by racing structured child tasks whose scope then waits for a stuck child. A timer/release lease must be able to reach its terminal release state independently of an ongoing append or blocked filesystem syscall. Expiring a waiter does not cancel the commit already in progress.
- A hard expiry is observable as `timed_out`/unfinished, never as committed drain. Keep dirty snapshots, durable intents and all physical worker ownership. Prefer the existing durable held-body handoff before a costly append when its protocol permits it; do not load bodies into memory or invent a new v5 intent to meet the timer.
- **Limit stated explicitly:** no design can both guarantee a finite callback deadline and guarantee a hung filesystem has completed durability. On timeout, preserve committed checkpoints and recovery authority, retain uncommitted bodies conservatively, and allow later recovery/refetch of an uncommitted tail. Never delete or bless it as durable merely to release the handler. This is the same failure class already represented by the bounded persistence barrier, extended to the whole wake.
- Release callbacks run on MainActor at the next available turn. The testable absolute bound is release eligibility/claim plus dispatch; OS scheduling or an independently wedged MainActor cannot be given a wall-clock callback guarantee. P6.2 removes the known persistence waits that would obstruct that turn.

#### Session persistence adapters

- Replace handler-presence-based synchronous resolves with submit plus bounded asynchronous continuations for both foreground and background contexts. Foreground task creation still waits for committed prerequisites; an OS completion may submit accepted work whose exact outcome is supervised by the wake barrier.
- Return completions onto the existing serialized `rangeIOQueue`; retain train epoch, exact attempt and halt checks immediately before append/publication/refill. Never block that queue waiting for work scheduled onto itself.
- Preserve O(1) temp ownership transfer during the URLSession delegate callback, before its temporary URL expires. Heavy copies, index waits, probes and late-body classification remain off delegate delivery.
- Keep no-probe-while-handler-pending (bg-37) and deferred revalidation's exactly-once drain. A timed-out wake must not immediately schedule a foreground probe while the scene remains inactive; resume it on the next authorized foreground edge.
- Emit one bounded diagnostic per deadline/expired operation with reason, operation kinds/counts, pending bytes where already known, elapsed time and persistence outcome. No titles, paths, URLs, tokens or full per-body event stream. Do not add a separate telemetry project.

**Exit:** pins 06–09 pass through real registry/session wiring as well as the pure gate, including handler reentrancy during release and old-completion/new-wake races.

### P6.5 Integration, documentation and one combined gate — lead

**Owned files:** lead test files and the canonical overhaul plan/testing documentation. Delegate makes any corrections in its own files; no simultaneous edits to shared files.

1. Integrate after both lanes pass focused checks. Search for production `resolve*Synchronously`, blocking wrapper calls, and `waitSynchronously` escaping worker/test scope; use the map above as the checklist. Inspect locking paths for indirect `fileSize`, `resolvedDownloadAssetURL`, journal calls and `Darwin` calls, not only `FileManager` spelling.
2. Re-run the red pins and the retained cases below on the combined result. Do not run a second competing matrix while the current checkout's matrix is active. This drafting task starts no verification processes.
3. For the future implementation PR, use the canonical CLAUDE.md gates once: hermetic PMSKit (`swift test --package-path PMSKit --no-parallel --skip 'Live.*ProbeTests'`), relevant hosted app tests, `scripts/native-test-matrix.py affected`, strict docs build/link/Mermaid checks and `scripts/ci-hygiene.sh`, clean native visionOS/iOS/macOS/tvOS builds, then serialized appropriate app smokes. tvOS must still compile without Downloads. Let the maintainer's matrix own build/simulator scheduling; no duplicate performance suite.
4. Journal the exact fixed, partially fixed and deferred IDs. Correct stale inventory evidence: st-09 duplicate admission already blocks at this head, and st-41's final reconcile loop is again lock-held. B06/B13's Appendix A phase cells still say P5, but the later P5 field-report paragraph explicitly assigns them to P6.
5. State live Plex/Jellyfin/Emby and physical iPhone/iPad/Vision Pro sleep/lock/off-head wakes, plus Mac recovery, as open maintainer gates. Unit deadlines establish application logic, not OS/hardware acceptance. The build-1506 root cause remains unproven without the matching termination report.

#### Ownership and sequencing

| Sub-phase | Owner | Files / handoff | Can overlap |
|---|---|---|---|
| P6.1 | Lead | Store, writer, artifact coordinator, minimal store filesystem seams; lead pins. Freeze signatures before session migration. | Delegate may draft its isolated P6 wake tests. |
| P6.2 | Lead | Every `DownloadManager*.swift`; lead manager tests. | P6.4, once the contract is available. |
| P6.3 | Lead | Store internals, artifact coordinator/seams, pure file-inventory helper and tests; lead store tests. | P6.4. Lead sequences its own P6.2/P6.3 edits as needed. |
| P6.4 | Delegate | Session, wake coordinator, registry, barrier, pure completion gate and their dedicated tests. | P6.2/P6.3; no shared implementation files. |
| P6.5 | Lead | Integration evidence and canonical plan/checklist updates; fixes in delegate files go back to delegate. | Verification is serialized. |

No additional agent is needed to execute this plan. These are future implementation assignments, not permission to alter the checkout during this read-only design task.

#### Suggested commits within the one PR

1. Lead: contract/test hooks and pins; demonstrate behavioural reds before fixes.
2. Lead: asynchronous store facade and MainActor caller migration, preserving authority checks.
3. Lead: off-lock reservation/observation fixes, B20 cleanup, B19 audit, B84 checked load and B17 retry bounds. Keep reviewable commits if needed; still one PR.
4. Delegate: startup distinctions, identified operations, whole-wake deadline and session adapter migration against the contract.
5. Lead: integration corrections, updated coverage/deferred journal and the combined verification record.

### Deferred

Deferral is explicit scope, not a claim that the original row is fixed. Carry these into the canonical journal/backlog before merging P6; none requires a performance baseline to close this PR.

| Item / ID | Disposition and reason |
|---|---|
| Full store/facet file split, actor conversion, wholesale ownership reorganization | Behaviour-neutral and a large review/conflict surface. Keep the existing lock and worker design; split last only if later work benefits. |
| Universal `DurableFS` replacing every existing seam | Behaviour-neutral consolidation. Extend existing seams only where red ordering/lock tests require it. |
| Deleting all ~30 rating-key/test-only APIs and wholesale test porting; B29 dead ownerless-delete branch | B29 was refuted as a live defect. Remove blocking production uses now; broad API/fixture cleanup does not improve the prioritized failures. |
| Physical tombstone-engine deletion promised in P2.5 | Compatibility import/receipts and cleanup authority already work. Deletion is behaviour-neutral cleanup with rollback risk; preserve legacy reads and the authority domain. |
| Generic typed-ticket/result registry replacing all per-operation outcome maps (remaining §6/B17 design) | Keep exact typed outcomes and fix live failed-epoch growth now. A unified result system is a separate refactor and must not silently change retained-waiter semantics. |
| General stable-media/side-asset launch orphan deletion (st-39), and merging all sweep engines | st-39 is explicitly non-required/dropped-intentional. The report and startup staging sweep are sufficient here; widening deletion requires new liveness proofs. |
| Fully durable, generalized reconcile working-body effect recipes (remaining B20) | Off-lock I/O, complete reference fencing and durable resume clearing are in P6. A new persistent recipe would add rollback/schema obligations. Retain working-body recovery authority and defer failed cleanup conservatively. Do not report all of B20's structural redesign complete. |
| B27: preempting a wedged validated promotion / legacy promotion deletion refusal | Current normal promotion uses the artifact queue; row deletion can queue behind its head and failed-head retirement exists. The remaining explicit reject is `pendingValidatedPromotionStatus` at store 5611 (legacy). Preemption needs cancellation/safe-publication rules; preserve current queue and document the residual rather than adding them here. |
| B30: emergency Delete on a completely full volume | Durable prepared-intent creation can itself fail at store 5724 before bytes are removed. Safely freeing bytes first needs reserved journal capacity or an emergency deletion protocol; changing durability ordering to force a delete would threaten D1 and cleanup authority. Keep explicit storage/persistence failure and retry. |
| B83: a proven global memory ceiling for inherited completed bodies plus side assets | Disk append already reads at most 4 MiB per iteration (session 5874–5879), but this does not prove a process-wide memory ceiling or bound all queued closures/assets. Preserve streamed bodies, serial append and P4 caps; whole-backlog memory accounting/backpressure is a separate policy. Do not mark B83 fixed by the wake timer. |
| B85: eliminating/measuring append write amplification and MetricKit disk-write exceptions | `appendFile` (session 5846–5882) re-copies bodies in bounded chunks; a clock bound does not bound lifetime bytes written. Zero-copy/extent redesign and amplification instrumentation are not required for this correctness PR. No baseline is requested; B85 remains open. |
| P5 rebuild primitive, `RangeAttemptState` packaging, unified owned-work snapshot, DEBUG extraction | Behaviour-neutral consolidation. Keep P5's targeted train generations/claims/backoff; the new wake operation handles do not authorize a restart-engine rewrite. |
| Deleting the opaque resume-data fallback | Still used by legacy metadata-poor rows. Preserve it until a separate compatibility decision. |
| Paused-static finish-before-reattach finalization (P3/P5 carry-over) | Preserving a just-finished body and deciding it is a whole publishable file are different decisions. Keep write-then-pause; finalization needs its own complete-file pin and remains outside this PR. |
| Async store construction and UI-wide async lookup APIs; B79 launch availability stat caching | The prioritized disk waits and lock-held filesystem work are removed. Initial classification/protection and some off-lock metadata reads remain synchronous. An async factory/UI observation redesign is larger and B79 belongs to P7. State this residual rather than claiming zero synchronous disk access. |
| B73–B75 playback-observed promotion and exact playing-attempt sinks; remaining P7 presentation/negotiation | P6 only changes persistence scheduling at existing call sites. Keep the planned P7 ownership and UI work intact. |
| B16/B21 read-only offline surface redesign | Already implemented in P3; preserve recovery/read-only gates and the distinct season-indeterminate reason. P6 changes execution context only. |
| New schema/intent cases or downgrade migration redesign (st-42) | P6 must preserve v5 decoding. No new persisted enum cases; do not spend this PR on a generalized rollback protocol. |
| A build-1506 root-cause claim or benchmark/profile campaign | No matching termination signature was supplied. The watchdog/wake/ownership ranking motivates bounded fixes, not a diagnosis. No baseline is needed. |

### Bug and inventory disposition

#### Appendix A rows assigned to P6, plus promoted wake bugs

| ID | P6 disposition |
|---|---|
| B06 | Fix late blocked/dormant handler release with remembered startup state; preserve B05/B07 distinctions. |
| B13 | Fix anonymous leaked holds with operation handles and bounded wake waiting. |
| B17 | Fix repeated failed-epoch live-table growth and unrelated-commit retry churn; defer universal result-system refactor. |
| B19 | Fix hidden/pending artifact audit accounting; audit remains report-only. |
| B20 | Fix remaining lock-held reconcile I/O, stale resume authority and path reservation gaps; generalized durable working-body recipes explicitly deferred. |
| B27 | Residual legacy/promotion preemption deferred, with current queued Delete/failed-head handling preserved. |
| B29 | Refuted; dead-code removal deferred, no fabricated bug fix. |
| B30 | Emergency full-volume delete protocol deferred. |
| B82 | Fix aggregate deadline across handler arrival, operations, missing finish-events and flush. |
| B83 | Global inherited-backlog memory ceiling deferred; no whole-body reads introduced. |
| B84 | Remove trapping load initializer; retain already-existing duplicate admission block and exact-byte conservation. |
| B85 | Append amplification work deferred; no claim that deadlines solve write amplification. |

#### Appendix B store rows — preserve or deliberately change

| Rows | Contract / required gate |
|---|---|
| st-01, st-02 | Container-relative one-level paths; validate **all touched** read/destructive inputs including decoded legacy paths and pending intents. Reject separators, dot/dot-dot and unsafe locations before I/O. Add unsafe-path fixtures and require outside-root sentinel files unchanged. |
| st-03–st-07 | Existing protection/backup exclusion, external cleanup authority, byte-equality legacy journal import, two-empty-pass unsupported reset and asynchronous retired-root reclamation remain intact. No path reservation spans journal I/O. |
| st-08–st-11 | Keep current fail-closed admission: the codec can isolate bad elements, but a malformed current index is not silently salvaged/rewritten. Duplicate files block; malformed attempt ownership never gets guessed. Newer schemas remain untouched. |
| st-12–st-16 | Serialized full snapshots, captured revision/schema, obsolete-snapshot suppression, durable unique temp/full-sync/rename/parent-sync, dirty retry and exact ambiguous-write proofs survive async adaptation. Progress stays about one write/second; status transitions submit immediately. |
| st-17 | Normal handler release waits for index and lifecycle in one budget. Hard deadline release is explicitly an observable timeout, retaining dirty work; it is never called a successful durability boundary. |
| st-18–st-20 | Resume prepared intent/private generation names, promotion crash replay and exact-attempt hidden working paths retain their durability/ownership rules. Bound waiters without killing worker authority. |
| st-21, st-23 | Existing-at-init staging eligibility plus current references/claims; held-body sweep never steals a new/unmanifested writer's path. Add named coverage for touched st-23. |
| st-22, st-24–st-27 | Held manifest/deletion durability; row-deletion terminal barrier; joined exact-epoch waiters; cleanup capsule; unreadable journals are never empty; canonical-byte/element-quarantine proofs remain. Failure or timeout does not release cleanup ownership or bless deletion. |
| st-28–st-31, st-41 | Although tagged P3a, P6 touches these reconcile paths. Preserve missing terminal-body failure, app partial before blob, missing-blob nonresumability, pending-intent skip, Plex-prep queueing, live static ownership and JF/Emby forward-only failure. Move I/O outside the lock with conservative stale-observation deferral. |
| st-32, st-33 | Retain adoption of legacy ownerless side bundles **with** a known attempt, rejection/retirement of mismatched bundles, and prepared-static lane normalization. Normalization must not stamp a pre-migration schema or delete bytes while admission is blocked. |
| st-34 | Atomic season barrier, exact retries, conditional compensation and indeterminate block remain; this is not a new reservation/admission redesign. |
| st-35 | Full cross-row path protection, including different artifact kinds and paths referenced only in pending intents, remains mandatory after unlocking. Reservation must close adoption between check and I/O. |
| st-36, st-37 | Durable filesystem bytes alone establish a checkpoint. Complete/unverified audits use the published file; nonterminal resumes use the private working file. A Retry's old body survives until new owner durability, and truncated/condemned bodies are never cloned. |
| st-38, st-39 | Restore report-only byte visibility including hidden files; do not introduce general stable-file deletion. |
| st-40 | Live lifecycle bookkeeping bounded by current work/intents, retired unclaimed history capped at 512. Joined/registered waiters retain their own failure epoch; supersession cannot report another epoch's success. |
| st-42, st-43 | No new persisted cases; retain the existing rollback boundary and Application Support-to-temporary-directory fallback. Do not turn fallback into a destructive reset. |

### Risks and edge cases to preserve

1. **D1 means “keep partials only,” in its final maintainer refinement.** Keep `complete`, `unverified` and every **paused static-range** row, including zero-byte checkpoints. Drop other upgrade candidates through the existing Delete barrier/capsule path; preserve the legacy-promotion rescue and rows already being deleted. Do not implement the earlier contradictory prose that dropped all paused rows. No await may expose `.ready` before the existing migration fences are installed.
2. **v4/v5 compatibility is byte-shape compatibility, not just a version integer.** Keep admissible 4...5, the existing row/envelope shape, existing Codable intent cases, existing filename grammar, and per-snapshot schema capture. Preserve v4 writes until stamp and v5 writes thereafter. A newer/unreadable/duplicate index stays untouched, including during failed Retry Recovery.
3. **Await reentrancy:** source/owner/queue admission can change while a commit resolves. Pause/delete remain immediate fences; callbacks and starts recheck exact authority at their final side-effect boundary. A wake operation ID does not replace the attempt or train epoch.
4. **Off-lock TOCTOU:** a lock check followed by an unreserved unlink/rename is not safe. All adopters and actual file writers must respect reservations; file identity alone is insufficient if it can change again before the syscall. Avoid store/session lock inversion and range-queue self-waits.
5. **Timeout is not cancellation or rollback:** a write/copy already in progress may finish later. Keep original intent/epoch, dirty state and bodies; stale continuations cannot retire successors. Never compensate ambiguous season success before exact canonical proof.
6. **Whole-wake timeout is not successful drain:** committed partials are protected; uncommitted body tails can require recovery/refetch after OS suspension. Do not force a shared physical worker free, start overlapping appends or run an AVPlayer probe while inactive. Normal release still honors durable work.
7. **Handler cardinality:** late handlers, pre-registration handlers, same-identifier reentrancy, identifier independence, already-flushing batches, absent finish-events, post-construction failure and subsequent Retry Recovery must all release exact tokens once. Old ends/timers cannot affect new holds.
8. **Low storage/protected data:** preserve ENOSPC failures, checkpoint/blob retention and manual retry; unreadable journals/indexes are not empty. Emergency delete remains explicitly unresolved. Parent sync/protection/backup exclusion cannot be dropped to speed the path.
9. **Filesystem evidence:** static checkpoints precede blobs; optimistic URLSession bytes never set resume offsets. Hidden staging, held bodies, publication sources, condemned bodies and index temps remain distinct. Audit never authorizes a deletion by itself.
10. **Migration/legacy scope:** do not erase server obligations, tombstone receipts or cleanup capsules; do not remove metadata-poor opaque compatibility paths. Reconcile must not demote a body behind pending validated promotion.
11. **Bounded claims:** a 4 MiB copy buffer and P4's start caps do not prove B83, bound inherited OS task count or close B85. A fake-clock unit test does not prove background continuation on hardware, and no P6 evidence establishes the build-1506 termination cause.

**P6 acceptance:** the new red pins pass; mapped production synchronous persistence facades are gone; mapped store filesystem I/O runs outside the lock with ownership preserved; every wake has an exact-token, non-sliding deadline; duplicate input cannot reach a trapping loader; D1/v5 regression gates stay green; and all deferred/open acceptance rows are journaled before moving to P7.

### Revision 2 amendments (co-review round 1: approve with changes)

These amendments bind the plan above. Where they conflict with it, they win.

1. **Epoch-safe store results (P6.1/P6.3).** Promotion and checkpoint outcomes are currently
   consumed by `intentID` (`DownloadStore.swift` ~1226, ~4617), so retry B can overwrite the slot
   before the delayed resolver for attempt A reads it. P6 retains results keyed by epoch for those
   two paths; the generic registry stays deferred.
   - **Pin 02 extended:** hold A's resolver, fail A, retry the same intent successfully as B,
     resolve both. A sees its own failure.
   - Also cover timeout cleanup, and registered waiters across the 512-entry retirement cap.
2. **Nonblocking lifecycle submission itself (P6.1/P6.2, pin 01).** `submitLifecycleEvent` calls
   `lifecycleFacts` (stat and existence work) before it returns.
   - Events that do not consume filesystem facts derive them from memory.
   - Events that need disk facts go through a worker observation adapter.
   - Immediate Pause and Delete fences stay synchronous.
   - **New pin:** a manager heartbeat survives while a lifecycle stat is held.
3. **Path-lease contract frozen in P6.1.** Store reservations do not cover the session's
   `appendFile` (`BackgroundDownloadSession.swift` ~5850) or the side-cache staging writers.
   P6.1 freezes a path-lease/serialization API next to the persistence signatures.
   - The delegate makes the session's append participate.
   - The lead makes the side-cache writers participate.
   - **New pin:** a held append against a Retry/reconcile proves the exclusion lasts through the
     actual syscall, including after a waiter has timed out.
4. **Release predicate for the wake budget (P6.4, pins 08–09).**
   - A normal release requires all three of:
     - finish-events;
     - every required operation settled;
     - persistence proof that covers those operations' resulting boundary.
   - A proactive flush may cache proof, but it cannot satisfy the other conditions.
   - Expiry with unfinished work is a timeout outcome even if the captured flush committed.
   - **New fake-clock cases:**
     - the flush succeeds while an append is still blocked;
     - finish-events never arrives.
   - The original absolute deadline is kept.
   - Timer registration and terminal-state acknowledgement are exposed, so clock advances follow
     confirmed production scheduling.
5. **B84 keeps whole-index blocking.** It does not guess a winner between duplicate rows.
   B83/B85, the structural splits, tombstone removal and the broad API cleanup stay deferred.

### P6.2/P6.3 implementation journal (2026-10-17)

Lead lane, based on the frozen P6.1 handoff. Manager lifecycle/seed/metadata/PlaySession,
playback-position and recovery callers now submit work and await bounded proof. Synchronous
Pause and Delete still install their halt/admission fences immediately; same-row continuations
are ordered, and start, poller, source and exact-handle authority are checked again after waits.
Season-plan persistence keeps its existing detached transaction. B76's persistence mechanism is
fixed; playback binding and observed-playback semantics remain P7.

Store observations copy row authority and an in-memory mutation generation before off-lock I/O.
Retry reserves the predecessor and private successor paths, uses the existing durable-copy seam,
then compares the captured generation before publishing. Failed/ambiguous commits retain the
source. Side-cache writers/publication, condemned bodies, startup staging and reconcile cleanup
participate in path reservations; expiration never releases a physical writer's lease. A current-
source rename remains an in-memory reference until metadata catches up, so delayed retirement
cannot remove the new bundle. Same-attempt staging cleanup defers rather than unlinking a newer
source's deterministic staging path. Reconcile
uses the durable resume-clear recipe instead of unlinking behind a live reference, retains failed
cleanup authority and protects other rows' complete artifact references (B20/st-41).

Typed resolvers preserve absolute deadlines and return timeout without cancelling physical work.
Promotion/checkpoint/deletion results use complete ticket epochs. Registered exact artifact
waiters retain failures outside the capped 512-entry unclaimed history; repeated failed retries
supersede old live entries. Generic index success retries only a head whose failed prepared
revision has since committed, rather than restarting permanent artifact I/O failures (B17).

The report-only audit includes hidden, infrastructure, working, held, resume and pending-intent
paths, recognizes the existing hidden staging grammar and accounts for every regular file once
(B19). Startup staging deletion remains limited to the initialization inventory and matching file
identity. Load performs checked insertion before normalization; duplicate rows still block the
whole index, conserve the exact bytes/files and never select a winner (B84/st-09).

Lead pins 01–05 and 10–12 have their known-issue/disabled markers removed. Independent store
lease coverage proves Retry/reconcile exclusion through physical completion; the original shared
append integration assertions remain annotated for the delegate's session lease participation.
No persisted fields, lifecycle values, filename grammar, D1 migration policy or v5 schema changed.
Frozen store/lease/wake signatures remain available; async convenience methods and typed worker
timeout handling are additive. Legacy synchronous worker/fixture adapters remain isolated from
mapped manager callers; delegate-owned callers are outside this lane.

Validation: hermetic PMSKit passed **1,616 tests** with no expected issues. The full
`LabstreamMacTests` plan passed **899 tests**: **889 passed, 10 expected delegate-owned
failures, zero unexpected failures and zero skips**. This was a clean build using worktree-local
DerivedData and `-parallel-testing-enabled NO`; the terminal Xcode result and readable
`build/p6-closeout.xcresult` both report success. Earlier parallel runs intermittently exceeded
fixture startup/read scheduling deadlines. Fixture fixes use explicit admission/registration
acknowledgements, preserve a safe one-level path, and return captured recovery ticket epochs
instead of resampling a live map that a fast worker may already have retired.

Repository hygiene passed **386 tooling tests** plus strict documentation, link, Mermaid and
public-redaction checks. No simulator was booted. Physical-device, live-backend, wake-budget and
background-continuation acceptance remain open. Failed current-owner side-cache staging and
working-body cleanup can defer conservatively; this does not claim a universal durable recipe
for every abandoned working-body deletion.

## Open gates (never claimed by this work)

- Live Plex, Jellyfin and Emby acceptance for every shared-behaviour phase.
- Physical-device background continuation, lock and off-head behaviour on iPhone, iPad and Vision
  Pro.
- Mac background recovery.
- HDR/DV offline playback on hardware.

## Edge cases added by the second review

| Case | Status | Phase |
|---|---|---|
| An unknown media size becomes a known extras-only estimate (B81) | not handled | P5 |
| Protected data unavailable at launch, then unlock | unpinned | P3 pin |
| Upgrade interrupted between the cleanup-journal commit and the index commit | not handled | P3 migration step 4/5 |
| Delivered callbacks after task enumeration or drain | handled by the current-owner rule; unpinned | P3 pin |
| Storage exhausted during migration | not handled | P3 restartable steps |
| Downgrade reopening a v5 index | not handled | P3 |
| `emby-37` overclaimed: known-job cleanup does cancel a job a live failed row still owns (B44) | regression | P1 containment → P2 |

## Appendix A — Bug list

Severity is the area agent's confidence, and *verified* is the result of the skeptic pass (`-` means it was not re-checked). *History* classifies the bugs the second review traced: a regression (the sha that broke working handling), never handled, or misdiagnosed. `-` means it was not traced. Phase `P1` means a small fix on the current engine; `containment → Pn` means P1 stops the damage and Pn owns the structural fix.

| ID | Area | Sev | Verified | History | Bug | Where | Phase |
|---|---|---|---|---|---|---|---|
| B00 | bg-session | high | confirmed + 2nd review | regression (a96db730) | The stale queued/downloading static-row detector reads the stable localURL, but in-flight partials live in the attempt working file, so in-process self-heal never fires | `PMSKit/Sources/PMSKit/DownloadRetryPolicy.swift:36-61; Labstream/Capabilities/Downloads/Core/DownloadManager.swift:4066-4076` | P1 |
| B01 | bg-session | high | confirmed + 2nd review | never handled | start() storage preflight requires the full expected size plus 500 MB even when resuming from a large durable partial | `Labstream/Capabilities/Downloads/Core/BackgroundDownloadSession.swift:1865-1878 (compare the continuation preflight at 2010-2030 and the manager gate at DownloadManager.swift:2172-2190)` | P1 |
| B02 | bg-session | medium | confirmed | - | Reattach (including the scene-active foreground reattach) re-adopts tasks whose pause or cancel is still in flight and forces the row to .downloading | `BackgroundDownloadSession.swift:1330-1331, 1591-1597; DownloadManager.swift:1851-1870` | P1 |
| B03 | bg-session | medium | confirmed | - | The reattach stash sweeps delete bodies whose append is still queued on rangeIOQueue | `BackgroundDownloadSession.swift:1603-1608, 1616-1647 (and the durable held sweep at 1729-1760)` | P5 |
| B04 | bg-session | medium | confirmed | - | Delayed range retries (HTTP 52x/503, move retry) are not held under the background completion gate, and the move-failure rehydrate never starts a rebuild grace | `BackgroundDownloadSession.swift:6444-6505 (rangeRetryQueue.asyncAfter at 6473), 5124-5165 (asyncAfter at 5133), 5097-5113` | P5 |
| B05 | bg-session | medium | confirmed | - | A runtime 'indeterminate season persistence' block aborts the active session's background gate and grace ownership | `DownloadManager.swift:851-856 → 825-833 → BackgroundDownloadSession.swift:1116-1128 → BackgroundDownloadWakeCoordinator.swift:97-108` | P1 |
| B06 | bg-session | medium | uncertain | - | An OS wake handler supplied while download startup is blocked or dormant is never released | `BackgroundDownloadCompletionRegistry.swift:56-68; BackgroundDownloadSession.swift:1823-1826; DownloadManager.swift:825-833` | P5 |
| B07 | bg-session | medium | confirmed | - | An activation failure after URLSession construction makes every later callback cancel healthy owned tasks and delete their finished bodies | `BackgroundDownloadSession.swift:872-884, 910-933 (rejectTaskCallback), 1007` | P1 |
| B08 | bg-session | medium | - | - | Transport-drop retry budget is reset by optimistic progress and has no backoff, so a flapping link refetches the same segment forever | `BackgroundDownloadSession.swift:2893 (retryCounts reset per didWriteData), 6094-6155 (immediate startRangeRemainder)` | P5 |
| B09 | bg-session | medium | - | - | OS-initiated -999 cancellations (Background App Refresh disabled, insufficient resources) are silently treated as user cancels | `BackgroundDownloadSession.swift:5769-5776, 5900-5905; PMSKit BackgroundRangeCompletionPolicy.swift / BackgroundOpaqueCompletionPolicy.swift` | P1 |
| B10 | bg-session | medium | confirmed + 2nd review | never handled | A forward-only body is lost if the app dies during finalization | `BackgroundDownloadSession.swift:3127-3165 (move to working file, then async finalize); DownloadStore.swift:4876-4884; OfflineDownloadModels.swift:80-83` | P3 |
| B11 | bg-session | low | uncertain | - | The AppDelegate hops to the MainActor before storing the handler, which can race urlSessionDidFinishEvents | `Labstream/Capabilities/Downloads/App/AppDelegate.swift:32-42; PMSKit BackgroundDownloadCompletionGate.swift:74-88` | P1 |
| B12 | bg-session | low | confirmed | - | onRangeRequestNeeded and onError carry only the rating key, not the attempt | `BackgroundDownloadSession.swift:450, 444; DownloadManager.swift:572-576` | P5 |
| B13 | bg-session | low | uncertain | - | No upper bound on a leaked gate operation | `BackgroundDownloadWakeCoordinator.swift:66-81; BackgroundDownloadSession.swift:4832, 4852-4870` | P5 |
| B14 | bg-session | low | confirmed | - | HEVCTagFixup can miss an hev1 sample entry outside the front and back 64 MiB windows | `PMSKit/Sources/PMSKit/Downloads/HEVCTagFixup.swift:70-104` | P5 |
| B15 | store | medium | confirmed + 2nd review | - | load() re-reads index.json; a transient second-read failure admits an empty store as current, and the next mutation overwrites the real index | `Labstream/Capabilities/Downloads/Core/DownloadStore.swift:660-679 and :5153-5157` | P1 |
| B16 | store | high | confirmed + 2nd review | regression (6eb1042c) + retry never worked | An .unreadable probe is cached for the whole process; 'Retry Recovery' can never succeed and the entire offline library renders empty | `DownloadStore.swift:660-667, :705-713, :4005-4012; DownloadManager.swift:678-686, :711-716; OfflineLibraryView.swift:70-78` | P3 |
| B17 | store | medium | - | - | A persistently failing artifact head grows the lifecycle coordinator's live table without bound and retries on every unrelated index commit | `DownloadStore.swift:3931-3952 (recoverPendingArtifactIntents), :3842-3870 (failArtifactLifecycle drops the ticket); DownloadArtifactLifecycleCoordinator.swift:62-81, :96-122` | P6 |
| B18 | store | medium | confirmed + 2nd review | confirmed in narrower form | The cleanup-authority directory and both journals are included in backups; Foundation .atomic writes drop the protection/exclusion set during migration and are not fsync… | `DownloadStore.swift:693-703, :876-880; DownloadCleanupIntentJournal.swift:25, :226-229; EmbyConvertCleanupJournal.swift:34` | P2 |
| B19 | store | high | confirmed + 2nd review | - | The storage audit is blind to hidden attempt-staging partials and temps, so the #171 ghost-storage diagnostic under-reports | `DownloadStore.swift:2588-2601 (.skipsHiddenFiles), :2411-2425; DownloadManager.swift:337-340; PMSKit OfflineDownloadFileInventory.swift:63-115` | P6 |
| B20 | store | medium | confirmed + 2nd review | - | reconcile deletes partials and resume blobs directly, under the lock, outside the lifecycle reservations, and leaves stale references on the row | `DownloadStore.swift:4876-4900` | P6 |
| B21 | store | medium | confirmed + 2nd review | - | An indeterminate season-plan persist reuses the .unreadable probe, which yields a misleading message and an in-process permanent block | `DownloadStore.swift:2870-2876; DownloadManager.swift:851-857, :711-716` | P3 |
| B22 | store | low | - | - | The held-range orphan sweep has no 'existed at Store init' gate and can delete a body written but not yet manifested | `BackgroundDownloadSession.swift:1729-1758 (consumes DownloadStore.referencedHeldRangeSegmentRelativePaths :2184-2190)` | P5 |
| B23 | storage-delete | high | - | - | start() storage preflight requires FULL expected size + 500 MB even when resuming a large static partial | `Labstream/Capabilities/Downloads/Core/BackgroundDownloadSession.swift:1862-1878 (checked before startRangeRemainder computes the durable offset at 1953-1958)` | dup B01 |
| B24 | storage-delete | high | confirmed + 2nd review | never handled | Storage-cap check double-counts a retried partial row and ignores in-flight rows' remaining bytes | `Labstream/Capabilities/Downloads/Core/DownloadManager.swift:3516-3541, 3556-3573; callers +Plex.swift:232, +Jellyfin.swift:57, +Emby.swift:63` | P5 |
| B25 | storage-delete | high | confirmed | - | Completed-row repair always re-fetches Plex /library/metadata for every completed Plex row, bypassing the side-asset rate limiter | `Labstream/Capabilities/Downloads/Core/DownloadSideAssetService.swift:105-110; DownloadManager+SideCache.swift:118-165; DownloadManager.swift:4965-4976` | P1 |
| B26 | storage-delete | medium | confirmed | - | Opaque-lane ENOSPC is not classified as storage-full | `Labstream/Capabilities/Downloads/Core/BackgroundDownloadSession.swift:5885-5960` | P1 |
| B27 | storage-delete | medium | confirmed + 2nd review | - | Delete during validated-promotion window is a silent no-op; a wedged promotion makes the row undeletable | `Labstream/Capabilities/Downloads/Core/DownloadStore.swift:4945-4950; DownloadManager.swift:3716-3727` | P6 |
| B28 | storage-delete | medium | confirmed | - | Plex optimize cancel on delete is non-durable, fires before deletion is confirmed, and skips paused prep rows | `Labstream/Capabilities/Downloads/Core/DownloadManager.swift:3752-3776; PMSKit/Sources/PMSKit/Downloads/DownloadDeletePolicy.swift:59-72` | P2 |
| B29 | storage-delete | low | refuted | - | Deleting a row with no attemptID silently returns | `Labstream/Capabilities/Downloads/Core/DownloadManager.swift:3714` | refuted (dead code, P6) |
| B30 | storage-delete | medium | confirmed | - | Delete cannot free space on a completely full volume | `Labstream/Capabilities/Downloads/Core/DownloadStore.swift:5052-5058 (executeRowDeletion); DownloadManager.swift:3698-3706` | P6 |
| B31 | storage-delete | medium | confirmed | - | Storage-full park memory is in-memory only | `Labstream/Capabilities/Downloads/Core/DownloadManager.swift:2170-2171` | P3 |
| B32 | storage-delete | low | uncertain | - | Side-asset park/unpark ordering is not guaranteed | `Labstream/Shared/Player/SideAssetFetchCoordinator.swift:712-716 (called from DownloadManager.swift:1711 and 2272)` | P7 |
| B33 | plex | medium | - | - | The rendered-Part download URL uses the enqueue-time server and token, not the live lane the poller re-resolved | `Labstream/Capabilities/Downloads/Core/DownloadManager+PlexOptimize.swift:61-62,232-237; Labstream/Capabilities/Downloads/Core/DownloadManager.swift:3140-3141,3424-3429 (the comment at :4821-4823 claims the opposite)` | P4 |
| B34 | plex | high | confirmed + 2nd review | - | Retrying a failed Plex optimize row drops the requested target and re-renders at the global default preset | `Labstream/Capabilities/Downloads/Core/DownloadManager.swift:2541-2557` | P1 |
| B35 | plex | high | confirmed + 2nd review | - | A fresh optimize POSTs a new server job even when a tier-matching Plex Version already exists, then adopts the old one and leaves the new job rendering | `Labstream/Capabilities/Downloads/Core/DownloadManager+PlexOptimize.swift:188-237 (comment :188-191 is stale), DownloadOptimizeSourcePolicy.swift:23-38` | P4 |
| B36 | plex | high | confirmed | - | The original-to-optimize validation fallback also fires for .existingVersion downloads | `PMSKit/Sources/PMSKit/Downloads/PlexOriginalFallbackPolicy.swift:6-21; Labstream/Capabilities/Downloads/Core/DownloadManager+Plex.swift:282-315` | P1 |
| B37 | plex | high | confirmed | - | A swallowed optimize-create failure leaves the row in 'Preparing on server' for up to 24 h | `Labstream/Capabilities/Downloads/Core/DownloadManager+PlexOptimize.swift:198-213; Labstream/Capabilities/Downloads/Core/DownloadManager.swift:4883-4934` | P4 |
| B38 | plex | medium | confirmed | - | The fallback optimizer Location URI uses the client identifier instead of the server machine identifier | `PMSKit/Sources/PMSKit/Optimize/OptimizeRequest.swift:78-79 (unchanged since 9675020e); reached when DownloadManager+PlexOptimize.swift:770-795 returns nil` | P1 |
| B39 | plex | medium | confirmed | - | Background-job progress can be attributed to another client's transcode | `Labstream/Capabilities/Downloads/Core/DownloadManager.swift:5245-5259; PMSKit/Sources/PMSKit/Optimize/ActivitiesRequest.swift:158-166,219-223` | P1 |
| B40 | plex | high | confirmed | - | Deleting a paused Plex prep row never cancels its server job | `PMSKit/Sources/PMSKit/Downloads/DownloadDeletePolicy.swift:65` | dup B28 |
| B41 | plex | medium | uncertain | - | The plain original-preflight fallback skips the up-front storage-limit check | `Labstream/Capabilities/Downloads/Core/DownloadManager+Plex.swift:52-60,156-166` | P5 |
| B42 | plex | low | confirmed | - | Type-42 completion vocabularies diverge | `PMSKit/Sources/PMSKit/Downloads/PlexOptimizeCompletionPolicy.swift:25 vs PMSKit/Sources/PMSKit/Optimize/OptimizeRequest.swift:256` | P1 |
| B43 | plex | low | uncertain | - | An audio override given as Stream.index is sent to Plex as audioStreamID | `Labstream/Capabilities/Downloads/Core/DownloadManager+Plex.swift:202-209; PMSKit/Sources/PMSKit/Downloads/DownloadAudioSelectionPolicy.swift:36-41` | P1 |
| B44 | emby | high | confirmed + 2nd review | regression (651e7929) | The launch/backend-switch cleanup sweep DELETEs live Convert jobs of failed rows and clears their job id, defeating the 401/403-keep and failed-row poll-resume rules | `Labstream/Capabilities/Downloads/Core/DownloadManager.swift:1005-1043 (introduced in 651e7929); conflicts with DownloadManager+EmbyConvert.swift:628-634 and PMSKit/Sources/PMSKit/Downloads/DownloadRetryPreparationPolicy…` | P1 containment → P2 |
| B45 | emby | high | confirmed + 2nd review | regression (9f782b4e) on older incomplete reuse | The convert poll/finish chain uses the synthesized Media.id as the primary MediaSource id, so the tier cap ignores the real source and pickup fails for low-res sources | `Labstream/Capabilities/Downloads/Core/DownloadManager+EmbyConvert.swift:553-559 and :890 (item.media?.first?.id); Emby Media.id is index+1 (PMSKit/Sources/PMSKit/MediaBrowser/MediaBrowserItemModels.swift:531) and nil af…` | P1 |
| B46 | emby | medium | confirmed | - | The completed-source fallback can adopt a pre-existing sibling or the original itself | `PMSKit/Sources/PMSKit/Downloads/EmbyConvertedSourcePolicy.swift:59-71 called from DownloadManager+EmbyConvert.swift:927-932; snapshot fetched best-effort at :193 (embyFileSources returns [] on error)` | P1 |
| B47 | emby | medium | confirmed | - | Pausing during the create POST cancels the job while the paused row keeps its dispatchAmbiguous identity | `Labstream/Capabilities/Downloads/Core/DownloadManager+EmbyConvert.swift:419-426` | P1 |
| B48 | emby | medium | confirmed | - | An unmodelled terminal Sync status (CompletedWithError) polls forever | `PMSKit/Sources/PMSKit/Emby/EmbyConvertRequest.swift:12-41; DownloadManager+EmbyConvert.swift:703` | P1 |
| B49 | emby | medium | confirmed | - | Launch race: the ambiguous-create cleanup intent and crash-window recovery act on the same failed row concurrently | `DownloadManager.swift:914-918 (reattach runs migrate before resumePendingServerPrepDownloads) vs ContentView.swift:145-149 (opposite order); DownloadManager.swift:1034-1041 and 2965-3002` | P1 containment → P2 |
| B50 | emby | medium | confirmed | - | Fire-and-forget Convert cancels are not journaled | `Labstream/Capabilities/Downloads/Core/DownloadManager+EmbyConvert.swift:844-857 (used at :422 and :580)` | P2 |
| B51 | emby | medium | - | - | Offline subtitles are lost for relaunch/retry convert handoffs, and rehydration queries the wrong MediaSource | `DownloadManager+Emby.swift:389-393; DownloadManager+SideCache.swift:423, 239-265` | P7 |
| B52 | emby | low | confirmed + 2nd review | - | Two user-equality rules disagree (normalised sameUser vs raw string compare) | `PMSKit/Sources/PMSKit/Emby/EmbyConvertRequest.swift:405-413 vs PMSKit/Sources/PMSKit/Downloads/BackendSession.swift:55-65` | P1 |
| B53 | emby | low | uncertain | - | Static original destination falls back to 'mp4' on retry when the server omits Container | `Labstream/Capabilities/Downloads/Core/DownloadManager+Emby.swift:290-292` | P1 |
| B54 | jellyfin | high | confirmed + 2nd review | never persisted + staging regression (a96db730) | A parked truncated forward-only row is deleted after a relaunch | `Labstream/Capabilities/Downloads/Core/BackgroundDownloadSession.swift:215, :5344-5360, :5439-5443; PMSKit/Sources/PMSKit/Downloads/BackgroundFinalizationResultPolicy.swift:28-35,71-87; revalidation path DownloadManager.…` | P1 publish → P3 persist |
| B55 | jellyfin | medium | confirmed + 2nd review | never handled; kill risk unproven | Jellyfin download keepalive sends Playing and Progress reports, which change watch state and Now Playing; it never sends Stopped | `Labstream/Capabilities/Downloads/Core/DownloadKeepaliveCoordinator.swift:293-331 (playingRequest + progressRequest with advancing positionTicks)` | D3 (live A/B) |
| B56 | jellyfin | high | confirmed + 2nd review | - | Storage-limit and free-space preflight are blind for Jellyfin Original and remux because MediaBrowser Parts never carry a size | `PMSKit/Sources/PMSKit/MediaBrowser/MediaBrowserItemModels.swift:519-525 (Part size: nil); Labstream/Capabilities/Downloads/Core/DownloadManager+Jellyfin.swift:57-61, :133; PMSKit/Sources/PMSKit/Downloads/DownloadStorage…` | P5 |
| B57 | jellyfin | low | - | - | Jellyfin comma-list MediaSource Container is not normalized for Original eligibility, the static URL, or the destination extension (Emby splits it) | `PMSKit/Sources/PMSKit/Jellyfin/JellyfinLibrary.swift:296-302; PMSKit/Sources/PMSKit/Downloads/OfflineDownloadDecision.swift:11-26; PMSKit/Sources/PMSKit/Downloads/DownloadMediaSelectionPolicy.swift:53-56; contrast PMSKi…` | P7 |
| B58 | jellyfin | medium | confirmed | - | Remux audio-copy decision uses the first audio stream, not the user-selected track | `PMSKit/Sources/PMSKit/Jellyfin/JellyfinPlayback.swift:238-250 (downloadDecision) vs :87-97 (playbackSourceMetadata(audioStreamIndex:))` | P1 |
| B59 | jellyfin | medium | confirmed | - | Missing preferred MediaSource silently becomes a different source on download and retry | `PMSKit/Sources/PMSKit/Jellyfin/JellyfinPlayback.swift:517-527; Labstream/Capabilities/Downloads/Core/DownloadManager+Jellyfin.swift:358-370` | P1 |
| B60 | jellyfin | medium | confirmed | - | Keepalive keeps pinging for a row with no live transfer (IC-4, never fixed) | `Labstream/Capabilities/Downloads/Core/DownloadKeepaliveCoordinator.swift:258-262 and :60-94` | P1 |
| B61 | jellyfin | low | uncertain | - | Remux rows with a server-reported Content-Length are excluded from the forward-only stall watchdog | `PMSKit/Sources/PMSKit/Downloads/DownloadDisplayClassifier.swift (compatibleRemux: progress <= 0) -> DownloadStallRecoveryPolicy.swift:19-26` | P3 |
| B62 | planner-ui | medium | confirmed + 2nd review | - | resumePendingServerPrepDownloads attaches Plex optimize pollers to season-pending rows, which bypasses the cap and can stall admission | `Labstream/Capabilities/Downloads/Core/DownloadManager.swift:3099-3101 (filter), callers ContentView.swift:145,181,191,214 and DownloadManager.swift:1769,1790,4217` | P4 |
| B63 | planner-ui | high | confirmed + 2nd review | never handled (narrowed: paused/failed rows) | Resume All starts every pending season row at once (lane caps bypassed) | `Labstream/Capabilities/Downloads/Core/DownloadManager.swift:1743-1772; PMSKit/Sources/PMSKit/Downloads/DownloadQueueToolbarPolicy.swift:57-63` | P4 |
| B64 | planner-ui | high | refuted by 2nd review | MISDIAGNOSED: pause persists .paused; only a race remains | Pausing a not-yet-admitted Jellyfin/Emby transcode or remux season row does nothing; the row starts later anyway | `PMSKit/Sources/PMSKit/Downloads/DownloadPausePolicy.swift:24-35; Labstream/Capabilities/Downloads/Core/DownloadManager.swift:1672-1710; Labstream/Capabilities/Downloads/Core/BackgroundDownloadSession.swift:2419-2453` | race test first, P4 |
| B65 | planner-ui | medium | confirmed + 2nd review | overstated: real defect is resume bypassing admission | seasonPlannerPendingAdmission is never cleared by user pause, resume, retry or Resume All, which leaves contradictory state | `Labstream/Capabilities/Downloads/Core/DownloadManager+SeasonPlanner.swift:171-211; DownloadManager.swift:4146-4155, :4354-4356` | P4 |
| B66 | planner-ui | medium | - | - | Admission clears the pending flag before the start is proven; early-return paths leave an orphan queued row | `Labstream/Capabilities/Downloads/Core/DownloadManager+SeasonPlanner.swift:194-207; DownloadManager+Plex.swift:29-37; DownloadManager.swift:1516-1530` | P4 |
| B67 | planner-ui | medium | - | - | Season admission fails rows outright when the backend is only temporarily unavailable (cold launch, server unreachable) | `Labstream/Capabilities/Downloads/Core/DownloadManager+SeasonPlanner.swift:157-169, :228-240; DownloadManager.swift:4354-4356` | P4 |
| B68 | planner-ui | high | confirmed | - | Season planner runs the Emby item refresh plus 5 s poll for every episode | `Labstream/Capabilities/Downloads/Core/DownloadItemPlanner.swift:231-233, :258-270; UI/SeasonDownloadPlannerSheet.swift:390-396` | P1 |
| B69 | planner-ui | medium | - | - | A transient probe failure becomes a permanent 'unsupported' failed row (Jellyfin/Emby, Original quality) | `UI/SeasonDownloadPlannerSheet.swift:251-264; Core/DownloadItemPlanner.swift:150-163, :199-201` | P4 |
| B70 | planner-ui | low | uncertain | - | The season sheet reads the live activeBackend instead of capturing it | `Labstream/Capabilities/Downloads/UI/SeasonDownloadPlannerSheet.swift:28` | P1 |
| B71 | planner-ui | low | uncertain | - | Dictionary(uniqueKeysWithValues:) can trap on a duplicate ratingKey | `Labstream/Capabilities/Downloads/UI/SeasonDownloadPlannerSheet.swift:185-189, :203-215` | P1 |
| B72 | planner-ui | low | confirmed | - | Admission undercounts in-flight retry starts across passes | `Labstream/Capabilities/Downloads/Core/DownloadManager+SeasonPlanner.swift:183-205` | P4 |
| B73 | offline-playback | high | confirmed + 2nd review | never handled | 'Play Offline' from Detail never saves the local playhead or confirms unverified rows | `Labstream/Shared/UI/DetailView.swift:715-725 (compare Labstream/Capabilities/Downloads/Core/OfflineLibraryView.swift:182-186)` | P7 |
| B74 | offline-playback | medium | confirmed + 2nd review | never handled | Unverified (including truncated-parked) rows are promoted to complete without any observed playback | `Labstream/Capabilities/Downloads/Core/DownloadManager.swift:3913-3915; Labstream/Shared/Player/PlaybackController.swift:643, 1110-1122, 1145` | P7 |
| B75 | offline-playback | medium | confirmed + 2nd review | - | Offline playback writes land on whichever attempt is current at write time, not the attempt that is playing | `Labstream/Capabilities/Downloads/Core/DownloadManager.swift:3908-3911; Labstream/Capabilities/Downloads/Core/OfflineLibraryView.swift:182` | P7 |
| B76 | offline-playback | medium | confirmed | - | Offline playback blocks the main thread on a durable index write every 10 seconds and on every pause/play | `Labstream/Capabilities/Downloads/Core/DownloadManager.swift:3916-3929; Labstream/Capabilities/Downloads/Core/DownloadStore.swift:167-181, 3119-3128, 4492-4509, 5260-5261` | P7 |
| B77 | offline-playback | medium | confirmed | - | Reconnect from the cold-launch Offline surface does not re-hydrate inactive backends or re-run orphan-encoder cleanup | `Labstream/Shared/App/ContentView.swift:136-149 vs 173-187; Labstream/Shared/UI/OfflineLaunchView.swift:118-125` | P1 |
| B78 | offline-playback | low | uncertain | - | visionOS: the Cinema exit route from the Offline launch surface is replayed after Reconnect | `Labstream/Platforms/visionOS/Player/CustomCinemaMode.swift:488-490; Labstream/Shared/SystemIntegration/SystemEntryRouter.swift:168-170; Labstream/Shared/UI/RootView.swift:41-55` | P7 |
| B79 | offline-playback | low | confirmed | - | The launch gate stats every record's file on each ContentView body evaluation | `Labstream/Capabilities/Downloads/Core/DownloadManager.swift:255-259; Labstream/Shared/App/ContentView.swift:225-233` | P7 |
| B80 | offline-playback | medium | uncertain | - | Sidecar subtitles hide subtitle tracks embedded in the downloaded file | `Labstream/Shared/Player/PlaybackController.swift:1280-1283, 1359-1376` | P7 |
| B81 | storage-delete | high | 2nd review | never handled | An unknown media size plus known side-asset bytes yields a known extras-only estimate, so the item evades the unknown-size confirmation (the test pins the wrong contract) | `PMSKit/Sources/PMSKit/Downloads/DownloadStorageEstimatePolicy.swift:43; PMSKit/Tests/PMSKitTests/DownloadStorageEstimatePolicyTests.swift:45` | P5 |
| B82 | background-wake | medium | field report | never handled | A background wake has no aggregate time bound: each gate operation balances, but queued completions plus slow append/index I/O can keep the wake open past the OS budget | `Labstream/Capabilities/Downloads/Core/BackgroundDownloadWakeCoordinator.swift:67; Labstream/Capabilities/Downloads/Core/BackgroundDownloadSession.swift:1141, 3526` | P6 |
| B83 | background-wake | low | field report | never handled | No memory ceiling is established for an inherited backlog of completed bodies plus side assets at relaunch | `Labstream/Capabilities/Downloads/Core/BackgroundDownloadSession.swift:5194` | P6 |
| B84 | store | low | field report | never handled | Duplicate persisted row identities trap during index load instead of salvaging or blocking recovery | `Labstream/Capabilities/Downloads/Core/DownloadStore.swift:5169` | P6 |
| B85 | storage-delete | low | field report | never handled | Static append re-copies already downloaded bodies; write amplification is unmeasured and unbounded (MetricKit disk-write exceptions) | `Labstream/Capabilities/Downloads/Core/BackgroundDownloadSession.swift:5188-5199; Labstream/Shared/Diagnostics/MetricKitDiagnostics.swift:107, 135` | P6 |

## Appendix B — Edge-case inventory

This is every edge case the history shows the module has had to handle. *Status* reflects the skeptic's correction where there was one. *Req* says whether the redesign must preserve the case. *Pinned* says whether the current handling cites a test; a required case without a pinning test must gain one before the phase that touches it merges. *Phase* is the phase that rehomes or changes the case; every other phase must leave it intact.


### bg-session

| ID | Edge case | Why | Status | Req | Pinned | Phase |
|---|---|---|---|---|---|---|
| bg-01 | Hold the OS background-completion handler until in-flight durable work drains | #169/#212: if the handler is released between moving a temp file into the stash and the append/status write, visionOS suspends the app and the row loses its progress or… | handled | yes | yes | P5 |
| bg-02 | Several handlers for the same identifier: release only the exact token batch claimed at finish | SAFE-10: the old registry replaced a same-identifier handler, so one OS handler was never called and a delayed release could swallow a newer wake's handler. | handled | yes | yes | P5 |
| bg-03 | Flush store persistence (5 s bound) before firing the released handlers | Submitted writes (status, progress, held manifests) were only queued. Releasing the wake before they commit loses them if the process is killed while suspended. | handled | yes | yes | P5 |
| bg-04 | Rebuild grace: hold the wake while the manager re-mints an authenticated request (20 s timeout, generation-fenced) | #212, the decisive half of the ~10 GB off-head stall. A reattached task has no request. Without the hold, the OS suspends the app after the append and before the next ta… | partially-handled | yes | yes | P5 |
| bg-05 | Keep a nested gate operation open across the held-body lifecycle completion | The outer gate operation ends when applyFinishedRangeBody returns, but the train refill happens later in an async lifecycle completion. The gate could reach zero in that… | handled | yes | yes | P5 |
| bg-06 | Handler stored after urlSessionDidFinishEvents already fired | The OS calls handleEventsForBackgroundURLSession and delivers delegate events on another queue. If finishEvents runs before the handler is recorded, finishEvents finds n… | partially-handled | yes | yes | P5 |
| bg-07 | Startup admission: keep the session dormant (URLSession not built) until the index is admitted, then purge unowned or non-current tasks before opening | Building the background session delivers callbacks immediately. Pre-current or unowned tasks must not append into rows before ownership is proven (F1 silent-corruption c… | handled | yes | yes | P5 |
| bg-08 | Destructive reset for an unsupported schema: cancel every OS task, require two consecutive empty enumerations, then replace the root | A pre-release reset has no trustworthy row ownership. One empty snapshot can race daemon bookkeeping. | handled | yes | yes | P5 |
| bg-09 | A startup block or failure must release stored OS handlers, because no finishEvents can arrive while dormant | Keeping an OS wake handler forever while downloads are blocked violates the background-session contract and leads to throttling. | partially-handled | yes | yes | P5 |
| bg-10 | Defer the initial transport activation by one MainActor turn; a retry cancels the deferred edge and owns the only submission | Takes transport construction off the launch critical path without allowing a double activation. | handled | no | yes | P5 |
| bg-11 | Reattach adopts only current-marker tasks for the row's exact attempt; mismatched, malformed or unowned tasks are cancelled and rebuilt from the dura… | A task from a prior attempt (another quality, or a cancelled life) would splice another rendition's bytes into the new partial. | handled | yes | yes | P5 |
| bg-12 | A reattached or dead-finish closed segment recovers its segmentLength (from the Range end, else the grid clamped to the expected total) | C3: without it, out-of-order finishes after relaunch were discarded rather than held, which refetched up to a full segment and burned the offset-mismatch budget. | handled | yes | yes | P5 |
| bg-13 | Terminal rows (complete/failed/unverified) must not re-adopt straggler tasks | Adoption forces .downloading, and a late finish could replace the published file. | handled | yes | no | P5 |
| bg-14 | Stamped tasks whose row was deleted are cancelled | An orphan would otherwise keep transferring in nsurlsessiond indefinitely. | handled | yes | no | P5 |
| bg-15 | Deletion-pending rows: cancel their tasks and keep held manifests and bodies until journal-first deletion completes | The row and its artifacts remain recovery authority until server cleanup is durable. | handled | yes | yes | P5 |
| bg-16 | Reattach must not re-adopt a task whose pause or cancel is in flight | Pause and cancel remove entries from rangeInflight synchronously, but URLSession cancellation is asynchronous, so getAllTasks still lists the task. Reattach (also run on… | partially-handled | yes | no | P5 |
| bg-17 | Re-enumerate and reconcile tasks on scene-active (headset wake) | A headset wake can leave static range tasks untracked, and users had to Pause All then Resume All to recover. | handled | yes | no | P5 |
| bg-18 | Recover pending validated promotions off the URLSession delegate queue, before task classification | F_FULLFSYNC of a multi-GB file on the delegate queue blocks every callback through the wake window. | handled | yes | yes | P5 |
| bg-19 | Move the didFinishDownloadingTo temp file synchronously (O(1) rename) before any classification; do the heavy append off the delegate queue | #220: the location is valid only until the delegate returns. Cocoa error 4 lost completed bodies, and appending on the delegate queue stalled other downloads (#169). | handled | yes | no | P5 |
| bg-20 | Never delete CFNetworkDownload_*.tmp during reattach; leaked network temps are only observed | #220: a finished but undelivered task is absent from getAllTasks while its payload sits in a CFNetwork temp (a body was seen suspended about 3 h before delivery). | dropped-intentional | yes | yes | P5 |
| bg-21 | Sweep orphaned range-body stashes (tmp/) and orphaned durable held bodies on reattach | A hard kill between the stash rename and the apply leaks up to 512 MiB per stash. visionOS clears tmp/ only under pressure. | partially-handled | yes | no | P5 |
| bg-22 | Dead-finish adoption of a marked segment that finished while the process was dead; unowned bodies limited to discard or reset | I1: the OS may redeliver a completed task before (or instead of) reattach, so dropping it wastes an irreplaceable body. NEW-1: such a body must never pin a validator, fa… | handled | yes | yes | P5 |
| bg-23 | Dead-finish adoption of a forward-only (opaque) transfer that completed while the app was terminated | JF-F4: dropping the finished multi-GB transcode temp forced a re-transcode from zero. | handled | yes | no | P5 |
| bg-24 | App killed during forward-only finalization (body already moved into the working file, row .downloading) | The AVPlayer probe can take 2-25 s or more and probes are serialised. A user swipe-kill during 'Verifying…' should not lose a complete transcode. | partially-handled (effectively unhandled) | yes | no | P5 |
| bg-25 | Duplicate or late delegate callbacks are absorbed: superseded-ID set, newer-task supersede, per-attempt finalizer single-flight, stale-attempt drops | A stale or duplicated callback must not publish backwards progress, append twice, or start a second AVPlayer probe. | handled | yes | yes | P5 |
| bg-26 | Halt kinds: a pause preserves a just-finished body (writeThenPause), a cancel discards it, and a pause never downgrades a cancel | The persisted .paused status lands at the end of an async chain. Keying on store status discarded bodies that finished inside the pause window; preserving onto a deletin… | handled | yes | yes | P5 |
| bg-27 | Train epochs: a body captured before a teardown (changed resource, adopted 200, cancel, truncate) is discarded; the 416 restart is serialised on rang… | IC-2/B.2: a stale sibling could splice bytes from the old resource version or append at offset 0 of the re-created file. | handled | yes | no | P5 |
| bg-28 | A closed segment that receives more than segmentLength bytes is cancelled and rebuilt; closed-segment resume blobs are never persisted or adopted | CFNetwork was seen replaying a resumed closed request as an effectively open-ended HTTP/3 transfer that pulled the rest of the file. | handled | yes | yes | P5 |
| bg-29 | Open-ended (unknown-total) remainder: persist the blob on pause or failure, adopt only when the blob's Range start equals the durable size, budget-bo… | #227/#212: a network blip must not discard GBs of non-durable temp, but a stale blob must never become authoritative. | handled | yes | yes | P5 |
| bg-30 | Network-path counter reset on the same task id: cancel and rebuild from the checkpoint, judged by the task's live counter | A frozen live watermark previously needed Pause All then Resume All. Treating a relaunch replay (buffered didWriteData lagging countOfBytesReceived) as a reset rolled GB… | handled | yes | yes | P5 |
| bg-31 | visionOS wake silently restarts the body of a custom-Range request with no error or resume data; loss is bounded by a pre-queued closed segment train | With one open-ended task, a wake bounce forfeits every un-appended byte overnight, and per-chunk wakes are throttled by the relaunch rate limiter. | handled | yes | yes | P5 |
| bg-32 | Train sizing and fan-out (512 MiB × 2 per row) | Five rows expanded to 34 simultaneous tasks on device. Small segments meant frequent task replacement while off-head. | partially-handled | yes | no | P5 |
| bg-33 | In-session transient transport retry for the range lane | Long HTTPS range streams drop (-1005). Without a retry the user taps Resume every few MB. | partially-handled | yes | no | P5 |
| bg-34 | HTTP 52x/503 retry with 1-4 s backoff; 401/403 one-shot rehydrate with grace; post-logout 401 deferral that stays attempt-fenced | Real server replies arrive as 'successful' error-page bodies. Logout revokes tokens server-side. | partially-handled | yes | no | P5 |
| bg-35 | Missing temp or body (Cocoa error 4) during stash or append: bounded retry or rehydrate from the durable checkpoint | #220: a move failure commits no bytes, so the partial remains a valid restart point. | partially-handled | yes | no | P5 |
| bg-36 | Storage full: ENOSPC on completion or move fails with .storageFull and tears down the train; preflight on start and on continuation; automatic redriv… | An ENOSPC 'pause' re-failed on the next byte and caused retry storms. | partially-handled | yes | no | P5 |
| bg-37 | No AVPlayer probe while an OS wake handler is pending: finalize as unverified and revalidate on the next foreground pass | Lens 4 F4: the muted probe cannot advance in a background launch, and serialised 8 s + 15 s timeouts would hold the wake past its window. | handled | yes | yes | P5 |
| bg-38 | Serialise playback-validation probes (global limiter) and bound retries | #187: parallel long AVPlayer probes were a plausible cause of headset gray-screen freezes and crashes. | handled | yes | no | P5 |
| bg-39 | Rewrite HEVC hev1 to hvc1 before probing, scanning only the first and last 64 MiB | #127/#83: AVFoundation shows a black screen on hev1. A full scan of a multi-GB file stalled 'Verifying…'. | partially-handled | yes | yes | P5 |
| bg-40 | Cellular policy is stamped per request, and the background session itself stays permissive | Changing the session configuration would mean recreating a background session with the same identifier. New tasks must observe the Wi-Fi-only default. | handled | yes | no | P5 |
| bg-41 | Simulator uses a foreground session with a per-request 3600 s timeout | nsurlsessiond XPC is unreliable in the visionOS simulator. Queued train tasks starved behind the per-host limit hit URLRequest's 60 s default (-1001 churn). | handled | no | no | P5 |
| bg-42 | Session identifier: per-bundle on macOS so worktrees don't reattach each other's transfers; legacy fixed identifier on iOS/visionOS | Mac dev builds share one user nsurlsessiond namespace. | handled | yes | no | P5 |
| bg-43 | macOS has no handleEventsForBackgroundURLSession and no relaunch-for-events | Mac background recovery is documented as a pre-release acceptance gate. | unclear | yes | yes | P5 |
| bg-44 | OS-initiated cancellation (-999 with a background-task-cancelled reason: user force-quit, Background App Refresh disabled, insufficient resources) is… | The OS can cancel tasks while the app is alive. A silent return leaves the row .downloading with no task. | partially-handled | yes | no | P5 |
| bg-45 | Self-heal a queued or downloading static row that has a durable partial but no tracked task | IC-1/B.2: rows froze mid-percent after pause/finish races, missed rebuilds, or OS cancels, and only relaunch or Pause/Resume healed them. | dropped-accidental | yes | yes | P5 |
| bg-46 | When the rebuild grace times out, park a queued row with no task as Paused at its checkpoint | A queued static row with no URLSession owner otherwise shows a spinner that only Pause then Resume can kick. | partially-handled | yes | no | P5 |
| bg-47 | Consecutive-truncation parking budget is keyed by row (not attempt), cleared on halt and on .complete | JF-F2: retry mints a new attempt, so a per-attempt budget made parking unreachable. D6: a re-download must not inherit an old count. | handled | yes | yes | P5 |
| bg-48 | A user start or resume resets every range restart budget; internal continuations do not | M-7/IC-8: an exhausted blob or rehydrate budget survived Retry and forced durable-checkpoint restarts. | handled | yes | no | P5 |
| bg-49 | Exact-attempt task creation: the session never mints authority, and every task description carries ratingKey + U+001F + an attempt or segment marker | A rating key is reused across delete and retry, so neither component is unique on its own. | handled | yes | yes | P5 |
| bg-50 | Jellyfin/Emby encoder keepalives: exact-attempt task slots, the session re-resolved every tick, auth-dead quarantine per credential generation, self-… | An idle server kills the transcode mid-download. Stale tokens must not ping, and an auth-dead loop must not hammer the server. | handled | yes | yes | P5 |
| bg-51 | Persisted range progress is pinned to the durable checkpoint; live train bytes are a separate overlay clamped to the total | Pause and relaunch must not appear to lose bytes that were never resumable (#224/#A5). | handled | yes | yes | P5 |
| bg-52 | First-progress handoff hold and graceful checkpoint pause | In the bounded-chunk era, the wake was held up to 15 s after creating a replacement task until its first progress, and a pause let the current chunk append before haltin… | dropped-intentional | no | no | P5 |
| bg-53 | Registry registration and handler storage never reattach on their own | Constructing or reattaching during a migration window admitted callbacks before legacy tasks were cancelled. | dropped-intentional | yes | no | P5 |
| bg-54 | Opaque lane HTTP and MIME gate, and forward-only streams never resume from a byte offset | D1: error pages were saved as 'complete'. #95: a byte-offset resume of a live transcode corrupts it (200/416). | handled | yes | yes | P5 |

### store

| ID | Edge case | Why | Status | Req | Pinned | Phase |
|---|---|---|---|---|---|---|
| st-01 | Persist one-level relative paths; re-hydrate absolute URLs against the live container (container moves on reinstall/update) | An absolute sandbox path in the index orphans every file once the container UUID changes. The original store was written relative-path-first for this reason. | handled | yes | yes | P6 |
| st-02 | Reject unsafe persisted relative paths (no '/', '..', '\\') before any file operation | A malformed or imported index must never make a destructive worker delete outside the Downloads root. | partially-handled | yes | no | P6 |
| st-03 | Exclude the Downloads root from backup and apply CompleteUntilFirstUserAuthentication protection; apply per-file protection to committed artifacts | Multi-GB media must not go to iCloud or device backups. The background daemon must be able to write while the device is locked after first unlock. | partially-handled | yes | yes | P6 |
| st-04 | Server-cleanup authority lives outside the versioned media root so a destructive reset or row deletion cannot erase it | Losing the only record of a Jellyfin/Emby ActiveEncoding or Emby Convert job leaks server-side transcodes indefinitely. | handled | yes | yes | P6 |
| st-05 | Migrate cleanup journals from the old in-root location to the authority directory, with byte-equality conflict check | Installs created before 6eb1042c kept the journals inside Downloads/. | handled | no | yes | P6 |
| st-06 | Versioned index envelope; unsupported schemas are reset only after the background session drains every OS task (two empty passes), using durable quar… | Decoding an old schema or adopting old tasks could bless the wrong owner. A half-finished reset must never be read as an empty library. | handled | yes | yes | P6 |
| st-07 | Reclaim quarantined/retired roots asynchronously, and again on every launch | Old multi-GB roots must not stay hidden on disk forever after an interrupted removal. | handled | yes | yes | P6 |
| st-08 | Per-row decode isolation: one corrupt row must not drop the whole offline library (#135 H8) | The old all-or-nothing decode wiped every listed download when a single row was corrupt. | dropped-intentional | no | yes | P6 |
| st-09 | Duplicate ratingKeys in a current index must not crash load (Dictionary(uniqueKeysWithValues:)) | A duplicate key traps in load(). | handled | yes | yes | P6 |
| st-10 | Unreadable or malformed index bytes are never overwritten while startup is blocked | Keep corrupt data for diagnosis and never replace it with a guessed snapshot. | handled | yes | yes | P6 |
| st-11 | Malformed current-schema ownership (missing or disagreeing top-level attemptID, wrong working path) blocks admission without guessing an owner | Repairing ownership could bless an unrelated live OS task. | handled | yes | yes | P6 |
| st-12 | Serialized, revisioned full-snapshot index writes with encode and I/O off the store lock; superseded snapshots are never written | Concurrent URLSession-delegate and main-actor writers used to race and interleave index writes. | handled | yes | yes | P6 |
| st-13 | Crash-durable index commit (unique temp, F_FULLFSYNC, rename, parent fsync) plus age-gated cleanup of abandoned temps | A torn or partially renamed index loses the library. | handled | yes | yes | P6 |
| st-14 | A failed index write stays dirty and is retried by the next full snapshot or a bounded flush | A full disk during a delete or progress write must not silently lose state. | handled | yes | yes | P6 |
| st-15 | Ambiguous post-rename commit failure (the new bytes may already be canonical) | A thrown error after rename can make callers compensate away a write that actually reached disk. | partially-handled | yes | yes | P6 |
| st-16 | Throttle progress-driven index writes to about 1 per second; status transitions persist immediately | The old per-callback rewrites burned CPU and I/O during large downloads. | handled | yes | yes | P6 |
| st-17 | Flush index and artifact lifecycle within one bounded budget before releasing the OS background-completion handler | If the app suspends right after handler release, its last state is not durable. | handled | yes | yes | P6 |
| st-18 | Never orphan a resume blob: write it under a generation-private name behind a durable prepared intent, and age-sweep abandoned commit temps | Resume blobs can be large. H9 found blobs written for rows whose path could never be recorded. | handled | yes | yes | P6 |
| st-19 | Validated promotion crash window (rename done, terminal index not yet committed) replays from a durable intent | Without it, a hard kill between rename and commit leaves a published file that the row does not own, or a row that never completes. | handled | yes | yes | P6 |
| st-20 | Attempt-scoped hidden working files, so a stale attempt can never write, checkpoint or promote over a replacement attempt's body | A re-download of the same ratingKey reused the same stable path and was clobbered by late callbacks from the old attempt. | handled | yes | yes | P6 |
| st-21 | Startup sweep deletes only attempt-staging files that existed at Store init and are unreferenced | Hard kills leave hidden partials behind. Files created during the current process may belong to a writer that has not yet recorded them. | handled | yes | yes | P6 |
| st-22 | Durable held range bodies with manifest; held-body deletion is recoverable across a failed commit or relaunch | Out-of-order range bodies were memory-only and were lost or orphaned on process death (audit B.1). Deletions that failed mid-way lost their authority. | handled | yes | yes | P6 |
| st-23 | Orphan held-range body sweep at reattach | Manifest-less .range-held-* bodies left by kills would otherwise accumulate. | partially-handled | yes | no | P6 |
| st-24 | Row deletion is a terminal artifact barrier: on failure the row and files stay, the intent stays durable, and relaunch retries; successors queued beh… | Earlier the row was removed first and file deletion was best-effort ('local file orphaned' log). Late tail callbacks could also resurrect state after a delete. | handled | yes | yes | P6 |
| st-25 | Joined deletion waiters (double-tap Delete, coalesced recovery) each receive the outcome for the same epoch | A second waiter must not see a stale or overwritten outcome from a different retry epoch. | handled | yes | yes | P6 |
| st-26 | Deletion-pending capsule: if the cleanup journal is unavailable, the row and its exact cleanup intents stay durable, and reconcile and mutators must… | A delete while the journal is unwritable would otherwise drop the only server-cleanup authority. | handled | yes | yes | P6 |
| st-27 | Cleanup journals: unreadable is not empty; exact-value proofs after an ambiguous atomic write; element-level quarantine repair (intent journal only) | An unreadable queue treated as empty would erase orphan-cleanup authority. | partially-handled | yes | yes | P6 |
| st-28 | Reconcile: a complete or unverified row whose file is missing becomes failed | Offline Play must not be offered for a file that no longer exists. | handled | yes | yes | P3a |
| st-29 | Reconcile: a non-live queued/downloading/paused row that cannot stay resumable is demoted to failed and its partial and resume blob deleted; resumabl… | Invisible dead bytes piled up on disk (e1dc0224). Deleting the partial of a resumable row made its resume data useless (adc8943f). | partially-handled | yes | yes | P3a |
| st-30 | Reconcile skips rows with pending artifact intents | A staged validatedPromotion leaves the row in .downloading while the working file is the validated body. Demoting it would delete the source. | handled | yes | yes | P3a |
| st-31 | Reconcile backend nuance: Plex server-prep rows return to queued; Jellyfin/Emby transcodes become failed; a live static range task stays downloading… | Emby/Jellyfin live renders die with the task, while Plex optimize jobs survive on the server. A paused row with a live task offered Resume and could start a duplicate Ra… | handled | yes | yes | P3a |
| st-32 | Side-asset owner fencing on load: a mismatched owner retires the bundle; a legacy ownerless bundle with an attempt is adopted | Stale-attempt side assets must not attach to a new attempt (SAFE-06). The fail-closed version, however, deleted every pre-owner-schema user's cached posters, trickplay,… | handled | no | yes | P6 |
| st-33 | Load-time normalization of legacy Plex prepared-static lane rows | Rows written before the rendered-Part handoff moved lanes showed the wrong badge. | handled | no | yes | P6 |
| st-34 | Atomic season plan: new rows plus retry markers commit in one snapshot off-lock; conditional compensation on failure; an indeterminate result blocks… | A partial season plan would admit work for rows that never became durable. The earlier version held the store lock across I/O and blocked delegate callbacks. | handled | yes | yes | P6 |
| st-35 | Cross-row path protection: a destructive step never deletes a path another row references, including paths captured only by pending intents | Malformed or imported indexes and cross-kind aliases can share a filename. Deleting one row's file could destroy another row's media. | handled | yes | yes | P6 |
| st-36 | Static byte-range checkpoints use only durable file size; a complete row can be reconstructed into a working checkpoint via a durable clone | #169: optimistic progress from OS temp bytes caused false resume offsets and corrupt partials. | handled | yes | yes | P6 |
| st-37 | A retry that changes attempt identity inherits the multi-GB static checkpoint by cloning the old working body before committing the new owner; the ol… | A manual Retry or relaunch must not throw away a large durable partial. | handled | yes | yes | P6 |
| st-38 | Storage audit: report referenced, unreferenced and orphan-candidate bytes in diagnostics (#171), report-only | Repeated pause/delete/restart cycles were suspected of leaking 5 GB ghost partials, and leaks need to be observable. | dropped-accidental (observability regressed by 6b62b5b0's h… | yes | no | P6 |
| st-39 | General launch-time orphan sweep of unreferenced stable media and side assets | Files whose delete failed, side-cache writes after delete, and old leftovers were never collected (#171 gaps 2-3). | dropped-intentional | no | no | P6 |
| st-40 | Bounded lifecycle bookkeeping: abandoned or superseded failures retire out of the live table into a FIFO capped at 512 | Every boundary scan walked dead intents and one dead intent poisoned every later boundary. | partially-handled | yes | yes | P6 |
| st-41 | Filesystem and journal I/O happens off the store lock (the lock is shared with URLSession delegate callbacks) | Lock-held I/O blocked delegate callbacks and contributed to the main-thread and watchdog stalls reported in #187 and #210. | partially-handled | yes | yes | P3a |
| st-42 | Rollback boundary: an older binary cannot decode newer pending intent cases, so intents must be drained before a downgrade | An exhaustive Codable enum fails on unknown cases, which makes the index unreadable for the older binary. | unclear | no | no | P6 |
| st-43 | If Application Support is unavailable, fall back to the temporary directory | Defensive init. | unclear | no | no | P6 |

### storage-delete

| ID | Edge case | Why | Status | Req | Pinned | Phase |
|---|---|---|---|---|---|---|
| sd-01 | Proactive free-space preflight counts iOS purgeable space | In a live diagnostics pull, Settings showed about 87 GB available while statfs reported about 8 GB, so two 9-11 GB movies were refused with storage_full. | handled | yes | yes | P5 |
| sd-02 | Start-time storage preflight (expected bytes + 500 MB headroom) rejects a transfer the disk cannot hold | A 5 GB download with 600 MB free should fail before it starts, not partway through. | partially-handled | yes | no | P5 |
| sd-03 | Range continuation/retry storage gate | Internal continuations skipped start()'s preflight. A row that failed with ENOSPC could re-plan, purge and refetch held bodies in a loop. | handled | yes | yes | P5 |
| sd-04 | ENOSPC mid-transfer on the static range lane is terminal storage-full, not a fake resumable pause or 'system code 640' | A disk-full error came through as a generic Cocoa 640, or as a 'resumable' pause that failed again on the next byte. | handled | yes | yes | P5 |
| sd-05 | ENOSPC on the opaque/forward-only lane (Jellyfin/Emby transcode, remux) | Same failure as sd-04, but on the lane that has no app-owned checkpoint. | partially-handled (effectively unhandled) | yes | no | P5 |
| sd-06 | Storage-full rows are parked, not auto-redriven against an unchanged full disk (retry storm) | An iPhone diagnostics pull showed 26 retries, with one row failing 9 times in about 2 minutes (retry -> start -> storage_full -> failed, once per second). | partially-handled | yes | yes | P5 |
| sd-07 | A user-initiated Retry always dispatches, bypassing storage-full parking | After freeing space, the user must not stay stuck behind the auto-resume gate. | partially-handled | yes | no | P5 |
| sd-08 | User storage cap (Unlimited/10-250 GB) enforced at enqueue/start, never deleting existing downloads | The user-configured limit. The Settings footer promises it 'won't delete existing downloads automatically'. | partially-handled | yes | yes | P5 |
| sd-09 | Storage estimate includes side assets (trick-play/BIF + chapter images) | Preflight would otherwise under-estimate the real disk use of a download. | handled | no | yes | P5 |
| sd-10 | Delete while downloading: halt the lane and bump the train epoch so in-hop bodies are discarded, not appended to a re-download | A delete racing a finished body tripped the DEBUG pre-append drift assertion, or appended old bytes at offset 0 of the replacement file. | handled | yes | no | P5 |
| sd-11 | Row actions (pause/retry/delete) are fenced to the exact rendered attempt | A stale rendered action must not delete or pause a replacement attempt that reuses the same rating key. | handled | yes | yes | P5 |
| sd-12 | Delete clears all recovery state (finalizing keys, preservation keys, pending resume, retry state) | A stale finalizingKeys entry parked a re-download's byte-complete relaunch as .alreadyFinalizing forever. Stale preservation keys leaked the deleted attempt's restart bu… | handled | yes | no | P5 |
| sd-13 | Delete cancels in-flight side-cache work and removes its staging files (#171 async side-cache race) | #171: a side-cache task finishing after delete wrote an orphan poster/BIF/tile that no index entry referenced. | handled | yes | no | P5 |
| sd-14 | Deleting a Jellyfin/Emby transcode row tears down the server ActiveEncoding durably | Engine audit B.9: delete removed the row before releaseInFlight read it, and a failed launch sweep left the deleted row's play-session id with no handle to tear it down. | handled | yes | yes | P5 |
| sd-15 | Deleting an Emby Convert row cancels its server Sync job, including failed rows and crash-window ambiguous creates | An abandoned conversion keeps rendering on the server. A row failed by terminal-poll 401/403 still had a Converting job (B.9 Emby edge leak). A session mismatch at delet… | handled | yes | yes | P5 |
| sd-16 | Deleting a Plex row still in server prep removes its type-42 optimize item | B.9: before this, a deleted in-prep download kept transcoding on the server and could store a rendered version nobody wanted. | partially-handled | yes | yes | P5 |
| sd-17 | Completed or handed-off Plex renders are never deleted on row delete (shared server version may be reused) | Deleting a completed type-42 item destroys the rendered version that other rows or relaunches may reuse. | dropped-intentional | yes | no | P5 |
| sd-18 | Deletion stays pending (row and files intact) until server-cleanup authority is durable | Deleting local state before the cleanup journal was durable would leak server encoders or conversions with no remaining handle. | handled | yes | yes | P5 |
| sd-19 | Missing server-cleanup identity: delete locally but surface the leak, and keep that disclosure after a successful delete | Legacy rows without server identity would otherwise be undeletable forever, or the leak would be cleared silently by lastError = nil. | handled | yes | yes | P5 |
| sd-20 | Delete while finalizing (validated promotion window) | A user tapping Delete during 'Verifying download…' or a stuck promotion expects the row to go. | partially-handled | yes | no | P5 |
| sd-21 | Delete must be able to free space when the volume is completely full | Disk full is exactly when a user deletes downloads. The delete path writes the index (and the cleanup journal) before removing any file. | unclear | yes | yes | P5 |
| sd-22 | Rows with no attemptID (ownerless/legacy) can still be deleted | A row the user cannot remove is a dead end, and Remove All Downloads skips it as well. | handled (unreachable by construction) | yes | no | P5 |
| sd-23 | Delete releases the in-flight slot, queue-title protection, and optimize progress/ETA | A deleted job leaked its activeJobs slot (blocking re-download) and showed a stale 'Preparing on server… N%' on re-download. | handled | yes | no | P5 |
| sd-24 | Re-download after delete starts with clean budgets (truncation counter, retry/range budgets) | M-7/D6: a re-download inherited stale truncation counts and parked immediately. | handled | yes | no | P5 |
| sd-25 | Pausing a Plex server-prep row (persisted as .queued) parks it synchronously | Routing it through the async no-task URLSession pause raced poller reattachment and left contradictory paused/active state. | handled | yes | yes | P5 |
| sd-26 | User pause supersedes pending system auto-resume and manual-queue-resume markers | A backend refresh silently retried a row a few seconds after it reached .paused. | handled | yes | no | P5 |
| sd-27 | Pause keeps held ahead-of-checkpoint stashes; cancel/delete/terminal purge them | M-6: purging on pause destroyed up to a full train of completed bodies that Resume would have reused. | handled | yes | no | P5 |
| sd-28 | Pause installs the halt at snapshot time and late cancel callbacks never re-pause a resumed replacement | L4: a pause window let a finished body continue the train and drop the pause. Delayed cancel callbacks flipped a resumed row back to Paused. | handled | yes | yes | P5 |
| sd-29 | Global queue pause persists across relaunch; Emby Convert keeps polling while paused and a completed convert parks instead of transferring | Emby conversions run on the server regardless, so polling should continue. Byte transfer must still honor Pause All. | handled | yes | no | P5 |
| sd-30 | Resume All is memoryless: retries every paused and failed row, then drives server prep and pending static resumes | #172: the toolbar and Resume All semantics were confusing. A quick Resume tap turned into an accidental Pause All once the first row started. | handled | yes | yes | P5 |
| sd-31 | Manual static resume while the queue is paused is honored without clearing the global gate | Users can resume one row under Pause All without the stale-queued detector re-parking it. | handled | yes | no | P5 |
| sd-32 | Retrying a paused or failed Emby Convert row that still owns a job id resumes POLLING, never a fresh POST | The poll-health budget fails a row after about 5 minutes offline while the job keeps rendering. A retry that posted again created a duplicate conversion. | handled | yes | yes | P5 |
| sd-33 | Persisted URLSession resume data for static rows resumes on the range lane | #227: the opaque lane moved a partial-body temp as a whole file and corrupted the download. | handled | yes | no | P5 |
| sd-34 | Resuming a paused Plex server-prep row reattaches to the existing optimize queue item (no duplicate transcode) | Recreating the optimize request on resume risked a duplicate Plex transcode. | handled | yes | no | P5 |
| sd-35 | Retry rehydrates the user's original lane intent from persisted metadata (compatible remux, Emby existing/converted version, original) | After a relaunch, makeMediaItem() lacks parts, so retries silently became optimized transcodes or were re-badged as Original. | handled | yes | yes | P5 |
| sd-36 | A failed row stays visible and retryable until backend auth/server preflight succeeds | Tapping Retry while disconnected removed the only visible retry affordance. | handled | yes | no | P5 |
| sd-37 | A resume-data retry restarts missing side-asset hydration for the exact attempt | The original failure cancelled side caches, and the resume-data path returns before the backend entry points that enqueue them. | handled | yes | no | P5 |
| sd-38 | Sign-out is a resumable pause of that backend's active rows, run before credentials are cleared | An open URLSession request keeps its Authorization header after logout. Encoder teardown needs the right session. | handled | yes | yes | P5 |
| sd-39 | A post-logout 401/403 defers to 'waiting for session' instead of failing the row | A background remainder racing logout got a 401 with the revoked token. | handled | yes | no | P5 |
| sd-40 | No purge of downloads on sign-out or server removal | Offline media must survive sign-out and unreachable servers. | dropped-intentional | yes | no | P5 |
| sd-41 | Side-asset payloads are validated before promotion (no HTML/error bodies in the offline bundle) | Corrupt error pages were promoted as posters, BIFs or subtitles. | handled | yes | no | P5 |
| sd-42 | Process-wide pacing of optional side-asset requests per origin | An incident sent 84 chapter-image requests in about 5 seconds and tripped server crawl rules (docs/archive/downloads/2026-07-15-optional-download-side-assets.md). | partially-handled | yes | no | P5 |
| sd-43 | Completed-row side-asset repair is bounded per launch and charged only on real dispatch | Assets the server can never produce were refetched on every foreground. Lifecycle triggers without a session burned the whole budget. | partially-handled | yes | yes | P5 |
| sd-44 | Side-asset requests honor the Wi-Fi-only download setting | Lens 4 F2: side assets total several MB and are data-plane traffic. | handled | yes | no | P5 |
| sd-45 | Pause / Pause All parks optional side-asset work; resume continues it | Pausing should stop new network starts, including side assets. | partially-handled | yes | no | P5 |
| sd-46 | Orphaned files in the Downloads directory are eventually reclaimed | #171: repeated pause/delete/restart could leave ghost multi-GB files; failed deletes had no later garbage collection. | partially-handled | yes | no | P5 |
| sd-47 | Remove Completed includes .unverified; Remove All cancels active transfers | These are the Settings bulk actions. | handled | no | no | P5 |
| sd-48 | A storage-limit or other pre-transfer abort fails the row BEFORE dropping its pending-resume marker | In the #210 cousin, a queued row with a lingering marker escaped stale demotion and re-drove the rejected start on every backend-ready edge. | handled | yes | no | P5 |

### plex

| ID | Edge case | Why | Status | Req | Pinned | Phase |
|---|---|---|---|---|---|---|
| plex-01 | X-Plex-Client-Profile-Name=Generic on every download-side Plex decision call | An unknown or missing profile name makes PMS return a bare HTTP 400. The Safari profile forced about 20 Mbps transcodes of 4K HEVC (hard constraint in CLAUDE.md). | handled | yes | yes | P4 |
| plex-02 | Original direct download requires an AVPlayer preflight of the remote static URL; on failure, fall back to the optimizer | The decision endpoint can say direct play while AVFoundation still cannot open the static source as a local file. | handled | yes | yes | P4 |
| plex-03 | A delete or pause landing during the long preflight must not upsert or seed a zombie prep row | Lens 6 F3: the pass branch would start a transfer for a deleted row. The fail branch would seed a queued prep row that the refresh kick revives as a full optimize. | handled | yes | yes | P4 |
| plex-04 | Existing Plex Version chosen explicitly: static as-is transfer, no preflight, never touches the optimize queue | #112: the user picks a pre-rendered version and must get exactly that file, with no re-render. | handled | yes | no | P4 |
| plex-05 | A static retry of a rendered or existing version keeps the exact Part identity and fails closed if the Part vanished | PLEX-F4: index-based fallback could silently download the raw source or a different Plex Version, unpreflighted. | handled | yes | no | P4 |
| plex-06 | The optimize create uses the type-42 playlist grammar with a server-resolved targetTagID and custom Device/MediaSettings | Hardcoded tag IDs are version-specific. Custom ladder rows must send Item[Device][profile] plus MediaSettings, as python-plexapi does. | handled | yes | no | P4 |
| plex-07 | Prefer an alternate (writable) library location for optimizer output | locationID=-1 writes beside the original. Read-only media mounts then fail the optimize. | handled | yes | no | P4 |
| plex-08 | Surface server read-only/optimizer failure: a completed type-42 item with failed>0 and successful==0 fails the row | Without this, the row sat in 'Preparing on server' forever when Plex could not write the optimized version. | handled | yes | no | P4 |
| plex-09 | Completed queue item but Part not yet indexed: bounded 120 s grace, armed only on iterations where metadata was inspected; disarm when status flaps b… | Plex reports completion before metadata shows the Part. A spurious completed reading, or a metadata outage, must not fail a valid job. | handled | yes | yes | P4 |
| plex-10 | Overall optimize deadline persisted across relaunches | PLEX-F6c: a healthy-but-never-producing queue item polled forever. | handled | yes | no | P4 |
| plex-11 | Poll health: consecutive 401/403 polls go terminal as auth-dead; unreachable diagnostics are bucketed | A-1: revoked tokens and dead servers looked like slow renders behind 'Preparing on server'. | handled | yes | yes | P4 |
| plex-12 | Re-resolve the Plex lane on every poll iteration; on sign-out or server change, park the row for deferred resume | The poll can outlive the enqueue-time token and address by hours. | partially-handled | yes | no | P4 |
| plex-13 | Orphan guard: the poll loop stops when the row is gone or the in-flight slot is released | B.9: after a delete, the fresh-start poller kept hitting the server every 5 s. | handled | yes | no | P4 |
| plex-14 | Deleting a row still in server prep cancels exactly its own non-completed type-42 item | B.9: otherwise the server keeps transcoding, and later stores a version, for an abandoned download. | partially-handled | yes | no | P4 |
| plex-15 | Never delete completed type-42 items, whether in the sweep or on delete | Deleting a completed type-42 item deletes the rendered Plex Version, which a relaunched client or another row may still need. Live evidence: the queue entry carries no o… | dropped-intentional | yes | no | P4 |
| plex-16 | Stale-job sweep is scoped to our '[Labstream ' marker, minus protected titles (in-memory plus persisted non-complete rows) | Abandoned pending items backlog the conversion queue. Persisted titles stop a relaunch from briefly exposing valid work before serverPrepAttempts is rebuilt. | handled | yes | no | P4 |
| plex-17 | Queue-title protection held for the whole download lifetime, not released in a defer | A defer released protection when session.start kicked off, so a concurrent job's sweep could delete the Part mid-download. | handled | yes | no | P4 |
| plex-18 | Relaunch during optimize: adopt an already-completed tier-matching render before inspecting or recreating queue work | While the app was suspended, Plex may have finished and removed the type-42 item. A missing item does not mean another POST is needed. | handled | yes | yes | P4 |
| plex-19 | Relaunch recreate only when the queue was actually inspected and the item is provably absent | A transient bg-key failure followed by a recreate puts a duplicate optimize beside a running job. | handled | yes | yes | P4 |
| plex-20 | Bounded in-loop retry of the background-processing key lookup | Losing one early bg-key request also lost completion detection (fell back to a 24 h metadata-only loop). An unbounded retry cost one extra failing request per tick. | handled | yes | no | P4 |
| plex-21 | Paused server-prep resume reattaches to the existing queue item and does not re-POST; a stale poller token is cleared | Re-POSTing duplicated a multi-hour transcode. A stale poller token made the scanner skip the row as already attached. | handled | yes | no | P4 |
| plex-22 | Failed optimize retry keeps the user's requested target | A user who asked for 4K 40 Mbps and hit a server failure or the 24 h timeout should get the same profile on retry. #194 also persists the requested profile. | dropped-intentional-but-stale (generic retry documents 'def… | yes | no | P4 |
| plex-23 | A validated original that fails the local playback probe falls back to an optimize, with no loop | Some originals download fine but AVFoundation rejects them locally. | partially-handled | yes | yes | P4 |
| plex-24 | Fallback seeds are stamped with the optimize lane and serverPrepThenStatic before the first upsert | PLEX-F1: a stale .original-lane seed let delete miss the server job, and a relaunch retry re-downloaded the raw original that had just failed preflight. | handled | yes | no | P4 |
| plex-25 | At handoff, persist the rendered Part id, its size, staticByteRange resume mode and serverPreparedVersion atomically | PLEX-F2: the source part size made demoteIncompleteCompletedStaticRows fail complete optimize downloads. Relaunch must Range-resume the file rather than restart the opti… | handled | yes | no | P4 |
| plex-26 | Optimized-version tier matching: ±16 px bounding box, container bitrate up to ×1.10 of the cap plus 768 kbps, original quality at source height | Exact-height or tight-bitrate gates missed valid renders (1088 vs 1080, surround audio) and re-enqueued multi-hour jobs. A loose gate reused 720p for 1080p requests. | handled | yes | no | P4 |
| plex-27 | Optimize baseline is only the selected source part, so a tier-matching existing Plex Version is discoverable | Old builds put every part id in the baseline, so a queued row could never adopt a matching rendered file. | handled | yes | no | P4 |
| plex-28 | An optimize-create failure (HTTP 400 duplicate) must not flash a terminal failed row | Plex rejects odd or duplicate creates while an already-rendered version is still discoverable from metadata. | partially-handled | yes | no | P4 |
| plex-29 | Unpause the server's idle-paused background queue (conditional write) | Queued optimize jobs never ran while BackgroundQueueIdlePaused was set. | handled | no | no | P4 |
| plex-30 | Optional 'Prioritize quick downloads': move only our item to just after the active conversion | Gives the user control over queue wait without pre-empting a running transcode. | handled | no | yes | P4 |
| plex-31 | Server-prep progress attribution under concurrent jobs | /activities can expose one activity while PMS runs several. Sole-optimizer fallback misattributed progress, and the percentage froze under ambiguity (#67, #181). | partially-handled | yes | no | P4 |
| plex-32 | Finalizing caption instead of 'Preparing on server… 100%' | #186: 100% looked done while the app waited for indexing. | handled | no | no | P4 |
| plex-33 | Plex audio track for server-prepared output: select the preferred stream on the Part before the optimize POST, best-effort | Plex optimizer output follows the Part's selected audio stream. Season downloads need the preferred language. | partially-handled | yes | yes | P4 |
| plex-34 | Original-quality optimize target maps to the server's 'Original Quality' tag (fallback id 3) with nil caps; the hidden server labels are not shown tw… | The picker shows 'Original video quality' while PMS names the target 'Original Quality'. | handled | yes | no | P4 |
| plex-35 | Multi-part items (one Media with several Parts) | Only the selected partIndex is downloaded or optimized. Existing-version options use part.first. The season planner hard-codes partIndex 0. | unclear | no | no | P4 |
| plex-36 | Optimize chain is a cancellable registered Task; superseded chains never tear down a newer attempt's state | A quick pause and resume, or delete and re-download, created a new attempt on the same key. Stale catch blocks stripped its slot and poller. | handled | yes | yes | P4 |

### emby

| ID | Edge case | Why | Status | Req | Pinned | Phase |
|---|---|---|---|---|---|---|
| emby-01 | Route decided by an authoritative download PlaybackInfo POST (static-mp4 download profile, ~200 Mbps ceiling), not the naked-item SupportsDirectPlay | The naked-item SupportsDirectPlay flag is optimistic, and the HLS playback profile returns .m3u8 URLs that can't be downloaded. A bitrate cap must never force a transcod… | handled | yes | no | P4 |
| emby-02 | Explicit static stream.mp4 transcode URL with the minted PlaySessionId (the codecless /stream URL 500s on HEVC/DTS) | Emby's minted codecless URL stream-copies HEVC/DTS sources and fails with HTTP 500. | dropped-intentional | no | no | P4 |
| emby-03 | A live transcode is rerouted to a persistent server Convert job. .original/.existingVersion fail closed instead of silently becoming forward-only | Live Emby transcodes are ephemeral and not range-resumable, so a dropped connection restarted a multi-GB download from zero. A row stamped .original must never accept re… | handled | yes | no | P4 |
| emby-04 | Existing-version/converted handoff is gated on local playability (container+codec), not Emby's streaming DirectPlay verdict | Emby 4.9 returns SupportsDirectPlay=false even for a clean mp4/h264 converted file. That silently killed the convert→download handoff. | handled | yes | no | P4 |
| emby-05 | No recursion: the .existingVersion handoff never re-enters the Convert lane | Convert handoffs call downloadEmby(.existingVersion). Rerouting would loop Convert→download→Convert. | handled | yes | no | P4 |
| emby-06 | Attempt-currency check after the PlaybackInfo await, with best-effort release of the just-minted PlaySession | Lens 6 F2: a delete or pause landing during negotiation was fully undone (row re-seeded, transfer started). | handled | yes | no | P4 |
| emby-07 | Explicit mediaSourceIDOverride must equal the negotiated MediaSource (EMBY-F6) | PlaybackInfo silently falls back to another source when the requested converted/existing version vanished, which downloads a different rendition under the old intent. | handled | yes | no | P4 |
| emby-08 | Width-aware resolution label persisted from negotiated dimensions for server-prepared versions | A 1920x800 converted copy of a 4K original was labelled from the primary media (#253). | handled | yes | no | P4 |
| emby-09 | Expected bytes for static originals and remux come from MediaSource.Size | Emby Part.size is always nil. Without this there is no storage or progress signal. | handled | yes | no | P4 |
| emby-10 | Compatible remux (#83) is forward-only: PlaySessionId is persisted before the transfer starts, torn down on terminal, and kept alive by a ping-only k… | The encoder leaks after a hard kill (#84). Emby idle-kills an unpinged remux at about one minute (EMBY-F9). | handled | yes | no | P4 |
| emby-11 | Compatible-remux fallback to the 1080p Convert preset is disclosed, and confirmation is required above 1080p (EMBY-F4) | When the video can't be remuxed, .optimizeCompatible reroutes to the default 1080p preset, which silently downgraded 4K sources. | handled | yes | no | P4 |
| emby-12 | A visible .preparing row is seeded before the expensive reuse/refresh preflight | The headset UI must reflect the accepted tap immediately, and repeat taps must see an active row. | handled | yes | no | P4 |
| emby-13 | Reuse an already-converted File source instead of creating a duplicate Convert job (#126 on the auto-convert path) | Repeat downloads piled up duplicate '- tv (N)' versions, and Sync jobs could transcode a derived source whose file was gone ('No such file' → job Failed). | handled | yes | no | P4 |
| emby-14 | Reuse fidelity: exact tier first, below-tier only in the source's own band, exact match for 4K/Original, and audio-language match when an audio strea… | A stale 404p sibling satisfied a 1080p request on a 4K source. Reuse ignored the user's audio choice. | partially-handled | yes | yes | P4 |
| emby-15 | Bounded targeted item refresh plus about 30 s source poll before creating a new conversion (#133) | A prior Sync job had already copied the MP4 next to the original, but PlaybackInfo hadn't indexed it, so the app re-converted. | handled | yes | no | P4 |
| emby-16 | Persist the full pre-conversion File-source snapshot so that, after relaunch, a prior converted version is never mistaken for the new output | With only the original id excluded, an older converted sibling was picked as the fresh output. | partially-handled | yes | no | P4 |
| emby-17 | Convert jobs are identified by the persisted job id, never by the submitted name | Emby ignores the submitted job name (verified on 4.9.3), so Plex-style '[Labstream …]' title markers are impossible. | handled | yes | no | P4 |
| emby-18 | A complete Sync-job baseline is captured before POST. The list decoder tolerates foreign clients' jobs | Without it, a POST accepted just before a kill orphans a job. One foreign job with an odd shape made the baseline undecodable, which failed EVERY convert start. | handled | yes | no | P4 |
| emby-19 | dispatchAmbiguous is persisted BEFORE POST. Create-failure disposition: pre-dispatch or 4xx clears recovery; transport, 5xx and bad 2xx bodies preser… | A 5xx or transport error cannot prove the server didn't create the job. | handled | yes | no | P4 |
| emby-20 | Crash-window recovery adopts a job only when exactly one new job matches the fingerprint inside a bounded creation window under the same public user.… | A kill between POST acceptance and persisting the job id orphaned the job and created duplicates. | handled | yes | no | P4 |
| emby-21 | Crash-window identity older than 24 h expires: handed to cleanup and the row released | Recovery past the adoption deadline could only fail, so the row looped .preparing→.failed on every Retry with delete as the only escape. | partially-handled | yes | no | P4 |
| emby-22 | A row deleted or paused while POST /Sync/Jobs is in flight is not resurrected | Re-upserting the row after a user delete resurrects a cancelled download. | partially-handled | yes | no | P4 |
| emby-23 | Status polling: healthy renders are unbounded; a consecutive run of unreachable/5xx/undecodable responses is bounded (60 × 5 s) | EMBY-F13: a persistently unreachable server left the row in 'Preparing on server…' forever. | handled | yes | no | P4 |
| emby-24 | Terminal poll HTTP: 404/410 clears the job id (fresh retry); 401/403 KEEPS it so re-login plus Retry resumes the live job | A dead job must not be re-polled forever, but an auth blip must not discard hours of server-side render. | handled (restored before P4: `isTerminalEmbyConvertPollStatus`, clear only on 404/410) | yes | yes | P4 |
| emby-25 | Retrying a .failed row that still owns a Sync job id resumes POLLING rather than POSTing again | The poll-health budget parks a row as failed after about 5 min offline while the job keeps rendering. A fresh POST orphaned it as a duplicate. | handled (restored before P4: `DownloadRetryPreparationPolicy` resumes polling for a failed row that owns a job id) | yes | no | P4 |
| emby-26 | Progress pinned at 0 while Converting shows indeterminate 'Preparing on server…', never '0%' or an ETA | Emby reports Progress 0 until completion, then jumps to 100. | handled | yes | no | P4 |
| emby-27 | Job status decoding is forward-compatible: unknown strings are non-terminal | An unexpected server string must never crash polling. | partially-handled | yes | no | P4 |
| emby-28 | Server-side Failed/Cancelled fails the row and clears the job id so Retry creates a fresh job | A failed row that kept a terminal job id re-polled and re-failed forever. | handled | yes | no | P4 |
| emby-29 | Post-completion indexing lag: item refresh, then poll unfiltered PlaybackInfo up to 72 × 5 s for the new File source | Emby reports Completed about 3 min before LibraryMonitor/ffprobe exposes the file. A single fetch failed rows with 'Converted source not found'. | handled | yes | no | P4 |
| emby-30 | Pickup selects the NEW converted output (outside the snapshot, converted-shaped, tier-sane relative to min(requested, source)) | A foreign low-res sibling that slipped past the snapshot was adopted as our output (9f782b4e). | partially-handled | yes | no | P4 |
| emby-31 | Relaunch at 'Preparing… 100%': check for an exposed converted source before the job loop, and cancel the still-live job before handing off (EMBY-F1) | Rows sat at 100% until the user retried. The handoff deleted the only job-id handle while the job rendered a duplicate. | partially-handled | yes | no | P4 |
| emby-32 | The .preparing row is kept until the static handoff atomically replaces it (EMBY-F11) | Removing the row before re-download left a kill window with no durable row. | handled | yes | no | P4 |
| emby-33 | With the queue paused, Convert polling continues; the static handoff is parked as paused | A global pause otherwise stranded persistent Sync work in .preparing. | handled | yes | no | P4 |
| emby-34 | A stale convert chain never fails, re-plants progress on, or resurrects a fresh row (attempt UUID plus row/job/target guard after every await) | Lens 6 F4/F6: an old chain's failEmbyConvert bricked a fresh re-download and stripped its slot. | handled | yes | no | P4 |
| emby-35 | Convert-lane persistence failures fail the row and release the slot | Review finding: a guard-return left a .preparing row holding activeJobs with no poller. | handled | yes | no | P4 |
| emby-36 | Deleting a preparing/failed/paused convert row durably journals server-job cancellation before local deletion; session mismatch defers rather than lo… | Audit gaps: a session mismatch at delete lost the job id; failed rows never cancelled; ENOSPC on the journal made delete a no-op (M4). | handled | yes | no | P4 |
| emby-37 | Cleanup never cancels a job owned by any live row | A crash-window delete followed by an immediate re-download creates a fingerprint-identical job; the sweep would DELETE the user's active conversion. | handled | yes | no | P4 |
| emby-38 | Only one recovery per tombstone/intent at a time | Overlapping lifecycle sweeps duplicated GET /Sync/Jobs and raced DELETEs. | handled | yes | no | P4 |
| emby-39 | The converted file is kept for future reuse; Sync-job DELETE never deletes an already-converted file | #126 reuse depends on the kept file. | partially-handled | yes | no | P4 |
| emby-40 | Server Sync-job hygiene: Completed/Failed jobs are never deleted, so they accumulate | The full-baseline requirement fetches the whole list (not paged) on every create and recovery. The list grows without bound, and if the server ever paginates, isComplete… | unclear | no | no | P4 |
| emby-41 | Audio stream intent is persisted and carried through Convert create, reuse, resume and handoff | Relaunch-resume reuse could not audio-match. | handled | yes | no | P4 |
| emby-42 | Text-subtitle sidecars for convert handoffs are cached from the SOURCE MediaSource (converted MP4s lack subtitle streams) | Optimized Emby copies don't carry subtitles. | partially-handled | yes | no | P4 |
| emby-43 | Resume, retry and cleanup run only under the same server and user that created the job | A different user's credential must not resume or cancel another user's conversion. | handled | yes | no | P4 |
| emby-44 | Server without Emby Premiere / Sync-Convert capability | Convert (Sync) is a Premiere feature. Every non-direct Emby optimize download depends on it. | unclear | yes | no | P4 |
| emby-45 | 4K/Original Convert uses profile:custom with mp4/h264/aac (tv downscales to 1080p; the literal 'original' token is rejected with 500) | #128: a true 4K output was impossible via the tv profile. | handled | yes | no | P4 |
| emby-46 | POST body is lowercase camelCase with targetId originalmediafolder (never the destructive originalmediafolderreplace). The create response nests the… | PascalCase returns 500. Decoding a bare job crashed with keyNotFound(Id). | handled | yes | no | P4 |
| emby-47 | A row with no job id after relaunch (died before create) fails as retryable 'did not finish starting'; a prepared-phase baseline is discarded | A preflight-phase crash must not hang in .preparing or blind-POST. | handled | yes | no | P4 |
| emby-48 | Pausing a .preparing convert row parks it; resume re-attaches polling of the same job | Pause is a keep, not a cancel. | handled | yes | no | P4 |
| emby-49 | The fresh convert chain runs inline in the caller's await (unregistered), while the relaunch chain runs in a registered poller task | Inline awaiting blocks callers for hours. This is the root of #362's serial season admission (owned by another agent). | partially-handled (season path fixed by #363/b63d1757; sing… | yes | no | P4 |
| emby-50 | A static original's destination extension stays stable across retry | A changed extension orphans the byte checkpoint (JF-F1 class). | partially-handled | yes | no | P4 |
| emby-51 | The debug probe classifies routes the same way production does | Probe evidence must reflect production routing. | partially-handled | no | no | P4 |

### jellyfin

| ID | Edge case | Why | Status | Req | Pinned | Phase |
|---|---|---|---|---|---|---|
| jf-01 | Server-minted PlaySessionId for the transcode lane (no locally minted ids) | A random local PlaySessionId made some Jellyfin servers return HTTP 500 from /Videos/{id}/stream.mp4 for items that otherwise stream fine. | handled | yes | no | P7 |
| jf-02 | Compatible remux gated by a re-probe of PlaybackInfo, not in-memory Part streams | Retry after relaunch rebuilds a lean MediaItem with no stream arrays, so a Part-based gate would misroute or refuse the retry. | handled | yes | yes | P7 |
| jf-03 | Remux request fallback: stale UI/retry for a non-copyable source becomes a 1080p 8 Mbps transcode and is relabeled lane .optimize | Without this, a stale remux row would request a copy the server cannot do, or show 'Remux' in the UI and retry on the wrong lane. | handled | yes | yes | P7 |
| jf-04 | Remux lists the source video and audio codec so the server stream-copies, keeps 7.1 (no maxAudioChannels), and uses AAC as the re-encode target | With aac alone, ac3/eac3 sources were silently re-encoded to AAC 192k while the UI promised a copy. A 6-channel cap forced a 5.1 downmix of 7.1 tracks that could have be… | handled | yes | yes | P7 |
| jf-05 | HEVC hev1->hvc1 tag fixup on finished MP4-family bodies (remux output and static mp4/mov) | AVFoundation black-screens on hev1. Jellyfin's progressive mp4 output does not force hvc1 (#83/#127). | handled | yes | yes | P7 |
| jf-06 | Live-forward streams are not byte-offset resumable: URLSession resume blobs are refused and the row fails with a 'restart from the beginning' message | An encoder stream has no stable validator. Resuming it by offset can return a 200 full restart or a 416, or splice two encodes into one corrupt file. | handled | yes | yes | P7 |
| jf-07 | Forward-only body that finishes while the app is terminated is adopted on redelivery (JF-F4) | On device, nsurlsessiond can finish a multi-GB encoder stream after the app dies. Dropping the redelivered temp file forced a full re-transcode. | handled | yes | yes | P7 |
| jf-08 | Tighter truncation guard for forward-only streams (0.95), and nil duration finalizes .unverified instead of .complete (JF-F2) | A cleanly killed encoder at 80-95% of runtime produces a valid, playable container that used to finalize .complete with the tail missing. | handled | yes | yes | P7 |
| jf-09 | Two-strike truncation park: repeated truncations keep the file as .unverified instead of deleting and re-transcoding forever | An environment that always kills the encoder near the end (idle kill, proxy timeout) would otherwise re-render a long movie in a loop. | partially-handled | yes | yes | P7 |
| jf-10 | Forward-only stall watchdog: cancel and restart a zero-bandwidth stream after 90s, at most 2 automatic restarts | After a network switch an encoder stream can look active forever at zero bandwidth (#189). Users had to cancel and retry by hand. | handled | yes | yes | P7 |
| jf-11 | Keepalive reports an advancing position for no-Content-Length rows (N2/F2c) | Forward-only rows have progress 0. The keepalive pinged PositionTicks=0 forever, and the server could idle-kill what looked like a stationary session. | handled | no | yes | P7 |
| jf-12 | Keepalive lifecycle: removes itself on any exit (generation guard), re-resolves the session every tick, stops on 401/403 with a quarantine per creden… | A returned task stayed registered, so after re-login the keepalive never restarted and the server idle-killed the transcode. Separately, try?-swallowed responses hid a d… | handled | yes | yes | P7 |
| jf-13 | Keepalive must not run for a row that has no live transfer (IC-4) | A Jellyfin forward-only row stuck .queued with no URLSession task keeps POSTing playing/progress/ping. That keeps a dead encoder alive and defeats the server's idle kill. | partially-handled | yes | yes | P7 |
| jf-14 | PlaySessionId is persisted on the row so a hard kill can still tear down the encoder; teardown goes through a durable cleanup-intent journal | #84: in-memory psid maps die with the process, which leaked live FFmpeg encoders on the server. | handled | yes | yes | P7 |
| jf-15 | Post-await currency check after PlaybackInfo, with best-effort teardown of the superseded minted session | A delete or pause during the PlaybackInfo await used to be fully undone: the row was re-seeded .queued, the psid persisted, the keepalive started and the transfer began… | handled | yes | yes | P7 |
| jf-16 | Original retry keeps the on-disk container extension (lean rebuilt item collapses to .mp4) | A retry rebuilt without parts switched <key>.mov/.m4v to .mp4, which zeroed the checkpoint, orphaned the partial and broke extension-keyed validation (JF-F1). | handled | yes | yes | P7 |
| jf-17 | Retry intent survives relaunch: a compatibleRemux lane with no optimizeTargetName retries as .optimizeCompatible, persisted audioStreamIndex and medi… | Without the lane discriminator, remux rows retried as .original. Deriving the choice from a missing Part turned original retries into transcodes. | handled | yes | yes | P7 |
| jf-18 | Retry against a different Jellyfin server or user is deferred instead of replayed (A-5), and the job never reads activeBackend (#84) | A forward-only row replayed against a foreign server fails with a misleading 404, or cleans up or pings under the wrong account. | handled | yes | no | P7 |
| jf-19 | Negotiated MediaSource id is persisted when PlaybackInfo picks a different source, and side assets use the resolved id | Trickplay, subtitles and later retries must address the source that was actually downloaded. | partially-handled | yes | no | P7 |
| jf-20 | Selected audio track is honored for server-prepared lanes | The user's track choice must survive the transcode or remux. | partially-handled | yes | no | P7 |
| jf-21 | Transcode and remux progress shows an estimated ~% from duration x bitrate (remux uses the source size) | No Content-Length; without an estimate the bar sat at 0% (#97). | partially-handled | yes | yes | P7 |
| jf-22 | Storage-limit and free-space preflight sized to the expected download | Refuse a 5 GB job with 600 MB free up front rather than mid-transfer. | partially-handled | yes | no | P7 |
| jf-23 | Trickplay cache: header auth, ApiKey stripped from tile URLs, sanitized local playlist, and an 'apikey=' guard before publishing | Offline scrubbing (#79) must never persist tokens in cached playlists. | handled | yes | no | P7 |
| jf-24 | Background-wake finalize defers the AVPlayer probe to .unverified and revalidates in the foreground | A muted probe cannot advance during a background launch, and serialized 8s+15s probes overran the wake window (Lens 4 F4). | handled | yes | no | P7 |
| jf-25 | Sign-out pauses in-flight Jellyfin rows and tears down encoders while credentials still exist | An open URLSession response keeps streaming under the revoked token, and teardown needs the right server's credentials. | handled | yes | no | P7 |
| jf-26 | Opaque forward-only transfer failure on a transient network error | Overnight downloads hit Wi-Fi blips. Static lanes self-heal; forward-only streams cannot resume. | partially-handled | no | no | P7 |

### planner-ui

| ID | Edge case | Why | Status | Req | Pinned | Phase |
|---|---|---|---|---|---|---|
| pu-01 | Tri-state watched state: a missing value is never treated as unwatched (Jellyfin/Emby); Plex nil viewCount means unwatched | An incomplete payload must not grow an 'Unwatched' batch. Plex leaves out viewCount for never-watched items, so without the Plex rule the Unwatched scope selected nothin… | handled | yes | yes | P4 |
| pu-02 | Unwatched scope offered only when usable watched state exists; skipped 'unavailable' count is shown | #205 approved scope: if the server returns no usable watched state, offer only All episodes and tell the user how many episodes were skipped. | handled | yes | yes | P4 |
| pu-03 | Idempotent re-run of Download Season (dedup by record identity): complete/unverified = available, queued/preparing/downloading = planned, paused = st… | Repeating Download Season must never create duplicate transfers or server-prep jobs, and must never resurrect a row that is being deleted. | handled | yes | yes | P4 |
| pu-04 | Episodes added to the season later are picked up by running Download Season again (no rolling sync) | #205 explicitly scopes out rolling refill. New episodes reach the plan only through an explicit re-run, which dedup turns into .add rows. | dropped-intentional | no | no | P4 |
| pu-05 | Persist every planned row atomically before admitting any work; on failure start nothing | A partially saved plan would start some episodes with no durable record of the others, or leave orphan rows. | handled | yes | yes | P4 |
| pu-06 | Indeterminate atomic-write outcome pauses download admission (fail closed) | If storage cannot prove whether the plan was saved, continuing could start rows nobody persisted, or lose rows that were persisted. | handled | yes | no | P4 |
| pu-07 | Lane-aware bounded admission window (static 2 / server-prep 1 / live-forward 1 / total 3) | #205 adversarial review: calling backend entry points for a whole season would fire every optimizer/convert/encoder job at once. | partially-handled | yes | yes | P4 |
| pu-08 | Ordinary stale/relaunch recovery must not start season-pending rows | Pending rows have no task by design. Recovery scanners that read them as 'stalled queued work' would start the whole season at once. | partially-handled | yes | no | P4 |
| pu-09 | Admission revoked when a row is deleted, replaced or paused during the metadata-refresh suspension | #293: a stale admission could recreate a deleted row through the public enqueue API. | handled | yes | yes | P4 |
| pu-10 | Exact source Part re-found by sourcePartID at admission (media array may reorder) | Picking the version by index after the server reordered Media would silently download a different version. | handled | yes | yes | P4 |
| pu-11 | Original quality never falls back to an unrelated bitrate rendition; an unsupported episode becomes its own failed row | #205 scope: 'Do not silently download an incompatible or materially unrelated file as fallback'. One bad episode fails only its own row. | partially-handled | yes | yes | P4 |
| pu-12 | Nearest existing server version by proportional (log-ratio) resolution+bitrate distance; tie goes to the smaller file; never auto-select a version wi… | #205 spec for Use Existing Versions. | handled | yes | yes | P4 |
| pu-13 | Unknown episode sizes are never counted as zero; known bytes over the cap block; unknown sizes need explicit confirmation | #205 adversarial review: the old storage policy failed open for nil estimates. | partially-handled | yes | yes | P4 |
| pu-14 | Audio for server-prepared/remux/transcode outputs: preferred language/role, then server default, then first track; byte-for-byte lanes keep every tra… | #205 audio scope: no season-level audio prompt. | handled | yes | no | P4 |
| pu-15 | Cancelled planning sheet never starts the next probe or publishes a partial plan; probes run one at a time | Probes can refresh backend authority, and a dismissed sheet must not publish a half-resolved plan. | handled | yes | yes | P4 |
| pu-16 | Immutable draft: the confirmation dialog and the commit use the same plan | Before 6eb1042c, confirmation and commit recomputed the plan separately and could diverge. | handled | yes | no | P4 |
| pu-17 | Global queue pause stops season admission | Pause All must keep the bounded worker from starting rows. | partially-handled | yes | no | P4 |
| pu-18 | Planning probes use an ephemeral, cookie-less, cache-less session; redirects only allowed for same-origin 307/308 with identical method/body/headers | A default 301/302 redirect can forward Emby's custom token header while rewriting POST to GET. URLSession.shared also kept cookies, which acted as a second source of aut… | handled | yes | yes | P4 |
| pu-19 | Jellyfin PlaybackInfo probe retries once on a spurious URL cancellation | A live sheet saw NSURLErrorCancelled without a real task cancellation, which wrongly hid the remux option. | handled | yes | no | P4 |
| pu-20 | Emby existing converted versions come from an unfiltered PlaybackInfo, then an item refresh plus short poll if none are visible | #126/#133: Emby filters PlaybackInfo to a single source when MediaSourceId is supplied, and finished Convert files can stay invisible until refreshed. | handled | yes | no | P4 |
| pu-21 | Offline list orders episodes by show title, then season, then episode, then title (not by episode title) | #170: the Offline list sorted episodes by episode title. | handled | yes | no | P4 |
| pu-22 | Episode rows identify themselves offline ('Show · S1E3 · Title') and show a year/runtime/rating subtitle | Downloaded episodes must be identifiable without a server. | handled | yes | no | P4 |
| pu-23 | Multi-row delete confirmation ('Delete N downloads?') | Bulk swipe/onDelete must confirm with an accurate count. | handled | yes | no | P4 |
| pu-24 | Row actions fenced by exact attempt identity (stale pause/retry/delete/play are no-ops) | A replacement retry or re-download must not receive an action rendered for its predecessor. | handled | yes | no | P4 |
| pu-25 | Progress: exact Content-Length fraction vs ~estimated (duration x bitrate) fraction capped at 99%; indeterminate spinner before any bytes | #97: transcoder streams have no Content-Length. An estimate must never read 100% before the row reaches terminal status. | handled | yes | yes | P4 |
| pu-26 | Separate post-transfer 'Verifying download…' and server-prep 'Finalizing server transcode…' phases | #186: a server at 100% that is still indexing, or a local file being validated, must not look stuck at 100%. | handled | yes | yes | P4 |
| pu-27 | 'Waiting for <backend>…' instead of 'Preparing on server…' when a prep row has no live poller and its backend is not configured | After sign-out, a server switch, or a relaunch without the backend, no poller can truthfully claim server work. | handled | yes | no | P4 |
| pu-28 | Server-prepared static versions are labelled 'Downloading optimized' with an Optimized badge, never 'transcode' | Byte-for-byte prepared files were mislabelled as live transcodes, with an orange Transcode badge. | handled | yes | no | P4 |
| pu-29 | Media bytes vs extras (side-asset) bytes shown separately in captions | A caption must not suggest that the percentage and the byte sum share one denominator. | handled | yes | no | P4 |
| pu-30 | Quality text: requested profile while in flight, derived average bitrate once complete (never the raw source/Emby bitrate) | #211/#253: misleading high bitrate labels on Emby converted versions. | handled | yes | no | P4 |
| pu-31 | 'Pausing at checkpoint' caption | Displayed while the old checkpoint-pause mechanism drained. | dropped-intentional | no | no | P4 |
| pu-32 | Paused rows show a non-red resumable caption and a Resume control; failed rows show the reason in red or a generic fallback | #95: a recoverable interruption is not a failure. | handled | yes | no | P4 |
| pu-33 | Season-pending rows shown as waiting, not as active work | Users see a pending row with a Pause control and active wording although no task exists. Also covered by #362. | partially-handled (sheet half fixed by #363 compactWaitingC… | yes | no | P4 |
| pu-34 | A backend switch must not bounce an already-ready browse UI; offline surface only after a failed restore with local media | #90: switching to Plex bounced to Home. cb557593: expose completed downloads after a disconnected cold launch. | handled | yes | yes | P4 |
| pu-35 | Season 0/Specials planned only when invoked from that season; no whole-show traversal | #205 scope. | handled | yes | no | P4 |
| pu-36 | Duplicate episode items collapsed by S\|E\|title display identity before planning | Jellyfin can return duplicate files as separate items that look identical in the list. | partially-handled | yes | no | P4 |

### offline-playback

| ID | Edge case | Why | Status | Req | Pinned | Phase |
|---|---|---|---|---|---|---|
| op-01 | Local playhead persisted per completed download row (#146) | On a plane, a downloaded item reopened from the start or from the stale server viewOffset captured at download time. | handled | yes | yes | P7 |
| op-02 | Saved position is clamped, floored below 1s, and reset to 0 within 30s of the end | Reopening a finished title used to land on its final frame. | handled | yes | yes | P7 |
| op-03 | Local playhead takes priority over the server viewOffset captured at download; the captured value is the fallback | Before any local play, resume should still honour where the user was online. After local play, the local value must win. | handled | yes | yes | P7 |
| op-04 | Playback position and unverified promotion only write to the attempt that is actually playing | A re-download or retry on the same rating key must not inherit, or be promoted by, a playhead from the old file. | partially-handled | yes | no | P7 |
| op-05 | 'Play Offline' from Detail saves the local playhead (and confirms unverified rows) the same way the Offline library does | Users who start a download from Detail and later tap Play Offline there lose their place; the next open resumes from the old value. | partially-handled (effectively unhandled) | yes | yes | P7 |
| op-06 | Offline playhead and watched state are reported back to the owning backend when it is reachable again | Without this, server-side Continue Watching and watched flags fall behind after offline viewing on every backend. | unclear | no | no | P7 |
| op-07 | Local playback makes no server requests (timeline, scrobble, up-next PlayQueue, artwork) | Required by the offline cold-launch contract (#259) and the checklist; a server request would hang or fail offline. | handled | yes | no | P7 |
| op-08 | Cold launch with a saved session but an unreachable server opens a restricted Offline surface when a completed file exists (#259) | Users were locked out of finished downloads on a plane because the only route to Offline sat behind the live browse gate. | handled | yes | yes | P7 |
| op-09 | Signed out / revoked (401) / refused (403 or wrong user) / temporarily unavailable are kept distinct; only the transient case opens Offline | A revoked credential must not quietly become offline authority. A transient failure must not delete the credential. | handled | yes | yes | P7 |
| op-10 | A stale temporarilyUnavailable outcome does not keep Offline open after switching to a backend with no saved credential; browse readiness always wins | Found while building #355: Offline stayed mounted for a backend the user was not signed in to. | handled | yes | yes | P7 |
| op-11 | Offline admission needs a terminal row (complete or unverified) whose local file still exists; durable rows alone do not count | A queued or failed row cannot be played, so the user would land on an empty surface with no exit. | handled | yes | yes | P7 |
| op-12 | Reconnect from the Offline surface returns to the normal browse root and re-runs download recovery | #259 acceptance: reconnect must return to browse without losing the offline library, and pending work should resume. | partially-handled | yes | no | P7 |
| op-13 | Completed downloads after an explicit sign-out or a confirmed revocation | A user who signs out, or whose token is revoked, cannot open local files at cold launch, even offline. | unclear | no | no | P7 |
| op-14 | Unverified (probe-miss) rows stay playable; confirmed local playback promotes them to complete | #98: the AVFoundation probe gives intermittent false negatives, so good bytes must not be deleted and real playback should clear the warning. | partially-handled | yes | no | P7 |
| op-15 | Downloaded SRT/VTT sidecar subtitles are offered offline, parsed lazily on selection, and generation-fenced | #80/#74: original downloads have no server to burn subtitles in. Parsing every sidecar when the menu opened was slow. | handled | yes | no | P7 |
| op-16 | Subtitle tracks embedded in the downloaded file stay selectable when sidecars also exist | Remuxed or optimized MP4s can carry tx3g/mov_text tracks. When sidecars exist, those tracks disappear from the menu. | partially-handled | no | no | P7 |
| op-17 | Image/bitmap subtitles offline | PGS/VobSub cannot be stored as text sidecars. | dropped-intentional | no | no | P7 |
| op-18 | Offline audio selection uses the file's AVFoundation audible group; backend metadata audio selection is disabled | There is no server to re-negotiate with, so a metadata PUT would fail. | handled | yes | no | P7 |
| op-19 | Cached side-asset references (poster, BIF, tiles, chapters, subtitles) survive later metadata upserts | 12c6dae3: stale non-nil metadata from a handoff or retry upsert wiped side-asset paths a cache task had just written. | handled | yes | yes | P7 |
| op-20 | Offline scrub previews: Plex BIF, Jellyfin tiles, Emby BIF with chapter-image fallback, loaded single-flight | #78/#79/#89. A refactor regression made every scrub request refetch about 6 MB of BIF. | handled | yes | yes | P7 |
| op-21 | Offline chapter images from the cache (#88) | The Chapters menu was empty offline. | handled | yes | no | P7 |
| op-22 | Offline poster and Now Playing artwork come from the cached poster, fenced by attempt and generation | 8ae908c9: offline Now Playing showed no artwork; stale posters from a replaced attempt must not appear. | handled | yes | no | P7 |
| op-23 | Local playback shows 'preparing' wording instead of remote 'Buffering' | #257: 'Buffering' was misleading for a local file. | handled | yes | no | P7 |
| op-24 | HDR / Dolby Vision files offline | DV/HDR can black-screen or tint, and source labels alone do not prove what was decoded. | partially-handled | yes | no | P7 |
| op-25 | Leaving Cinema returns to the originating Offline row (#87), including from the cold-launch Offline surface | Leaving Cinema used to always land on Home detail. | partially-handled | yes | no | P7 |
| op-26 | iOS rotates before the full-screen offline player appears and restores orientation on close | 5c807fc5: the offline player did not restore orientation. | handled | yes | no | P7 |
| op-27 | Music yields the audio session before offline video starts (#17) | Music and video share one audio session. | handled | yes | no | P7 |
| op-28 | Partial or active rows never offer local Play; Play re-checks that the file exists for the exact row identity | Playing a partial file would hit a truncated or missing file. Row taps from an outdated render must not act on a newer attempt. | handled | yes | no | P7 |
| op-29 | Items deleted on the server stay playable offline; repairs for missing side assets are bounded | A completed local copy should not depend on the source still existing. | handled | yes | no | P7 |
| op-30 | Fallbacks for rows with no metadata snapshot (pre-D5) or no owner | Libraries created before D5/#84 had to keep playing. | dropped-intentional | no | no | P7 |
| op-31 | The user's resume-rewind preference applies to offline resumes | Online resumes rewind a few seconds. Offline resumes should behave the same. | partially-handled | no | no | P7 |
| op-32 | The offline player resolves the backend from persisted metadata, not the rating-key prefix | #84 per-backend identity; namespaced Jellyfin/Emby keys. | partially-handled | yes | no | P7 |
| op-33 | Up Next / autoplay between downloaded episodes offline | Binge-watching a downloaded season on a plane. | unclear | no | no | P7 |
| op-34 | Offline records never store tokens | The repo/index is not a credential store, and records must survive sign-out. | handled | yes | no | P7 |
| op-35 | Losing connectivity mid-session keeps Offline reachable; switching to an unreachable backend opens Offline | #259 noted Offline stays reachable once RootView is mounted. The typed outcome also covers the backend-switch case. | handled | yes | no | P7 |

### Cross-area gaps found by the skeptic pass

| Gap | Status | Evidence |
|---|---|---|
| Automatic launch/backend-ready resume surge cap was added and removed the same day | dropped-accidental (no stated reason; the premise it relied on was la… | git show 59c9c81a / 1535ce09; docs/archive/downloads/2026-07-10-downloads-engine-audit-plan.md:835-841; bg-32 |
| User Pause is overridden by an in-flight delayed rebuild/rehydrate callback | unhandled | DownloadManager.swift:572-576, 2088-2214; BackgroundDownloadSession.swift:1886, 6430-6434 |
| Destructive store reset drops row-owned server-cleanup authority | partially-handled | DownloadStore.swift:753-800 (no row walk); migrateAndRetryActiveEncodingCleanupOnLaunch only journals terminal rows |
| Offline cold launch is unavailable whenever startup admission is blocked, unsupported or awaiting reset | unhandled | DownloadStore.swift:705, :4005-4012; OfflineLaunchAvailability.swift:9; ContentView.swift:225-233 |
| Season admitting key is held for the full server-prep duration after #363 | partially-handled (new interaction introduced post-base) | git show b63d1757 -- DownloadManager+SeasonPlanner.swift; DownloadManager.swift:4065-4069, 4146-4154 |
| Reattach of a paused row with a mismatched/unowned task flips it to .queued and requests a rebuild | unhandled | BackgroundDownloadSession.swift:1355-1368, 1400-1430, 1578-1589 |
| Retry ladder deletes a static partial when the detector misses the attempt working file | unhandled | DownloadManager.swift:2493, 2552, 2679; DownloadRetryPolicy.swift:48-61 |
| A queued single-item Jellyfin/Emby row paused during PlaybackInfo negotiation still starts | unhandled | DownloadPausePolicy.swift:24-35; DownloadManager.swift:1700-1704 |
| Public-repo hygiene: a code comment names a real media title | unhandled | Labstream/Capabilities/Downloads/Core/DownloadManager.swift:5251-5253 |
| #210 refresh/resume recursion backstop | handled | DownloadManager.swift:2088-2104; markStartAbortedBeforeTransfer ordering :3556-3586 |
| #125 existing-version offline-compatibility gate also applies to season 'Use Existing Versions' | handled | DownloadExistingVersionOptionPolicy.swift:52-68 (playableOffline); SeasonDownloadPlanningPolicy nearestIndex skips !playable (:123-126); DownloadOptionsSheet.s… |

## Appendix C — P3a call-site transition matrix

Every production status write and reconcile branch on `downloads/p3-lifecycle`, mapped to the
P3a event that replaces it.

- **Line numbers** are approximate, from the P3 code map.
- **Lifecycle column:** `*` means unchanged; `→X` is the new lifecycle.
- **"Effects"** lists durable effects (P3a.5).
- **"Keep"** means bytes and checkpoint are recorded through a constrained mutator, with no
  lifecycle change.

### C.1 Store primitives

| Site | Today | Event | Lifecycle | Effects / notes |
|---|---|---|---|---|
| `submitProgress` (~4677) | queued/paused/failed → downloading, implicitly | `transferProgress`; anything other than admitted/transferring becomes `checkpointAdvanced` | admitted→transferring; else * | the implicit promotion is removed (B09) |
| `markCompleteIfUnverified` (~4788) | unverified → complete | `localPlaybackProgressed` | unverified→complete | — |
| `executeValidatedPromotion` (~1200) | downloading → terminal | `promotionCommitted(terminal)` | finalizing→terminal | strike reset if complete |
| `abandonUnrecoverablePromotion` (~1246) | → failed | `promotionAbandoned` | finalizing→failed | `lastFailure = internal` |
| `recoverPendingValidatedPromotion` (~1322) | → legacy marker | `promotionRecovered(terminal)` | →terminal | resolved before other events |
| `createAttemptOwnedRecord` | writes `record.status` | creation takes an initial lifecycle | planned \| admitted \| serverPrep | history inherited (R2-5) |
| `applySeasonPlanAtomically` | new rows `.failed` + flag | creation | planned + `admissionIntent = seasonPlanned` | legacy flag still projected (R2-3) |
| `reconcile` (~4833) | table | `relaunchObserved(facts)` / `foregroundObserved(facts)` | see C.5 | deletions become effects |

### C.2 BackgroundDownloadSession

| Site | Today → | Event | Lifecycle |
|---|---|---|---|
| 1327 rebuild grace expired | paused | `rebuildExpired` | transferring→paused(`deferredResume`) |
| 1712 reattach, requestNeeded | queued | `transferRebuilding` | →transferring |
| 1722 reattach, adopted task | downloading | `taskAdopted(gen)` (task gate) | →transferring |
| 2272/2336 segment enqueue | downloading | `transferStarted` | admitted\|transferring→transferring |
| 2579/2642/2772 user pause | paused | `pause(user)` | →paused(user) |
| 2911/2971 oversized body / counter reset | queued | `transferRebuilding` | * (transferring) |
| 3871/4265 halt/pause while finishing | paused | `checkpointAdvanced`, then `pause(cause)` | →paused |
| 4312 halt with no task | paused | `pause(haltCause)` | →paused |
| 4544 held-drain halt | paused | `checkpointAdvanced` + `pause` | →paused (bytes kept) |
| 4589 `setFailedPurgingHeldSegments` (~25 callers) | failed | `transferFailed(reason)` | →failed |
| 4705/4726 continue / pause after body | queued / paused | `transferRebuilding` / `pause` | * / →paused |
| 4792 offset-mismatch retry | queued | `transferRebuilding` | * |
| 4905/4927 changed resource | queued / paused | `resourceChanged` / `pause` | * / →paused |
| 5259/5280 move-failure retry | queued | `transferRebuilding` | * |
| 3261/3296 body arrives (B10) | — | `bodyCaptured(path)`, then `bodyAtWorking` | →finalizing (R2-4) |
| 5525–5662 `finalizeTransferredFile` | per outcome | `finalizeOutcome(id, outcome)` | finalizing→failed / finalizing (promote) |
| 5683 promote | complete / unverified | promotion recipe | stays finalizing until commit |
| 5721 promotion rejected | failed | `promotionAbandoned` | →failed |
| 5622 revalidation | complete / unverified / failed | `publishedBodyRevalidated(outcome, id)` | per rule (B54) |
| 5974 system cancel | paused | `transferInterrupted(systemCancel)` | →paused(`systemInterrupted`) |
| 6086/6090 adopted failed remainder | queued / paused | `transferRebuilding` / `pause` | * / →paused |
| 6184 opaque interruption, blob | paused | `transferInterrupted(network)` | →paused |
| 6464 blob failure | queued | `transferRebuilding` | * |
| 6589 blob-resumed adoption | downloading | `taskAdopted(gen)` | →transferring |
| 6673 401/403 rehydrate | queued | `transferRebuilding(auth)` | * |

### C.3 DownloadManager

| Site | Today → | Event | Lifecycle |
|---|---|---|---|
| 1626/1632 pause | paused | `pause(user)` | →paused(user) |
| 1951/1957/1960 deferred resume | queued / paused / failed | `backendUnavailable(disposition)` | per disposition |
| 2053 queue paused with checkpoint | paused | `pause(queuePaused)` | →paused |
| 2260 retry, Emby convert | preparing | `retry(convertResume)` | →serverPrep |
| 2295 retry with blob | downloading | `retry(resumeBlob)` | →transferring |
| 2332 blob refused | failed | `transferFailed(blobRefused)` | →failed |
| 2361 retry, static | queued | `retry(staticCheckpoint \| freshAttempt)` | →admitted |
| 2398/2441 retry, auth / part missing | failed | `retryRejected(reason)` | →failed |
| 2577 resume Plex prep | queued | `retry(prepReattach)` | →serverPrep |
| 2594/2606 Plex retry, auth / server | paused | `backendUnavailable` | →paused(`awaitingSession`) |
| 2650/2672/2717/2738 JF/Emby retry, auth / server | failed | `retryRejected` | →failed |
| 2866 relaunch Convert recovery | preparing | `prepReattached` | →serverPrep |
| 2900/2932 Convert identity mismatch / expired | failed | `prepFailed(reason)` | →failed |
| 3187/3353/3379 Plex optimize deadline / poller error | failed | `prepFailed(reason)` | →failed |
| 3469 start aborted | failed | `transferFailed(aborted)` | →failed |
| 3732/3738 transfer start threw | failed | `transferFailed(start)` | →failed |
| 3780 local playback | complete | `localPlaybackProgressed` | unverified→complete |
| 3826 size audit | failed | `sizeAuditFailed` | terminal→failed |
| 3962/4044 refresh, queue paused | paused | `pause(queuePaused)` | →paused |
| 4251 forward-only stall | failed | `stallDetected` | transferring→failed (B61: facts-driven) |
| 912/1786 reattach + reconcile | table | `relaunchObserved` / `foregroundObserved` | see C.5 |

### C.4 Extensions

| Site | Today → | Event | Lifecycle |
|---|---|---|---|
| +Plex 80/243, +Jellyfin 86/322, +Emby 94/352, +PlexOptimize 101/173/345 | seed queued | creation | admitted (P4 makes it planned → admitted) |
| +EmbyConvert 92/275/300/391 | seed preparing | creation | serverPrep |
| +SeasonPlanner 123 | queued \| failed+flag | creation | admitted \| planned |
| +SeasonPlanner 205 admission | calls `retry` | `admissionGranted` | planned→admitted |
| +Plex 260, +PlexOptimize 111/268/290/311, +Jellyfin 314/334/351/374, +Emby 157/196/274/344, +EmbyConvert 747/765, +SeasonPlanner 254/287 | failed | `transferFailed` / `prepFailed(reason)` | →failed |
| +Emby 396 queue paused before Convert→static | paused | `pause(queuePaused)` | →paused |
| Convert→static handoff | new static record | `prepHandoff(route)` | serverPrep→admitted, same attempt |

### C.5 Reconcile as `relaunchObserved` (facts → lifecycle)

The order is preserved from today's reconcile:

| Facts | Lifecycle | Effects |
|---|---|---|
| pending artifact head, or deletion pending | * | none (skipped today) |
| finalizing with a capture or working body | finalizing | re-request finalization (B10) |
| Plex prep route, queued/transferring, no task | serverPrep, bytes reset | — |
| live static task | transferring | — |
| prep checkpoint (paused + target or Emby job) or app Range checkpoint > 0 | paused(`deferredResume`), bytes = durable | — |
| complete/unverified + published body | * | — |
| complete/unverified, no body | failed | — |
| queued/transferring, no task, no checkpoint | failed | `deleteBody(working)`, `clearResumeBlob` (effects, outside the lock) |
| paused with a blob or static restart | paused | — |
| paused, nothing resumable | failed | `deleteBody(working)` |
| planned | planned | — (not in today's table; added) |
