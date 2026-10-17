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
- 82 bug rows: 81 from the first pass plus B81 from the second review.
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
| **P7** | MediaBrowser, offline playback and row UX | Section 7. |

Bug counts and estimated line removal (roughly 5–8k net) are indicators, not acceptance criteria.
Acceptance is a phase's pins and inventory rows staying green.

## Progress journal

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

*Revision 1 (2026-10-17). Written from a code map of the v4 schema and every status write. To be
co-reviewed by GPT-6.1-Sol before implementation.*

### What the code map changed about the design

- **History is not persisted at all today.** Truncation strikes live in memory, keyed by
  ratingKey. The unverified reason appears only in diagnostics. A storage-full park lives in
  in-memory `lastError`. Finalizing is inferred from `.downloading` with progress ≥ 1.
- **`.failed` is overloaded.** A season-planned row that has not started is stored as `.failed`
  with `seasonPlannerPendingAdmission`.
- **Progress silently changes status.** `submitProgress` moves `queued`, `paused` and `failed` to
  `downloading`. About 11 session call sites rely on this, and it is how a paused row can be
  re-promoted (B09's race).
- **There are about 75 production status writes** across `DownloadManager*`,
  `BackgroundDownloadSession` and the store.
- **Reconcile deletes files under the store lock.** It is still the relaunch authority.
- **Any v4 index is `.unsupported` to a v5 binary today.** The store would then take the
  destructive reset path.

### Design decision: facets are logical in P3; the physical split is P6

Revision 2 of the overall plan proposed separately persisted facets. The map shows that a
physical rewrite of `Row` and `OfflineMetadata` at the same time as the reducer would put
identity, artifact and obligation data at risk for no behavioural gain.

P3 therefore does the following:

- **Adds two persisted fields to `Row`:**
  - `lifecycle: DownloadLifecycle`;
  - `history: DownloadAttemptHistory`.
- **Groups the existing fields behind typed facet views,** computed and read-only: `identity`,
  `artifacts` and `obligations`. Callers read these views, never the raw `OfflineMetadata` fields
  they cover.
- **Derives `status: DownloadStatus` from lifecycle.** It is still encoded for diagnostics and
  external readers, but it is no longer authority.
- **Leaves the physical split into separate stored structs to P6.** By then every write goes
  through the reducer and the views.

### P3.1 Types (PMSKit)

`DownloadLifecycle` has these cases, none carrying a payload:

| Case | Meaning |
|---|---|
| `planned` | Created but not admitted. Season planner rows, and later every new row (P4). |
| `admitted` | Admission granted; the transfer has not started yet. |
| `serverPrep` | A Plex optimize or Emby Convert job is in progress. |
| `transferring` | URLSession work is live or being rebuilt. |
| `finalizing` | A body is complete and validation or promotion is pending. Persisted (B10). |
| `complete` | |
| `unverified` | |
| `paused` | |
| `failed` | |

`DownloadAttemptHistory` holds:

- `truncationStrikes: Int`;
- `unverifiedReason: UnverifiedReason?`, with values `probeMiss(String)`, `truncatedRepeated`,
  `backgroundProbeDeferred` and `migratedUnknown`;
- `lastFailure: DownloadFailureReason?`, a bounded enum: storage, auth, network, server,
  validation, source missing, cancelled by system, internal;
- `parkedForStorage: Bool`;
- `pauseCause: PauseCause?`, with values `user`, `queuePaused`, `systemInterrupted`,
  `awaitingSession`, `storage` and `migration`.

History belongs to one attempt. A retry mints a new attempt, except where the existing retry
paths keep the attempt (blob resume). Those carry history forward deliberately.

`DownloadStatus` is derived as follows:

| Lifecycle | Status |
|---|---|
| `planned` | `queued` |
| `admitted` | `queued` |
| `serverPrep` | `preparing` |
| `transferring` | `downloading` |
| `finalizing` | `downloading` |
| `complete` | `complete` |
| `unverified` | `unverified` |
| `paused` | `paused` |
| `failed` | `failed` |

`planned` maps to `queued` rather than `failed`. The season planner's "not started" rows become
visibly queued; their caption comes from the admission marker.

### P3.2 Reducer (PMSKit, pure)

The reducer's signature is
`DownloadLifecycleReducer.reduce(_ state: State, _ event: Event) -> Transition`.

- **`State`** is `lifecycle`, `history` and a few facet facts the rules need: lane, whether a
  server obligation exists, whether a durable checkpoint exists, whether a body is complete.
- **`Event`** covers:
  - user: `pause`, `resume`, `retry` (with blob or without), `delete`;
  - admission: `granted`;
  - server prep: `prepStarted`, `prepProgress`, `prepReady`, `prepFailed(reason)`;
  - transfer: `transferStarted`, `transferProgress`, `transferRebuilding`,
    `transferInterrupted(systemCancel | storage | network | auth)`, `transferFailed(reason)`,
    `bodyComplete`;
  - finalize: `finalizeOutcome(complete | unverified(reason) | truncated | incomplete | empty)`;
  - `promotionCommitted(terminal)`;
  - `relaunchObserved(observation)` and `foregroundObserved(observation)`;
  - `backendUnavailable` / `backendAvailable`;
  - `storageMeasured(fits:)`;
  - `localPlaybackProgressed`;
  - `sizeAuditFailed`;
  - `stallDetected`.
- **`Transition`** is either `.rejected(.illegal | .stale)` or `.applied(State, [Effect])`.
  - Effects are descriptive, for example `deleteBody(.working | .published)`, `requestFinalization`,
    `scheduleResume` or `clearResumeBlob`. Existing code executes them.
  - P3 does not move effect execution. The reducer decides the transition, and existing call sites
    keep doing the I/O they already do, now chosen by the effect list.
- **Key rules** (each one a reducer test):
  1. `transferProgress` is legal only from `admitted` or `transferring`. From `paused`, `failed`
     or `finalizing` it is rejected; there is no implicit promotion any more (B09).
  2. `finalizeOutcome(.truncated)` increments `truncationStrikes`. Below the budget the row fails
     and the body is deleted. At the budget it becomes `unverified(truncatedRepeated)` with the
     body kept.
     - A revalidation of a published body never deletes it (this is the P1 B54 containment, now
       persisted).
     - The strikes survive a relaunch.
  3. `relaunchObserved` reproduces `DownloadStatus.reconciledStatus` and the store's reconcile
     table as reducer rules, adding:
     - `finalizing` with a complete body present → `requestFinalization` (B10); the body is never
       deleted.
     - The resulting file deletions are effects, executed outside the lock (st-41), where today
       they run inside it.
  4. `pause` records a `pauseCause`.
     - A system interruption parks the row with `systemInterrupted` (B09, now persisted).
     - `resume` from `paused(storage)` re-measures through `storageMeasured`. Storage parks persist
       across relaunch, where today they live in `lastError`.
  5. `delete` is always legal. Its effect is the existing P2 delete path.
  6. Terminal states accept only these events:
     - `delete`;
     - `retry`, which mints a new attempt;
     - `localPlaybackProgressed` (unverified → complete);
     - `sizeAuditFailed` (complete/unverified → failed);
     - `relaunchObserved` with the file missing.

### P3.3 Store API

- `store.apply(_ event:, for key:) -> ApplyResult` takes the attempt fence, runs the reducer under
  the store lock, persists the new lifecycle and history together with any field updates the
  call site supplies, and returns the effects.
- `submitStatus` and `setStatus` are removed by the end of P3.
- `submitProgress` updates bytes and progress only. A status change is an explicit
  `transferProgress` event.
- `executeValidatedPromotion` applies `promotionCommitted(terminal)` in its terminal snapshot.
  The intent's `terminalStatus` maps to the lifecycle.

### P3.4 Conversion order

The ~75 call sites are converted in commits grouped by file. The build stays green after each one.
Until a call site is converted it goes through a temporary `apply(.legacy(status))` shim. The shim
logs `downloads.lifecycle_legacy_write`, and a CI-hygiene check fails if any shim use remains by
the last commit.

1. `BackgroundDownloadSession`: transfer, pause and finalize events.
2. `DownloadManager`: retry, pause, resume, refresh, startup and size audit.
3. The extensions: Plex, Jellyfin, Emby, EmbyConvert, PlexOptimize and SeasonPlanner.
4. Reconcile becomes `relaunchObserved`/`foregroundObserved` events, with deletions as effects.

### P3.5 v5 schema and migration

- **Detection.** `DownloadIndexCoding.currentSchemaVersion = 5`.
  - A new probe case, `.migratable(fromVersion: 4)`, is classified before `.unsupported`.
  - Versions 1–3 and anything over 5 stay `.unsupported`. Over 5 means newer than this binary;
    see the downgrade guard.
- **Migration** follows the restartable steps in the overall plan:
  1. close admission;
  2. drain transport;
  3. take the inventory, resolving pending promotions and deletions under the v4 rules;
  4. journal obligations;
  5. commit v5;
  6. reclaim.

  Steps 1–2 reuse the existing unsupported-reset drain. The steps are made durable by a
  `migration-progress.json` file in the authority directory, written with the P2 committer.
- **Step 4 (obligations).** Rows dropped by the migration (in flight, paused, failed or planned)
  journal their obligations as abandonment intents, and their reference is released when the row
  is dropped, so P2's runner executes them. Kept rows (`complete`, `unverified`) keep their
  handles. The launch sweep journals those as terminal releases, as it does today.
- **Step 5 (commit).**
  - `complete` → lifecycle `complete`, empty history.
  - `unverified` → lifecycle `unverified` with `unverifiedReason = migratedUnknown`. A B54 park
    still in staging, with its body present, is published in this step, as the overall plan
    requires. Bytes are never discarded.
  - Every other row is dropped (D1).
  - The v5 index is written by one committer write.
- **Step 6 (reclaim).** Unreferenced staging bodies, partials, held bodies and resume blobs are
  deleted, with a directory sync.
- **Failure.** Before step 5 commits, v4 stays authoritative and the store is blocked with
  `.migrationFailed(step, reason)`. The next launch resumes from the recorded step. An
  unparseable v4 index takes today's destructive reset.
- **Read-only offline load while blocked.** If migration or admission is blocked, the store still
  exposes `complete`/`unverified` rows as read-only for offline playback. No mutations are
  allowed; the session stays dormant.

### P3.6 Downgrade guard (ships separately, before P3)

A v4 binary that opens a v5 index sees `.unsupported(5)` and resets.

The guard is a small PR off `main` that adds `.newerThanBinary(version)`. That case blocks
downloads with a "newer app version" message and never resets or quarantines. It has to ship in
a v4 build before any v5 build reaches users. The app is pre-release, so this is low-risk, but
it is cheap and removes the hazard.

### P3.7 Pins written first (before behaviour changes)

1. **Staging → finalizing → relaunch.**
   - A complete forward-only body with the app killed before validation: today the body is
     deleted; after P3 it is re-validated (B10). The pin records today's behaviour as a known
     failure and flips in commit 5.
   - The B54 park survives relaunch and revalidation (the P1 containment).
2. **Pause during delayed rebuild or auth callback, then resume** (B02 class).
3. **Failed Convert, launch sweep, Retry** (B44/B49; the P1 and P2 pins already exist).
4. **Season commit followed by each resume entry point:** manual, Resume All, launch,
   backend-ready and the prep scanner (B62/B63).
5. **Migration interrupted at each step,** then relaunched.
6. **Protected data unavailable at launch,** then unlocked: read-only rows, no reset.
7. **Progress cannot promote a paused or failed row** (B09; currently allowed).

### P3.8 Commits

1. **Pins.** The tests from P3.7; known-failing ones are marked `withKnownIssue`.
2. **PMSKit lifecycle, history, derivation and reducer,** with exhaustive transition tests.
3. **Store:**
   - v5 fields;
   - the `apply` API and `.legacy` shim;
   - the `migratable` probe and restartable migration;
   - read-only blocked load;
   - encode and decode tests;
   - migration crash-point tests.
4. **Session call sites,** converted to events.
5. **Manager and extension call sites, plus reconcile as events.** Removes `submitStatus`/`setStatus`
   and the shim, and adds the hygiene check.
6. **Docs:** DOWNLOADS-OFFLINE, PERSISTENCE, the testing checklist and the plan journal.

### Out of P3

- The admission coordinator (P4) will drive `planned → admitted`.
- Storage policy unification (P5).
- The physical facet split and moving file I/O off the store lock beyond reconcile (P6).
- UI (P7).

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
| st-28 | Reconcile: a complete or unverified row whose file is missing becomes failed | Offline Play must not be offered for a file that no longer exists. | handled | yes | yes | P6 |
| st-29 | Reconcile: a non-live queued/downloading/paused row that cannot stay resumable is demoted to failed and its partial and resume blob deleted; resumabl… | Invisible dead bytes piled up on disk (e1dc0224). Deleting the partial of a resumable row made its resume data useless (adc8943f). | partially-handled | yes | yes | P6 |
| st-30 | Reconcile skips rows with pending artifact intents | A staged validatedPromotion leaves the row in .downloading while the working file is the validated body. Demoting it would delete the source. | handled | yes | yes | P6 |
| st-31 | Reconcile backend nuance: Plex server-prep rows return to queued; Jellyfin/Emby transcodes become failed; a live static range task stays downloading… | Emby/Jellyfin live renders die with the task, while Plex optimize jobs survive on the server. A paused row with a live task offered Resume and could start a duplicate Ra… | handled | yes | yes | P6 |
| st-32 | Side-asset owner fencing on load: a mismatched owner retires the bundle; a legacy ownerless bundle with an attempt is adopted | Stale-attempt side assets must not attach to a new attempt (SAFE-06). The fail-closed version, however, deleted every pre-owner-schema user's cached posters, trickplay,… | handled | no | yes | P6 |
| st-33 | Load-time normalization of legacy Plex prepared-static lane rows | Rows written before the rendered-Part handoff moved lanes showed the wrong badge. | handled | no | yes | P6 |
| st-34 | Atomic season plan: new rows plus retry markers commit in one snapshot off-lock; conditional compensation on failure; an indeterminate result blocks… | A partial season plan would admit work for rows that never became durable. The earlier version held the store lock across I/O and blocked delegate callbacks. | handled | yes | yes | P6 |
| st-35 | Cross-row path protection: a destructive step never deletes a path another row references, including paths captured only by pending intents | Malformed or imported indexes and cross-kind aliases can share a filename. Deleting one row's file could destroy another row's media. | handled | yes | yes | P6 |
| st-36 | Static byte-range checkpoints use only durable file size; a complete row can be reconstructed into a working checkpoint via a durable clone | #169: optimistic progress from OS temp bytes caused false resume offsets and corrupt partials. | handled | yes | yes | P6 |
| st-37 | A retry that changes attempt identity inherits the multi-GB static checkpoint by cloning the old working body before committing the new owner; the ol… | A manual Retry or relaunch must not throw away a large durable partial. | handled | yes | yes | P6 |
| st-38 | Storage audit: report referenced, unreferenced and orphan-candidate bytes in diagnostics (#171), report-only | Repeated pause/delete/restart cycles were suspected of leaking 5 GB ghost partials, and leaks need to be observable. | dropped-accidental (observability regressed by 6b62b5b0's h… | yes | no | P6 |
| st-39 | General launch-time orphan sweep of unreferenced stable media and side assets | Files whose delete failed, side-cache writes after delete, and old leftovers were never collected (#171 gaps 2-3). | dropped-intentional | no | no | P6 |
| st-40 | Bounded lifecycle bookkeeping: abandoned or superseded failures retire out of the live table into a FIFO capped at 512 | Every boundary scan walked dead intents and one dead intent poisoned every later boundary. | partially-handled | yes | yes | P6 |
| st-41 | Filesystem and journal I/O happens off the store lock (the lock is shared with URLSession delegate callbacks) | Lock-held I/O blocked delegate callbacks and contributed to the main-thread and watchdog stalls reported in #187 and #210. | partially-handled | yes | yes | P6 |
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
| emby-24 | Terminal poll HTTP: 404/410 clears the job id (fresh retry); 401/403 KEEPS it so re-login plus Retry resumes the live job | A dead job must not be re-polled forever, but an auth blip must not discard hours of server-side render. | dropped-accidental | yes | yes | P4 |
| emby-25 | Retrying a .failed row that still owns a Sync job id resumes POLLING rather than POSTing again | The poll-health budget parks a row as failed after about 5 min offline while the job keeps rendering. A fresh POST orphaned it as a duplicate. | dropped-accidental | yes | no | P4 |
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
