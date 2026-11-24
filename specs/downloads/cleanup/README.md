# DownloadsCleanup: Delete, the cleanup journal and a full volume

`DownloadsCleanup.tla` follows a Delete from the tap to the last reclaimed byte. It covers the
row-deletion barrier in the index, the artifact worker that unlinks files, the server-cleanup
intent journal and its runner, and a volume that can be completely full.

Run it with:

```sh
TLC_WORKERS=2 TLC_HEAP=2g scripts/check-tla-specs.sh specs/downloads/cleanup/DownloadsCleanup.tla
swift test --package-path PMSKit --no-parallel --filter DownloadsFormalModelCleanupTests
```

## What is modelled

| Part | Swift | In the model |
| --- | --- | --- |
| Delete | `DownloadManager.delete(record:)`, `finishDeletion`, `DownloadCleanupOrdering` | `UserFirstDelete`, `UserRetap`, `PrepJournal`, `PrepProof` |
| Deletion barrier | `DownloadStore.submitRemove`, `stageRowDeletionLocked`, `submitDeletionPending` | `StageDel`, the row's `queue` and `delPending` |
| Artifact worker | `executeRowDeletion`, `executeValidatedPromotion`, `failArtifactLifecycle`, `retireFailedHeadBeforeQueuedRowDeletion`, `recoverPendingArtifactIntents` | `Del*`, `Promo*`, `Retire*`, `AutoRetryHead`, `ExplicitRecover` |
| Index writer | `RevisionedPersistenceWriter`, `waitForPersistence` | `Commit`, `Durable(r)` |
| Legacy promotion | `recoverPendingValidatedPromotion` | `RecoverRename`, `RecoverCommit` |
| Journal and runner | `DownloadCleanupIntentJournal`, `DurableJournalCommit`, `DownloadCleanupIntentRunner`, `CleanupIntentEligibilityPolicy`, `executeCleanupIntent` | `jrnl`, `jSynced`, `MayRun`, `JournalTerminalRelease`, `RunnerCancel`, `RunnerClearRef`, `RunnerRetire` |
| Failure | process death, power loss, a full volume, a failing rename | `Crash`, `PowerLoss`, `Relaunch`, `FillDisk`, `FreeDisk`, `PromoIOFails` |

Durable state is the committed index (`dIdx`), the files, the volume, the journal and the server
job. In-memory state is the store's rows (`mIdx`), the worker and the manager's tasks. `Crash`
resets the in-memory state; `PowerLoss` also drops a journal entry that was visible but not
synced. A whole reducer state is kept per row, so there is no projection config. The reducer is
used for the promotion's terminal step, an abandoned promotion, the legacy recovery and Retry.

A run starts each row as one of six kinds: `complete`, `completeJob` (finished, still naming a
server job), `prep` (server prep with a job), `failedJob` (failed, keeping its job for Retry),
`finalizing` (a body waiting to be published) and `legacy` (an old build's
`pendingValidatedPromotionStatus`, with a working body, a stable body or neither).

## Bounds

- One or two rows. One attempt per row, at most two files and one server job per row.
- An artifact queue of at most two intents: a promotion and a row deletion.
- The volume is full or not. A full volume fails every index and journal commit; unlinking a file
  makes room.
- Safety runs leave the environment unbounded. Liveness runs allow four environment steps (a
  first Delete, a crash, a volume fill, an explicit recovery, a failed rename, a Retry).

## Properties

| Property | Kind | Meaning |
| --- | --- | --- |
| `NoOrphanFile` | invariant | Every file belongs to a row the committed index still holds. |
| `JobAccountable` | invariant | A running server job is owed to a durable row that names it or to a journal entry. This is "the journal commits first" for server cleanup (B18). |
| `JobKeptWhileNeeded` | invariant | A job is cancelled only when no durable, unfinished, non-deleting row needs it (B28, B44). |
| `DeletionIntentDurableBeforeUnlink` | invariant | The worker unlinks only when the committed index already marks the row for deletion. Broken today: finding Cleanup-C1. |
| `DurablePlayableHasBody` | invariant | What a relaunch would load: a playable row not marked for deletion has its body. Broken today by Cleanup-C1. |
| `DeleteReclaims` | liveness | A Delete the user keeps asking for ends with the row and its bytes gone. `DeleteNotWedgedBehindPromotion` (B27) and `DeleteReclaimsOnFullVolume` (B30) are the same formula under the issue names. |
| `DeletedRowJobCancelled` | liveness | A deleted row's server job is eventually cancelled. |

Fairness covers the app's own steps, the relaunch and the user tapping Delete again. Crashes, a
full volume, a failing rename and explicit recovery are never forced.

## Configs

All at `TLC_WORKERS=2 TLC_HEAP=2g`.

| Config | Expect | Distinct states | Time |
| --- | --- | --- | --- |
| `Current-OneRow` | pass | 2,548 | 1 s |
| `Current-TwoRows` (symmetry) | pass | 1,426,644 | 44 to 78 s |
| `Liveness-OneRow` | pass | 1,451 | 2 s |
| `Faithful-B18-off` | violation `JobAccountable` | 75 | 1 s |
| `Faithful-B28-off` | violation `JobKeptWhileNeeded` | 3 | 1 s |
| `Faithful-B44-off` | violation `JobKeptWhileNeeded` | 40 | 1 s |
| `Mutant-B27-PreemptWithoutFence` | violation `NoOrphanFile` | 79 | 1 s |
| `Finding-C1-UnlinkBeforeDurableIntent` | violation `DeletionIntentDurableBeforeUnlink` | 37 | 1 s |
| `Finding-B27-LegacyPromotionWedgesDelete` | violation (liveness) | 19 | 2 s |
| `Finding-B30-FullVolumeDelete` | violation (liveness) | 373 | 1 s |
| `Proposed-Safety` | pass | 942 | 1 s |
| `Proposed-Liveness` | pass | 2,586 | 2 s |

