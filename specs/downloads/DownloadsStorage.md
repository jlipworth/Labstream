# DownloadsStorage: module notes (W6)

`DownloadsStorage.tla` models storage accounting for downloads: what each row holds on disk, the
storage cap, the free-space preflights, storage-full failure and the automatic-redrive gate, and
the storage audit. Run it with:

```sh
TLC_WORKERS=2 TLC_HEAP=2g scripts/check-tla-specs.sh specs/downloads/DownloadsStorage.tla
swift test --package-path PMSKit --no-parallel --filter DownloadsFormalModelStorageTests
```

## What is modelled

Bytes are small integers. A static-range row downloads `Size` one-byte segments, one at a time:
the daemon writes a segment to an OS temporary file, the app stashes it as a hidden held body,
and appending copies it onto the hidden working file before the held body is deleted (the copy
is the duplication peak). A forward-only row downloads one body of `Size` bytes and moves it to
the working path. Publication renames the working file. Lifecycle and history change only
through `Reduce`; each row keeps a whole reducer state, so there is no projection config.

| Actor | Actions |
| --- | --- |
| User | `Enqueue`, `UserRetry`, `UserPause`, `UserDelete` |
| Start | `CloneBegin`, `CloneCommit` (checkpoint handoff to a new attempt), `Start` (free-space preflight) |
| URLSession daemon | `DaemonWrites`, `DaemonOutOfSpace`, `DaemonFinishes` (run while the app is dead) |
| Session | `DidFinish`, `AppendHeld`, `HandleOutOfSpace`, `Finalize`, `SideAsset` |
| Recovery | `AutoRedrive` (`resumeStaticRangeWhenReady`), `Relaunch` (candidates, startup sweep, reconcile) |
| Environment | `ForeignGrows`, `ForeignShrinks` (other apps' bytes), `BackendFlips`, `Crash` |

Durable: the row, the working, held, side-asset, published and checkpoint-copy bytes, the
daemon's task and temporary body, other apps' bytes, and the backend session (environment).
In memory: `up`, the `lastError == .storageFull` latch, the pending-resume marker, the launch
candidates, and a start in flight. Five ghost variables record what a property needs and are
never read by a guard.

The policy operators are the Swift ones: `RequiredAdditional` is
`requiredAdditionalFreeBytes`; `Contribution`, `Usage`, `Projection` and `CapRejects` are
`CapRow.contribution`, `capUsage`, `capProjection` and `capRejection`. The PMSKit suite
`DownloadsFormalModelStorageTests` compares them with the Swift over the model's bounds.

Bounds of the default configs: two rows, `Size` 2, one side-asset byte, a disk of 6, up to 4
foreign bytes, a cap of 3 (or Unlimited), headroom 1 (or 0).

## Properties

| Property | Kind | Meaning |
| --- | --- | --- |
| `CountedOnce` | invariant | A row's cap contribution is what it holds plus its side assets, plus the remaining bytes of an active row of known size, and never more than the larger of its estimate and what it holds (B24). |
| `RetryCountedOnce` | invariant | A retry replaces its own row in the cap projection (B24). |
| `CapRefusalJustified` | invariant | The cap never refuses a start that fits (B24). |
| `CapHonoured` | invariant | The durable media of known-size rows stays inside the cap. The one slack is a body that finished while its row was paused (B24, second half). |
| `PreflightRefusalJustified` | invariant | A free-space preflight never refuses a start whose remaining work fits (B01, B23). |
| `UnknownStaysUnknown` | invariant | A row of unknown size reserves nothing, is never refused by the cap, and is charged only the peak, side assets and headroom. |
| `AuditCountsHiddenStaging` | invariant | The audit references every byte a row owns, hidden working and held files included (B19). |
| `AuditBalances` | invariant | Referenced plus unreferenced bytes are the directory, and the orphan candidates are exactly the checkpoint copies no running handoff owns. |
| `NoOrphanAfterStartup` | invariant | While the app runs, a checkpoint copy belongs to a handoff in progress (B86). |
| `ParkIsDurable` | invariant | A storage-parked row is durably `failed` with reason `storage` until something re-measures (B31). |
| `NoBlindRedrive` | invariant | No automatic redrive of a storage-parked row against a disk that still cannot hold it, unless the gate measured first (B31, sd-06). |
| `StorageFullClassified` | action | An ENOSPC completion fails the row with the storage reason (B26). |
| `StorageFailureKeepsCheckpoint` | action | A storage-full failure keeps a static row's durable checkpoint. |
| `PausedRowKeepsBytes` | action | A paused row keeps its bytes, and a body that finishes is added (issue 401). |
| `OrphansOnlyReclaimedAtStartup` | action | While the app runs, a checkpoint copy is removed only by its own handoff, a pause or Delete: the audit is report-only (issue 401). |

`TypeOK` includes `Used <= Disk`: no action writes past the volume.

## Configs (2026-11-24, tla2tools v1.7.4, `TLC_WORKERS=2 TLC_HEAP=2g`)

| Config | Expectation | Distinct states | Time |
| --- | --- | --- | --- |
| `Storage-Current-TwoStatic` (symmetry) | pass | 256,342 | 12 s |
| `Storage-Current-ParkHolds` (symmetry) | pass | 22,171 | 2 s |
| `Storage-Current-Mixed` | pass | 14,456 | 2 s |
| `Storage-Current-Unknown` | pass | 88,087 | 4 s |
| `Storage-Current-Unlimited` (symmetry) | pass | 43,234 | 3 s |
| `Storage-Proposed-S1-DurableParkGate` (symmetry) | pass | 60,204 | 4 s |
| `Storage-Faithful-B01-off` | `PreflightRefusalJustified` violated | first error | < 1 s |
| `Storage-Faithful-B24-off` | `RetryCountedOnce` violated | first error | < 1 s |
| `Storage-Faithful-B24R-off` | `CapHonoured` violated | first error | 1 s |
| `Storage-Faithful-B26-off` | `StorageFullClassified` violated | first error | < 1 s |
| `Storage-Faithful-B31-off` | `NoBlindRedrive` violated | first error | < 1 s |
| `Storage-Faithful-B19-off` | `AuditCountsHiddenStaging` violated | first error | < 1 s |
| `Storage-Faithful-B86-off` | `NoOrphanAfterStartup` violated | first error | < 1 s |
| `Storage-Finding-S1-RequeueErasesPark` | `NoBlindRedrive` violated | first error | < 1 s |
| `Storage-Deep-ThreeStatic` (deep tier, symmetry) | pass | DEEP_STATES | DEEP_TIME |

`Storage-Current-TwoStatic` lets the backend session come and go and checks every property
except the two finding S1 breaks (`ParkIsDurable`, `NoBlindRedrive`). The other `Current-*`
configs keep the backend session and check those two as well.

### Faithfulness

- **B01/B23 off.** A static row pauses with a checkpoint; on Resume the preflight charges the
  whole file again and refuses although the remaining byte fits.
- **B24 off (`FixB24`).** The projection for a retry adds the estimate on top of the row's own
  contribution.
- **B24 off, reservations (`FixB24R`).** A second download is admitted while the first is
  active and has reserved nothing; both finish and their media is larger than the cap.
- **B26 off.** A forward-only transfer hits ENOSPC and the row fails with a generic transfer
  reason.
- **B31 off.** A start is refused for free space, the refusal is remembered only in memory, the
  process dies, and the relaunch redrives the row against the same disk without measuring. The
  pre-fix code is approximated: the fix-off branch leaves the durable row untouched.
- **B19 off.** The audit does not reference a paused row's held body.
- **B86 off.** A hard kill during the checkpoint copy leaves a temporary that the startup sweep
  does not reclaim.

## Finding S1: an automatic requeue erases a storage-full park

Trace: a static-range transfer is running when the process dies; the disk fills; on relaunch the
row is a `launch_interrupted` candidate, and the body that finished is appended but the next
segment's preflight is refused, so the row is `failed(storage)` and the manager records
`lastError = .storageFull`. The automatic redrive for the candidate then runs while the backend
session is not ready. `resumeStaticRangeWhenReady` checks the backend before the storage gate,
so it calls `deferStaticRangeResume(preserveActiveIntent: true)`: the row is `requeued` to
`admitted`, which clears the durable storage reason, `lastError` is overwritten with an
"interrupted" message, and the pending-resume marker is set. When the session returns, the
drain calls the same function, the gate reads `lastError`, finds no storage failure, and
retries against the same full disk without measuring.

Why it is real: the gate's only memory is the in-memory `lastError`, written and overwritten in
the same function; the reducer's durable record for this (`storagePark`, set by
`transferInterrupted(.storage)`) is never produced because no app code submits that event (every
storage-full path submits `transferFailed(.storage)`). The durable reason that does exist,
`lastFailure == .storage`, is not read by the gate and is cleared by `requeued`.

