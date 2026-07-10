# Downloads Engine Fault-Injection Harness (Phase 6)

Phase 6 now has a smallest-real transport harness: a DEBUG-only `URLProtocol` drives the
foreground `URLSession` owned by the real `BackgroundDownloadSession`. It does not model or call
the range policies directly. Real download tasks, delegate ordering, temp-file stashing, durable
append, validator restart, and request-rehydration callbacks remain in the exercised path.

There is no Labstream app unit-test target in `Labstream.xcodeproj`; the only unit-test target is
the PMSKit Swift package, which cannot construct the app-internal session/store types. Therefore
these are executable simulator probes, not claimed automated unit coverage. The injectable
`protocolClasses` initializer seam exists for a future app test target and deliberately selects an
in-process foreground session (custom URL protocols do not run in the device background daemon).

## Driver

Use a signed-in Plex simulator and select a static-download item larger than one 512 MiB segment.
To find one without guessing at titles or repeatedly creating server optimize jobs, run the
opt-in headless candidate probe first:

```sh
scripts/live-phase6-download-candidate-probe.sh
```

It uses the gitignored `scripts/plex-live.env`, scans only technical metadata, runs the production
direct-play decision, and prints eligible rating keys plus media/part indexes and byte buckets.
It never prints the server address, token, media title, or file path. Optional bounds are
`PLEX_LIVE_PHASE6_SCAN_LIMIT`, `PLEX_LIVE_PHASE6_DECISION_LIMIT`, and
`PLEX_LIVE_PHASE6_MIN_BYTES`.

The existing connection-drop contract remains the default:

```sh
scripts/probe-plex-range-drop.sh --rating-key KEY --delete-after
```

The first two priority Phase 6 scripts are:

```sh
scripts/probe-plex-range-drop.sh --rating-key KEY --fault validator-flip --delete-after
scripts/probe-plex-range-drop.sh --rating-key KEY --fault 401-mid-train --delete-after
scripts/probe-plex-range-drop.sh --rating-key KEY --fault held-body-pause \
  --pause-resume --pause-after-seconds 2 --delete-after
scripts/probe-plex-range-drop.sh --rating-key KEY --fault double-connection-drop \
  --drop-after-bytes 2097152 --delete-after
scripts/probe-plex-range-drop.sh --rating-key KEY --fault held-body-delete \
  --delete-during-transfer
scripts/probe-plex-range-drop.sh --rating-key KEY --fault write-failure --delete-after
```

The script builds/installs the DEBUG app, launches the existing Plex download probe, captures
Downloads/DownloadProbe unified logs, and exits nonzero unless both the requested injected fault
and its engine reaction appear. `--query TEXT` may replace `--rating-key KEY`; all prior range-drop
options remain supported.

## Deterministic scenarios and pass criteria

### `validator-flip`

The protocol assigns synthetic ETag v1 to the first zero-offset body and v2 to every other body,
then deliberately finishes each mutated response after 64 KiB. Validator integrity is checked by
the real engine before body-length/alignment handling, so this reaches the delegate→stash→apply
path without downloading eight real 512 MiB segments. Assignment happens when each protocol load
starts, so completion order cannot erase the flip:
if an ahead segment pins v2 first, the delayed v1 body conflicts; if offset zero pins v1 first, the
first ahead body conflicts. A restarted zero-offset request receives v2, modeling a resource that
stabilized after changing.

Required diagnostics:

- `downloads.fault_injected` with scenario `validator-flip`
- `downloads.range_validator_changed`

The engine must supersede the old train/restart from the durable safety boundary; the probe fails
if it only proves the transport mutation without reaching the changed-resource path.

### `401-mid-train`

The protocol synthesizes exactly one HTTP 401 for the first positive-offset segment it sees and
proxies every other request normally. This makes the fault bounded while still entering through a
real closed-range task in the active train.

Required diagnostics:

- `downloads.fault_injected` with scenario `401-mid-train`
- `downloads.range_http_rehydrate`

The bad response body must not append. The engine resets displayed progress to the durable
checkpoint, enters request-rebuild grace, and asks `DownloadManager` for a fresh authenticated
request. The probe fails if the 401 does not reach that rehydration path.

### `held-body-pause`

