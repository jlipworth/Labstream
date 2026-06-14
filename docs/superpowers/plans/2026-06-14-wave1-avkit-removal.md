# Wave 1 — Custom Player Becomes the Sole Player (AVKit Removal) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the app-owned custom player (`CustomPlayerView` + `CustomCinemaScaffoldView`) the one and only player, delete the legacy AVKit path entirely, and remove the `experimentalCustomPlayerEnabled` toggle.

**Architecture:** Three sub-waves on a single dedicated branch, each build-verified, with live-sim verification batched into `TESTING-CHECKLIST.md` for the owner. **1a** gives the custom player a local-file entry point and repoints the two offline call sites (the only call sites that bypass the toggle today). **1b** extracts the windowed player's chrome (`CustomPlayerChrome` and its menu/popover/overlay helpers) into a shared file and reuses it in the Cinema immersive scene, achieving full normal-mode control parity by *sharing* the surface rather than duplicating it. **1c** deletes the three AVKit files and strips the toggle, flipping the streaming default to the custom player.

**Tech Stack:** Swift 6, SwiftUI, AVFoundation (`AVPlayerLayer`), visionOS `ImmersiveSpace`, `xcodebuild` (unsigned simulator build). No automated UI tests exist for the player — see "Testing model" below.

---

## Testing model (read first)

This wave touches only SwiftUI/visionOS player UI. **There is no unit-test harness for the player** (PMSKit has tests, but nothing in this wave touches PMSKit). The per-task verification is therefore:

1. **Build-clean gate** after every code change, using the project's link-skip-trap guard (delete the `.app` product first, then build, so a skipped `Ld` step cannot masquerade as success):

   ```sh
   rm -rf $HOME/Library/Developer/Xcode/DerivedData/PlexAVPApp-*/Build/Products/Debug-xrsimulator/PlexAVPApp.app
   xcodebuild -project PlexAVPApp.xcodeproj -scheme PlexAVPApp \
     -destination 'platform=visionOS Simulator,id=D9BD8E9D-8E58-485D-B332-F8CDF37133B5' \
     -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet
   ```
   Expected: `** BUILD SUCCEEDED **` and a fresh `PlexAVPApp.app` (verify mtime is newer than the build start).

2. **Live-sim verification** is performed by the owner. Every behavior this wave can only confirm in-headset is collected into `TESTING-CHECKLIST.md` (Task 1d) — do **not** ask the owner for screenshots mid-wave; the checklist is the single handoff.

If the simulator UDID differs, `xcrun simctl list devices booted` to find the booted one.

## Branch

All Wave 1 work lands on one branch off `main`:

```sh
git switch -c wave1/custom-player-sole-player
```

Commit after each task (the steps below include the exact commit). Do **not** push or merge — the owner merges after the live-sim checklist passes.

## File structure

| File | Disposition in Wave 1 |
|---|---|
| `PlexAVPApp/Player/CustomPlayerView.swift` | Modify (1a: add local-file init; 1b: chrome extraction leaves this file importing the shared chrome) |
| `PlexAVPApp/Player/CustomPlayerChrome.swift` | **Create** (1b: extracted `CustomPlayerChrome`, `CustomPlayerMenuKind`, `CustomPlayerMenuPopover`, `CustomReconnectingOverlay`, shared scrubber-clock helper) |
| `PlexAVPApp/Player/CustomCinemaMode.swift` | Modify (1b: cinema scaffold hosts the shared chrome for full control parity) |
| `PlexAVPApp/UI/DetailView.swift` | Modify (1a: repoint local arm; 1c: collapse toggle branch, drop `@AppStorage`) |
| `PlexAVPApp/Downloads/OfflineLibraryView.swift` | Modify (1a: repoint local arm) |
| `PlexAVPApp/UI/SettingsView.swift` | Modify (1c: remove toggle, `@AppStorage`, footer clause) |
| `PlexAVPApp/Player/PlayerView.swift` | **Delete** (1c) |
| `PlexAVPApp/Player/PlayerControlSurface.swift` | **Delete** (1c) |
| `PlexAVPApp/Player/CinemaEnvironment.swift` | **Delete** (1c) |
| `TESTING-CHECKLIST.md` | Modify (1d: add the Wave 1 live-sim section) |

