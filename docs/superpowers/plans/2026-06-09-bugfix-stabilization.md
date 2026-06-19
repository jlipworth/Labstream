# Plex AVP Bugfix Stabilization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the high-signal repo-audit bugs without starting the Keystone overlay redesign.

**Architecture:** Stabilize state transitions at the app boundaries: auth discovery must produce either a browse-ready server token/base URL or visible unauthenticated/error state; downloads must only expose validated completed files and respect the selected media version; playback startup/retry must be cancellable and generation-guarded. Small PMSKit/request fixes should be covered by package tests; app-level behavior should use extracted pure helpers where feasible plus visionOS build verification.

**Tech Stack:** Swift 6, SwiftUI/Observation, AVKit/AVFoundation, URLSession background downloads, Xcode visionOS simulator, Swift Testing in PMSKit.

---

## File Structure

- `VisionPlay/App/AppModel.swift`: add selected server token/readiness fields.
- `VisionPlay/Auth/AuthManager.swift`: make restore/login discovery explicit, set selected server token, cancel PIN polling.
- `VisionPlay/Auth/KeychainStore.swift`: expose checked token persistence while keeping current simulator fallback behavior narrow.
- `VisionPlay/Networking/PlexClient.swift`: preserve cancellation errors.
- `PMSKit/Sources/PMSKit/Models/Library.swift`: lenient section decoding.
- `PMSKit/Sources/PMSKit/Auth/PinAuth.swift`: percent-encode auth fragment values.
- `PMSKit/Tests/PMSKitTests/*`: failing tests first for PMSKit behavior.
- `VisionPlay/Downloads/DownloadStore.swift`: expose only completed local URLs, persist resume offset, sanitize filenames.
- `VisionPlay/Downloads/DownloadManager.swift`: selected media indices, background handler race fix.
- `VisionPlay/UI/DetailView.swift`: use server token, thread media index into downloads, fix failed/download labels and offline playback guard.
- `VisionPlay/UI/DownloadOptionsSheet.swift`: accept/pass media index.
- `VisionPlay/UI/HomeView.swift`, `LibraryGridView.swift`, `SearchView.swift`, `RootView.swift`: use selected server token and visible no-server errors.
- `VisionPlay/Player/PlaybackController.swift`: tracked startup task/generation, current-resume retry, selected media diagnostics, interruption/background flags.
- `VisionPlay/Player/PlaybackDiagnostics.swift`: selected media index support.

---

### Task 1: PMSKit low-risk test-first fixes

**Files:**
- Modify: `PMSKit/Sources/PMSKit/Models/Library.swift`
- Modify: `PMSKit/Sources/PMSKit/Auth/PinAuth.swift`
- Test: `PMSKit/Tests/PMSKitTests/LibraryDecodeTests.swift`
- Test: `PMSKit/Tests/PMSKitTests/PinAuthTests.swift`

- [ ] Write failing tests for empty `Directory` decoding and auth URL fragment escaping.
- [ ] Run targeted `swift test` from `PMSKit` and verify failure.
- [ ] Implement custom decode/default and fragment encoding.
- [ ] Re-run targeted and full `swift test`.

### Task 2: Auth/session readiness and selected server token

**Files:**
- Modify: `VisionPlay/App/AppModel.swift`
- Modify: `VisionPlay/Auth/AuthManager.swift`
- Modify: `VisionPlay/Auth/KeychainStore.swift`
- Modify: `VisionPlay/UI/*.swift` authenticated call sites

- [ ] Add failing compile-time/use-site checks by changing call sites to prefer `appModel.serverToken` where PMS APIs are used.
- [ ] Implement `serverToken`, `isBrowseReady`, explicit restore discovery handling, and per-resource token selection.
- [ ] Add PIN poll task cancellation and current-pin guard.
- [ ] Build visionOS target to verify integration.

### Task 3: Downloads correctness pass

**Files:**
- Modify: `VisionPlay/Downloads/DownloadStore.swift`
- Modify: `VisionPlay/Downloads/DownloadManager.swift`
- Modify: `VisionPlay/UI/DetailView.swift`
- Modify: `VisionPlay/UI/DownloadOptionsSheet.swift`

- [ ] Add/adjust small pure helpers where possible so selected media index, completed-local-URL gating, failed-label behavior, and offline metadata resume can be verified by buildable code paths.
- [ ] Thread selected media/part index into download requests.
- [ ] Only return local URLs for `.complete` rows.
- [ ] Persist offline `viewOffset` and keep retry/remove available for `.failed` rows.
- [ ] Fix background session registry so late register services pending handlers.
- [ ] Build visionOS target.

### Task 4: Playback race/retry/diagnostics fixes

**Files:**
- Modify: `VisionPlay/Player/PlaybackController.swift`
- Modify: `VisionPlay/Player/PlaybackDiagnostics.swift`

- [ ] Track and cancel playback startup/reload task with generation guard.
- [ ] Use current playhead for retry/auto-retry fallback.
- [ ] Split background pause resume state from audio interruption resume state.
- [ ] Feed selected media index into static diagnostics.
- [ ] Build visionOS target.

### Task 5: Final verification and issue mapping

**Files:**
- No required source edits.

- [ ] Run `swift test` in `PMSKit`.
- [ ] Run `xcodebuild`/XcodeBuildMCP visionOS simulator build.
- [ ] Run `git diff --check`.
- [ ] Summarize which existing GitHub issues are addressed and which new issues remain worth creating.
