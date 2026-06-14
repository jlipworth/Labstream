# Custom Player Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Add an experimental, default-off AVPlayerLayer-backed fallback player with an app-owned natural scrubber, isolated on `playback/custom-player-fallback`.

**Architecture:** Keep `AVPlayerViewController` as default. Add a Settings toggle that routes video playback to a new SwiftUI custom player presenter backed by `AVPlayerLayer`, while reusing the existing `PlaybackController` for stream construction, proxy use, timeline, recovery, subtitles/audio state, and PMS lifecycle. Put the deterministic drag/commit scrubber math in PMSKit so it is unit-tested independently.

**Tech Stack:** SwiftUI, UIKit `UIViewRepresentable`, AVFoundation `AVPlayerLayer`, PMSKit Swift Package, Swift Testing.

---

### Task 1: Tested scrubber state model

**Files:**
- Create: `PMSKit/Sources/PMSKit/Playback/PlaybackScrubState.swift`
- Create: `PMSKit/Tests/PMSKitTests/PlaybackScrubStateTests.swift`

- [x] Write tests that prove drag updates are clamped, display follows draft while dragging, commit returns the requested target, and zero/unknown duration commits nil.
- [x] Run targeted PMSKit tests and confirm they fail because `PlaybackScrubState` is missing.
- [x] Add `PlaybackScrubState` with `beginDrag(livePositionMs:)`, `updateDrag(fraction:)`, `commit()`, `cancel()`, and `displayedPositionMs`.
- [x] Run the targeted PMSKit tests and confirm they pass.

### Task 2: Experimental routing setting

**Files:**
- Modify: `PlexAVPApp/UI/SettingsView.swift`
- Modify: `PlexAVPApp/UI/DetailView.swift`

- [x] Add `@AppStorage("experimentalCustomPlayerEnabled")` to Settings.
- [x] Add a default-off `Custom player fallback (experimental)` toggle in Playback settings.
- [x] Read the same key in `DetailView` and route video playback to `CustomPlayerView` only when enabled.
- [x] Keep local/offline playback on the system player for the first pass unless the same initializer can support it trivially.

### Task 3: AVPlayerLayer custom presenter

**Files:**
- Create: `PlexAVPApp/Player/CustomPlayerView.swift`
- Modify: `PlexAVPApp/Player/PlaybackController.swift`

- [x] Add `PlayerLayerView`, a `UIViewRepresentable` whose backing `UIView.layerClass` is `AVPlayerLayer`.
- [x] Add `CustomPlayerView` that builds a `PlaybackController`, starts/stops it with SwiftUI lifecycle, and renders video via `PlayerLayerView`.
- [x] Add natural bottom chrome: play/pause, current time, slider, duration, Close.
- [x] Add Retry/error and buffering/reconnecting states sufficient for the fallback test path.
- [x] Add `PlaybackController.performUserSeek(toMs:)` as the app-owned scrubber commit hook; it calls `player.seek` and logs the target.

### Task 4: Verification

**Files:**
- Whole worktree

- [x] Run PMSKit tests for the new scrubber state.
- [x] Run project hygiene script.
- [x] Build the visionOS app for simulator if available.
- [x] Run `git diff --check` and check for forbidden AI co-author trailers.
- [x] Commit the work without any Anthropic/Claude trailer.