New Swift files are picked up automatically (file-system-synchronized groups) — **never** edit the pbxproj.

**Keep untouched (shared engine / views — do not over-reach):** `PlaybackController.swift`, `PlayerControlPickers.swift`, `StatsForNerdsView.swift`, `PlaybackDiagnostics.swift`, `TimelineReporter.swift`, `AudioSessionCoordinator.swift`, all of PMSKit. `PlayerLayerView` lives in `CustomPlayerView.swift:132` (not in the deleted `PlayerView.swift`), so the custom player and cinema scene keep their presenter after deletion.

---

## Wave 1a — Local-file support + repoint offline call sites

**Why first:** `DetailView.swift:361` (downloaded-copy play) and `OfflineLibraryView.swift:50` call `PlayerView(localFile:)`, bypassing the toggle. Deleting `PlayerView` before this would break the build and remove offline playback. `CustomPlayerView` already accepts a zero-arg `controllerFactory`, and `PlaybackController` already has `init(localFile:item:identity:client:)` — this is pure presentation wiring.

### Task 1a.1: Add a local-file initializer to `CustomPlayerView`

**Files:**
- Modify: `PlexAVPApp/Player/CustomPlayerView.swift` (after the existing `init` ending at line 35)

`OfflineLibraryView` holds no `AppModel`/identity, so this initializer must synthesize a throwaway offline identity/client exactly as the deleted `PlayerView.init(localFile:item:onClose:)` did (`PlayerView.swift:119`). DetailView has an `AppModel` but will use this same convenience init for simplicity.

- [ ] **Step 1: Add the initializer**

Insert immediately after the closing `}` of the existing `init(item:controllerFactory:onClose:onRequestPlay:)` (currently line 35):

```swift
    /// Offline initializer: plays a downloaded file through the custom player.
    ///
    /// Mirrors the contract of the retired `PlayerView.init(localFile:item:onClose:)`. A pure
    /// offline file needs no server session, but `PlaybackController` still wants an identity +
    /// client for type symmetry, so we synthesize a throwaway pair here. Callers that already
    /// hold an `AppModel` can use `init(item:controllerFactory:…)` with a local-file factory if
    /// they prefer their real identity/client.
    init(localFile: URL, item: MediaItem, onClose: (() -> Void)? = nil) {
        let identity = ClientIdentity(clientIdentifier: "offline",
                                      product: "VisionPlex",
                                      version: "0.1.0",
                                      deviceName: "Apple Vision Pro")
        let client = PlexClient(identity: identity)
        self.init(item: item,
                  controllerFactory: {
                      PlaybackController(localFile: localFile,
                                         item: item,
                                         identity: identity,
                                         client: client)
                  },
                  onClose: onClose,
                  onRequestPlay: nil)
    }
```

- [ ] **Step 2: Build-clean gate**

Run the build-clean gate (see Testing model). Expected: `** BUILD SUCCEEDED **`. (No call site uses the new init yet; this only proves it compiles.)

- [ ] **Step 3: Commit**

```sh
git add PlexAVPApp/Player/CustomPlayerView.swift
git commit -m "Add local-file initializer to CustomPlayerView"
```

### Task 1a.2: Repoint `OfflineLibraryView` to the custom player

**Files:**
- Modify: `PlexAVPApp/Downloads/OfflineLibraryView.swift:50` (and the doc comments at lines 5, 197)

- [ ] **Step 1: Replace the player call**

Change line 50 from:

```swift
            PlayerView(localFile: record.localURL, item: offlineItem(from: record))
```

to:

```swift
            CustomPlayerView(localFile: record.localURL, item: offlineItem(from: record))
```

- [ ] **Step 2: Refresh the doc comments**

Line 5 — change `through the shared Task 11 player (`PlayerView(localFile:item:)`).` to `through the custom player (`CustomPlayerView(localFile:item:)`).`

