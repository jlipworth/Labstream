# Full Downloads-Engine Audit Plan (2026-07-10)

Systematic audit plan for the entire downloads subsystem, produced after a full read of
`Labstream/Downloads/BackgroundDownloadSession.swift` (4409 lines), `DownloadManager.swift`
(3027) + its 5 backend extensions, `DownloadStore.swift` (1067), the ~80 PMSKit download
policy files and ~85 test files, `docs/DOWNLOADS-OFFLINE.md`, and the segment-train design
doc `docs/archive/downloads/2026-07-10-static-range-segment-checkpointing.md`.

Motivation: recurring live-found bugs in the interaction of orthogonal dimensions
(backend × lane × resume mode × lifecycle × server response × environment × concurrency).
Line numbers below are as of commit edf2d27.

## A. Surface map — actual files per area

- **Route planning/choice:** app `Labstream/UI/DownloadOptionsSheet.swift`,
  `Labstream/Downloads/DownloadManager+Plex.swift`/`+Jellyfin.swift`/`+Emby.swift`; PMSKit
  (all `PMSKit/Sources/PMSKit/Downloads/`) `PlexDownloadRouter`, `JellyfinDownloadRouter`,
  `EmbyDownloadRouter`, `EmbyDownloadRoutePlan` (rerouteConvert), `JellyfinDownloadSourcePlan`,
  `DownloadChoice`, `DownloadMediaSelectionPolicy`, `DownloadAudioSelectionPolicy`/
  `DownloadAudioCodecList`, `DownloadExistingVersionOptionPolicy`, `OptimizedVersionMatch`,
  `DownloadOptimizeSourcePolicy`, `PlexOriginalFallbackPolicy`, `DownloadPresetPolicy`,
  `OfflineDownloadDecision`.
- **Server prep (Plex optimize):** `DownloadManager+PlexOptimize.swift`
  (`triggerOptimizeAndDownload` :31, `cleanStaleOptimizeJobs` :461,
  `unpauseBackgroundQueueIfNeeded` :514); `DownloadManager.swift` `pollForOptimizedPart` :2605,
  `pollOptimizeActivity` :2759, poller lifecycle `beginServerPrepPoller`/`endServerPrepPoller`/
  `clearServerPrepPoller` :1520–1556, optimize-ETA cluster :2826–2892; PMSKit
  `ServerPrepAttemptTracker`, `ServerPrepRefreshPolicy`.
- **Server prep (Emby Convert):** `DownloadManager+EmbyConvert.swift` (attempt-UUID tracking
  :18–33, `pollAndDownloadEmbyConvertJob` :264, `cancelEmbyConvertJob` :434,
  `refreshAndPollReusableEmbyConvertedSource` :616); PMSKit `EmbyConvertedSourcePolicy`.
- **Range/segment engine:** `BackgroundDownloadSession.swift`, `StaticRangeTransferRegime.swift`,
  `BackgroundDownloadCompletionRegistry.swift`; PMSKit `StaticRange*` (~15 types) +
  `BackgroundRange*`/`BackgroundDownload*` policies.
- **liveForwardOnly:** `DownloadManager.swift` `detectForwardOnlyStreamStalls` :2213,
  `restartStalledForwardOnlyStream` :2220, `ensureJellyfinDownloadKeepalives` :2300,
  `teardownOrphanedEncodersOnLaunch` :311; PMSKit `DownloadForwardOnlyStallTracker`,
  `DownloadStallRecoveryPolicy`, `TranscodeSizeEstimator`, `JellyfinDownloadKeepalivePolicy`,
  `DownloadEncoderTeardownPolicy`.
- **Finalize/validation:** `BackgroundDownloadSession` `finalizeTransferredFile` :3173,
  `finalizeCompletedStaticRangeFile` :2906, `revalidateCompletedDownload` :2935;
  `DownloadManager` `demoteIncompleteCompletedStaticRows` :1910,
  `revalidateUnverifiedDownloads` :1934; PMSKit `DownloadCompletionValidation`,
  `DownloadExpectedBytesPolicy`, `BackgroundFinalizationResultPolicy`,
  `BackgroundDownloadCompletionGate`.
- **Store/registration/deletion:** `DownloadStore.swift` (`upsert` :435, `reconcile` :855,
  `remove` :964, `storageAudit` :239, `sourceExactBytes` :399, resume-data/validator
  persistence :557–731); `DownloadManager.delete`/`deleteAllDownloads` :1737–1746;
  `OfflineLibraryView.swift`; PMSKit `DownloadDeletePolicy`, `DownloadTerminalReleasePolicy`,
  `OfflineDownloadFileInventory`, `BackgroundTempFileCleanupPolicy`,
  `OfflineLibrarySnapshot(Builder)`.
- **Side assets:** `DownloadManager+SideCache.swift` (posters, BIF, trickplay, chapter images,
  text subs); PMSKit `DownloadSideAssetPolicy`, `OfflineTextSubtitles`.
- **Playback handoff:** `DownloadStore` URL resolvers :255–278 + `setLocalPlaybackPosition`
  :496; `Labstream/Player/PlaybackController.swift`, `TrickPlayThumbnailProviders.swift`;
  PMSKit `OfflinePlaybackDecision`.
- **UI state:** `DownloadManager` caption/progress cluster :2480–2596; PMSKit
  `DownloadRowStatusCaptionPolicy`, `DownloadRowDisplayPolicy`, `DownloadProgressDisplay`,
  `DownloadLiveRangeProgressPolicy`, `DownloadDisplayClassifier`,
  `OfflineDownloadAggregateStats`, `DownloadQueueToolbarPolicy`, `DownloadRateEstimator`.
- **Storage:** `DownloadManager.rejectIfOverStorageLimit` :1705 (+ :1682–1713); PMSKit
  `DownloadStorageLimitPolicy`, `DownloadStorageEstimatePolicy`.
