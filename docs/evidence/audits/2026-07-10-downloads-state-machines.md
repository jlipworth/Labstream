# Downloads Engine — Extracted State Machines vs Documented Intent (Phase 2)

> **Status:** point-in-time extraction at `347f035`. Later fixes and the schema-v4
> remediation changed these machines; use this file as audit evidence, not current operating
> guidance. Current invariants live in [`docs/DOWNLOADS-OFFLINE.md`](../../DOWNLOADS-OFFLINE.md),
> and remediation status lives in
> [`docs/plans/2026-07-10-codebase-remediation.md`](../../plans/2026-07-10-codebase-remediation.md).

Extraction date 2026-07-10, read at commit `347f035` (includes `00c1dc7` train-supersede and
`9600fe9` server-job/poller fixes). Concurrent small fixes were landing in
`BackgroundDownloadSession.swift` / `DownloadManager.swift` while this was written, so line
numbers may drift by a few lines; every citation was verified against the working tree at
extraction time.

Reference docs diffed against: `docs/DOWNLOADS-OFFLINE.md` (lifecycle + segment-train
contract) and `docs/archive/downloads/2026-07-10-static-range-segment-checkpointing.md`
(original design plan).

---

## A. Machine 1 — Range engine (`Labstream/Downloads/BackgroundDownloadSession.swift`)

### A.1 State variables (the machine is implicit; row state is the product of these)

| Variable | Scope | Declared | Meaning |
| --- | --- | --- | --- |
| `rangeInflight[taskID] = RangeTransfer` | per task | :72, :169 | live range task; `segmentLength != nil` ⇒ closed train segment, `nil` ⇒ open-ended remainder |
| `heldRangeSegments[key][offset] = (url, length, validator)` | per row | :79 | finished out-of-order bodies stashed on disk, **in-memory index only** |
| `rangeTrainEpochs[key]` | per row | :85 | train generation; bumped on changed-resource restart (:2923) and adopted-200 replaceWhole (:2357) |
| `haltedRangeKeys` | per row | :89 | cancel/pause fence; blocks all continuation/retry starts |
| `rangeRequestRebuildGraceKeys` (+20 s timeout) | per row | :161, :475 | `.requestNeeded` rebuild in flight; holds the background-completion handler |
| `supersededRangeTaskIdentifiers` | per task | :152 | abandoned task ids whose late callbacks must be ignored |
| `finalizingRatingKeys` (on `finalizationStateQueue`) | per row | :105 | post-transfer validation single-flight |
| Budgets: `staticRangeRetryBudget` (:93), `retryCounts` (:97), `rangeHTTPRehydrateCounts` (:101), `rangeBlobResumeCounts` (:155) | per row | | bound validator restarts / transient retries / auth rehydrates / blob re-resumes |
| Store sidecars | per row | DownloadStore | status, durable file size (the checkpoint), pinned validator, resume blob + display watermark, `sourcePartSize` |

### A.2 Row-level states (derived)

1. **Idle** — no `rangeInflight` entries; store status terminal/`paused`/`queued`.
2. **TrainRunning** — ≥1 closed segments live; optionally held stashes; durable file = checkpoint.
3. **OpenEndedRunning** — single `segmentLength == nil` task (unknown-total fallback, legacy blob, `.openEndedRemainder` regime).
4. **Held/Draining** — held stashes exist ahead of the checkpoint; drained on each in-order append (:2600, :2680).
5. **RebuildGrace** — no task; key in `rangeRequestRebuildGraceKeys`; store `.queued`; `onRangeRequestNeeded` fired; ends on replacement registration (:1064/:1089/:4190), pause/cancel (:1348/:1563), or 20 s timeout (:487).
6. **RetryDelay** — *invisible state*: a closure parked on `rangeRetryQueue.asyncAfter` (:3211, :4291, :4332) with no tracked entry; only the `haltedRangeKeys` check inside the eventual `startRangeRemainder` protects it.
7. **Halted** — key in `haltedRangeKeys`; delegate callbacks discard/cancel (:1596, :2064, :2245).
8. **Finalizing** — key in `finalizingRatingKeys`; store shows `.downloading` + progress 1.0 (UI derives “Verifying…”, :3134).
9. **BlobParked** — store `.paused` + persisted resume blob + display watermark; session tracks nothing.
10. **EpochSuperseded (per body)** — a finished body carrying `bodyTrainEpoch < rangeTrainEpochs[key]` is discarded in `applyFinishedRangeBody` (:2225–2237).