Line 197 — change `offline file flows through the same `PlayerView` path with real title/metadata.` to `offline file flows through the same `CustomPlayerView` path with real title/metadata.`

- [ ] **Step 3: Build-clean gate**

Run the build-clean gate. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```sh
git add PlexAVPApp/Downloads/OfflineLibraryView.swift
git commit -m "Play offline downloads through the custom player"
```

### Task 1a.3: Repoint `DetailView` downloaded-copy play to the custom player

**Files:**
- Modify: `PlexAVPApp/UI/DetailView.swift:360-363`

This is the `if let local = playLocalURL` arm of `playerCover`. It is **not** behind the toggle today; repoint it now (the toggle-gated streaming arm is handled in Task 1c).

- [ ] **Step 1: Replace the player call**

Change lines 361-363 from:

```swift
            PlayerView(localFile: local, item: playing,
                       onClose: { presentingPlayer = false })
                .ignoresSafeArea()
```

to:

```swift
            CustomPlayerView(localFile: local, item: playing,
                             onClose: { presentingPlayer = false })
                .ignoresSafeArea()
```

- [ ] **Step 2: Build-clean gate**

Run the build-clean gate. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```sh
git add PlexAVPApp/UI/DetailView.swift
git commit -m "Play downloaded copies through the custom player"
```

---

## Wave 1b — Custom cinema full control parity

**Why:** Decision (2) requires Cinema Mode to replicate the full normal-mode control set (play/pause, scrubber, skip, and the quality/audio/subtitle/chapters/stats/speed menu). The windowed player already implements all of that inside the file-private `CustomPlayerChrome` (in `CustomPlayerView.swift`). The cinema scaffold (`CustomCinemaScaffoldView`) today has only bare skip ± and an Exit button. We achieve parity by **extracting the chrome into a shared file and hosting it in the cinema scene** — deduplicating, not rebuilding.

**Design decision (locked):** The cinema scene reuses `CustomPlayerChrome` verbatim. It supplies the shared `controller` from `CustomCinemaSessionStore`, its own `@State scrubState` driven by a shared clock helper, `isReconnecting: false`, and `onRetry: { session.controller?.retry() }`. The failure/buffering/up-next cards inside the chrome render for free because they read the shared `controller` state directly; only the "Reconnecting…" overlay (gated by the external `isReconnecting` flag) stays owned by the windowed presentation, which remains mounted behind the immersive space and continues to own the reconnect watchdog. The chrome's existing `cinemaButton` already flips to "Exit Cinema" when `presentationState == .open`, giving the in-cinema exit affordance; `onClose` is passed `nil` so no redundant window-close button appears inside Cinema.

### Task 1b.1: Extract the chrome into a shared file

**Files:**
- Create: `PlexAVPApp/Player/CustomPlayerChrome.swift`
- Modify: `PlexAVPApp/Player/CustomPlayerView.swift` (remove the moved declarations; add a shared clock helper call)

The following declarations currently live in `CustomPlayerView.swift` and are `private`/file-private:
- `CustomPlayerChrome` (struct, lines ~162-605)
- `CustomPlayerMenuKind` (enum, lines ~607-673)
- `CustomPlayerMenuPopover` (struct, lines ~675-755)
- `CustomReconnectingOverlay` (struct, lines ~757-781)

- [ ] **Step 1: Create `CustomPlayerChrome.swift` with the moved declarations made internal**

Create the new file. Move the four declarations verbatim from `CustomPlayerView.swift`, changing each leading `private struct`/`private enum` to `struct`/`enum` (internal) so the cinema scene in another file can host them. Add the shared scrubber-clock helper that both hosts will call (it factors out the duration-resolution logic currently inlined in `CustomPlayerView.refreshScrubberClock`, `CustomPlayerView.swift:97-112`).

