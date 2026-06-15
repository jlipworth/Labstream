# Jellyfin Backend Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a selectable Jellyfin backend mode with real Jellyfin login/session restore, Jellyfin library browsing, existing detail/player reuse, and Jellyfin active-encoding cleanup.

**Architecture:** Keep Plex paths intact and add a small Jellyfin lane beside them. PMSKit owns tested Jellyfin request builders and JSON-to-`MediaItem` mapping; app code stores separate Jellyfin credentials, routes login/restore by `MediaBackendKind`, and uses `JellyfinBrowseService` plus the existing `CustomPlayerView with PlaybackController(remoteStreamURL:)` seam for browse/playback.

**Tech Stack:** Swift 6.2, Swift Testing/XCTest in PMSKit, SwiftUI, Foundation URLSession, Keychain Services, AVKit existing player, visionOS simulator build.

---

## File Structure

- Create `PMSKit/Sources/PMSKit/Jellyfin/JellyfinLibrary.swift`: Jellyfin auth/session response models, library request builders, item DTOs, mapping to `MediaItem`, image URL helpers, active encoding stop request.
- Create `PMSKit/Tests/PMSKitTests/JellyfinLibraryTests.swift`: request-shape and mapping tests.
- Modify `PMSKit/Sources/PMSKit/Jellyfin/JellyfinAuth.swift`: decode `AuthenticationResult` and nested `User` fields.
- Modify `PlexAVPApp/App/AppModel.swift`: add `MediaBackendKind`, Jellyfin session fields, backend-aware readiness.
- Modify `PlexAVPApp/Auth/KeychainStore.swift`: separate persisted Jellyfin keys and selected backend.
- Modify `PlexAVPApp/Auth/AuthManager.swift`: backend selection, Jellyfin login, restore, sign-out.
- Create `PlexAVPApp/Backend/Jellyfin/JellyfinBrowseService.swift`: app-side URLSession service for Jellyfin library/detail/playback/cleanup.
- Modify `PlexAVPApp/UI/LoginView.swift`: backend picker and Jellyfin credential form.
- Modify `PlexAVPApp/UI/HomeView.swift`, `LibraryGridView.swift`, `SearchView.swift`, `MusicLibraryView.swift`, `PosterImage.swift`, `DetailView.swift`, `SettingsView.swift`: branch UI/load/playback behavior by active backend while preserving Plex.
- Modify `PlexAVPApp/Player/PlaybackController.swift` and `CustomPlayerView.swift`: carry optional remote session stop callback for Jellyfin active encoding cleanup.

## Task 1: PMSKit Jellyfin library and mapping layer

**Files:**
- Create: `PMSKit/Sources/PMSKit/Jellyfin/JellyfinLibrary.swift`
- Modify: `PMSKit/Sources/PMSKit/Jellyfin/JellyfinAuth.swift`
- Create: `PMSKit/Tests/PMSKitTests/JellyfinLibraryTests.swift`

- [ ] **Step 1: Write failing tests**

Add tests covering `AuthenticationResult`, `/UserViews`, `/Items`, `/Items/{id}`, image URLs, active encoding stop, and item mapping. The test should use real `JellyfinClientIdentity` and verify MediaBrowser auth headers and mapped `MediaItem` fields.

- [ ] **Step 2: Verify red**

Run: `swift test --package-path PMSKit --filter JellyfinLibraryTests`

Expected: fails because `JellyfinAuthenticationResult`, `JellyfinLibrary`, and DTO mapping symbols do not exist.

- [ ] **Step 3: Implement minimal PMSKit layer**

Implement public structs/functions:

```swift
public struct JellyfinAuthenticationResult: Decodable, Sendable, Equatable {
    public let user: JellyfinAuthenticatedUser?
    public let accessToken: String?
    public let serverId: String?
}

public struct JellyfinAuthenticatedUser: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String?
}

public enum JellyfinLibrary {
    public static func userViewsRequest(server: URL, token: String, identity: JellyfinClientIdentity, userId: String) throws -> URLRequest
    public static func itemsRequest(server: URL, token: String, identity: JellyfinClientIdentity, userId: String, parentId: String?, recursive: Bool) throws -> URLRequest
    public static func itemRequest(server: URL, token: String, identity: JellyfinClientIdentity, userId: String, itemId: String) throws -> URLRequest
    public static func imageURL(server: URL, itemId: String, imageType: JellyfinImageType, tag: String?, width: Int? = nil, height: Int? = nil) throws -> URL
    public static func activeEncodingStopRequest(server: URL, token: String, identity: JellyfinClientIdentity, deviceId: String, playSessionId: String) throws -> URLRequest
}
```

Include DTOs with `toMediaItem()` and synthetic image paths `jellyfin://item/{id}/Primary?tag=...`.

- [ ] **Step 4: Verify green**

Run: `swift test --package-path PMSKit --filter JellyfinLibraryTests`

Expected: all JellyfinLibrary tests pass.

- [ ] **Step 5: Commit**

Run:

```bash
git add PMSKit/Sources/PMSKit/Jellyfin PMSKit/Tests/PMSKitTests/JellyfinLibraryTests.swift
git commit -m "Add Jellyfin library API mapping (#35)"
```

## Task 2: Backend-aware app session state

**Files:**
- Modify: `PlexAVPApp/App/AppModel.swift`
- Modify: `PlexAVPApp/Auth/KeychainStore.swift`
- Modify: `PlexAVPApp/Auth/AuthManager.swift`

- [ ] **Step 1: Add backend model and keychain storage**

