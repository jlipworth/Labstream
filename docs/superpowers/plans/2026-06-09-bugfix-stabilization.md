# Plex AVP Bugfix Stabilization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the high-signal repo-audit bugs without starting the Keystone overlay redesign.

**Architecture:** Stabilize state transitions at the app boundaries: auth discovery must produce either a browse-ready server token/base URL or visible unauthenticated/error state; downloads must only expose validated completed files and respect the selected media version; playback startup/retry must be cancellable and generation-guarded. Small PMSKit/request fixes should be covered by package tests; app-level behavior should use extracted pure helpers where feasible plus visionOS build verification.

**Tech Stack:** Swift 6, SwiftUI/Observation, AVKit/AVFoundation, URLSession background downloads, Xcode visionOS simulator, Swift Testing in PMSKit.

---

## File Structure

- `PlexAVPApp/App/AppModel.swift`: add selected server token/readiness fields.
- `PlexAVPApp/Auth/AuthManager.swift`: make restore/login discovery explicit, set selected server token, cancel PIN polling.
- `PlexAVPApp/Auth/KeychainStore.swift`: expose checked token persistence while keeping current simulator fallback behavior narrow.
- `PlexAVPApp/Networking/PlexClient.swift`: preserve cancellation errors.
- `PMSKit/Sources/PMSKit/Models/Library.swift`: lenient section decoding.
- `PMSKit/Sources/PMSKit/Auth/PinAuth.swift`: percent-encode auth fragment values.
- `PMSKit/Tests/PMSKitTests/*`: failing tests first for PMSKit behavior.
- `PlexAVPApp/Downloads/DownloadStore.swift`: expose only completed local URLs, persist resume offset, sanitize filenames.
- `PlexAVPApp/Downloads/DownloadManager.swift`: selected media indices, background handler race fix.
- `PlexAVPApp/UI/DetailView.swift`: use server token, thread media index into downloads, fix failed/download labels and offline playback guard.
- `PlexAVPApp/UI/DownloadOptionsSheet.swift`: accept/pass media index.
- `PlexAVPApp/UI/HomeView.swift`, `LibraryGridView.swift`, `SearchView.swift`, `RootView.swift`: use selected server token and visible no-server errors.
- `PlexAVPApp/Player/PlaybackController.swift`: tracked startup task/generation, current-resume retry, selected media diagnostics, interruption/background flags.
- `PlexAVPApp/Player/PlaybackDiagnostics.swift`: selected media index support.

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
- Modify: `PlexAVPApp/App/AppModel.swift`
- Modify: `PlexAVPApp/Auth/AuthManager.swift`
- Modify: `PlexAVPApp/Auth/KeychainStore.swift`
- Modify: `PlexAVPApp/UI/*.swift` authenticated call sites

- [ ] Add failing compile-time/use-site checks by changing call sites to prefer `appModel.serverToken` where PMS APIs are used.
- [ ] Implement `serverToken`, `isBrowseReady`, explicit restore discovery handling, and per-resource token selection.
- [ ] Add PIN poll task cancellation and current-pin guard.
- [ ] Build visionOS target to verify integration.

### Task 3: Downloads correctness pass

**Files:**
- Modify: `PlexAVPApp/Downloads/DownloadStore.swift`
- Modify: `PlexAVPApp/Downloads/DownloadManager.swift`
- Modify: `PlexAVPApp/UI/DetailView.swift`
- Modify: `PlexAVPApp/UI/DownloadOptionsSheet.swift`

- [ ] Add/adjust small pure helpers where possible so selected media index, completed-local-URL gating, failed-label behavior, and offline metadata resume can be verified by buildable code paths.
- [ ] Thread selected media/part index into download requests.
- [ ] Only return local URLs for `.complete` rows.
- [ ] Persist offline `viewOffset` and keep retry/remove available for `.failed` rows.
- [ ] Fix background session registry so late register services pending handlers.
- [ ] Build visionOS target.

### Task 4: Playback race/retry/diagnostics fixes

**Files:**
- Modify: `PlexAVPApp/Player/PlaybackController.swift`
- Modify: `PlexAVPApp/Player/PlaybackDiagnostics.swift`

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