```swift
import AVFoundation
import PMSKit
import SwiftUI

/// Shared scrubber-clock tick used by both the windowed custom player and the Cinema scene.
///
/// Resolves the live duration from the player item (falling back to the catalog duration) and
/// pushes the controller's resume position into the scrub state unless the user is mid-drag.
@MainActor
func tickCustomScrubberClock(_ scrubState: inout PlaybackScrubState,
                             from controller: PlaybackController,
                             fallbackDurationMs: Int) {
    let duration = controller.player.currentItem?.duration
    let durationMs: Int
    if let duration, duration.seconds.isFinite, duration.seconds > 0 {
        durationMs = Int((duration.seconds * 1000).rounded())
    } else {
        durationMs = fallbackDurationMs
    }
    scrubState.updateDuration(durationMs)
    if !scrubState.isDragging {
        scrubState.updateLivePosition(controller.currentResumeMs)
    }
}

// MARK: - Chrome

/// App-owned player chrome (play/pause, scrubber, skip, the menu strip, and the
/// failure/buffering/up-next/reconnect overlays). Hosted by both `CustomPlayerView` (windowed)
/// and `CustomCinemaScaffoldView` (Cinema immersive scene) so the control set is defined once.
struct CustomPlayerChrome: View {
    // … entire body moved verbatim from CustomPlayerView.swift, unchanged …
}

private enum CustomPlayerMenuKind: String, CaseIterable, Identifiable {
    // … moved verbatim …
}

private struct CustomPlayerMenuPopover: View {
    // … moved verbatim …
}

struct CustomReconnectingOverlay: View {
    // … moved verbatim …
}
```

Notes:
- `CustomPlayerMenuKind` and `CustomPlayerMenuPopover` are only referenced by `CustomPlayerChrome`, so they stay `private` *within the new file* (file-private to `CustomPlayerChrome.swift`). Only `CustomPlayerChrome` and `CustomReconnectingOverlay` need to be internal.
- Move the declarations **verbatim** — no body changes in this step. The goal is a pure relocation that still compiles.

- [ ] **Step 2: Update `CustomPlayerView.refreshScrubberClock` to call the shared helper**

In `CustomPlayerView.swift`, replace the body of `refreshScrubberClock(from:)` (lines 97-112) with a call to the shared helper so the duration logic lives in one place:

```swift
    @MainActor
    private func refreshScrubberClock(from controller: PlaybackController) {
        tickCustomScrubberClock(&scrubState, from: controller, fallbackDurationMs: item.duration ?? 0)
    }
```

- [ ] **Step 3: Build-clean gate**

Run the build-clean gate. Expected: `** BUILD SUCCEEDED **`. This proves the extraction is behavior-neutral (windowed player still compiles against the moved chrome).

- [ ] **Step 4: Commit**

```sh
git add PlexAVPApp/Player/CustomPlayerChrome.swift PlexAVPApp/Player/CustomPlayerView.swift
git commit -m "Extract CustomPlayerChrome into a shared file"
```

### Task 1b.2: Host the shared chrome in the Cinema scene

**Files:**
- Modify: `PlexAVPApp/Player/CustomCinemaMode.swift` (`CustomCinemaScaffoldView`, lines 48-122)

- [ ] **Step 1: Give the scaffold its own scrub state + clock and host the chrome**

Replace `CustomCinemaScaffoldView`'s state, `body`, `cinemaSurface`, and the now-obsolete `cinemaSkipButton` (lines 48-122) with the version below. The themed video panel stays; the bare skip/exit `HStack` and the redundant title `Text` are removed (the chrome renders the title and full controls). `inactiveState` (lines 124-145) is unchanged and kept.

