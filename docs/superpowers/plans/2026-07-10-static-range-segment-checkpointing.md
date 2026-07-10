# Static-Range Segment Checkpointing Contingency Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bound the bytes a visionOS wake-time network bounce can destroy to one segment (~512 MB) instead of the whole file, without per-segment background wakeups.

**Architecture:** Keep the #227/#231 single-session static-range architecture (resume-data first, durable-partial Range fallback), but replace the single open-ended `Range: bytes=N-` remainder with a **pre-queued train of closed-range segment tasks** that nsurlsessiond executes without app involvement. Completed segment bodies are appended in contiguous order whenever the app is next serviced; the durable checkpoint therefore advances continuously off-head. A wake-time silent retry (the failure mode resume data can never see, observed 2026-07-09 ~21:44Z as `reset_body_bytes: 1173`) restarts only the segment that was mid-flight.

**Tech Stack:** Swift, URLSession background session, PMSKit pure policies + swift-testing, app-side wiring in `Labstream/Downloads/BackgroundDownloadSession.swift`.

## Global Constraints

- Never regress `X-Plex-Client-Profile-Name=Generic` (unrelated but repo-wide rule).
- New Swift files are auto-picked-up (file-system-synchronized groups) — do NOT edit the pbxproj.
- All new decision logic goes in PMSKit as pure, IO-free policies with swift-testing tests (existing pattern: `StaticRange*Policy`).
- The background-relaunch rate limiter is real: NOTHING in this design may require an app wakeup to keep bytes flowing. Transfers must proceed with the process dead.
- Every rebuild-request site that sets `.queued` + fires `onRangeRequestNeeded` MUST call `beginRangeRequestRebuildGrace(ratingKey:)` first (#212).
- Preserve the live-counter reset guard from `26e322d` (`max(callback, countOfBytesReceived)`).
- **Commit visibility:** every Path A commit message starts with `range-segments:` so the
  series is greppable/bisectable as a unit. Order: pure PMSKit policies first (no behavior
  change), then app wiring, then the regime flip — reverting the design later means
  reverting the tail commits, never untangling policies.
- **Per-platform kill switch:** the open-ended lane is NOT deleted. A compile-time
  `StaticRangeTransferRegime` constant (Task A4 Step 0) selects `.segmentTrain` (default,
  all platforms) or `.openEndedRemainder` (today's shipping behavior). Bifurcating
  non-visionOS back is a one-line, one-commit change. Regime switches are safe across
  launches because both regimes restart from the durable-partial checkpoint.
- Close out with the standard sim smoke test AND `scripts/deploy-to-device.sh` + a `scripts/headset-evidence.sh` pull after an off-head/on-head cycle.

---

## Decision gate — run this BEFORE executing any path

Pull the morning bundle and diff against the baseline
(`build/headset-evidence/baseline-20260710-postdeploy/headset-evidence-20260709T214710Z`):

```sh
scripts/headset-evidence.sh --device "$VP_DEVICE_ID" \
  --out build/headset-evidence/morning-20260710
```

Compare, per the baseline analysis script pattern (jq/python over
`app-container-files/Library/Application Support/Labstream/Diagnostics/app-diagnostics.jsonl`
and `.../Downloads/index.json`):

| Signal | Healthy | Poor |
|---|---|---|
| Rows that were `bytes: 0, downloading` at baseline (13 of them) | non-zero durable bytes or `complete` | still 0 |
| New `downloads.range_counter_reset_rebuild` events after `2026-07-09T21:47Z` | 0–1, `reset_body_bytes` close to `previous_body_bytes` (replay-shaped; the 26e322d guard should have eaten these) | several with tiny `reset_body_bytes` (~1 KB = genuine wake restarts) |
| `downloads.range_remainder_appended` count | rising | flat |

- **Healthy** → no action; keep observing. The 26e322d guard was enough.
- **Poor with tiny-reset events** → execute **Path A** (segments). This is the expected outcome and the recommended path.
- **Poor AND Path A judged too risky right now** (e.g. need a working build today) → execute **Path B** (revert recipe) as a stopgap, then Path A later.
- **Path C** is a small independent hardening that can ship with either.

---

## Path A — pre-queued closed segments (recommended re-implementation)

Design constants (tune later, start here): `segmentBytes = 512 * 1024 * 1024`,
`maxQueuedSegments = 8` (≈4 GB of unattended runway per file).

Key idea per component:

- **PMSKit `StaticRangeSegmentQueuePolicy` (new):** pure planner. Given durable bytes,
  expected total, and the segment offsets already live in the session, emit the closed
  ranges to enqueue (up to depth). Unknown `expectedBytes` → emit today's single
  open-ended remainder (fallback = current behavior, zero regression).
- **PMSKit `StaticRangeSegmentAssemblyPolicy` (new):** pure assembler. Given durable
  size and stashed finished bodies `[(offset, length)]`, return which stashes to append
  now (contiguous run) and which to hold (out-of-order).
- **Task marker:** deliberate segments set
  `task.taskDescription = "lbs-segment:v1:<offset>"`. `StaticRangeReattachPolicy` adopts
  closed-range tasks bearing the marker; unmarked closed ranges keep today's
  `.dropLegacyRange` disposition (#231 safety stays intact).
- **Session wiring:** enqueue the train at start/refill points; on
  `didFinishDownloadingTo`, stash then run the assembly policy (append run, refill
  queue); the existing counter-reset / stale-progress / supersede guards operate
  per-segment unchanged.

### Task A1: closed-range header + segment queue policy

**Files:**
- Create: `PMSKit/Sources/PMSKit/Downloads/StaticRangeSegmentQueuePolicy.swift`
- Modify: `PMSKit/Sources/PMSKit/Downloads/StaticRangeRemainderRequestPolicy.swift` (add closed-header builder next to `rangeHeaderValue(offset:)`)
- Test: `PMSKit/Tests/PMSKitTests/StaticRangeSegmentQueuePolicyTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `StaticRangeRemainderRequestPolicy.rangeHeaderValue(offset: Int, length: Int) -> String` → `"bytes=O-(O+length-1)"`.
  - `struct StaticRangeSegmentPlan: Equatable, Sendable { public let offset: Int; public let length: Int?; public var rangeHeaderValue: String }` (`length == nil` → open-ended fallback).
  - `StaticRangeSegmentQueuePolicy.segmentsToEnqueue(durableBytes: Int, expectedBytes: Int?, liveSegmentOffsets: Set<Int>, segmentBytes: Int, maxQueuedSegments: Int) -> [StaticRangeSegmentPlan]`

- [ ] **Step 1: Write failing tests** covering: fresh file (durable 0, expected 3 GB → 6 plans of 512 MB starting at 0); partial train alive (offsets 0/512 MB live → plans start at 1 GB, depth topped to max); tail shorter than a segment (last plan length = remainder); `expectedBytes == nil` → exactly one plan, `length == nil`, header `"bytes=D-"`; durable ≥ expected → empty.

```swift
@Test func plansFreshFileTrain() {
    let plans = StaticRangeSegmentQueuePolicy.segmentsToEnqueue(
        durableBytes: 0, expectedBytes: 3 * 512 * MB, liveSegmentOffsets: [],
        segmentBytes: 512 * MB, maxQueuedSegments: 8)
    #expect(plans.count == 3)
    #expect(plans[0].rangeHeaderValue == "bytes=0-\(512 * MB - 1)")
}
@Test func unknownTotalFallsBackToOpenEnded() {
    let plans = StaticRangeSegmentQueuePolicy.segmentsToEnqueue(
        durableBytes: 700, expectedBytes: nil, liveSegmentOffsets: [],
        segmentBytes: 512 * MB, maxQueuedSegments: 8)
    #expect(plans == [StaticRangeSegmentPlan(offset: 700, length: nil)])
    #expect(plans[0].rangeHeaderValue == "bytes=700-")
}
```

- [ ] **Step 2:** `cd PMSKit && swift test --filter StaticRangeSegmentQueuePolicy` → FAIL (type not found).
- [ ] **Step 3:** Implement the policy (pure arithmetic; no Foundation networking). Resurrect the bounded-header arithmetic from the deleted planner rather than rederiving it: `git show d463667^:PMSKit/Sources/PMSKit/Downloads/RangeChunkPlanner.swift` (`boundedRangeHeaderValue`/`segmentPlan`) and its tests from `git show d463667^:PMSKit/Tests/PMSKitTests/RangeChunkPlannerTests.swift` — adapt the math, do not copy the legacy `RangeTransferSegmentKind` classification.
- [ ] **Step 4:** `swift test --filter StaticRangeSegmentQueuePolicy` → PASS; full `swift test` → PASS.
- [ ] **Step 5:** Commit: `range-segments: add segment queue policy`.

### Task A2: out-of-order assembly policy

**Files:**
- Create: `PMSKit/Sources/PMSKit/Downloads/StaticRangeSegmentAssemblyPolicy.swift`
- Test: `PMSKit/Tests/PMSKitTests/StaticRangeSegmentAssemblyPolicyTests.swift`

**Interfaces:**
- Produces: `StaticRangeSegmentAssemblyPolicy.appendableRun(durableBytes: Int, stashedSegments: [(offset: Int, length: Int)]) -> (append: [(offset: Int, length: Int)], hold: [(offset: Int, length: Int)], discard: [(offset: Int, length: Int)])` — `append` is the maximal contiguous run starting exactly at `durableBytes`, in order; `hold` is future segments beyond a gap; `discard` is anything fully behind the checkpoint (`offset + length <= durableBytes`) or overlapping-but-not-aligned (mis-aligned appends must never be attempted — same invariant as today's `durable_checkpoint_ahead` guard).

- [ ] **Step 1: Write failing tests:** in-order run appends; gap holds the later segment; segment fully behind durable discards; overlap-not-aligned discards; empty input → all empty.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** `swift test` → PASS. **Step 5:** Commit: `range-segments: add segment assembly policy`.

### Task A3: reattach adopts marked segment tasks

**Files:**
- Modify: `PMSKit/Sources/PMSKit/Downloads/StaticRangeReattachPolicy.swift` (plan input gains `taskMarker: String?`; a `.closed` shape with a valid `lbs-segment:v1:` marker whose offset matches the header no longer returns `.dropLegacyRange`)
- Modify: `PMSKit/Sources/PMSKit/Downloads/StaticRangeRemainderRequestPolicy.swift` or new small type: `StaticRangeSegmentMarker.parse(_ taskDescription: String?) -> Int?` / `.value(offset: Int) -> String`
- Test: `PMSKit/Tests/PMSKitTests/StaticRangeReattachPolicyTests.swift` (extend), new `StaticRangeSegmentMarkerTests.swift`

**Interfaces:**
- Consumes: `StaticRangeReattachPolicy.plan(taskIdentifier:downloadID:durableBytes:requestedOffset:rangeRequestShape:bodyBytesWritten:existingTasks:)` (existing — add `taskMarker:` parameter with default `nil` so existing call sites/tests compile).
- Produces: marked closed segments reattach via the existing `.adopt`/`.suppressForExisting`/`.replaceExisting` machinery; **multiple simultaneous marked segments for one downloadID must coexist** — the duplicate-remainder supersede rules apply only between tasks claiming the SAME offset.

- [ ] **Step 1:** Failing tests: unmarked closed → still `.dropLegacyRange`; marked closed with matching offset → adopted; two marked segments, different offsets → both adopted; two marked segments, same offset → newer adopted, older superseded.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement (touch the offset-mismatch rule: a marked segment's `requestedOffset` may legitimately be `> durableBytes` — earlier segments still in flight — so the `rejectOffsetMismatch` guard must exempt marked segments whose offset is durable-aligned to the segment grid: `offset % segmentBytes == 0 && offset >= durableBytes`). **Step 4:** `swift test` → PASS. **Step 5:** Commit: `range-segments: adopt marked segment tasks on reattach`.

### Task A4: session wiring — enqueue train, stash-and-assemble, refill

**Files:**
- Create: `Labstream/Downloads/StaticRangeTransferRegime.swift` — the compile-time kill switch:

```swift
/// Which static-range transfer regime this platform runs. `.segmentTrain` is the
/// pre-queued closed-segment design; `.openEndedRemainder` is the pre-segment shipping
/// behavior (single `Range: bytes=N-` task). Flip a platform back with a one-line edit —
/// both regimes recover from the durable-partial checkpoint, so switching across
/// launches is safe.
enum StaticRangeTransferRegime {
    case segmentTrain
    case openEndedRemainder

    static var current: StaticRangeTransferRegime {
        #if os(visionOS)
        return .segmentTrain
        #else
        return .segmentTrain   // flip to .openEndedRemainder to bifurcate non-visionOS
        #endif
    }
}
```

- Modify: `Labstream/Downloads/BackgroundDownloadSession.swift`
  - `startRangeRemainder(...)` (line ~863): plan via `StaticRangeSegmentQueuePolicy` **when `StaticRangeTransferRegime.current == .segmentTrain`**; under `.openEndedRemainder`, force the single open-ended plan `[StaticRangeSegmentPlan(offset: durableBytes, length: nil)]` — the same shape the planner already emits for unknown `expectedBytes`, so ALL downstream wiring (marker, stash, assembly, refill) is shared and the open-ended regime is exercised by the same code path, not a divergent fork. Create one task per plan, set `taskDescription` marker, register each in `rangeInflight` with `baseOffset = plan.offset`.
  - `didFinishDownloadingTo` range branch (~1691): after the existing stash move, name the stash by offset, run `StaticRangeSegmentAssemblyPolicy.appendableRun`, append the run via the existing append path, delete `discard` stashes, keep `hold` stashes on disk, then **refill** the train (same planner) while the app is alive.
  - `reattach` (~465): pass `task.taskDescription` into the reattach policy; count adopted segments per key.
  - Counter-reset / stale-progress guards: no change needed — they are already per-task; verify `durableBytes > rangeEntry.baseOffset` early-cancel does not fire for later segments (it must compare against the SEGMENT's own extent, not global durable — change guard to `durableBytes > rangeEntry.baseOffset + (rangeEntry.segmentLength ?? Int.max)` equivalent; add optional `segmentLength` to `RangeTransfer`).
- Test: PMSKit policies already pinned; app-side is exercised by smoke + device evidence.

- [ ] **Step 0:** Create `StaticRangeTransferRegime.swift` (code above; new files are auto-picked-up — do not touch the pbxproj). Build.
- [ ] **Step 1:** Add `segmentLength: Int?` to `RangeTransfer` + marker set/read. Build.
- [ ] **Step 2:** Wire planner into `startRangeRemainder` + refill on append. Build.
- [ ] **Step 3:** Wire assembly into the finished-body path (stash naming: reuse `rangeBodyStashURL(taskIdentifier:)` but ALSO record offset in filename, e.g. `-o<offset>`, and teach `BackgroundTempFileCleanupPolicy.shouldDeleteRangeBodyStash` the new suffix — held stashes owned by a finished task must survive the orphan sweep until appended). Update its tests in PMSKit.
- [ ] **Step 4:** Full sim smoke test (CLAUDE.md block) — start a large Plex download in the sim, kill + relaunch the app mid-train, confirm adoption diagnostics (`downloads.range_duplicate_remainder_*` absent, adopted count > 1) and progress climbing.
- [ ] **Step 5:** Commit: `range-segments: queue closed segment train for static downloads` (this is the regime-flip commit — the one to revert if the design must come out wholesale).

### Task A5: progress aggregation across live segments

**Files:**
- Modify: `PMSKit/Sources/PMSKit/Downloads/DownloadLiveRangeProgressPolicy.swift` + tests: live display bytes = durable + Σ(live segment bodies), monotonic under the existing resume-display watermark merge.
- Modify: `Labstream/Downloads/BackgroundDownloadSession.swift` `didWriteData` range branch: publish `displayTotal` as durable + sum over `rangeInflight` entries for the key (all segments), not `baseOffset + body` of the callback task alone.

- [ ] **Step 1:** Failing PMSKit test for the multi-segment sum + watermark merge. **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** `swift test` PASS + sim smoke: display never exceeds expected total, never goes backwards during segment completion. **Step 5:** Commit: `range-segments: aggregate live progress across segment train`.

### Task A6: close-out

- [ ] Full `swift test` + visionOS sim smoke + **iPhone sim build** (`LabstreamMobile`) — segments run on all platforms; iPad/iPhone must stay green.
- [ ] `scripts/deploy-to-device.sh`, then user does one off-head/on-head cycle; pull `scripts/headset-evidence.sh` and verify: `range_counter_reset_rebuild` events (if any) show `previous_body_bytes ≤ segmentBytes`, and durable bytes in `index.json` ≈ live totals.
- [ ] Update `docs/DOWNLOADS-OFFLINE.md` + `docs/DEVELOPMENT.md` (verified platform finding: visionOS wake silently restarts custom-Range bodies; resume data cannot see it; segments bound the loss).
- [ ] Comment on #227/#231 with the empirical result (scrub identifiers; issues are public).

---

## Path B — revert recipe (stopgap only)

**History facts (verified 2026-07-10 by reading the diffs):** the architecture flip was a
three-commit sequence on 2026-07-09 — `31c8a2c` 15:07 ("Simplify static download resume
lifecycle") switched NEW work from the hybrid (foreground `.boundedCheckpoint` 64 MB
chunks chained in-process + off-head promotion to one `.continuousRemainder`, from
e47db12/#169) to open-ended in ALL scene phases; `d463667` 15:33 removed legacy
closed-range adoption; `8f4a364` 16:02 pruned the abstractions. Reverting only
d463667/8f4a364 would restore compat shims, NOT chunking — **the revert target must
include `31c8a2c`.**

What this path restores: the pre-2026-07-09 hybrid — durable checkpoints every 64 MB
while on-head (0% resets impossible past the first chunk), off-head still one open-ended
remainder, so a wake bounce still forfeits everything transferred off-head (unbounded
overnight; that weakness predates today and is why Path A exists). The old
`backgroundCheckpoint` off-head chunking stays dead — it was abandoned because each
chunk wakeup feeds the OS relaunch rate limiter (#212).

- [ ] **Step 1:** Branch: `git checkout -b revert-static-range-flip`.
- [ ] **Step 2:** Revert in reverse order, resolving conflicts at each step:
  `git revert --no-commit a49c151 && git revert --no-commit 8f4a364 && git revert --no-commit d463667 && git revert --no-commit 31c8a2c`
  Conflict hotspots (all touched later on 2026-07-09): `BackgroundDownloadSession.swift` (9c7617f watermark, eb00e79 counter reset, 982a9fa grace, 26e322d live-counter guard), `DownloadManager.swift` (3fb9eb6 foreground recovery), `DownloadStore.swift` (watermark accessors), `DownloadLiveRangeProgressPolicy.swift` + tests.
- [ ] **Step 3:** Conflict policy — keep BOTH: the restored `RangeChunkPlanner`/checkpoint-adoption code AND tonight's four fixes. The counter-reset block (with grace + live-counter guard) and the foreground recovery sweep are orthogonal to chunking and must survive the revert.
- [ ] **Step 4:** `cd PMSKit && swift test` (the reverted `RangeChunkPlannerTests` return) → PASS.
- [ ] **Step 5:** Sim smoke + `LabstreamMobile` build → green. Commit revert; deploy to device.
- [ ] **Step 6:** Leave #231 open with a note that the removal is parked pending Path A.

---

## Path C — checkpoint-on-doff (small, complementary, optional)

Bounds ON-HEAD progress loss for the current architecture: when the scene goes
**inactive** (headset coming off, process still briefly alive), for each `.downloading`
static-range row call `cancel(byProducingResumeData:)` on the live remainder and
immediately resubmit via the existing blob-resume path (`downloads.range_pause_resume_data`
→ `downloads.range_blob_resume`, both proven working in tonight's logs). The blob
persists the temp bytes; the resubmitted task continues off-head. A wake bounce still
restarts the resubmitted task's body, but everything up to the doff moment is preserved.

- Files: `Labstream/Downloads/DownloadManager.swift` (`noteAppScenePhase` gains an
  `"inactive"` branch, visionOS-gated `#if os(visionOS)`), reusing the pause/blob-resume
  path end to end; debounce so rapid active/inactive flapping can't thrash (reuse the
  `foregroundStaticRangeRecoveryInFlight` coalescing pattern).
- Test: sim smoke + device evidence (blob events at doff in diagnostics).
- Risk: low — it composes existing proven paths; but it does add a cancel/restart cycle
  per doff, so ship it AFTER confirming morning logs still show losses with 26e322d.
