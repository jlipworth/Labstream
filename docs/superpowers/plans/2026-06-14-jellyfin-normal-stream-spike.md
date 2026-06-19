# Jellyfin Normal Stream Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first Jellyfin path for #35: prepare a Jellyfin stream through official PlaybackInfo, resolve the returned normal stream URL, and load it through the existing AVPlayer-based player without making the player itself Jellyfin-aware.

**Architecture:** Add a small Jellyfin request/model layer in PMSKit with tests first. Add a Jellyfin playback resolver that mirrors reference clients: authenticate/header shape, POST PlaybackInfo, prefer returned TranscodingUrl, otherwise build a static `/Videos/{id}/stream` URL. Wire a default-off, debug/manual app path that can exercise one Jellyfin item without touching the hot #33 Plex proxy files beyond the narrow PlayerView/PlaybackController seam needed to load a resolved URL.

**Tech Stack:** Swift 6.2, PMSKit SwiftPM tests, Foundation URLSession, AVFoundation/AVKit existing player, SwiftUI Settings experimental fields.

---

## File Structure

- `PMSKit/Sources/PMSKit/Jellyfin/JellyfinAuth.swift`: MediaBrowser auth header and login request builders.
- `PMSKit/Sources/PMSKit/Jellyfin/JellyfinPlayback.swift`: PlaybackInfo request/response models and stream URL resolver.
- `PMSKit/Tests/PMSKitTests/JellyfinAuthTests.swift`: auth header/login request tests.
- `PMSKit/Tests/PMSKitTests/JellyfinPlaybackTests.swift`: PlaybackInfo JSON/body, TranscodingUrl resolution, direct/static fallback tests.
- `VisionPlay/Player/PlaybackController.swift`: add a URL-streaming initializer that loads a pre-resolved URL while keeping local/offline and Plex paths unchanged.
- `VisionPlay/Player/PlayerView.swift`: add an initializer for resolved remote stream URLs.
- `VisionPlay/UI/SettingsView.swift`: add default-off/manual Jellyfin test-stream fields and a button to open a typed item id when credentials are present.

## Task 1: PMSKit Jellyfin auth/request builders

**Files:**
- Create: `PMSKit/Sources/PMSKit/Jellyfin/JellyfinAuth.swift`
- Create: `PMSKit/Tests/PMSKitTests/JellyfinAuthTests.swift`

- [ ] Write failing tests for `Authorization: MediaBrowser Client="...", Device="...", DeviceId="...", Version="...", Token="..."` and `POST /Users/AuthenticateByName` body.
- [ ] Run `swift test --package-path PMSKit --filter JellyfinAuthTests` and verify failure because the symbols do not exist.
- [ ] Implement minimal auth/header and login builder.
- [ ] Re-run focused tests and verify pass.

## Task 2: PMSKit Jellyfin normal stream resolver

**Files:**
- Create: `PMSKit/Sources/PMSKit/Jellyfin/JellyfinPlayback.swift`
- Create: `PMSKit/Tests/PMSKitTests/JellyfinPlaybackTests.swift`

- [ ] Write failing tests for PlaybackInfo request body and headers.
- [ ] Write failing tests resolving server-relative `TranscodingUrl` into an absolute playable URL.
- [ ] Write failing tests for direct/static fallback `/Videos/{id}/stream` using selected `MediaSourceInfo.Id`, `Static=true`, `PlaySessionId`, tag, and auth token query.
- [ ] Run focused tests and verify failure.
- [ ] Implement minimal models/builders/resolver.
- [ ] Re-run focused tests and verify pass.

## Task 3: Player seam for already-resolved remote URLs

**Files:**
- Modify: `VisionPlay/Player/PlaybackController.swift`
- Modify: `VisionPlay/Player/PlayerView.swift`

- [ ] Add a remote-URL initializer that accepts a pre-resolved stream URL and optional HTTP headers.
- [ ] Keep timeline/proxy/stop behavior disabled for this spike path until Jellyfin session reporting is wired.
- [ ] Load the URL through existing AVPlayer observer path so player UI/error handling remains shared.

## Task 4: Default-off manual Jellyfin test stream path

**Files:**
- Modify: `VisionPlay/UI/SettingsView.swift`

- [ ] Add `@AppStorage` fields for experimental Jellyfin base URL/token/user id/item id.
- [ ] Add a button that calls PMSKit Jellyfin resolver and presents `PlayerView(resolvedRemoteURL:item:)` using a placeholder MediaItem title.
- [ ] Keep the path visibly experimental and manual; no default backend toggle yet.

## Task 5: Verify and commit

**Files:** all above

- [ ] Run `swift test --package-path PMSKit`.
- [ ] Run `./scripts/ci-hygiene.sh`.
- [ ] Build the visionOS simulator app with code signing disabled.
- [ ] Commit the branch.