- **Auth/identity:** request construction in `BackgroundDownloadSession.start` :878–960
  (note :892 comment re tokens-in-query), `requestApplyingCellularPolicy` :388; PMSKit
  `BackendSession`, `BackgroundDownloadTaskIdentity`.
- **Migration/compat:** `DownloadStore` `Row.init(from:)` :36–45 (`decodeIfPresent` +
  `migratedStatus(forLegacyProgress:)`), tolerant row-by-row decode + versioned envelope
  :998–1062; PMSKit `DownloadIndexCoding`.
- **Diagnostics:** `Labstream/Diagnostics/AppDiagnostics.swift`, `DiagnosticFileLogSink.swift`,
  `DiagnosticReportArtifact.swift`; redaction rule referenced at
  `BackgroundDownloadSession.swift:4119`; PMSKit `DownloadHealthSnapshotPolicy`,
  `DownloadJobSnapshot`, `DownloadWatchdogPolicy`.

## B. Highest-suspicion areas (verify first; several look like live bugs)

1. **Held-segment stashes vs orphan sweep across relaunch.**
   `sweepOrphanedRangeBodyStashes(liveTaskIdentifiers:)` (BackgroundDownloadSession:731) keys
   survival on LIVE task ids, but `heldRangeSegments` (:77) holds bodies of FINISHED tasks
   awaiting contiguity. Is the dict rebuilt from disk after process death, or are completed
   512 MiB segments silently swept/lost on reattach?
2. **Validator consistency across the segment train.** If the server file changes between
   segment N and N+1 (the post-optimize-render scenario that already produced the
   416-then-200 bug), do all segments carry the same If-Range, and does a mismatch on one
   segment tear down the whole train (`restartRangeFromChangedResource` :2830)?
   Per-segment-only handling appends bytes from two file versions — silent corruption.
3. **200-instead-of-206 on a MID-train segment.** replaceWhole semantics predate the train; a
   200 answering `bytes=1073741824-…` must not replace the whole file, and a 200 on segment 0
   must supersede segments 1–7. Check whether `StaticRangeRemainderRequestPolicy`/
   `StaticRangeFinishedBodyPolicy` inputs distinguish closed mid-train segment from remainder.
4. **`rangeBlobResumeCounts` asymmetric cleanup** — cleared at exactly one site (:2515) while
   `retryCounts`/`rangeHTTPRehydrateCounts` clear at :2319/:2512 and reset in all three start
   paths (:937/:1198/:1287). An exhausted 3-blob budget may survive pause→re-download
   forever, permanently refusing blob adoption.
5. **`supersededRangeTaskIdentifiers` (:144) never pruned + task-identifier reuse across
   session recreation** — :3506 can silently drop a fresh task's completion; per-identifier
   dicts (`loggedProgressMilestones`, `lastRangeProgressDiagnostic`, `loggedExpectation`)
   also uncleaned by `supersedeRangeSegmentTasksLocked` (:267).
6. **Lock-drop windows** in `drainHeldRangeSegments` (:2611–2665, lock taken/released per held
   segment around rangeIOQueue appends) and the asyncAfter-ended rebuild grace (:477) racing
   pause/cancel/newer-generation restarts.
7. **Non-atomic `appendFile` (:3143) vs checkpoint=file-size.** Crash mid-append leaves a
   non-segment-aligned checkpoint; `StaticRangeSegmentAssemblyPolicy` then discards every
   held/queued segment as overlap-not-aligned. Is there truncate-to-alignment recovery on
   relaunch?
8. **No real free-space preflight.** `rejectIfOverStorageLimit` enforces a user-configured cap
   only; NO `volumeAvailableCapacity*` query exists anywhere in app code. Disk-full
   mid-transfer lands in `failRangeMove`/`recoverRangeMoveFailure` (:3039–3142) — audit
   whether NSFileWriteOutOfSpaceError is terminal or retry-loops (a retry loop against a full
   disk with a 512 MiB stash can dead-loop the queue).
9. **Server-job cancellation on user cancel/delete.** `cancelEmbyConvertJob` (EmbyConvert:434)
   and `cleanStaleOptimizeJobs` (PlexOptimize:461) exist — verify `DownloadManager.delete`
   (:1746) and pause reach them in every phase (prep-in-progress,
   prep-done-transfer-started). Orphaned server transcode jobs eat the server's disk
   invisibly.
10. **Attempt-generation races in server prep.** Two parallel staleness mechanisms (Emby
    attempt UUIDs vs Plex `assertCurrentOptimizeAttempt` PlexOptimize:266 +
    `ServerPrepAttemptTracker`) with pollers started/ended at :1520–1556. Retry-while-poller-
    alive and pause-during-poll are exactly the shape of past bugs.