The two liveness findings declare `EXPECT: violation TEMPORAL`: `check-tla-specs.sh` reports a
violated liveness property only as `TEMPORAL`, so each of those configs checks one property.

The `Current` and `Liveness` configs leave out the two invariants that Cleanup-C1 breaks.
`Proposed-Safety` checks them with the proposed fix on.

## Faithfulness

| Config | Fixed bug | What the run shows |
| --- | --- | --- |
| `Faithful-B18-off` | B18 | The journal reports a visible, unsynced entry as committed. The row is deleted, a power loss drops the entry, and the server job has no owner. |
| `Faithful-B28-off` | B28 | Delete cancels the server job at once, before the row is durably marked for deletion. |
| `Faithful-B44-off` | B44 | A terminal release runs against a failed row and cancels the Convert job it keeps for Retry. |
| `Mutant-B27-PreemptWithoutFence` | injected | See B27 below. |

## Findings

### Cleanup-C1: a recovered row deletion unlinks before its intent is durable (new)

Issue: #479.

1. The volume is full. The user deletes a finished row.
2. The row-deletion intent is queued in memory. Its index commit fails, so the worker fails the
   head and drops its ticket.
3. Another download resumes a range request (or a background-completion flush runs). Both call
   `currentArtifactLifecycleWatermark`, which runs an explicit recovery for every row.
4. Recovery finds the queued deletion without a ticket and registers one with
   `preparedRevision` 0.
5. `executeRowDeletion` waits for revision 0, which returns at once, and unlinks the files. The
   index on disk still holds a finished row with no deletion intent.
6. A kill before the terminal commit, or a terminal commit that fails, leaves a row on disk that
   claims a body that is gone. After relaunch the user sees a failed download they had deleted.

Severity is low to medium: the user asked for the delete, so no wanted data is lost, but the
write-ahead rule the worker documents is broken and the row comes back as a failure. The
held-body and promotion workers are not affected: each waits for a revision it submitted itself.
Pinned by `rowDeletionUnlinksOnlyAfterDurableIntent`.

For a row with no server job, this path is also the only way Delete reclaims space on a full
volume today. Fixing C1 alone removes it, so C1 and B30 should be fixed together.

### B27 (#392): a legacy validated promotion wedges Delete (known, open)

1. An old build left `pendingValidatedPromotionStatus` on a row, and both bodies are gone.
2. Launch recovery returns `.sourceMissing` and leaves the flag.
3. `submitRemove` and `submitDeletionPending` refuse a row with the flag as stale. Every Delete
   tap does nothing, and Retry is refused too.

Pinned by `deleteIsNotRefusedByLegacyPromotion`. The proposed fix lets Delete proceed over the
flag. `Mutant-B27-PreemptWithoutFence` shows that this alone is unsafe when a body
exists: the launch recovery renames the working body over the stable path after the worker
unlinked that path, and the file outlives its row. The fix needs a fence: Delete waits while the
recovery is in flight, and the recovery skips a row with a staged deletion
(`FixB27Fence`).

### B30 (#393): Delete on a completely full volume reclaims nothing (known, open)

1. The volume is full. The user deletes a row to make room.
2. For a row with no server job, the deletion intent cannot be committed, and the worker returns
   before any unlink. For a row with a server job, the deletion-pending reservation cannot be
   committed, and the manager reports "Deletion could not be saved".
3. Tapping Delete again repeats the same steps. No byte is freed unless something else frees
   space, or the C1 path happens to run.

Pinned by `deleteOnFullVolumeReclaims`. The proposed fix (`FixB30`) is reserved capacity that
Delete's own index and journal writes may use. With it, and with C1 and B27 fixed,
`Proposed-Liveness` shows Delete always completes on a volume that is never freed from
outside.

## Modelling artefacts fixed in the model

- Relaunch first re-drove a deletion-pending capsule only when no row deletion was queued. The
  code re-drives every capsule from its captured intents, beside an already queued deletion, and
  the model now does the same (`Relaunch`, the stale branch of `PrepProof`). No counterexample
  depended on it.

## Not covered

- Retry-by-replacement (a second attempt on the same key) and two rows naming one path. The
  cross-row exclusion and `reservedArtifactDeletionPaths` in `executeRowDeletion` are not
  exercised, and neither is the rule that a new attempt is refused while a deletion is pending.
- Writers that could create a file after the deletion recipe was captured. The model assumes the
  barrier fences them.
- Abandonment intents, the ownership recheck against other rows (`claimingRecords`), encoders,
  Plex optimize retention and expiry, backoff and the runner's two-worker limit.
- Legacy tombstone migration, quarantine import and journal repair.
- Held-body deletion, resume-blob and static-checkpoint intents.
- A failing unlink, a failing directory sync and commit timeouts. Only a full volume fails a
  commit.
- The schema probe (`.unknown` row state) and an unreadable journal.