```swift
struct CustomCinemaScaffoldView: View {
    @Environment(CustomCinemaSessionStore.self) private var session
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @State private var scrubState = PlaybackScrubState(durationMs: 0, livePositionMs: 0)

    var body: some View {
        ZStack {
            if let controller = session.controller, let player = session.player {
                cinemaSurface(controller: controller, player: player)
            } else {
                inactiveState
            }
        }
        .onAppear { session.presentationState = .open }
        .onDisappear {
            if session.presentationState != .closed {
                session.presentationState = .closed
            }
        }
    }

    private func cinemaSurface(controller: PlaybackController, player: AVPlayer) -> some View {
        PlayerLayerView(player: player)
            .frame(width: 1180, height: 664)
            .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            }
            .background {
                RoundedRectangle(cornerRadius: 44, style: .continuous)
                    .fill(.black.opacity(0.92))
                    .shadow(color: .black.opacity(0.45), radius: 38, y: 18)
            }
            .overlay {
                CustomPlayerChrome(controller: controller,
                                   title: session.title ?? "Cinema Mode",
                                   scrubState: $scrubState,
                                   isReconnecting: false,
                                   onRetry: { session.controller?.retry() },
                                   onClose: nil)
            }
            .padding(30)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 46, style: .continuous))
            .task(id: session.controller != nil) { await runCinemaClock(controller) }
    }

    private func runCinemaClock(_ controller: PlaybackController) async {
        await MainActor.run {
            tickCustomScrubberClock(&scrubState, from: controller, fallbackDurationMs: 0)
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            await MainActor.run {
                guard let controller = session.controller else { return }
                tickCustomScrubberClock(&scrubState, from: controller, fallbackDurationMs: 0)
            }
        }
    }
```

Leave the closing `}` of the struct and the unchanged `inactiveState` property below `runCinemaClock`. Delete the old `cinemaSkipButton(seconds:)` method (it is no longer referenced).

- [ ] **Step 2: Build-clean gate**

Run the build-clean gate. Expected: `** BUILD SUCCEEDED **`. Watch specifically for "unused function `cinemaSkipButton`" — if it appears, the old method was not fully removed.

- [ ] **Step 3: Commit**

```sh
git add PlexAVPApp/Player/CustomCinemaMode.swift
git commit -m "Give custom Cinema mode full normal-mode control parity"
```

---

## Wave 1c — Delete AVKit + toggle surgery

**Why last:** After 1a and 1b, no code path *depends* on the AVKit player except the toggle-gated streaming arm in `DetailView`. Deleting the three files and stripping the toggle flips the streaming default to the custom player and removes ~1,187 lines of dead AVKit surface. Confirmed by `rg`: outside their own files and doc comments, `PlayerView`/`PlayerControlSurface`/`CinemaEnvironment`/`AVExperienceController` have **no** remaining code references after 1a (the streaming-arm `PlayerView(item:...)` at `DetailView.swift:396` is the only one, removed in this wave).

### Task 1c.1: Collapse the `DetailView` toggle branch

**Files:**
- Modify: `PlexAVPApp/UI/DetailView.swift` (line 46 `@AppStorage`; the `if experimentalCustomPlayerEnabled { … } else { … }` block at lines 381-408)

- [ ] **Step 1: Remove the streaming-arm toggle, keeping only the custom arm**

Replace lines 381-408 (the entire `if experimentalCustomPlayerEnabled { CustomPlayerView(…) } else { PlayerView(…) }` block) with the unconditional custom arm:

```swift
                CustomPlayerView(item: playing,
                                 controllerFactory: {
                                     PlaybackController(item: playing,
                                                        server: server,
                                                        token: token,
                                                        identity: appModel.identity,
                                                        client: appModel.client,
                                                        maxVideoBitrateKbps: maxVideoBitrateKbps,
                                                        mediaIndex: mediaIndex,
                                                        machineIdentifier: machineIdentifier)
                                 },
                                 onClose: { presentingPlayer = false },
                                 onRequestPlay: playNext)
```

- [ ] **Step 2: Remove the now-unused `@AppStorage`**

Delete line 46:

```swift
    @AppStorage("experimentalCustomPlayerEnabled") private var experimentalCustomPlayerEnabled = false
```

If the doc comment above it (line 48 references the "custom fallback path") still reads as fallback language, simplify it to describe the single bitrate-cap default. Also update the header comment at line 8 (`presents the AVKit `PlayerView``) to `presents the custom player`.

- [ ] **Step 3: Build-clean gate**

Run the build-clean gate. Expected: `** BUILD SUCCEEDED **`. (`PlayerView` still exists in this step — only its `DetailView` references are gone.)

- [ ] **Step 4: Commit**

```sh
git add PlexAVPApp/UI/DetailView.swift
git commit -m "Route all streaming playback through the custom player"
```

### Task 1c.2: Remove the Settings toggle

