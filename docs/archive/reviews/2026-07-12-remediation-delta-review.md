# Remediation branch delta review — 2026-07-12 (second pass)

> **Resolved snapshot:** This review describes `72c4b83..1e58a47d`, not current branch
> health. All confirmed D1–D8 findings were fixed in `139a7a5f` with focused regression
> coverage; the later remediation journal records the remaining live/device acceptance
> gates. The findings and line references below are retained as review evidence, not as an
> open work list.

**Scope:** `codex/remediation-nondownloads`, committed range `72c4b83..1e58a47d` (188 commits, 144 files, +19,264/−3,215). Working tree clean. This is a follow-up to the [first remediation branch review](2026-07-12-remediation-branch-review.md), which covered `main..72c4b83`.

**Method:** 17-agent verified review — 3 deep reviewers on the downloads artifact-lifecycle rewrites, 5 reviewers on browse refactor / playback revalidation / tests-probes / fix verification, each resulting finding adversarially verified by an independent agent instructed to refute it. 8 findings confirmed, 1 refuted.

---

## Verdict

**The delta is a clear improvement, and every one of the previous review's 14 findings (C1, C2, M1–M12) plus the minors batch is verified fixed at HEAD** — each fix was traced to the actual failure scenario, not just the journal claim. No new criticals. However, **4 new majors were confirmed, 3 of them in the new Phase 1A artifact-lifecycle machinery**, and all 3 are recurrences of the same defect theme the first review identified: fail-closed logic on a durable path without a recovery/restart fallback. They are seam gaps in otherwise sound new machinery, not design flaws — but they should be closed before the branch's crash-recovery guarantees are trusted.

Previous-findings verification summary:

| Finding | Status | Where verified |
|---|---|---|
| C1 pre-admission callback cancellation | **Fixed** — owned current-marker callbacks admitted during legacy purge (`BackgroundDownloadSession.swift:815`) |
| C2 v4 migration wedges ownerless rows | **Fixed** — ownerless nonterminal rows are adopted with a minted attemptID (`DownloadStore.swift:3766`) |
| M1–M9 (downloads) | **All fixed** |
| M10–M12 (auth/player) | **All fixed** |
| 19 minors | **Fixed** (batch spot-check, no exceptions) |

Area verdicts on the new work:

- **DownloadStore artifact lifecycle** (staged index committer, two-phase artifact intents, journal-first deletion, terminal-barrier row deletion): coherent and mostly correct; crash-window replay traced correctly for resume blobs, static checkpoints, held bodies, legacy resets, and row deletion. The 3 majors below are its seam gaps.
- **BackgroundDownloadSession admission/held-body**: clear net improvement; the old C1 flow is genuinely redesigned; nonblocking submissions cannot be observed reordered (in-memory mutation is synchronous under the store lock; only durability is deferred and fenced). One major (D4).
- **DownloadManager cleanup ordering**: correct in substance — delete/re-add, joined-waiter, retry-epoch, and side-cache paths all traced clean; journal unavailability now degrades to a durable deletion-pending reservation with user-visible retry. Two minors.
- **Phase 3/4 browse refactor**: behavior-preserving; wire shapes (query order, casing, paths, userId placement, paging, decode types) verified identical against `72c4b83` and golden tests. **No defects found.**
- **Playback foreground revalidation**: fail-closed gating is correctly paired with a fallback (parked keys re-admitted on next `scene_active`); Detail launcher unification preserves per-backend encoder-stop contracts. **No defects found.**
- **Tests/probes**: real code under test, no tautologies; live probes gate account mutation behind explicit opt-in with mandatory restoration; no secrets/PII (placeholder hosts only). **No defects found.**

---

## Major findings (4)

### D1 — Resume-blob submissions never restart an inactive artifact-queue head; can wedge the download callback path
`Labstream/Downloads/DownloadStore.swift:3050` (and `submitClearResumeData` at :3236)

`submitResumeData`/`submitClearResumeData` gate worker startup on `row.pendingArtifactIntents.count == 1`, unlike every other lifecycle submitter, which goes through `activateArtifactHeadLocked` and restarts an inactive predecessor head. After `failArtifactLifecycle` (e.g. ENOSPC on `writeAuthArtifact`), the failed head stays durably queued but inactive; a subsequent resume submission appends intent #2, activates nothing, and its coordinator ticket has no worker. `BackgroundDownloadSession` then calls `resolveSynchronously → waitSynchronously` with no timeout on the serialized session/range callback queue — on an otherwise idle store, download processing wedges for the rest of the session. The two submit sites also skip the `artifactRetirementKeys` check, so a submission racing an in-flight retirement can start a second worker whose publish re-check reports a spurious `blockedByPriorArtifactIntent` failure.

**Fix direction:** route both submitters through `activateArtifactHeadLocked` like the other lifecycle submitters, and honor `artifactRetirementKeys`.

### D2 — Launch reconcile ignores pending artifact intents; can delete a validated body and wedge the row
`Labstream/Downloads/DownloadStore.swift:5005` (reconcile), interaction with `submitValidatedPromotion`

