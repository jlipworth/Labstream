# Download backlog memory and append writes

Investigation of [#394](https://github.com/jlipworth/Labstream/issues/394),
[#390](https://github.com/jlipworth/Labstream/issues/390), and
[#391](https://github.com/jlipworth/Labstream/issues/391), against local base
`e2e4c3b810eafba24f0b95fa7b68e26d9264ee64`. All three complete issue bodies and
comment lists were retrieved on 2026-10-22; none had comments. Their claims are
hypotheses, not implementation instructions. No production behavior changes here.

The immediate candidate is a two-result window covering fetch through promotion
for chapters and Jellyfin tiles. A global memory limit and a different media-file
layout require more evidence. Exit criteria: confirm the window under production
cancellation/slow-I/O seams, then measure actual device footprint and write counters
before choosing a wider redesign.

## Source ownership and scaling

Read alongside the canonical [Downloads guide](../DOWNLOADS-OFFLINE.md),
[architecture](../ARCHITECTURE.md#downloads-and-offline-ownership),
[performance guidance](../COMPILE-PERFORMANCE.md),
[overhaul plan](../plans/2026-10-16-downloads-overhaul.md), and
[B83/B85 evidence](../evidence/2026-10-17-downloads-overhaul-bugs-vs-main.md).
Current admission differs from historical plan shorthand: total transfers default
to three (configurable one–five), static cap is `max(1, total - 1)`, live-forward
cap one, and five server preparations do not count toward transfer total.

- `DownloadManager+SideCache.cacheChapterImages` and
  `DownloadManager+Jellyfin.cacheJellyfinTrickPlay`: one task-group child per
  missing image/tile; each returns a tuple containing `Data`. The parent consumes
  results and awaits prepare/promote serially. Finished results retain payloads
  while the parent waits. Pending request arrays and task/continuation metadata
  also scale with item count. Tile playlist data/text and publication maps remain
  separately retained. Text subtitles already fetch/prepare/promote sequentially;
  poster and BIF are individual jobs, potentially concurrent across rows/kinds.
- `SideAssetFetchCoordinator.fetch/schedule/complete`: per-origin one start per
  second and two active network requests; fair owner selection and exact-request
  coalescing. `complete` reduces active count and resumes `Data` continuations,
  then schedules again. The slot ends at transport completion, before preparation.
  The network cap does not bound completed results, cross-origin work, or payload
  size. An existing-file fast path also reads `Data` without network admission.
- `DownloadSideAssetService.prepare`: detached image/BIF/text validation and
  atomic staging write retain input `Data`. Image decode and parser allocations
  are additional costs. `prepareSideAsset` holds a staging path lease and checks
  attempt/source; `promoteSideAsset` uses bounded store work and store fences.
  A timeout is not proof that the physical worker released its bytes or lease.
  Metadata publication is batched after files, avoiding an index snapshot per tile.
- `DownloadWorkRegistry`: one parent registration per exact attempt and kind,
  coalescing duplicate starts. Its count is not the group's child count, retained
  bytes, or detached physical-worker count. Pause can preserve hydration while
  parking coordinator owners; delete/retry cancellation is attempt-scoped.
- `BackgroundDownloadSession.urlSession(_:downloadTask:didFinishDownloadingTo:)`,
  `finishRangeRemainder`, `applyFinishedRangeBody`, and `drainHeldRangeSegments`:
  delivered URLSession bodies are **files**, claimed/moved before delegate return;
  queued closures retain URLs, entries, and response metadata, not a whole-media
  `Data`. One serial `rangeIOQueue` drains bodies; held out-of-order bodies have
  manifests and validators. Relaunch/inherited work can exceed new-start caps.
  Known totals use 512 MiB segments at depth two per row; inherited tasks are
  not retroactively bounded by fresh admission. File bytes grow with backlog;
  resident memory need not grow by those file bytes, but temporary append
  allocations can (see the autorelease controls below).
- `appendFile`: `FileHandle` reads/writes up to 4 MiB at a time. Runtime allocation
  overhead and overlapping loop-buffer lifetimes are not an exact 4 MiB RSS ceiling.
  Normal append copies only the newly delivered body into the existing partial,
  then the source is retired. Whole-file replacement and opaque completion can move bodies instead; the
  extra append pass applies to normal range assembly. Ordinary checkpoints record/observe length and
  persist state; they do not repeatedly copy the entire growing prefix.
- `DownloadStore.executeStaticCheckpoint`, checkpoint handoff, and
  `DownloadStaticCheckpointFilesystem.durableCopy`: reconstruction/ownership
  handoff can copy an existing prefix using `copyItem`, file `F_FULLFSYNC`, rename,
  and directory fsync. This is distinct from ordinary per-segment checkpointing.
  Retry/handoff frequency can add prefix-copy cost; APFS may implement file copy
  differently from the explicit append loop.
- Admission counts transfer lanes, not bytes; path leases exclude writers, not
  memory consumers. Storage admission counts remaining transfer bytes, held-body
  credit, largest append peak, future side assets and headroom. Checkpoint-copy
  reservations cover concurrent copy capacity. These are disk-space protections,
  not process-memory accounting. Wake deadlines bound waiting, not cumulative
  writes or physical worker lifetime. No global retained-payload byte gate exists.
  Pending resume artifacts can also
  retain `Data` in `DownloadStore.pendingResumeArtifactData`; index snapshots,
  row metadata and request closures are additional O(backlog) state. These are
  not whole-media buffers and were not measured by the synthetic worker.
  `RevisionedPersistenceWriter` coalesces obsolete pending snapshots; snapshot
  size still scales with records, not with media-file bytes.

## Reproduction and bounds

The committed standalone Swift worker and Python driver live in `scripts/research/`.
They run actual Swift structured tasks, `Data`, atomic file writes, rename, and the
same 4 MiB `FileHandle` loop shape. The file case stores a URL array, not production
session tasks/closures. They **model** ownership; they do not execute production
fetch, decoding, store, URLSession daemon, or checkpoint durability.
No image codec validity claim is made for the synthetic byte payloads.

```sh
mkdir -p build/download-backlog-research
python3 scripts/xcodebuild-lease.py run --lane download-research --wait-timeout 300 -- \
  xcrun swiftc -O -parse-as-library scripts/research/download-backlog-worker.swift \
  -o build/download-backlog-research/worker
# Run each command under the same shared lease policy used for compilation.
python3 scripts/xcodebuild-lease.py run --lane download-research --wait-timeout 900 -- \
  python3 scripts/research/download-backlog-measure.py \
  --worker build/download-backlog-research/worker --suite assets --repetitions 3 \
  > build/download-backlog-research/assets.jsonl
python3 scripts/xcodebuild-lease.py run --lane download-research --wait-timeout 900 -- \
  python3 scripts/research/download-backlog-measure.py \
  --worker build/download-backlog-research/worker --suite files --repetitions 1 \
  > build/download-backlog-research/files.jsonl
python3 scripts/xcodebuild-lease.py run --lane download-research --wait-timeout 900 -- \
  python3 scripts/research/download-backlog-measure.py \
  --worker build/download-backlog-research/worker --suite large-file --repetitions 3 \
  > build/download-backlog-research/large-file.jsonl
```

Each case is a fresh process. Order reverses on alternate repetitions. The eager
case submits every child; the candidate submits two, consumes/prepares/promotes
one result serially, then refills. Network starts are modeled at 1 ms intervals
(1,000× accelerated single-origin pacing), with instantaneous completion, versus
0 or 12 ms artificial prepare delay. Delay represents suspension behind slow
work, not a calibrated disk speed. Neither case raises production network limits.

File controls compare an unpooled long async scope, explicit per-body pools,
explicit per-chunk pools, and one serial `DispatchQueue` work item per body (approximating individual production completion work items). A separate single 128 MiB body case tests whether
memory scales with body size despite fixed read size.

Caps: 128 assets, 1 MiB each; static 32 bodies of 8 MiB or one 128 MiB body, at most 256 MiB pending and
512 MiB source/destination/copy storage; 20 ms maximum configured delay, 30-second
per-case watchdog, three repetitions maximum per suite, 1 GiB free-space preflight. The listed
commands submit approximately 12.4 GiB of logical file writes/copy requests in
total; copies may be clones, and peak retained temporary storage stays at 512 MiB. The
Python owner removes only its own unique temporary directory even on worker
failure/timeout. Direct worker invocation also uses its own UUID directory, but
an external hard kill can skip Swift defers; use the driver for measurements.
No network, app container, privileged setting, simulator, or shared-temp sweep.

Counters distinguish unfinished children, produced/unconsumed group results,
and live payload bytes through deinitialization (including current preparation).
Window cases can retain one completed result while the parent prepares another.
`getrusage.ru_maxrss` is measured process peak RSS on Darwin, not peak
`phys_footprint`, heap allocation, or daemon memory. Baseline RSS is already a
high-water mark. `st_blocks * 512` reports allocated file blocks, not physical
bytes written. Per-call logical byte counters exclude filesystem metadata,
index journals, retries, protection attributes, and device writeback effects.

## Measurements

Measured on arm64 macOS 27.0.1, Apple Swift 6.4, optimized standalone worker. RSS
numbers below are absolute peaks, not baseline-subtracted footprint. Asset results
are medians of three fresh processes; file stage controls are exploratory single
runs per cell. They are not a release benchmark or a physical-device result.

- **256 KiB images, normal preparation:** increasing 8 to 128 images raised
  eager peak payloads from 0.5 to 1.75 MiB. The window remained
  0.5 MiB. The eager group's unfinished child count reached 8/128, versus two.
- **256 KiB images, 12 ms preparation:** at 8 images eager/window peaks were
  2/0.5 MiB; at 128 they were 29.75/0.5 MiB. The larger eager queue held 118
  unconsumed results at peak (29.5 MiB), versus one during delayed windowed
  preparation. Absolute RSS was about 38.0/9.5 MiB. Elapsed times were similar
  (2.18/2.21 seconds), not a throughput improvement claim.
- **1 MiB images, 128 requests, 12 ms preparation:** eager/window peak owned
  payloads were 120/2 MiB, absolute RSS about 128.7/11.8 MiB. A count window
  bounds these fixed-size payloads; it cannot enforce a fixed byte budget for
  arbitrarily sized responses.
- **File backlog and an important harness correction:** with 4/32 bodies of
  8 MiB, fixture creation peaked near 7.5 MiB RSS. Running every append in one
  long async scope reached 40.6/265.8 MiB after append. `copyItem` added little
  further peak. Explicit per-body autorelease pools instead reached roughly
  16.5/16.8 MiB; one serial-dispatch work item per body reached 16.7/17.1 MiB;
  per-chunk pools reached 12.5/12.8 MiB. Values include both normal and delayed
  append controls. Thus the original unpooled loop alone would misleadingly
  suggest all file bytes must live in RAM. The measured difference is consistent
  with Foundation temporary objects surviving until an autorelease boundary.
- **Single 128 MiB body, three repetitions:** no pool, a pool around the body,
  and one serial-dispatch body each reached about 137 MiB RSS. A pool around each
  4 MiB read/write iteration reached 12.5 MiB. Fixture generation stayed near
  7.4 MiB and copy added only about 0.02 MiB to the high-water mark. Thus bounded
  read size did not imply bounded resident memory even in the dispatch control;
  body size matters. Extrapolation to the shipped 512 MiB segments is a risk
  hypothesis, not a measured device footprint.

The dispatch control is not proof of a production ceiling: `applyFinishedRangeBody`
appends the head then calls `drainHeldRangeSegments`, whose loop can append several
held bodies inside the **same** queue work item. A large body and a contiguous
held run can therefore outlive individual 4 MiB buffers. An explicit chunk-level
pool is a much narrower candidate to test than a global memory/zero-copy redesign;
a pool only around each whole body did not solve the large-body control.
The harness does not execute the production queue itself, so actual app/OS
allocation stacks and device footprint remain unmeasured.

For 4/32 × 8 MiB, the worker issued exactly 32/256 MiB of fixture writes plus
32/256 MiB of append writes. That is **2× logical media bytes including the
synthetic initial download write, or 1× additional app append writes**. Ordinary
checkpoint counts were 4/32; they did not copy the prefix. The isolated handoff
copy requested another 32/256 MiB. Allocated blocks were around the file length
(with allocation variation), and do not reveal whether `copyItem` cloned extents.
No physical disk-write or flash-wear factor is measured. Retry bytes, repeated
handoffs, metadata journals, finalization fixups and writeback can change lifetime
cost; historical MetricKit exceptions cannot attribute it to this loop alone.

## Decision and remaining validation

1. **Smallest next production change: #394.** Refill a shared small window only
   after prepare/promote settles for both eager image groups. Preserve serial
   publication and existing per-origin coordinator pacing. This removes the
   backlog-proportional completed-`Data` queue without changing media layout.
   Merely wrapping all eager children in a network semaphore would retain O(N)
   tasks; merely limiting fetch lifetime repeats the current bug. A window still
   leaves O(N) request metadata, and is not a global byte ceiling.
2. **#390: test chunk-scoped temporary release, then global accounting.** The
   read size alone did not bound measured RSS in the unpooled harness. First
   instrument the real append/held-drain worker and compare an explicit per-chunk
   autorelease pool using large bodies under the existing lease/currency fences.
   The native synthetic result makes this a concrete memory-risk candidate, not
   evidence that a global byte gate would fix temporary retention inside a worker.
   This test does not require a file-layout change. Count aggregate
   retained side-asset bytes, active decode/prepare workers, unfinished children,
   queued result bytes, pending/held media-file bytes and inherited task count
   separately. Fresh admission cannot revoke inherited bodies. A shared byte gate
   may be needed across rows/origins and oversized BIF/tile responses; an item
   window alone cannot bound variable payload sizes or all consumers. With R
   independent row/kind windows of W slots and maximum payload S, the payload
   component is at best R × W × S, before decodes; R and S need their own bounds. Reserve
   before materializing a response (or stream to a bounded file); acquiring after
   `data(for:)` is too late. Coalesced `Data` must not be charged once per waiter
   unless it actually copies. Do not discard irreplaceable delivered media bodies
   just to satisfy a heap counter. These measurements do not establish a safe
   device memory threshold or justify a global media-body heap redesign.
3. **#391: retain append architecture pending device write evidence.** The
   baseline has a real extra media-sized logical append pass, but no quadratic
   ordinary-prefix copy. Candidate cheap experiments are first-body adoption when
   the partial is empty, then filesystem-aware copy/handoff measurement. Both
   need ownership/durability work; rename alone is not a safe drop-in replacement.
   Extent/scatter layouts affect validators, contiguous playback/finalization,
   resumability, garbage collection and capacity accounting. Do not undertake
   that redesign solely from historical MetricKit disk-write exceptions.

Safety gates for the next change: cancellation before dispatch and after every
suspension; exact attempt, source, train epoch and control-generation checks;
permit release on all error/timeout branches without releasing a still-running
physical worker's ownership; no duplicate writers; stale staging cleanup only
under its own attempt; durable checkpoint/held-manifest ordering before source
retirement; foreground/background wake expiry must fence refill, not erase
recovery authority. Keep copy-peak reservations, held-body accounting and low-space
behavior. Test cancellation while queued/fetching/preparing/promoting, pause/resume,
source replacement, failed promotion, expired wake, and multiple rows/origins.
The fixture-cleanup work in #411 is intentionally untouched.

Use existing path/worker fault seams (`holdRangeIOForTesting`,
`appendWillPerformIO`, store filesystem hooks and side-cache tests) for bounded
production integration tests. Device follow-up must use actual background
URLSession relaunch with small and larger inherited sets, normal and delayed
assembly, representative images/BIF, and a foreground-to-background wake. Capture
Instruments allocations/VM or process footprint, URLSession daemon separately,
and app/disk write counters with before/after workload boundaries. Existing
`PerformanceInstrumentation` signposts/PerformanceAudit tooling can frame runs;
MetricKit reports provide delayed context, not per-workload attribution. Reconcile
logical writes with filesystem/writeback counters and durability checkpoints;
report APFS/cache/flash effects separately. No physical-device, energy, background
scheduler, jetsam, or production throughput claim is established here.

## Validation and local handoff

The worker was compiled with `-O` under the shared host lease and all reported
cases completed with byte-count, payload-bound and owned-directory cleanup checks.
No production app was built or launched and no simulator lease was used. Source
and output hashes, toolchain, issue snapshots and raw aggregate results are kept
under ignored `build/download-backlog-research/`; workflow receipts live at
`build/workflow/state.json`. Full documentation/repository hygiene is recorded in
`build/download-backlog-research/hygiene.log`. These local artifacts are not
committed; the report contains only scrubbed aggregate observations.