### A.3 Events and transitions

**Start / refill** — `start(byteRangeCheckpoint:)` :886 → `startRangeRemainder` :970:
clears halt + (optionally) budgets (:928–933); truncates an oversized partial (:986);
`offset >= expected` ⇒ finalize directly (:996); plans via `StaticRangeSegmentQueuePolicy`
with live-closed + held offsets excluded (:1022–1036); a closed train supersedes any live
open-ended task first (:1045); empty plan ⇒ end grace and return (:1063); per-plan
`enqueueRangeSegment` :1093 (duplicate decision pre- and post-task-creation, halted re-check
:1157, If-Range stamped from the pinned validator :1148).

**didWriteData** :1578 (range branch), in guard order:
1. halted ⇒ supersede+cancel task (:1596–1612);
2. durable > `baseOffset + (segmentLength ?? 0)` ⇒ stale, supersede (:1615);
3. counter reset (live counter drops ≥1 MiB) ⇒ supersede task, reset store to checkpoint, **begin rebuild grace, store `.queued`, `onRangeRequestNeeded`** (:1647–1673) — siblings keep running;
4. newer-task supersede, segment-scoped for marked/closed tasks (:1676);
5. publish aggregate live bytes (durable + Σ live bodies) via `onRangeLiveProgress`; persisted progress stays checkpoint-pinned (:1700–1775).

**didFinishDownloadingTo** :1818: superseded ⇒ ignore (:1850); newer task ⇒ discard temp
(:1839); tracked range entry ⇒ `finishRangeRemainder`; tracked in *neither* lane ⇒
**dead-finish adoption** `adoptFinishedRangeSegment` :1992 (marked segments on live
non-terminal static rows only; `remainderReason = dead_finish_adopted`).

**finishRangeRemainder** :2056: halted-and-not-paused ⇒ discard (:2072); stash the OS temp
by `(taskID, offset)` (:2086); `writeDecision(httpStatus)`:
- `.failServer` ⇒ transient HTTP retry (52x/503, :4303) → auth rehydrate (401/403, :4260 → grace + `.queued` + `onRangeRequestNeeded(.serverAuthorizationRejected)`) → terminal `.failed` (:2140).
- `.alreadyComplete` (416) ⇒ reconcile durable vs known total: equal ⇒ finalize; short + server total ⇒ continue; short + only local expected ⇒ bounded offset-mismatch retry then `.failed`-retryable (:2162–2189); durable > total ⇒ **changed-resource restart** (:2186).
- `.append` / `.replaceWhole` ⇒ off-queue `applyFinishedRangeBody` on `rangeIOQueue`, carrying the epoch captured at delegate time (:2201–2209).

**applyFinishedRangeBody** :2216:
1. epoch check ⇒ discard stale-train body (:2225);
2. halted disposition (`discardTemp` / `writeThenPause`) (:2245–2259);
3. durable > baseOffset ⇒ stale discard (:2262);
4. unowned dead-finish body: absent/different validator ⇒ discard + reset, **never** restart (:2285, NEW-1);
5. `.replaceWhole` (200): adoption gate `shouldAdoptReplaceWholeBody`; adopted ⇒ replace file, pin validator, purge held, **supersede whole train + epoch++** (:2354–2370, B.3(b) fix), finalize (or `.paused` under `writeThenPause`); rejected ⇒ bounded offset-mismatch retry → `.failed`;
6. `.append`, held branch (durable < baseOffset, segment): `arrivingBodyDecision` — first body **pins** the validator, mismatch ⇒ changed-resource restart (:2402–2414, B.2 fix); Content-Range must equal baseOffset (:2418); empty stash rejected (:2446); stash recorded **with its validator** (:2464) then train topped up;
7. `.append`, in-order: `arrivingBodyDecision` again (:2506); alignment / internal-resume adoption (:2524–2565); `appendFile` (:2569, non-atomic block append); on success **all four budgets reset** (:2578–2583); drain held (`heldSpliceDecision` re-checks each stash’s validator against the pin, :2694); `nextStep` ⇒ complete / stalled(`.failed`) / continue.