`reconcile()` skips `deletionPending` rows but not rows with `pendingArtifactIntents`. A staged `.validatedPromotion` intent doesn't change `row.status` until its terminal snapshot, so after a hard kill in the prepared→terminal window the row is still `.downloading` with a durable promotion intent at head. Intent replay runs asynchronously on the artifact worker queue with no ordering barrier against the manager's reconcile. For liveForwardOnly transcode lanes (Jellyfin/Emby), reconcile demotes the row to `.failed` and **deletes the working file that is the fully-downloaded validated body**. The replayed promotion then loops on `.sourceMissing` forever (the head intent has no abandonment path), and `createAttemptOwnedRecord` rejects retries with `.artifactLifecyclePending` until the user deletes the row. Verified as a genuine regression vs `72c4b83`.

**Fix direction:** make reconcile skip (or barrier behind) rows with pending artifact intents, and give a permanently-source-missing promotion intent an abandonment path.

### D3 — Lifecycle coordinator boundary waits permanently poisoned by abandoned failed entries; entries never pruned
`Labstream/Downloads/DownloadArtifactLifecycleCoordinator.swift:170`

Coordinator `entries` are inserted at `register()` and never removed. `blockingBoundaryWait` returns `.failed` immediately if any intent's newest at-or-below-watermark entry is failed. Failed entries are only superseded by re-registering the SAME intentID — but permanently abandoned intents (failed head retired ahead of a queued row deletion; failed intent on a subsequently-deleted row; the one-shot random-UUID entry in `submitClearResumeData`'s no-change branch) are never re-registered. From then on, every `flushPersistenceThenFireBackgroundCompletions` (`BackgroundDownloadSession.swift:1090`) returns `.failed` instantly for the rest of the process: the background-completion barrier stops holding the OS handler until terminal snapshots are durable, so the OS may suspend the app mid-commit and recovery falls entirely on next-launch replay. Secondarily, the never-pruned dictionary is unbounded memory and is rescanned every 50 ms poll.

**Fix direction:** prune/supersede entries when their intent is abandoned (retired, row-deleted, one-shot), or scope boundary failure to still-live intents.

### D4 — Held-segment persist ends the background-completion gate before the replacement task exists
`Labstream/Downloads/BackgroundDownloadSession.swift:3805`

In `applyFinishedRangeBody`'s hold branch, `continueRangeAfterBody` was moved into the async `resolveHeldLifecycle` completion, but the enclosing background-completion gate operation ends when `applyFinishedRangeBody` returns — before the completion runs. Pre-change, `continueRangeAfterBody` ran synchronously inside the gate, so the rebuild-grace/next-task hold always overlapped and the gate could never hit zero in between (the file's own comments call this "the decisive half of the off-head stall", the #212 invariant). Off-head on a background wake: gate hits zero, the OS handler fires, the app suspends before the completion runs — the train slot is never refilled and the download runs a lane short or stalls. Verified against base: this reopens a previously-closed race.

**Fix direction:** keep the gate operation open across the `resolveHeldLifecycle` completion (begin a nested operation before ending the outer one), restoring the overlap invariant.

---

## Minor findings (4)

- **D5** — `BackgroundDownloadSession.swift:1208`: `reattach()`'s pending-promotion recovery does `F_FULLFSYNC` of a potentially multi-GB working file, rename, dir sync, and a synchronous `waitForPersistence` **on the URLSession callback queue** during the background-wake window — the commit that reworked activation deleted the comment warning against exactly this. Move it off-queue like the reset work.
- **D6** — `BackgroundDownloadSession.swift:214`: `truncationFailureCounts` (correctly rekeyed to ratingKey) is cleared only on `.complete`; `halt()` resets every sibling budget but omits it, so a delete + re-download of the same item inherits the old consecutive-truncation count and can park immediately.
- **D7** — `DownloadManager.swift:790`: startup pending-deletion completion failure (`resolveRowDeletion` ≠ `.removed`) is a silent guard-return — no diagnostic, no lastError, no retry; the row sits frozen until a manual Delete.
- **D8** — `DownloadManager.swift:3231`: the fail-open "server cleanup identity was unavailable" disclosure is erased moments later by the deletion success path's `lastError[ratingKey] = nil`, so the leaked server encoder is silent — the exact outcome the message was added to disclose.

---

## Refuted (1)

- "Revalidation/recovery re-registrations share a zero-revision deletion epoch" (DownloadManager) — traced and refuted; the aliasing cannot produce a wrong-epoch observation in practice.

## Suggested triage order

1. **D2** (data destruction + permanent row wedge on hard-kill during promotion — worst user outcome)
2. **D3** (process-wide loss of the background-completion durability barrier)
3. **D1** (callback-path wedge; also ENOSPC-adjacent so co-occurs with D2's trigger class)
4. **D4** (reopened off-head stall race)
5. D5–D8 as a batch (all small, mostly one-line-adjacent fixes)

All four majors are in the new artifact-lifecycle seams and share the established theme: a durable intent/entry can enter a failed-but-live state that nothing restarts, prunes, or barriers against. A cheap systematic sweep: for every place a lifecycle intent or coordinator entry can fail, verify something (a) restarts it, (b) abandons it, or (c) excludes it from waits.