Positive-offset segments are finished after 64 KiB while the head segment remains live. This
forces real out-of-order delegate finishes into `heldRangeSegments`; the driver then pauses and
resumes the row. It fails unless a held body precedes a confirmed paused state, no held-stash purge
occurs between those events, and the probe reaches the retry/resume path. Final deletion may purge
the test stashes and is intentionally outside that preservation assertion.

### `double-connection-drop`

Only the logical head segment is eligible for this fault (bounded by the original segment-end
offset), preventing concurrent sibling failures from producing a false positive. The protocol
drops that segment twice at the configured body threshold. The driver requires strict diagnostic
ordering: first injected fault → persisted blob resume → second injected fault → second persisted
blob resume. This exercises composed resume-data adoption and its retry budget through the real
URLSession delegate path.

### `held-body-delete`

This uses the same bounded positive-offset finishes as `held-body-pause`, but deletes the row while
the head segment is still live. The driver requires held-body creation → cancel-time held-stash
purge → confirmed row removal ordering, distinguishing destructive cancellation from
pause-preservation behavior.

### `write-failure`

The head response finishes after 64 KiB and the DEBUG seam throws the real Cocoa
`fileWriteOutOfSpace` error at `appendFile`. The body still travels through URLSession,
delegate delivery, stash move, and the range IO queue. The driver requires terminal
`downloads.move_failed reason=storage_full stage=append` and rejects any transient
`downloads.range_move_retry`.

## Phase 6 coverage status

- [x] Validator flip during a live segment train.
- [x] 401 on a positive-offset segment with authenticated request rehydration.
- [x] Pause with multiple held out-of-order bodies; held stashes survive the pause.
- [x] Delete with multiple held bodies; cancel purges stashes before row removal.
- [x] Reset → persisted resume-blob adoption → second reset → second blob adoption.
- [ ] Pause/delete specifically while `drainHeldRangeSegments` is appending.
- [ ] Concurrent 200 replacement or 416 restart with queued append work.
- [ ] Relaunch with on-disk held stashes.
- [x] Injected append failure / ENOSPC classification and terminal train teardown.

The unchecked lifecycle/filesystem cells need control beyond a simple response mutation and should
not be simulated by bypassing the real session.

## Live execution evidence (2026-07-11)

The candidate probe found 19 eligible original/static parts larger than 600 MiB. A 1–10 GB
H.264/AAC MP4 alternate was used without recording its title or file path. All six bounded
scenarios passed against the real foreground `BackgroundDownloadSession`:

- `validator-flip`: synthetic v1/v2 responses produced
  `downloads.range_train_superseded reason=changed_resource_restart` followed by
  `downloads.range_validator_changed`.
- `401-mid-train`: the positive-offset 401 produced `downloads.range_http_rehydrate`, request
  rebuild grace, and an authenticated backend retry; no 401 body was appended.
- `held-body-pause`: nine positive-offset bodies reached `downloads.range_segment_held` before
  `probe.plex_download.paused reached=true`; no held-stash purge occurred across the pause, the
  retry/resume path ran, and final probe deletion then purged the test stashes.
- `double-connection-drop`: the head segment produced strict
  fault attempt 1 → `downloads.range_blob_resume attempt=1` → fault attempt 2 →
  `downloads.range_blob_resume attempt=2` ordering, proving two composed resume-data adoptions on
  the same logical segment rather than two concurrent sibling failures.
- `held-body-delete`: eight held bodies were present before delete; cancellation emitted
  `downloads.range_held_segments_purged purged_count=8` before
  `probe.plex_download.deleted_during_transfer row_missing=true`.
- `write-failure`: injected Cocoa code 640 at append produced
  `downloads.move_failed reason=storage_full stage=append`, terminally superseded seven sibling
  tasks, transitioned the row to failed, and emitted no transient range-move retry.

The first live attempt also exposed a harness bug: `probeRange` used `data(for:)`, so a server that
ignored or delayed a bounded Range could buffer a multi-gigabyte response before the actual test
started. It now uses `URLSession.bytes(for:)` and drops the sequence after response headers; the
live check returned 206 with `Content-Range: bytes 0-1023/TOTAL` and a 1024-byte content length.