11. **Token/URL staleness on long-lived requests.** Segments/rebuilds bake in auth at enqueue
    time. On Jellyfin/Emby token invalidation or LAN↔WAN base-URL change mid-train: does the
    `onRangeRequestNeeded` rebuild re-resolve token+URL via `staticRangeBackendSession(for:)`
    (:671) or replay stale? And does `retryTransientRangeHTTPFailure` (:4203) classify a
    dead-token status (401, or Plex's bare 400) terminally or churn?
12. **`sourcePartSize` byte-exactness gating** (confirmed trap): it's the SOURCE size even on
    transcode rows; `DownloadStore.sourceExactBytes` (:399) gates on staticByteRange — audit
    every consumer (`DownloadCompletionValidation`, `demoteIncompleteCompletedStaticRows`
    :1910, `markCompleteIfUnverified` :821) for a path comparing transcode bytes against
    source size → false "incomplete" demote-churn loops.
13. **`reconcile(liveRatingKeys:)` (:855) vs not-yet-registered starts** — a row created after
    the live-key snapshot (server-prep phase, slot acquired but transfer not started) could be
    reaped; interacts with `acquireInFlightSlotForStart` (:475) / `releaseInFlight` (:2394)
    slot leaks.
14. **DownloadManager per-key lifecycle leaks** — `lastError`, keepalive tasks
    (`startJellyfinDownloadKeepalive` :2322), stall trackers, optimize-ETA state (:2826–2887),
    retry handoffs (:1960–1971): same scattered-cleanup topology that produced items 4–5.
15. **Diagnostics over-redaction** — the "generic secret rule blanks longer bare tokens"
    (:4119) can blank legitimate long identifiers in app-diagnostics.jsonl, destroying
    live-debugging evidence; verify FNV-1a download_id mapping survives redaction.

## C. Phases (prioritized, quick wins first)

**Phase 1 — Bookkeeping-lifecycle tables** (~1 day; 2 parallel subagents; read-only). For
every per-ratingKey/per-taskIdentifier mutable collection, build populated/read/cleared
tables across all terminal paths (complete, cancel, delete, pause, supersede, prep-failure,
relaunch). Agent A: `BackgroundDownloadSession` (14 collections, :68–153) — closes
suspicions 4–5. Agent B: `DownloadManager` + extensions (slots, pollers, keepalives, attempt
UUIDs, ETA, lastError) + `DownloadStore` sidecar state — closes 9, 10, 13, 14. Catches:
stuck budgets, ghost rows blocking re-download, orphaned server jobs, leaked pollers.

**Phase 2 — State-machine extraction + three-layer coherence diff** (~1.5 days; 1 thorough
subagent + lead review). Extract actual machines and diff against `docs/DOWNLOADS-OFFLINE.md`
lifecycle diagram + the segment-train doc: (a) range engine (delegate methods
:1570/:1810/:3497/:4399 + retry cluster :3789–4278); (b) orchestration (DownloadStatus in
store × DownloadManager phase × session tracking — the CROSS-LAYER coherence invariants are
the point: store `.queued` while session tracks a live transfer, `finalizingRatingKeys` set
while row deleted, keepalive running while `isTrackingTransfer` false); (c) server-prep
sub-machine per backend (trigger→poll→resolve→static handoff→cancel). Deliverable: state
tables in docs/ + an executable PMSKit model skeleton feeding Phase 6. Every code-vs-model
mismatch is a bug or an undocumented invariant.

**Phase 3 — End-to-end route traces** (~1 day; 1 subagent per backend, parallel). Walk each
pipeline cell: Plex {original, existing-version, optimize-fresh, optimize-reuse}, Jellyfin
{original, remux, capped-transcode}, Emby {original, existing, convert-reroute, remux} —
from DownloadOptionsSheet choice → router → `DownloadTransferStartPlan` →
`OfflineDownloadModels.DownloadResumeMode.resolved` → transfer lane → validation gating
(suspicion 12) → registration → deletion incl. server-job cancel (suspicion 9). Each trace
asserts correct lane, expected-bytes source, validation strictness, cleanup set. This is
where the Emby-Convert-misclassified-as-server-paced class lives.

**Phase 4 — Coverage-gap matrix + targeted PMSKit tests** (~2 days; matrix by one agent,
test-writing fanned out 3–4 agents; pure `swift test`, no simulator, fully parallel).
Dimensions: backend × lane × resume mode × lifecycle event × response class
(206/200/416/validator-flip/truncation/slow-start/401) × environment × concurrency. Priority
dark cells: retry×train×blob adoption COMPOSED (`StaticRangeResumeDataPolicy` ×
`StaticRangeReattachPolicy` × `StaticRangeSegmentMarker`); response class × train position
(head/mid/tail — suspicions 2–3); `DownloadResumeMode.resolved` full edge matrix (nil convert
jobID, missing optimize targetName, unknown size); pause/delete × held segments;
forward-only stall→restart→stall budget exhaustion + `TranscodeSizeEstimator` with
absent/false Content-Length + keepalive during queue-pause; `DownloadCompletionValidation` ×
transcode rows × sourcePartSize; `DownloadIndexCoding` migration round-trips (pre-D5 rows,
corrupt-row skips, forward-version envelope).

**Phase 5 — Adversarial review fan-out** (~1.5 days; 8 parallel subagents, one lens each,
primed with past-bug list + Phase 2 tables):
1. Lock discipline/lock-drop windows (NSLock :115 vs finalizationStateQueue/rangeIOQueue/
   rangeRetryQueue) — BackgroundDownloadSession :2611–2740, :1319–1540, :430–510.
2. Offset arithmetic/alignment/append atomicity — `enqueueRangeSegment`, `appendFile`,
   `continueRangeAfterBody`, queue/assembly policies.
3. Task identity: markers, identifier reuse, reattach adoption — `StaticRangeSegmentMarker`,
   `StaticRangeReattachPolicy`, `BackgroundDownloadTaskIdentity`, `reattach()` :508–730.
4. Simulator/device #if divergence (only 2 sites: :338, :1133) + EVERY URLRequest
   construction site for the 60s-timeout regression incl. retry rebuilds.
5. Finalize/move-failure recovery, temp accounting, disk-full (suspicion 8) — :2906–3495,
   `BackgroundTempFileCleanupPolicy`, `sweepOrphanedNetworkTemps`.
6. Async orchestration races: attempt UUIDs, pollers, Task cancellation, actor hops —
   `+PlexOptimize`, `+EmbyConvert`, poller cluster :1520–1556, resume cluster :646–1519.
7. Deletion completeness: file inventory vs everything ever written (main file, stashes,
   resume blobs, posters, BIF, trickplay tiles, chapter images, subs, validators, play
   sessions, server jobs) — `DownloadStore.remove`/`reconcile`/`storageAudit`,
   `DownloadDeletePolicy`, `+SideCache`.
8. Auth/URL staleness + diagnostics redaction integrity (suspicions 11, 15) — request rebuild
   paths, `BackendSession`, `Labstream/Diagnostics/*`.

**Phase 6 — Fault-injection harness** (2–3 days; after Phases 1–5 confirm the seams).
URLProtocol fake server driving the REAL BackgroundDownloadSession (foreground path); one
seam needed: injectable `URLSessionConfiguration.protocolClasses` in `makeURLSession` (:336).
Priority scripts: out-of-order finish→hold→drain→pause mid-drain; validator flip at segment
2; reset mid-segment→blob adopt→second reset; session teardown/recreate with stashes on disk
(relaunch sim); 401 mid-train; injected write failure (disk-full). Only layer that catches
delegate-ordering/lock-interleaving bugs — the class every past live-found bug belongs to.
Cheaply extendable to the forward-only lane (streamed body, mid-stream stall) once built.

**Phase 7 — Live/device checklist delta** (~2 hours; ships as TESTING-CHECKLIST.md update).
Device-only cells: process-kill mid-train + background completion delivery; blob availability
force-quit vs OS-kill; wake-time silent retry with train active; token revoked while asleep;
LAN→WAN switch mid-download; device disk pressure; play-while-downloading (per whatever
Phase 3 finds the intended semantics to be); Emby Convert finishing while asleep.
Cross-reference each with app-diagnostics.jsonl event names + hashed download ids so live
runs yield checkable evidence, not impressions.

## D. Sequencing

1. Phase 1 (both agents) + Phase 4 matrix construction start immediately in parallel
   (read-only).
2. Phase 2 next; feeds Phase 5 lens briefs and Phase 6 scripts. Phase 3 runs parallel to
   Phase 2 (different files).
3. Phase 5 fan-out after Phase 2; Phase 4 test-writing anytime (no simulator contention).
4. Phase 6 once cheaper phases stop yielding — or immediately if suspicions 1–3 can't be
   closed by inspection. Phase 7 anytime.

Only Phase 6 (if run as app-target tests) and confirm-repro steps touch a simulator;
everything else is source/`swift test` and safe for unlimited worktree parallelism under the
sim-lease rules.

**Single highest-yield first hour:** verify suspicion 1 (held-stash survival across relaunch)
and suspicion 2 (If-Range consistency across the train) by direct inspection — both are
plausible silent data-loss/corruption bugs in code the latest commits touched — plus
suspicion 9 (server-job cancel on delete), a five-minute call-graph check with real
server-side cost if broken.

## E. First-hour verification results (2026-07-10, read-only inspection)

Suspicions B.1, B.2/B.3, and B.9 were verified by three independent read-only passes.
Citations are `BackgroundDownloadSession.swift` unless noted, as of edf2d27.

### B.1 — CONFIRMED (bandwidth loss, not corruption)

Held out-of-order segment bodies are stashed to `tmp/vp-range-body-<taskID>-o<offset>` but
recorded only in the in-memory `heldRangeSegments` map (:77, :2406) — never persisted. After
process death + reattach (device background session), `sweepOrphanedRangeBodyStashes` (:723)
builds its protection set from the now-empty map, and the held segment's task is absent from
`getAllTasks` (it completed in the prior life), so `BackgroundTempFileCleanupPolicy.
shouldDeleteRangeBodyStash` deletes the stash. No re-adoption path from disk exists, so even
retention would just leak. Self-heals: the remainder planner (:1014–1028) sees the hole and
re-enqueues a fresh segment — worst case ~3.5 GiB (7 × 512 MiB) silently re-downloaded per
row. Simulator behavior is correct (foreground train dies with the process; sweep is right).
Secondary unproven race: a REdelivered finished task's fresh stash (:2077–2080) can be swept
mid-flight before `applyFinishedRangeBody` registers it — needs a device experiment.
Fix direction: persist held-segment metadata (offset, length, validator) keyed by download
ID, and re-adopt matching stashes on reattach before sweeping.

### B.2 — CONFIRMED BUG (silent corruption window + restart churn)

Segments stamp If-Range from the pinned validator (:1140–1142) and an owned 206 with a
different response validator does route to `restartRangeFromChangedResource` (:2350–2356,
:2445–2451, restart :2830–2897). But:

1. **Restart does not tear down the train.** The restart never calls
   `supersedeRangeTasksLocked`; worse, the re-plan's `liveSegmentOffsets` (:1014–1018)
   includes stale in-flight siblings and `StaticRangeSegmentQueuePolicy.segmentsToEnqueue`
   skips their offsets — old-resource fetchers remain authoritative in the new train.
2. **Silent-corruption window via held segments.** Restart clears the pinned validator
   (:2841); a fresh one is pinned only when the first new body appends (:2518–2519). A stale
   sibling finishing in that window takes the held path where the validator check is vacuous
   with no stored validator (:2350–2352), is stashed (:2406) recording only (url, length) —
   NOT its response validator — and `drainHeldRangeSegments` splices it onto the new-version
   prefix with no re-check possible (:2606–2611). Bytes from two file versions in one file;
   byte-count validation passes if sizes line up. Same window exists at initial train start.
3. Even outside the window, each stale sibling finishing after re-pinning triggers another
   full delete-and-restart (successful append resets the budget :2512–2513): up to 7 multi-GB
   re-downloads, or terminal "source file kept changing" (:2854–2868) when the file changed
   exactly once.

### B.3 — split: (a) NOT A BUG, (b) CONFIRMED (completed-file destruction)

`StaticRangeRemainderRequestPolicy.writeDecision` knows only the HTTP status (no request
shape), so a mid-train 200 routes to `.replaceWhole` (:2106) — but adoption is gated by
`RangeTransferHTTPPolicy.shouldAdoptReplaceWholeBody` (PMSKit :22–35): size must equal the
expected total, or validators must differ, or no expected total. Rejected 200 → discard +
bounded retry (:2277–2305). So no append/blind-replace: (a) not a bug. Residual weakness:
the validator-diff branch adopts a changed-resource 200 of ANY size (truncated body judged
against the OLD expected size downstream). (b) CONFIRMED: after an adopted whole-file 200,
an in-flight tail segment with baseOffset ≥ the (smaller) new file size takes the held path,
hits validator mismatch against the freshly pinned 200 validator (:2314, :2350–2354), and
calls `restartRangeFromChangedResource` — deleting the just-completed file (:2840) and
restarting from 0, racing the in-flight `finalizeRangeWhole` (:3019–3026). Nothing marks
siblings superseded on the replaceWhole path; completed/verifying status does not gate
`finishRangeRemainder` (:2056–2072).

**Shared fix surface for B.2 + B.3(b):** (1) changed-resource restart and adopted-200
replace must supersede/cancel the whole train (mechanism exists: `supersedeRangeTasksLocked`);
(2) held stashes must record their response validator so the drain re-checks before splicing.

### B.9 — CONFIRMED LEAKS (primarily Plex optimize)

Shared: user "cancel" == delete (OfflineLibraryView:347); delete (DownloadManager:1746–1799)
→ Emby job cancel, task cancel, row removal, `releaseInFlight` (:2394–2478 — poller cancel,
keepalive cancel, JF/Emby ActiveEncodings DELETE from in-memory psid maps); launch sweep
`teardownOrphanedEncodersOnLaunch` (:311–345).

- **Plex optimize (leaks):** (1) No delete-time server-job removal exists at all — the only
  reap is `cleanStaleOptimizeJobs` (+PlexOptimize:461–505), called solely from the NEXT
  `triggerOptimize` (:328) and skipping completed jobs (OptimizeRequest:386–393): a deleted
  in-prep download keeps transcoding server-side and its rendered version can persist
  indefinitely. (2) Fresh-start poller is uncancellable: only the resume path stores its
  Task in `serverPrepPollerTasks` (:1516); the fresh path (+Plex:138,159) runs inline with
  no handle, and `pollForOptimizedPart` (:2615–2661) never checks `activeJobs` — after
  delete it keeps polling 3–4 req/5s until a part appears (then staleness throws safely) or,
  if the queue item was reaped concurrently, FOREVER until app exit. (3) Phases b/c: cleanup
  deliberately never deletes completed type-42 items (correct — it would delete the rendered
  version), but after row deletion nothing ever reclaims the rendered server-side version.
  Correct: pause (intentional keep + title protection), relaunch-resume poller, retry reap.
- **Emby Convert (mostly correct):** delete of a `.preparing` row fires DELETE /Sync/Jobs
  (:1757–1789 + DownloadDeletePolicy:18–28); create-race covered (+EmbyConvert:241–248);
  pollers exit promptly via attempt UUIDs. Edge leaks: session-mismatch/signed-out at delete
  → job id lost, conversion runs on; a row failed while the job still Converting (e.g.
  terminal-poll 401/403, :323–333) → delete returns `.none` (policy requires `.preparing`),
  job never cancelled. Converted-file retention is by design (#126 reuse).
- **Jellyfin encoder (correct in-session, two warts):** (1) ordering — delete removes the
  store row (:1791) BEFORE `releaseInFlight` reads it (:2412), so the server-match guard is
  silently skipped and the persisted-psid branch can never act on a deleted row; (2) if the
  launch sweep couldn't clear a persisted psid (signed out/unreachable, retained :304–310),
  deleting that row destroys the only handle → no teardown, no later retry. Self-limiting
  via JF idle-kill of unpinged transcodes; same applies to Emby psids.

## F. Execution log (updated 2026-07-10, end of Phase 3)

Fix commits on main, all gated by full PMSKit suite + visionOS build + golden-sim smoke:
- `00c1dc7` — B.2/B.3(b): train teardown on changed-resource restart + adopted-200;
  held-stash response validators re-checked at hold and drain; first-arriving-body
  validator pinning; Content-Length guard on replaceWhole adoption
  (`StaticRangeTrainIntegrityPolicy`).
- `9600fe9` — B.9 + Phase-1B #1/#2c: Plex delete-time optimize-job cancel
  (`plexOptimizeCancelDecision`, completed-render-safe `cancellableItemID`); fresh-start
  prep poller registered/cancellable + in-loop orphan exit; Emby failed-row Convert
  cancel; delete passes pre-removal row snapshot to `releaseInFlight`; optimize progress
  cleared on delete/terminal; attempt-guarded poller releases.
- `22f05ba`/`ec0ccf2` — Phase-1 batch: L1 blob-budget reset on start + pre-halt fallback
  clear; L3 resumeRange full budget reset; L4 unconditional pause halt-key; L2 held-stash
  purge on all 17 terminal-`.failed` sites (`setFailedPurgingHeldSegments`); B.14
  `StaticRangeRecoveryTracker.removeAll` on delete; B.13 reconcile snapshot-membership
  guard (`DownloadStatus.reconcileEligible`).
- `5928f2b` — Phase-2 follow-ups: IC-2 pre-append epoch/size re-check
  (`preAppendDecision`; residual microsecond window noted — full fix = serialize restart
  teardown onto rangeIOQueue); IC-1 halt-stranded rows parked `.paused` at discard sites;
  M-6 pause no longer purges held stashes (resume reuses them); M-7 cancel-time budget
  clears.

Phase results (full reports in session transcript):
- Phase 1A/1B: lifecycle tables done. B.5 REFUTED (session never recreated in-process).
  B.4 downgraded (bounded waste). Slot accounting, attempt UUIDs, keepalives, DownloadStore
  row state all CLEAN. Open (small): side-cache orphan files after quick delete;
  dangling `lastError` writers (deliberate in one case).
- Phase 2: `docs/audits/2026-07-10-downloads-state-machines.md` written (3 machines,
  incoherent composite states, 11 executable invariants, Phase-6 model skeleton).
  Correction: audit plan B.8 wrong — free-space preflight EXISTS in start() (+500 MB
  headroom); only mid-transfer disk-full classification open. Open: IC-4 JF keepalive
  never checks isTrackingTransfer; doc gaps M-1..M-5, M-11.
- Phase 3 traces: Plex F1–F6, Emby F1–F13, Jellyfin F1–F6 (see reports). Emby's two
  named targets REFUTED (crash-window mode flip fails closed; sourcePartSize trap not
  applicable — Part.size nil by construction). Generic-profile constraint holds on all
  Plex cells. Phase-3 fix batch LANDED: `43f6d0e` (PLEX-F1 fallback-seed lane/mode stamp
  + PLEX-F2 rendered sourcePartSize at handoff), `66b5246` (EMBY-F1 Convert cancel before
  reuse handoff + EMBY-F2/F5 selection hardening: exact-tier-first, source-band below-tier
  rule, audio-language match, positional recency tie-break), `4fddb47` (JF-F1 container
  extension derived from existing original-lane relativePath across all retry funnels),
  `47b9035` (JF-F3 stall-restart budget re-seeded after releaseInFlight; cap binds).
  Plus `95fb6fc` (IC-2 debug assert, size-read-before-epoch ordering). Suite at 1293.
  Noted follow-up: audioStreamIndex not persisted in OfflineMetadata, so the
  relaunch-resume reuse probe can't audio-match (future persistence item).

Deferred to user judgment / later phases:
- JF-F2 (HIGH class, policy decision): truncated forward-only stream ≥80% duration (or
  nil duration) finalizes `.complete`; fix needs a completion-authority signal (encoder
  session final state) or tighter threshold. Interacts with N2 (keepalive reports
  position 0) and F2c (in-process keepalive dies while background transfer continues).
- JF-F4 (device-only): forward-only download finishing while app terminated is dropped
  (adoption path only handles static-range tasks); feasible via opaque taskDescription.
- JF-F5: persisted-psid branch never issues `.stop` (non-terminal rows post-relaunch).
- EMBY-F3: POST-create crash orphans untaggable Sync job; EMBY-F4: `.optimizeCompatible`
  silent 1080p downgrade (UX disclosure decision); EMBY-F6 existing-version silent source
  swap (add override-vs-decision guard); EMBY-F11 handoff remove→re-download crash window;
  EMBY-F13 unbounded poll on persistent 5xx; EMBY-F9 no Emby keepalive (live-verify).
- PLEX-F3 vacuous height guard on original-quality reuse; PLEX-F4 vanished-render retry
  downloads raw source unpreflighted; PLEX-F5 reuse leaves duplicate job rendering;
  PLEX-F6c poller has no overall deadline.
- Phases not yet run: 4 (coverage-matrix test writing), 5 (adversarial lens fan-out),
  6 (fault-injection harness — model skeleton ready), 7 (device checklist delta).

## G. Phase 5 results + JF completion batch (2026-07-10, evening)

JF batch landed: `88392d9` (forward-only truncation threshold 0.95, nil-duration → .unverified,
2-strike truncation park), `76c4342` (keepalive reports real advancing position), `b460a4b`
(adopt app-dead forward-only finishes), `3a3016f` (persisted-psid teardown on delete of
non-terminal rows). Suite at 1304.

Phase 5 (8 adversarial lenses, full reports in session transcript) — confirmed findings
consolidate into four mechanisms plus standalones:

1. **Attempt-token identity** (lens 3 F1–F3, HIGH corruption class): task identity is
   ratingKey-only; prior-attempt/prior-life tasks can be adopted into a re-download —
   old-rendition bytes appended or validator pin poisoned before first pin (F1); unowned
   416/404 can overwrite sourcePartSize, trigger destructive restart, or terminally fail a
   healthy train (F2 — NEW-1 covers only applyFinishedRangeBody, not finishRangeRemainder);
   reattached prior-life opaque task can replace the file wholesale (F3). Fix: marker v2
   with per-row attempt token; dead-finish outcomes restricted to discard/reset.
2. **Halt+supersede+epoch at every destructive/terminal site** (lens 1 F1/F3, lens 5 F1,
   lens 3 F5/F6): serialize the 416 restart call site onto rangeIOQueue (verified
   deadlock-free); epoch-bump on cancel/delete/truncate (missing bump = debug-build
   assert crash on legit delete race); terminal `.failed` sites must halt+supersede the
   live train (disk-full currently self-resurrects into an unbudgeted refetch loop that
   repeatedly purges siblings' held bodies; free-space check missing on continuation
   paths; ENOSPC shows "system code 640" or fake resumable pause); reattach needs a
   terminal-status gate (completed row flipped .downloading by straggler tasks) and
   should cancel unmatched (deleted-row) tasks instead of leaving them transferring
   forever.
3. **Start-attempt guards at entry points** (lens 6 F1–F4, HIGH): downloadJellyfin /
   downloadEmby negotiations and the Plex .original preflight tail have NO post-await
   currency checks — delete/pause during them is fully undone (row resurrection, orphan
   encoder; preflight-fail fallback seeds a zombie prep row that the refresh kick
   self-reanimates). Emby convert failure branches (3 sites) lack the attempt guard their
   success siblings have. Fix: per-key start-attempt token checked after every await
   preceding a store write or session.start.
4. **Standalones:** grace-timer needs a generation token (lens 1 F2 — first cycle's timer
   ends second cycle's grace early; device stall regression vector); pause-vs-cancel halt
   distinction so pause actually preserves finished bodies (lens 1 F4); CFNetwork temp
   reaper is dead code — needs a caller (lens 7 G1 = lens 5 F4); delete of .paused prep
   rows must cancel server jobs (lens 7 G2); held branch needs the internal-resume escape
   the in-order path has (lens 2 F1 — budget burn can terminal-fail healthy trains);
   dead-finish baseOffset must come from the REQUEST not response Content-Range (lens 2
   F2); reattach grid predicate must anchor at durable, not 0 (lens 2 F3 — legacy
   open-ended partials lose all background segments every relaunch); planner should be
   interval-aware + top-up on stale-discard (lens 2 F4); opaque lane needs the sim
   timeout stamp (lens 4 F1 — the 60s-override bug's sibling); background-wake finalize
   should defer the AVPlayer probe via .unverified (lens 4 F4 — handler held ~12s/file →
   wake-kill); side assets bypass the cellular policy (lens 4 F2); finalize needs a
   generation check vs a live replacement transfer (lens 5 F3); Plex prep poller must
   re-resolve auth per iteration + surface HTTP failures (lens 8 A-1); JF keepalive must
   check statuses and re-resolve (lens 8 A-2); 401/403 exhaustion should surface
   sign-in-again not generic HTTP (lens 8 A-3); redactor digit-requirement fix + rename
   domain_family + 3 missing events: range_stash_swept, keepalive first-failure,
   optimize_poll_unreachable (lens 8 B-1/B-3, ~25 labels currently blanked).

Verified-clean highlights: no lock-order inversions; consume-on-remove sound; range-lane
request stamping uniform; token storage/redaction leak-free; Range math and 64-bit
arithmetic sound; B.7 answered (misaligned checkpoint = bounded double-fetch, no
corruption); disk-full terminal at task level (the bug is train-level).

## H. HANDOFF — where this session stopped (2026-07-10, late evening)

Session ended due to usage limits while the final two Phase-5 fix waves were in flight.
A successor agent should pick up exactly here.

### State at stop

- **main is at `6a523cf`** (Waves A+B merged and fully verified: 1332/1332 PMSKit tests,
  clean visionOS build, golden-sim smoke UUID_MATCH, sim shut down). All 21 fix commits
  from today are on main but **NOT pushed**. `docs/audits/` is deliberately untracked.
- **Wave C (engine standalones) — agent `fix-wave-c-engine`, running directly in the
  MAIN worktree.** It has UNCOMMITTED in-progress edits to:
  `Labstream/Downloads/BackgroundDownloadSession.swift`,
  `PMSKit/.../StaticRangeFinishedBodyPolicy.swift` (+tests — adding
  `haltKind`/`isHalted`/`persistedStatusPaused` = pause-vs-cancel halt distinction),
  `StaticRangeReattachPolicy.swift` (+tests — `attemptID`/`rowAttemptID` params),
  `StaticRangeSegmentQueuePolicy.swift` (+tests — `liveSegmentOffsets:` = interval-aware
  planner), `RangeTransferHTTPPolicyTests.swift`.
  Scope (10 items, section G "Standalones"): grace-timer generation token; pause-vs-cancel
  halt kinds; held-branch internal-resume escape; request-derived dead-finish offsets;
  reattach grid predicate anchored at durable; interval-aware planner + top-up;
  opaque-lane sim timeout stamp; deferred background-wake AVPlayer probe via .unverified;
  finalize generation check vs live replacement; zero-byte-source edge.
  If the agent is dead: either resume it (SendMessage), or review/finish the working-tree
  diff by hand — do NOT `git checkout --` it without reading it first.
- **Wave D (auth + diagnostics) — agent `fix-wave-d-authdiag`, isolated worktree at
  `.claude/worktrees/agent-a742adacfafc73783`.** ⚠️ That worktree was cut at STALE base
  `3a9aa06` (predates all of today's fixes) — before merging, verify the agent
  fast-forwarded or rebase its commits onto current main; expect possible conflicts in
  DownloadManager+Plex/+Jellyfin.
  Scope: Plex prep-poller per-iteration auth re-resolution + `downloads.optimize_poll_unreachable`
  event; JF keepalive status checking + re-resolution; retry server-match guards; redactor
  digit-requirement fix (`\b(?=[A-Za-z0-9_=-]*\d)[A-Za-z0-9_=-]{24,}\b`) + label regression
  tests + `domain_family=` → `family=` rename; cellular policy on side assets.
  Items it was told to DEFER to its report (they live in BackgroundDownloadSession.swift,
  which Wave C owns): 401→notAuthenticated message mapping (~:2149–2155) and a
  `downloads.range_stash_swept` event in the reattach sweep → route to a small follow-up
  fix on main after both waves land.

### Close-out procedure (what the interrupted session would have done)

1. Wait for / resume both agents until they deliver. Wave C commits directly on main;
   Wave D commits on its worktree branch — merge it into main (mind the stale base).
2. Combined verification on main: `cd PMSKit && swift test` (expect >1332 green);
   full visionOS build per CLAUDE.md (delete stale .app first); golden-sim smoke:
   install → UUID_MATCH guard → launch → log check → screenshot; then
   `xcrun simctl shutdown "$SIMID"`. One sim at a time.
3. Clean up Wave D worktree: `scripts/worktree-sim.sh closeout <worktree>` then
   `git worktree remove` + branch delete.
4. Append Wave C/D commits to section F execution log; do the small session-file
   follow-up (401 mapping + range_stash_swept).

### Remaining audit work (not started)

- Phase 4: coverage-gap matrix + targeted PMSKit test writing.
- Phase 6: URLProtocol fault-injection harness (model skeleton in
  `2026-07-10-downloads-state-machines.md`; needs injectable protocolClasses seam in
  makeURLSession).
- Phase 7: TESTING-CHECKLIST.md device-cell delta.
- Deferred findings catalogued in sections F/G (Emby F3/F4/F6/F9/F11/F13; Plex
  F3/F4/F5/F6c; lens-7 gaps 3/4/6; B.1 held-stash persistence; CFNetwork temp reaper
  caller if Wave C didn't take it).
- Live verification carry-over: `range_internal_resume_adopted` on the user's paused
  big-movie download; headset device pass; audioStreamIndex persistence follow-up.

## I. SESSION CLOSE-OUT UPDATE (supersedes section H's "at stop" state)

Both final waves LANDED and the close-out in section H was completed by the original
session after all. Final state:

- **main is at `047aa56`** with a CLEAN tree (only `docs/audits/` untracked; nothing
  unpushed has been pushed — push is still pending user say-so).
- **Wave C landed as `e9a3636`** — all 10 engine standalones fixed (halt kinds,
  grace-timer generations, held-branch internal-resume escape, request-derived adoption
  offsets, durable-anchored attempt-matched reattach, interval-aware planner + top-up,
  opaque-lane sim timeout, deferred background-wake probe via .unverified, finalize
  attempt guard, zero-byte source). Its own gates were green (1339 PMSKit, build, smoke).
- **Wave D landed as merge `047aa56`** (branch commits `4759bc0`, `26f641f`, `5e2906f`).
  The branch was based on stale `3a9aa06`; merge conflicts in
  DownloadManager+PlexOptimize.swift (kept both: Lens-6-F3 seed cleanup in the
  staleOptimizeAttempt catch + new plexSessionUnavailable catch) and
  DownloadManager.swift (JF keepalive: kept N2/F2c monotonic reportedPositionTicks AND
  Wave D's tick-outcome/status health tracking; Plex poller: kept B.9 orphan guard first,
  then A-1 per-iteration auth re-resolution + PlexOptimizePollHealthPolicy) were resolved
  by the lead. The A-3 string contract ("Server returned HTTP 401./403." exact-match in
  DownloadTerminalAuthMessagePolicy) was verified intact against the post-Wave-C session
  file (interpolated at BackgroundDownloadSession.swift:2137/2439).
- **Combined verification on merged main: ALL GREEN.** PMSKit `swift test` 1360
  swift-testing + 89 XCTest, 0 failures. Full visionOS build exit 0
  (slug 952-047aa56245d0-clean). Golden-sim smoke: UUID_MATCH, launch clean (no
  crash/fatalError), screenshot shows signed-in Plex Home (Continue Watching + On Deck).
  Sim shut down; Wave D worktree/branch removed; orphaned agent sims pruned.

Phase 5 remediation is therefore COMPLETE (Waves A, B, C, D all merged + verified).

### Still open for the next session (unchanged from section H otherwise)

1. Small session-file follow-up deferred by Wave D: (a) `downloads.range_stash_swept`
   count+byte-bucket event in `sweepOrphanedRangeBodyStashes`
   (BackgroundDownloadSession.swift:~725); (b) optionally move the 401→notAuthenticated
   mapping engine-side (manager-side remap via DownloadTerminalAuthMessagePolicy works
   but is a string contract — keep the exact-match in sync with
   BackgroundDownloadSession.swift:2137/2439 if that text ever changes).
2. Remaining audit phases 4 (coverage-gap matrix), 6 (URLProtocol fault-injection
   harness), 7 (device checklist delta) — see section H.
3. Deferred findings list — see section H.
4. Push today's commits when the user asks; decide whether to commit `docs/audits/`.
5. Live verification carry-overs — see section H.

## J. RESUME UPDATE (2026-07-11)

The audit documents were committed on main (`23b0bac`) and the three remaining phases were
resumed in parallel from that checkpoint.

- **Phase 4 complete — `a6c964f`.** Added
  `2026-07-11-downloads-phase4-coverage-matrix.md` and five targeted PMSKit composition tests:
  backend/lane/resume-mode resolution; retry budget + v2 marker + reattach + segment-local blob
  adoption; head/mid/tail response classes; expected-byte/completion gating; and forward-schema
  corrupt-row isolation. Combined suite: 1365 Swift Testing + 89 XCTest, zero failures.
- **Phase 6 transport harness landed — `8414a59`.** The real foreground
  `BackgroundDownloadSession` now has a DEBUG-only injectable `URLProtocol` seam. The existing
  Plex range-drop probe also drives deterministic validator-flip and one-shot mid-train 401
  scenarios and requires both injection and engine-reaction diagnostics. See
  `2026-07-11-downloads-fault-injection-harness.md`. A live fault-path pass is still outstanding:
  the available probe records entered Plex optimize instead of an immediate static train.
  Pause-mid-drain, reset→blob→reset, relaunch-with-stashes, and filesystem-write injection remain
  open Phase-6 cells.
- **Phase 7 checklist complete — `3e817f9`.** Added all eight physical-device cells to
  `TESTING-CHECKLIST.md`, with verified JSONL event sequences, hashed `download_id` correlation,
  and explicit instrumentation gaps rather than invented evidence.
- **Deferred stash diagnostic complete — `a885e91`.**
  `downloads.range_stash_swept` reports successful cleanup count and a redacted byte bucket.

Combined main verification after integration: full PMSKit suite green, clean visionOS build,
install UUID match, clean launch/log smoke, and signed-in Home screenshot; simulator shut down.

### Highest-value next work

1. Extend the now-live-verified Phase-6 transport harness from validator-flip, mid-train 401,
   held-body pause/delete, and double resume-blob adoption into pause/delete-mid-drain,
   concurrent 200/416 handling, and relaunch with on-disk held stashes. Injected append ENOSPC is
   now live-verified as terminal with whole-train teardown and no transient retry.
2. Execute the Phase-7 physical-device cells, prioritizing process-kill/background redelivery,
   token/network changes while asleep, and disk pressure.
3. Close the checklist's evidence gaps (lifecycle cause, blob presence, network path, free-space,
   remote-play/download correlation, and Emby server-completion timing) before treating device
   observations as deterministic.
4. Continue the deferred backend/product findings in sections F–H (Emby F3/F4/F6/F9/F11/F13,
   Plex F3/F4/F5/F6c, held-stash persistence, and audio-stream-index persistence).