**Files:**
- Modify: `PlexAVPApp/UI/SettingsView.swift` (line 35 `@AppStorage`; the `Toggle` at lines 61-63; the footer clause at line 67)

⚠️ This file's Playback section is a known 3-way conflict hotspot (this toggle removal, #31 headroom, #26 reset-prefs). Land this edit alone and commit before any Wave 2 work touches the section.

- [ ] **Step 1: Delete the toggle and its `@AppStorage`**

Delete lines 61-63:

```swift
            Toggle(isOn: $experimentalCustomPlayerEnabled) {
                Label("Custom player fallback (experimental)", systemImage: "play.rectangle.on.rectangle")
            }
```

Delete the `@AppStorage` and its doc comment (lines 31-35):

```swift
    /// Experimental fallback player path, default OFF. The normal AVPlayerViewController path
    /// stays the product default; this routes streaming playback through an app-owned
    /// AVPlayerLayer presenter with a deterministic scrubber when we need to test whether
    /// native AVKit chrome is the source of Plex seek/reconnect weirdness.
    @AppStorage("experimentalCustomPlayerEnabled") private var experimentalCustomPlayerEnabled = false
```

- [ ] **Step 2: Trim the footer**

Change the footer (line 67) from:

```swift
            Text("The quality new streams start at. Changing quality inside the player updates this too. Direct Stream plays compatible video without re-encoding on the server. Custom player fallback keeps the normal player as default, but lets you test an app-owned scrubber if AVKit playback misbehaves.")
```

to (drop only the final "Custom player fallback…" sentence):

```swift
            Text("The quality new streams start at. Changing quality inside the player updates this too. Direct Stream plays compatible video without re-encoding on the server.")
```

- [ ] **Step 3: Build-clean gate**

Run the build-clean gate. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```sh
git add PlexAVPApp/UI/SettingsView.swift
git commit -m "Remove the experimental custom-player toggle"
```

### Task 1c.3: Delete the three AVKit files

**Files:**
- Delete: `PlexAVPApp/Player/PlayerView.swift`
- Delete: `PlexAVPApp/Player/PlayerControlSurface.swift`
- Delete: `PlexAVPApp/Player/CinemaEnvironment.swift`

- [ ] **Step 1: Delete the files**

```sh
git rm PlexAVPApp/Player/PlayerView.swift \
       PlexAVPApp/Player/PlayerControlSurface.swift \
       PlexAVPApp/Player/CinemaEnvironment.swift
```

- [ ] **Step 2: Build-clean gate**

Run the build-clean gate. Expected: `** BUILD SUCCEEDED **`.

If the build fails with an unresolved reference, it is a doc-comment-only symbol or a missed call site. Resolve with: `rg -n "PlayerView|PlayerControlSurface|CinemaEnvironment|AVExperienceController" PlexAVPApp/`. Expected remaining hits after this task are **comments only** in `PlaybackController.swift`, `StatsForNerdsView.swift`, `DownloadManager.swift`, `AppModel.swift`, and the `PrivacyInfo.xcprivacy` manifest text — none are compiled references.

- [ ] **Step 3: Commit**

```sh
git add -A
git commit -m "Delete the legacy AVKit player path"
```

### Task 1c.4: Sweep stale comment/manifest references (non-breaking)

**Files:**
- Modify: `PlexAVPApp/Downloads/DownloadManager.swift:19`, `PlexAVPApp/App/AppModel.swift:11`, `PlexAVPApp/PrivacyInfo.xcprivacy:20`

These are descriptive text only (the build already passes). Update the most user-visible ones so the public repo doesn't reference a deleted type. The dense AVKit-mechanics comments inside `PlaybackController.swift`/`StatsForNerdsView.swift` are deferred to the DEVELOPMENT.md decomposition (Task #10), not this wave.

- [ ] **Step 1: Update the references**

