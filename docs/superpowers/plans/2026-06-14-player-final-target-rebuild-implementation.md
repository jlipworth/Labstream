# Player Final-Target Rebuild Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Replace the failed Stage-3 proxy-owned segment seek recovery with a direct, server-safe final-target player rebuild model.

**Architecture:** PlaybackController returns to owning PMS decision/start URL resolution and loads direct PMS HLS URLs into AVKit. Deep seek recovery is an intentional player-item rebuild at the final target; proxy segment interception and re-prime behavior are removed from the active path. Rebuild work is generation-fenced and one-shot, so rapid inputs collapse to the last requested offset and failures surface instead of retrying silently.

**Tech Stack:** Swift 6.2, visionOS AVFoundation/SwiftUI app, PMSKit SwiftPM package, XCTest/Swift Testing, XcodeBuildMCP simulator build.

---

### Task 1: Remove failed Stage-3 active code and dirty artifacts

**Files:**
- Modify: `PMSKit/Sources/PMSKit/MediaSession/MediaSessionProxy.swift`
- Delete: `PMSKit/Sources/PMSKit/MediaSession/SegmentTimeline.swift`
- Modify: `PMSKit/Tests/PMSKitTests/MediaSessionProxyTests.swift`
- Delete: `docs/superpowers/plans/2026-06-14-issue33-stage3-proxy-owned-playlist.md`
- Delete: `docs/superpowers/reviews/2026-06-14-issue33-stage3-proxy-review.md`

- [x] Save a temporary patch of current dirty Stage-3 work: `git diff > /tmp/visionplay-stage3-dirty.patch`.
- [x] Restore modified Stage-3 files to the last committed state with `git restore PMSKit/Sources/PMSKit/MediaSession/MediaSessionProxy.swift PMSKit/Tests/PMSKitTests/MediaSessionProxyTests.swift`.
- [x] Remove untracked Stage-3 artifacts with `rm -f PMSKit/Sources/PMSKit/MediaSession/SegmentTimeline.swift docs/superpowers/plans/2026-06-14-issue33-stage3-proxy-owned-playlist.md docs/superpowers/reviews/2026-06-14-issue33-stage3-proxy-review.md`.
- [x] Verify no active code references `SegmentTimeline`, `serveSegment`, `segmentReprime`, or `segmentClientStability` with `rg 'SegmentTimeline|serveSegment|segmentReprime|segmentClientStability' PMSKit/Sources PMSKit/Tests`.

### Task 2: Restore direct PMS stream URL loading in PlaybackController

**Files:**
- Modify: `PlexAVPApp/Player/PlaybackController.swift`

- [x] Write or reuse a test seam if possible; otherwise use existing PMSKit request tests and app build as the verification boundary because `PlaybackController` is not currently unit-testable.
- [x] Remove the `MediaSessionProxy` property and `mediaProxyGeneration` from `PlaybackController`.
- [x] Remove `teardownMediaProxy()` calls from `stop()` and stale open cancellation paths.
- [x] In `startStreaming(resumeOffsetMsOverride:stopPrevious:generation:)`, build `TranscodeRequest` directly, run the same direct-play probe/decision logic in the controller, and set `assetURL` to the resolved PMS `start.m3u8` URL.
- [x] Keep `stopPreviousTranscode` bounded at 2s and only run it for explicit rebuild/retry/reload paths.
- [x] Keep Stats-for-Nerds decision data by applying the decision object returned from the direct decision/probe logic.
- [x] Build with XcodeBuildMCP to verify `PlaybackController` compiles.

### Task 3: Add explicit final-target rebuild API and latest-wins safety

**Files:**
- Modify: `PlexAVPApp/Player/PlaybackController.swift`

- [x] Add a small generation-fenced rebuild entry point such as `rebuildAtFinalSeekTarget(seconds:)` that calls existing `restart(resumeOffsetMsOverride:stopPrevious:)` with the final offset.
- [x] Ensure a new final-target rebuild cancels any older `playbackTask` through existing `playbackGeneration` mechanics.
- [x] Ensure `surfaceFailure` cancels pending work and does not trigger hidden retry loops.
- [x] Confirm `didAutoRetry` does not silently restart indefinitely; remove auto-retry if it conflicts with one-shot visible Retry.

### Task 4: Keep PMSKit proxy minimal or remove from active app path

**Files:**
- Modify or keep: `PMSKit/Sources/PMSKit/MediaSession/*`
- Modify: `PMSKit/Tests/PMSKitTests/MediaSessionProxyTests.swift`

- [x] If the app no longer references `MediaSessionProxy`, keep PMSKit proxy tests only for package-level historical coverage or delete them if they depend on Stage-2/Stage-3 seek behavior.
- [x] Remove tests that assert proxy-owned seek/re-prime behavior.
- [x] Keep forwarding/socket tests only if they still compile and are isolated from app playback.
- [x] Run `cd PMSKit && swift test --filter MediaSessionProxyTests`.

### Task 5: Update docs and checklists

**Files:**
- Modify: `TESTING-CHECKLIST.md`
- Modify: `docs/DEVELOPMENT.md`
- Modify: `docs/superpowers/specs/2026-06-14-player-final-target-rebuild-design.md` only if implementation decisions differ from the approved spec.

- [x] Mark Stage-3 proxy-owned seek as abandoned/removed.
- [x] Add manual gates for direct final-target rebuild: normal playback, small scrub, deep single scrub reload, double-drag final-target reload, repeated PMS failures surface overlay, close during rebuild.
- [x] Remove claims that the proxy owns seek recovery.

### Task 6: Full verification

**Files:** all changed files.

- [x] Run `cd PMSKit && swift test`.
- [x] Run `./scripts/ci-hygiene.sh && git diff --check`.
- [x] Run XcodeBuildMCP `build_sim` with `CODE_SIGNING_ALLOWED=NO`.
- [x] Inspect `git status --short` and ensure only intentional files remain changed.
