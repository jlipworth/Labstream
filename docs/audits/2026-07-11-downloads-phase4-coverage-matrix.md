# Downloads audit Phase 4 — coverage-gap matrix (2026-07-11)

> **Status:** completed Phase-4 coverage snapshot at `23b0bac`. The G/A/D6/DEV labels below
> describe that baseline, not current aggregate coverage. Use
> [`docs/TESTING-STRATEGY.md`](../TESTING-STRATEGY.md) for current test lanes and
> [`docs/DOWNLOADS-OFFLINE.md`](../DOWNLOADS-OFFLINE.md) for current download invariants.

Baseline: `23b0bac` (`main` after the Phase 5 remediation and audit-document commit).
The baseline PMSKit run passed **1360 Swift Testing tests plus 89 XCTest tests**.

This matrix is deliberately seam-oriented rather than the impossible literal Cartesian product
of every dimension. A cell is covered only when a deterministic PMSKit test exercises the named
dimensions together. Tests of each policy in isolation do not make a composed cell green.

Legend: **G** = directly covered before Phase 4, **A** = added by Phase 4, **D6** = requires the
Phase 6 URLProtocol/delegate-ordering harness, **DEV** = device/background-session only, **N/A** =
the dimension does not reach that lane or policy.

## Route/lane/resume-mode matrix

`DownloadResumeMode.resolved` is the common policy seam. Each cell below covers all three lanes
(`original`, `optimize`, `compatibleRemux`); the edge column records the missing inputs which can
change the answer.

| Backend | original | optimize | compatible remux | Edge inputs | Status |
|---|---|---|---|---|---|
| Plex | static | prep→static only with target name | static | target `nil`, empty, non-empty; irrelevant Emby job | **A** |
| Jellyfin | static | live-forward | live-forward | target/job inputs must not override Jellyfin lane semantics | **A** |
| Emby | static unless job exists | live-forward unless job exists | live-forward unless job exists | Convert job `nil` vs non-`nil` overrides every lane | **A** |

Unknown `sourcePartSize` is not an input to `resolved`; it is covered at the expected-byte and
completion seam below. Whitespace-only Plex target names remain treated as present by production
policy; changing that is a routing/product decision, not a missing assertion.

## Static-range response/train matrix

| Response/lifecycle cell | Head | Mid | Tail | Relaunch / concurrency | Status |
|---|---:|---:|---:|---|---|
| 206, matching validator | G | G | G | task ownership/epoch guards G | **G** |
| 206, first validator | G | G | G | first arrival may be out of order G | **G** |
| 206, validator flip | G | G | G | actual delegate race | **G / D6** |
| 200 instead of 206 | G | A | A | sibling cancellation race | **A / D6** |
| 200 truncated vs declared Content-Length | G | A | A | actual temp/body mismatch | **A / D6** |
| 416 | G | A | A | restart vs queued append race | **A / D6** |
| 401/403 | G | A | A | auth refresh/base-URL change while suspended | **A / DEV** |
| slow start / timeout | request timeout policy G | request timeout policy G | request timeout policy G | CFNetwork scheduling | **G / DEV** |
| retry blob at head | G | N/A | N/A | persisted open remainder | **G** |
| retry blob on train segment | G in isolation | A composed | A composed | marker→reattach→blob adoption | **A** |
| stale/prior-attempt blob | G in isolation | A composed | A composed | attempt mismatch rejects before adoption | **A** |
| pause with held body | G | G | G | pause/apply interleave | **G / D6** |
| cancel/delete with held body | G (`cancel` halt) | G | G | delete/apply interleave | **G / D6** |

The new train-position tests assert the pure boundary: response classification is intentionally
position-independent, while 200 adoption still requires a whole plausible body. They do not claim
to cover URLSession delegate ordering; those cells remain explicitly dark for Phase 6.

## Forward-only and completion matrix

| Backend / condition | Original/static | Remux/live | Optimize/live | Status |
|---|---:|---:|---:|---|
| Plex completion exact bytes | G | N/A | server-prepared static G | **G** |
| Jellyfin/Emby source size present on transcode row | N/A | source size ignored A | source size ignored A | **A** |
| Content-Length absent/false; size estimate | N/A | estimator G | estimator G | **G** |
| stall→restart→stall→budget exhausted | N/A | G | G | **G** |
| keepalive while active | N/A | G | G | **G** |
| keepalive while queue-paused | N/A | manager scheduling, not a PMSKit input | same | **D6** |
| encoder ends at 80–95% duration | N/A | forward threshold G | forward threshold G | **G** |
| encoder has unknown duration | N/A | `.unverified` G | `.unverified` G | **G** |

The Phase 4 composition test feeds `DownloadExpectedBytesPolicy.staticRangeExpectedBytes` into
`DownloadCompletionValidation.outcome`; it proves a live-forward row cannot compare its downloaded
transcode bytes against the original `sourcePartSize`, while the same metadata on a static row is
still exact-byte gated.

## Persistence/migration matrix

| Payload | Healthy rows | Corrupt row isolation | Schema result | Status |
|---|---:|---:|---:|---|
| legacy bare array / pre-envelope | G | G | v1 | **G** |
| current v2 envelope | G | G | v2 | **G** |
| forward-version envelope | A | A | preserves future version | **A** |
| pre-D2 row (no status) | G | N/A | progress migration | **G** |
| pre-D5 row (no metadata/new optionals) | G | N/A | optional defaults | **G** |
| unreadable top-level JSON | empty result G | N/A | current version fallback | **G** |
| half-written but still valid outer array/object | healthy element recovery G | G | shape-derived | **G** |
| syntactically truncated top-level document | no recoverable boundary | no | current fallback | **G (fail closed)** |

## Remaining dark cells

1. **D6 delegate ordering:** validator flip, held-body pause preservation, pause and delete
   specifically during held-body drain, and reset→blob adoption→second reset are now live-covered
   by the Phase-6 harness. Delayed 200 replacement and 416 restart are
   now live-covered with a durable prefix plus held/queued sibling work; injected ENOSPC is also
   live-covered and terminally tears down the train without transient retry. The previously dark
   simulator delegate-ordering cells are therefore closed by real session evidence rather than
   pure-policy composition.
2. **DEV background lifecycle:** simulator process death with held stashes is now covered and
   confirms launch sweep/refetch rather than durable reuse. Still dark on a physical background
   session: OS completion redelivery, token rotation or LAN↔WAN change while suspended, and device
   disk pressure.
3. **Queue-pause keepalive scheduling:** the PMSKit keepalive policy has no queue-pause input; the
   manager task lifetime needs an orchestration harness or app-target test.
4. **Environment:** cellular/Wi-Fi transition, constrained network, and actual CFNetwork slow-start
   behavior are request/session integration cells, not pure model cells.

## Tests added from this matrix

- `DownloadsPhase4CompositionTests`: full backend × lane × resume-input table.
- `DownloadsPhase4CompositionTests`: retry budget × v2 marker × reattach × segment-blob adoption,
  including stale-attempt and stale-offset rejection.
- `DownloadsPhase4CompositionTests`: 206/200/416/401 across head/mid/tail train positions, plus
  whole-body and Content-Length gates for a mid-train 200.
- `DownloadsPhase4CompositionTests`: resume-mode expected-byte selection composed with completion
  validation, preventing transcode/source-size false incompleteness.
- `DownloadIndexCodingTests`: future-version envelope with one corrupt row.