- `DownloadManager.swift:19` — `Offline playback reuses the Task 11 player via `PlayerView(localFile:item:)`.` → `Offline playback reuses the custom player via `CustomPlayerView(localFile:item:)`.`
- `AppModel.swift:11` — change `creates `PlayerView`s` to `creates `CustomPlayerView`s`.
- `PrivacyInfo.xcprivacy:20` — change `UserDefaults (PlaybackController/PlayerView)` to `UserDefaults (PlaybackController/CustomPlayerView)`.

- [ ] **Step 2: Build-clean gate**

Run the build-clean gate. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```sh
git add -A
git commit -m "Sweep stale AVKit player references in comments and privacy manifest"
```

---

## Wave 1d — Live-test checklist handoff

### Task 1d.1: Write the Wave 1 live-sim section into `TESTING-CHECKLIST.md`

**Files:**
- Modify: `TESTING-CHECKLIST.md`

The owner runs these in-headset; this is the only place behaviors that can't be build-verified are recorded. (This task also feeds Task #9 "Gather live-test checklist for user".)

- [ ] **Step 1: Append a Wave 1 section**

Add a section titled "Wave 1 — Custom player is the sole player" with these check items:

```markdown
## Wave 1 — Custom player is the sole player

### Streaming (windowed)
- [ ] Play a movie from DetailView → custom player opens (no AVKit transport bar).
- [ ] Play/pause, scrubber drag-to-seek, and skip ±10/±30 all work.
- [ ] Each menu opens and applies: Quality, Subtitles, Audio, Chapters, Speed, Stats.
- [ ] Close (✕) dismisses back to DetailView.
- [ ] Up Next autoplay advances to the next episode (controller rebuilds cleanly).

### Offline / downloaded
- [ ] Play a completed download from the Offline tab → custom player opens and plays the local file.
- [ ] Play a downloaded copy from DetailView (offline) → custom player opens and plays.
- [ ] Scrubber + skip work on a local file (no network).

### Cinema parity
- [ ] From the windowed player, tap "Cinema" → immersive theater opens with the same video.
- [ ] In Cinema: play/pause, scrubber, skip ±, and ALL menus (Quality/Subtitles/Audio/Chapters/Speed/Stats) work — matching windowed mode.
- [ ] "Exit Cinema" returns to the windowed player; playback position is continuous.
- [ ] Closing the windowed player while Cinema is open tears down cleanly (no orphaned immersive space).

### Settings
- [ ] Settings → Playback no longer shows the "Custom player fallback" toggle.
- [ ] Streaming quality picker and Direct Stream toggle still present and functional.

### Regression
- [ ] No reference to the old AVKit player anywhere in the UI.
- [ ] Reconnect/failure: kill the server mid-stream → failure card with Retry appears in the windowed player.
```

- [ ] **Step 2: Commit**

```sh
git add TESTING-CHECKLIST.md
git commit -m "Add Wave 1 live-sim checklist"
```

---

## Self-review against the roadmap (spec coverage)

- **Decision (1) "custom player is the only player; all AVKit code removed":** Tasks 1c.1–1c.3 delete the three AVKit files and the toggle; 1a repoints the offline call sites that blocked deletion. ✅
- **Decision (2) "Cinema replicates the full normal-mode control set":** Task 1b reuses `CustomPlayerChrome` (play/pause, scrubber, skip, all six menus) in the Cinema scene. ✅
- **Roadmap blocker 🔴 (offline hard-wired to AVKit):** Tasks 1a.1–1a.3. ✅
- **Roadmap blocker 🟠 (bare cinema controls):** Task 1b. ✅
- **Anti-redundancy goal:** chrome is shared, not duplicated (Task 1b.1 extraction); the scrubber-clock logic is unified via `tickCustomScrubberClock`. ✅
- **"Keep shared engine/views":** the Keep list is untouched; `PlayerLayerView` confirmed to live in `CustomPlayerView.swift`, not the deleted files. ✅
- **SettingsView 3-way hotspot:** Task 1c.2 lands alone and is committed before Wave 2. ✅
- **Deferred (not in this wave, by design):** AVKit-mechanics comments inside `PlaybackController.swift`/`StatsForNerdsView.swift` → DEVELOPMENT.md decomposition (Task #10); `[VP]` NSLog strip → Wave 2 (#27/#7 closeout).