**changed-resource restart** `restartRangeFromChangedResource` :2913: supersedes the whole
train + epoch++ (:2922–2927, B.2 fix), deletes the partial, clears validator, purges held,
then per `afterValidatorChange`: restart from 0 / `.queued`+grace+rebuild / `.failed`
(“source file kept changing”) when the restart budget is exhausted (:2954).

**didCompleteWithError** :3597 (range entry still present ⇒ error path):
cancelled ⇒ silent (:3628); blob re-resume from OS resume data, budget-bounded — a closed
segment retries **in place** at its own offset, an open-ended remainder adopts at the durable
offset (:3642, :4000, :4107); rejected blob ⇒ durable-checkpoint restart (:4039); transient
in-session retry (:3942); park: persist blob with the **aggregate** train watermark (:3680),
reset to checkpoint, `.paused` + `interruptedResumable` — or `.queued`+grace when the entry
has no in-memory request (:3720).

**pause** :1327 / **cancel** :1550: cancel removes all entries, halts, ends grace, purges
held stashes. Pause computes a row-level context once (durable + aggregate, :1423), persists
resume data **only for the head segment** (`shouldPersistSegmentBlobOnPause`), plain-cancels
off-head siblings (:1444–1509), resets store to checkpoint, `.paused`. Pause also **purges
held stashes** (:1352) — see mismatch M-6.

**reattach** :516: marked closed segments adopted with recovered `segmentLength` (:607);
unmarked closed ⇒ `.dropLegacyRange` + rebuild; offset-mismatch ⇒ drop + rebuild; duplicate
handling segment-scoped for marked tasks (:641–691); adopted rows set `.downloading` (:719);
then `sweepOrphanedRangeBodyStashes` protects only stashes still indexed in the (empty after
relaunch) held map (:739–753) — the B.1 held-loss finding.

**2026-07-11 remediation:** B.1 is closed. Held bodies now live in the Downloads directory with a
persisted offset/length/validator/attempt manifest, restore before reattach planning, participate in
the segment planner, and are removed with every consuming/terminal teardown path. The live relaunch
probe restored seven bodies without a temporary-stash sweep.

### A.4 Per-task lifecycle

created → resumed → {superseded (cancel expected) | finished-owned (`finishRangeRemainder`) |
finished-unowned (dead-finish adoption) | errored (`didCompleteWithError`)}. Removal from
`rangeInflight` happens exactly once per path; `supersededRangeTaskIdentifiers` absorbs the
late duplicate callback and is drained by that callback (:1822, :3605).

---

## B. Machine 2 — Orchestration coherence (DownloadStore × DownloadManager × session)

### B.1 The three layers

- **Store** (`DownloadStore.swift`): persisted `DownloadStatus` (7 values,
  `OfflineDownloadModels.swift:10`), durable bytes/progress, resume blob, validator.
  `updateProgress` **auto-promotes** `queued/paused/failed → downloading` (:771). `reconcile`
  (:855) recomputes status from disk + live keys; a static-range row with a durable partial
  stays `.paused` **without** a resume blob (`hasAppRangeCheckpoint`, :878, :909), and a
  reattached live static task forces `.downloading` (:903).
- **Manager** (`DownloadManager.swift`): `activeJobs` (:88), `serverPrepPollerTasks` (:95) +
  `serverPrepAttempts` (:100), `retryState` (:92), `staticRangeRecovery`
  pendingResume/finalizing/manualQueueResume (:108), keepalives (:205), `lastError` (:134),
  ephemeral progress overlays. Terminal release is centralized in `releaseInFlight` (:2473)
  driven by the terminal-row sweep in `refreshRecords` (:2272) and by `delete` (:1872).