What limits it: the blind redrive is not a storm. It mints an attempt, rebuilds the request, and
is refused again by the checkpoint-copy admission or the start preflight, which re-latches
`lastError`. Each further redrive needs another backend-return edge. While it waits the row shows
as queued with an "interrupted" caption instead of "Not enough free space", and as an admitted
row it reserves its remaining estimate in the cap.

Verdict: real, low severity. `Storage-Proposed-S1-DurableParkGate` shows one sufficient design:
the gate reads the durable storage failure and runs before the backend check.

Pin: `DownloadsFormalModelStorageTests.automaticRequeueKeepsTheStoragePark` (known issue). It
accepts either fix: the storage reason survives `requeued`, or the gate precedes the deferral in
the app source.

## Modelling artefacts fixed in the model

- `StorageFailureKeepsCheckpoint` first required the checkpoint to be unchanged. An append can
  land in the same step as the refusal of the next segment, so the property is "never shrinks".
- A first `CapHonoured` had no slack for a body that finishes while its row is paused. The code
  keeps that body on purpose (`writeThenPause`) and the cap does not count held bodies
  (`DownloadStorageSnapshot` reports them as unknown), so the property carries the ghost `late`.

## Not covered

- Several segments in flight and held-body manifests (W7); resume blobs; server preparation.
- Admission lanes and season planning (W1). Planned rows reserve nothing in the cap, by design
  ("not a new atomic reservation system").
- A free-space measurement that is unavailable (the code fails open), and the reservation
  between concurrent checkpoint copies (`reservedCheckpointCopyBytes`): the copy is one step here.
- Estimates that differ from the real size, and a cap the user changes mid-download.
- The cap does not gate side assets, and concurrent transfers do not reserve free space against
  each other; ENOSPC is the backstop. The model shows both and classifies the result.
- The `lastError` write after a session failure is asynchronous in the app (a main-actor hop).
  The model sets the latch in the same step, so it does not explore a redrive that runs in
  between.
- A cap refusal at start fails the row as `aborted`, not `storage`; its message lives only in
  `lastError`. Not treated as a finding.
- The drift header does not list `DownloadManager.swift` or `DownloadStore.swift`, although the
  redrive gate and `storageAudit`/`storageCapRows` live there: listing them would tie every
  change to those files to this spec.