Add `MediaBackendKind` and Jellyfin session fields to `AppModel`. Add Keychain convenience properties for `selectedBackend`, `jellyfinServerURLString`, `jellyfinAccessToken`, `jellyfinUserID`, and `jellyfinServerID`.

- [ ] **Step 2: Add Jellyfin login/restore/signout**

Add `AuthManager.selectBackend(_:)`, `loginToJellyfin(server:username:password:)`, backend-aware `restoreSession()`, and backend-aware `signOut()`.

- [ ] **Step 3: Verify compile through app build**

Run: `xcodebuild -project PlexAVPApp.xcodeproj -scheme PlexAVPApp -destination 'platform=visionOS Simulator,id=D9BD8E9D-8E58-485D-B332-F8CDF37133B5' -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet`

Expected: app builds.

- [ ] **Step 4: Commit**

Run:

```bash
git add PlexAVPApp/App/AppModel.swift PlexAVPApp/Auth/KeychainStore.swift PlexAVPApp/Auth/AuthManager.swift
git commit -m "Add backend-aware Jellyfin session state (#35)"
```

## Task 3: Jellyfin browse service and login UI

**Files:**
- Create: `PlexAVPApp/Backend/Jellyfin/JellyfinBrowseService.swift`
- Modify: `PlexAVPApp/UI/LoginView.swift`
- Modify: `PlexAVPApp/UI/SettingsView.swift`

- [ ] **Step 1: Add browse service**

Create a `@MainActor` service with `userViews()`, `items(parentId:recursive:)`, `metadata(itemId:)`, `playbackOpen(item:maxVideoBitrateKbps:)`, `stopActiveEncoding(playSessionId:)`, and `jellyfinIdentity` helpers.

- [ ] **Step 2: Add Jellyfin login form**

Update `LoginView` with a backend segmented picker. Plex shows the existing PIN UI. Jellyfin shows server, username, password fields and calls `authManager.loginToJellyfin`.

- [ ] **Step 3: Update Settings backend display**

Show active backend and use `authManager.signOut()` for active backend. Keep the manual Jellyfin test section behind experimental toggle for now.

- [ ] **Step 4: Build verification**

Run the same `xcodebuild ... CODE_SIGNING_ALLOWED=NO -quiet` command.

- [ ] **Step 5: Commit**

Run:

```bash
git add PlexAVPApp/Backend/Jellyfin/JellyfinBrowseService.swift PlexAVPApp/UI/LoginView.swift PlexAVPApp/UI/SettingsView.swift
git commit -m "Add Jellyfin login UI and browse service (#35)"
```

## Task 4: Jellyfin browsing, images, playback, and cleanup wiring

**Files:**
- Modify: `PlexAVPApp/UI/HomeView.swift`
- Modify: `PlexAVPApp/UI/LibraryGridView.swift`
- Modify: `PlexAVPApp/UI/SearchView.swift`
- Modify: `PlexAVPApp/Music/MusicLibraryView.swift`
- Modify: `PlexAVPApp/UI/PosterImage.swift`
- Modify: `PlexAVPApp/UI/DetailView.swift`
- Modify: `PlexAVPApp/Player/CustomPlayerView.swift`
- Modify: `PlexAVPApp/Player/PlaybackController.swift`

- [ ] **Step 1: Browse branch**

For Jellyfin, `HomeView` and `LibrariesView` load `JellyfinBrowseService.userViews()`. `LibraryGridView` accepts either `PlexSection` or `JellyfinUserView` and loads corresponding items. `ContainerBrowserView` loads Jellyfin children through `/Items?parentId=`.

- [ ] **Step 2: Unsupported feature placeholders**

`SearchView` and `MusicLibraryView` show disabled Jellyfin placeholders when active backend is Jellyfin.

- [ ] **Step 3: Image branch**

`PosterImage` detects `jellyfin://item/...` paths, builds a Jellyfin direct image URL, and fetches with MediaBrowser auth.

- [ ] **Step 4: Playback branch**

`DetailView` Jellyfin play calls service `playbackOpen`, presents `CustomPlayerView with PlaybackController(remoteStreamURL:...)`, and passes an `onStopRemoteSession` callback that deletes active encodings with the returned `playSessionId`.

- [ ] **Step 5: Build verification**

Run the same `xcodebuild ... CODE_SIGNING_ALLOWED=NO -quiet` command.

- [ ] **Step 6: Commit**

Run:

```bash
git add PlexAVPApp/UI/HomeView.swift PlexAVPApp/UI/LibraryGridView.swift PlexAVPApp/UI/SearchView.swift PlexAVPApp/Music/MusicLibraryView.swift PlexAVPApp/UI/PosterImage.swift PlexAVPApp/UI/DetailView.swift PlexAVPApp/Player/CustomPlayerView.swift PlexAVPApp/Player/PlaybackController.swift
git commit -m "Wire Jellyfin browse and playback mode (#35)"
```

## Task 5: Final verification and push

**Files:** all changed files

- [ ] **Step 1: Run package tests**

Run: `swift test --package-path PMSKit`

Expected: all tests pass.

- [ ] **Step 2: Run hygiene**

Run: `./scripts/ci-hygiene.sh`

Expected: `ci-hygiene: ok`.

- [ ] **Step 3: Run app build**

Run: `xcodebuild -project PlexAVPApp.xcodeproj -scheme PlexAVPApp -destination 'platform=visionOS Simulator,id=D9BD8E9D-8E58-485D-B332-F8CDF37133B5' -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet`

Expected: exit 0.

- [ ] **Step 4: Push branch**

Run: `git push`

Expected: branch uploads all commits to `origin/backend/35-jellyfin-support`.