- **Session**: `inflight`/`rangeInflight` tracking; `isTrackingTransfer` (:309).

### B.2 Self-healing loops that exist

- Stale `.queued` static partial with no live task and no pendingResume marker →
  `refreshRecords` stale-queued detector re-drives resume synchronously (:2060–2120).
- `.queued`/`.preparing` server-prep row with no attached poller → `ServerPrepRefreshPolicy`
  refresh kick (:2123–2186) → `resumePendingServerPrepDownloads` (:1428) /
  `resumePendingEmbyConvertDownloads`.
- `activeJobs` slot with no row → recovered at next start (`acquireInFlightSlotForStart`
  `.recoverStaleSlotAndAccept`, :526); slot + row + no live task → recovered only with
  `allowReplacingExistingActiveRow` (:480).
- Byte-short `.complete`/`.unverified` static rows → `demoteIncompleteCompletedStaticRows`
  (:1985) on every session-change/scene edge.
- Launch/foreground: `reattach → reconcile → finalize/revalidate/resume` (:285–301, :646).
- `downloadWatchdogTask` re-runs `refreshRecords` periodically while active work exists (:2320).

### B.3 Reachable-but-incoherent composite states (ranked)

**IC-1 (high, race window): store `.downloading`, zero live tasks, lane halted — frozen row.**
Entry: user Pause races a segment finishing. `pause` snapshots `rangeIds` (:1333) and only
sets the halt inside per-task processing; a task that completed between snapshot and
`getAllTasks` is not returned, so its entry is removed by `finishRangeRemainder` while
`pauseStillApplies` (:1310) sees a “replacement” entry and skips `setStatus(.paused)`; the
finished body is then discarded by the halted gate without any status write (:2072, :2251).
Result: `.downloading`, no tasks, halted. No detector covers `.downloading` (the stale-queued
detector is `.queued`-only, :2060; the forward-only stall tracker excludes static rows,
:2288). Self-heal: none until relaunch/foreground `reconcile`; user heals it by tapping Pause
again (`parkStaticWithoutLiveTask`, :560). Symptom: row frozen mid-percent, Pause appears
ignored.
A cousin: a segment enqueued by a continuation in the pre-halt window has a task id in
neither `rangeIds` nor `ids`, survives the pause sweep entirely, and keeps the row
downloading after Pause.

**IC-2 (high, race window): 416-restart on the delegate queue racing an append on
`rangeIOQueue`.** `restartRangeFromChangedResource` can be entered from
`finishRangeRemainder`’s 416 branch (:2186, delegate queue) while a sibling’s
`applyFinishedRangeBody` is between its epoch check (:2226) and `appendFile` (:2569) on
`rangeIOQueue`. The restart deletes and re-creates the destination at size 0; the append then
seeks-to-end and writes a mid-file segment at offset 0, and `updateProgress` publishes it as
durable. The epoch mechanism closes the *stash/held* version of this race but the
epoch-check→append distance is a lock-drop window; the `durableBytesBeforeWrite` read (:2261)
is also pre-window. Probability low (requires a 416 and a finishing sibling in the same
instant) but the outcome is silent corruption. This is Phase 5 lens 1/2 territory; a
re-check of epoch + on-disk size immediately before `appendFile` (or funneling the 416
restart through `rangeIOQueue`) closes it.

**IC-3 (medium): `.queued` in store while sibling segments actively transfer.** Every
single-task recovery path (counter reset :1664, offset-mismatch retry :2868, auth rehydrate
:4290) sets the whole row `.queued` while the rest of the train keeps running; the next
sibling `didWriteData`/append promotes it back via `updateProgress` (:771). Not damaging, but
the store status oscillates queued↔downloading (diagnostic/`status_transition` churn) and the
documented lifecycle has no such edge. It also means “store `.queued` while session tracks a
live transfer” is an *expected* state in this design — any assertion must scope it to
“no rebuild-grace and no live tracking”.

**IC-4 (medium): keepalive running for a row with no transfer.** The Jellyfin keepalive loop
exits only when the row leaves `queued/downloading` (:2410). A JF forward-only row stuck
`.queued` with no URLSession task (start raced, or reconcile missed) keeps POSTing
playing/progress/ping every interval — keeping a dead server encoder alive indefinitely.
No detector ties keepalive existence to `session.isTrackingTransfer`. Self-heal: only via a
status change. Symptom: invisible server load; JF idle-kill is defeated by our own pings.

**IC-5 (medium): `finalizingRatingKeys` + probe running against a deleted row.**
`delete` does not (and cannot cheaply) interrupt an in-flight `finalizeTransferredFile`; the
probe runs up to ~30 s against a removed file, then `setStatus` no-ops (row gone) but
`onError` re-populates `lastError[key]` *after* `delete` cleared it (:1859 vs :3373). The
`lastError` entry for a deleted key persists for the app run. Cosmetic unless the key is
re-downloaded quickly, where a stale failure message can flash. (Known; being addressed by
the lifecycle-batch fix agent.)

**IC-6 (low): `activeJobs` slot without a row.** Post-delete async callbacks (JF/Emby retry
Tasks, optimize error handlers) can re-insert bookkeeping after `releaseInFlight`. The
terminal sweep keys off rows (:2272) so a rowless slot is invisible to it; heals only at the
next start attempt for that key (:526). Symptom: none until re-download; first re-download
tap logs `inflight_recovered` and proceeds.

**IC-7 (low, by-design asymmetry): failure-park keeps held stashes, user pause purges them.**
The `.paused` park in `didCompleteWithError` (:3730) leaves `heldRangeSegments` intact
(good — an in-session Resume re-plans around them via :1025), while user Pause purges them
(:1352) even though the resume planner honors held offsets. Up to 7×512 MiB of completed
bodies are destroyed on every user Pause for no correctness reason the code states beyond C2
caution. Inconsistent siblings; one of the two behaviors is wrong (I believe the purge-on-
pause is the wasteful one, though it is the *safe* one across process death since the held
index is in-memory).

**IC-8 (low): in-memory range budgets survive delete.** `cancel()` (session) and `delete`
(manager) never clear `retryCounts`/`rangeHTTPRehydrateCounts`/`rangeBlobResumeCounts`/
`staticRangeRetryBudget` for the key, and a fresh `start()` resets only three of the four
(:930–933, :945 — `rangeBlobResumeCounts` is missing). A delete→re-download of the same item
can therefore start with an exhausted 3-attempt blob budget until the first successful append
resets it (:2582). Bandwidth-only impact (blob adoption refused → durable-checkpoint restart).

### B.4 Composite states verified as coherent

- `.paused` + blob + no tracking (BlobParked) — resume paths route to the range lane
  correctly (`retry` :946–983, `resumeRange` :4240).
- `.queued` + rebuild grace + no task — pendingResume marker exempts it from stale-demotion
  (:2067) and `resumeStaticRangeWhenReady` has recursion bail-out (:783).
- `.preparing` with no poller across relaunch — reconcile preserves `.preparing`
  (`reconciledStatus` :77) and resume scans re-attach or fail it.
- Reattached live static task + durable partial — reconcile forces `.downloading`, not
  `.paused` (:903), preventing the duplicate-resume trap.

---

## C. Machine 3 — Server-prep sub-machines

### C.1 Plex optimize (`DownloadManager+PlexOptimize.swift`, poll cluster in DownloadManager.swift)

States: **Kickoff → QueuedOnServer → Rendering(poll) → PartDiscovered → StaticHandoff**, with
**StaleAttempt** and **Failed** exits.

- **Trigger** :31: `beginServerPrepPoller` mints the attempt (UUID in
  `ServerPrepAttemptTracker`); the whole chain now runs in a Task registered via
  `registerServerPrepPollerTask` (:40–46, the `9600fe9` fix — fresh starts are cancellable).
  Queue title minted/protected (:61, :86); `.queued` row seeded at 0 bytes.
- **Attempt-identity guards**: `assertCurrentOptimizeAttempt` (:294) checks activeJobs slot,
  protected queue title, row still `.queued` at 0/0, resume mode, and target — called after
  *every* await boundary in the chain (:89, :135, :157, :170, and 3× inside
  `startOptimizedPartDownload` :236/:256). The poll loop itself re-checks row-exists +
  slot-active every iteration (`plexPrepPollerShouldContinue`, DownloadManager.swift:2704 —
  the `9600fe9` orphan-exit).
- **Poll** `pollForOptimizedPart` :2689: no wall-clock timeout by design; discovers the new
  Part by baseline part-id diff; progress via `pollOptimizeActivity` (no sole-activity
  fallback).
- **Static handoff** :221: persists `sourcePartID` + `resumeMode = .staticByteRange` +
  `serverPreparedVersion` before `session.start(byteRangeCheckpoint: true)` — from here the
  row belongs to Machine 1 and retries never re-run optimize (`resolveStaticRetryTarget`).
- **Cancel/delete**: `delete` (:1834) → `DownloadDeletePolicy.plexOptimizeCancelDecision` →
  `removePlexOptimizeQueueItem` (:542, immediate single-item removal; completed items
  protected because deleting a completed type-42 destroys the rendered version) →
  `releaseInFlight` cancels the registered poller Task (:2483) and releases the attempt.
- **Pause** parks `.paused` and cancels the poller; queue item intentionally survives
  (resume reattaches by queue title, :1145, recreating the job only if the queue lost it
  :1592–1619).
- **Broad reap** `cleanStaleOptimizeJobs` (:489) still runs only at the next optimize kickoff
  and protects in-memory + persisted non-complete queue titles.
- **Residual leaks (post-9600fe9, matches audit E):** a *completed* render whose row is later
  deleted is never reclaimed server-side (by design, no reclaim path); a session-mismatch at
  delete skips the cancel and the job runs on.

### C.2 Emby Convert (`DownloadManager+EmbyConvert.swift`)

States: **Preflight(.preparing) → ReuseHandoff | JobCreated → Polling → {Succeeded →
FinishHandoff → StaticLane | Failed} **, with **StaleAttempt** exits at every await.

- **Attempt identity** is a UUID per key (`beginEmbyConvertAttempt` :18);
  `embyConvertAttemptIsCurrent` (:22) requires slot + current UUID + row `.preparing` +
  target/jobId match — checked at pre-poll reuse (:287), each poll iteration (:311),
  post-status (:375), and finish entry (:459). This is the strictest of the three lanes.
- **Reuse preflight** (:106): an existing converted File source short-circuits to the
  `.existingVersion` static lane (row removed, slot released, re-acquired by `downloadEmby`).
- **Poll** (:308): transient poll errors keep polling (job is server-side); terminal HTTP
  401/403/404/410 fails the row (:322–333); Emby progress pinned at 0 until completion is
  deliberately not surfaced as “0%” (:355).
- **Cancel**: `delete` of a `.preparing` row fires `DELETE /Sync/Jobs` via
  `DownloadDeletePolicy.embyConvertCancelDecision` (:1797–1824); the converted *file* is
  retained by design (#126 reuse).
- **Failure teardown** `failEmbyConvert` (:417) releases the slot explicitly (asymmetric with
  Plex, documented in code).
- **Residual gaps (matches audit E):** a row failed while the job is still Converting (e.g.
  the 401/403 terminal-poll path) never cancels the job — delete-policy requires `.preparing`
  and `failEmbyConvert` doesn’t call `cancelEmbyConvertJob` (:434 has no caller on that
  path); a signed-out/mismatched session at delete loses the job id.

### C.3 Jellyfin (for completeness)

No prep machine: live forward-only stream + keepalive loop (:2397) + stall tracker restart
(:2295). Encoder teardown on terminal transitions via `releaseInFlight` psid maps with the
delete-path `rowSnapshot` fix (:2473, :1872) and the launch sweep (:311).

---

## D. Code-vs-doc mismatches

Legend: **[doc-gap]** = code is right, doc is wrong/stale → fix doc; **[bug]** = code should
change; **[undocumented invariant]** = real invariant that exists only in code comments →
promote to doc + test.

- **M-1 [doc-gap]** `docs/DOWNLOADS-OFFLINE.md` lifecycle diagram (lines 44–57) is missing:
  the `.unverified` state entirely; `Complete/Unverified → Failed` demotion
  (`demoteIncompleteCompletedStaticRows`, reconcile-on-missing-file); `Verifying → Paused`
  (`writeThenPause`); the `Transferring → Queued` bounce during request rebuilds (grace
  states); `Preparing → Paused/Failed`; `Paused → Failed` at reconcile without a checkpoint.
- **M-2 [closed 2026-07-11]** Held segment bodies and their index are now durable across process
  death; the relaunch harness restores them before planning and verifies reuse/no stash sweep.
- **M-3 [undocumented invariant]** Train epochs, validator pinning by the *first arriving
  body* (head or held), per-stash validators, and the held re-check at drain
  (`StaticRangeTrainIntegrityPolicy`, session :85, :2402, :2464, :2694) — all landed in
  `00c1dc7` and appear nowhere in the docs. These are the load-bearing anti-corruption
  invariants now.
- **M-4 [undocumented invariant]** Dead-finish adoption (I1, :1992) and its stricter NEW-1
  validator rule (unowned body may never trigger a destructive restart, :2285) are
  code-comment-only.
- **M-5 [doc-gap]** `DownloadStatus.reconciledStatus`’s own doc (“`.paused` stays resumable
  IFF the blob survived”, OfflineDownloadModels.swift:69–71) is stale relative to the store
  wrapper: `DownloadStore.reconcile` keeps a static-range row `.paused` on the strength of a
  durable partial alone (`hasAppRangeCheckpoint`, :878, :909). The durable-partial-as-
  checkpoint rule is correct and intended; the PMSKit docstring misstates the contract the
  composed system implements.
- **M-6 [bug, low]** Pause purges held stashes (:1352) while the failure-park keeps them —
  see IC-7. One sibling is wrong; the purge destroys completed bytes the resume planner
  (:1025) is explicitly built to reuse.
- **M-7 [bug, low]** `rangeBlobResumeCounts` is the only budget not reset by a fresh
  user-initiated `start()` (:930–933) and none of the four are cleared on session
  `cancel()`/row delete — see IC-8.
- **M-8 [bug, medium]** IC-1: the pause snapshot/halt ordering can strand a row
  `.downloading` with no tasks (and can let a window-enqueued segment escape the pause).
- **M-9 [bug candidate, needs Phase 6]** IC-2: 416-restart (delegate queue) vs in-flight
  append (`rangeIOQueue`) epoch TOCTOU — plausible silent corruption; needs the
  fault-injection harness to confirm reachability.
- **M-10 [audit-plan correction]** Plan item B.8 claims “NO free-space preflight exists”; in
  fact `start()` checks `systemFreeSize` against expected + 500 MB headroom and throws
  `.storageFull` (session :909–921). What remains open from B.8 is only the *mid-transfer*
  disk-full behavior (`failRangeMove` / `rangeMoveDecision` classification of
  `NSFileWriteOutOfSpaceError`).
- **M-11 [doc-gap]** The doc’s module-ownership table says the store owns “file-side
  effects”, but a load-bearing side effect lives in `updateProgress`’s silent
  `paused/failed/queued → downloading` promotion (:771) — several session paths depend on it
  (and one must actively undo it, the `writeThenPause` re-park :2624). Worth documenting;
  it is the single most surprising cross-layer coupling in the system.

Items the docs claim that the code **does** honor (verified): head-only blob persistence on
pause; stale-blob discard together with its watermark (:4123–4136); append-alignment
never-misaligned invariant (assembly policy + :2418/:2526); open-ended fallback as the
unknown-total plan; `#231` unmarked-closed-range drop on reattach; reattached tasks treated
as authoritative live work.

---

## E. Invariants that deserve executable enforcement

Confirmed from the audit plan’s candidate list, plus extensions. Suggested home:
**(P)** = PMSKit swift-testing model/property test, **(A)** = debug-build assert in app code
(under the existing lock), **(H)** = health-snapshot/diagnostic check (release-safe).

1. **Durable bytes monotonic** per row except the three sanctioned resets (changed-resource
   restart, oversized-partial truncate, user restart). (A) in `appendFile` callers: assert
   `fileSize(destination) == entry.baseOffset` immediately before append; (P) model test over
   the append/held/drain sequence.
2. **Exactly one head**: ≤1 authoritative task per (key, offset) for segments, ≤1 open-ended
   task per key, and never both an open-ended task and a closed train. (A) after every
   `rangeInflight` insert; (P) `StaticRangeTaskSelectionPolicy` composed with reattach +
   enqueue sequences.
3. **Blob offset discipline**: adopted blob offset == durable, or == the retried segment’s
   own base offset; adopted closed blobs must recover `segmentLength`. (P) — extend
   `StaticRangeResumeDataPolicy` tests with the train-pause→resume composition.
4. **Epoch discipline**: `rangeTrainEpochs` strictly increases; no body with a stale epoch
   reaches `appendFile`/`heldRangeSegments`; **new:** re-verify epoch + on-disk size
   immediately before `appendFile` (closes IC-2). (P) for the policy, (A) for the pre-append
   re-check.
5. **No orphaned tasks/stashes after supersede**: every id returned by
   `supersedeRange*Locked` is cancelled *and* its stash removed (today `removeRangeBodyStashes`
   runs only on the reattach path — in-session supersedes leave stashes to the next sweep). (A)
   + small code fix.
6. **Held-set invariants**: ∀ held: offset > durable, length > 0; held ∩ live-segment offsets
   drives the planner; held(key) is empty after cancel/restart/replaceWhole/finalize. (P) on
   assembly policy; (A) in `purgeHeldRangeSegments` call sites.
7. **Budget counters bounded and cleared**: all four counters cleared on complete, delete,
   cancel, and fresh user start (fix M-7 first, then (A) assert in `cancel()`); (H) the
   health snapshot could sum per-key counter cardinality vs row count.
8. **Grace/gate balance**: `rangeRequestRebuildGraceKeys` and
   `backgroundCompletionGate.pendingOperationCount` return to zero when no row is in active
   work. (H) — fields already exist in `diagnosticSnapshot` (:321).
9. **Cross-layer**: `activeJobs ⊆ rows ∪ in-delete`; `serverPrepPollerTasks.keys ⊆ activeJobs`;
   keepalive keys ⊆ keys with `isTrackingTransfer ∨ status ∈ {queued<grace>, downloading}`;
   `finalizingRatingKeys ⊆ rows`. (H) in `recordDownloadHealthSnapshotIfNeeded` — counts are
   already collected there; add the subset checks and a diagnostic when violated.
10. **`.downloading` liveness**: status `.downloading` ⇒ session tracking ∨ rebuild grace ∨
    reattach in flight. Catching IC-1 requires exactly this check; the watchdog (:2320) is
    the natural place, demoting violations to `.paused` at the durable checkpoint. (H→A)
11. **Server-prep attempt identity**: after any await in the Plex chain, either
    `assertCurrentOptimizeAttempt` passed or the chain exited without touching the store;
    Emby equivalent via `embyConvertAttemptIsCurrent`. (P) — an executable model of the
    attempt tracker (begin/end/clear/release interleavings, two overlapping attempts on one
    key) would pin the exact races `9600fe9` fixed.

An executable PMSKit skeleton for Phase 6: model the row as
`(durable, expected, epoch, validatorPin, held{offset→(len,validator)}, live{offset→body},
halted, budgets)` and drive it with the event alphabet extracted in §A.3; assert invariants
1–7 after every step. All inputs are already pure policies; only the sequencing shell is new.
