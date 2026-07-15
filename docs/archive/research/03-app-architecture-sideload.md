# Plex visionOS Client — App Architecture & Sideload Realities

> **Archived research snapshot:** retained as dated evidence, not current architecture, feature
> status, or implementation guidance. Verify any reusable detail against the active docs and
> current source; old `VisionPlay` names, issue links, branches, and paths below are historical.

**Date:** June 2026
**Scope:** Personal-use native Apple Vision Pro (visionOS) Plex client. **Free/personal Apple ID, no paid Apple Developer account, sideload-only via Xcode.**

> TL;DR: The architecture is the easy part — a standard SwiftUI visionOS app with a clean module split is very achievable. The hard part is **distribution**: a free Apple ID provisioning profile **expires every 7 days**, after which the app stops launching and you must re-deploy from Xcode with the headset connected to the Mac. That re-signing treadmill is the single biggest practical downside versus an App Store / TestFlight app, and there is currently **no AltStore/SideStore escape hatch on visionOS**.

---

## 1. visionOS SwiftUI App Structure

visionOS apps are SwiftUI apps. The scene system offers three scene types: **windows** (flat 2D content, the default), **volumes** (bounded 3D content), and **immersive spaces** (unbounded/surrounding content). For a Plex client you primarily need **windows** for browsing + playback, and **optionally** one immersive space for 180/360/spatial video.

### The App entry point + scenes

```swift
import SwiftUI

@main
struct PlexVisionApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        // 2D floating browse UI — the main window
        WindowGroup(id: "main") {
            RootView()
                .environment(appState)
        }
        .windowStyle(.plain)               // or .volumetric for 3D chrome
        .defaultSize(width: 1280, height: 800)

        // Optional: dedicated player window so playback survives navigating the browser
        WindowGroup(id: "player", for: MediaID.self) { $mediaID in
            PlayerWindow(mediaID: mediaID)
                .environment(appState)
        }

        // Optional: only if you want surrounding/immersive (180/360/spatial) playback
        ImmersiveSpace(id: "immersive-player") {
            ImmersivePlayerView()
                .environment(appState)
        }
        .immersionStyle(selection: $appState.immersion, in: .progressive, .full)
    }
}
```

Key facts:
- `WindowGroup` renders a flat 2D floating window — exactly right for the Plex library browse UI. Multiple windows can be open at once.
- visionOS 26 adds a single-instance `Window` (vs duplicable `WindowGroup`) if you want a unique window that can't be duplicated.
- `ImmersiveSpace` is opened **programmatically** via `@Environment(\.openImmersiveSpace)` and dismissed via `dismissImmersiveSpace`; only **one** immersive space can be open at a time, and opening it hides other apps' content. For a v1 personal Plex client playing ordinary 2D movie files, **you do not need an ImmersiveSpace at all** — a windowed player is enough. Add it later only if you want big-screen/180/360 modes.

### Presenting a video player

Three valid approaches, in increasing complexity:

1. **`AVPlayerViewController` wrapped in `UIViewControllerRepresentable`** — the preferred MVP path for this project because it participates in the visionOS system player/theater experience and gives you stock transport, subtitle/audio UI, and docking behavior. Host an `AVPlayerViewController` holding an `AVPlayer(playerItem:)`.
2. **SwiftUI `VideoPlayer` (AVKit)** — `VideoPlayer(player: avPlayer)`. Useful for a tiny prototype, but do not make it the main theater implementation because the deeper visionOS system-player controls live on `AVPlayerViewController`.
3. **RealityKit `VideoPlayerComponent`** (visionOS 26) — attaches video to a 3D entity/mesh; required only for true immersive 180/360/Apple Immersive Video inside an `ImmersiveSpace`. Overkill for normal files. visionOS 26 also added progressive immersive mode and comfort-mitigation (auto-reducing immersion on high motion) in AVKit/QuickLook.

In all cases the player is fed an `AVPlayerItem` built from **either an HLS/HTTP URL (Plex transcode/stream) or a local file URL (offline download)** — same code path, which keeps the Player module simple.

### Minimal file skeleton (fresh Xcode "visionOS App" template)

```
PlexVision/
├── PlexVisionApp.swift          # @main App, scene declarations
├── RootView.swift               # top-level WindowGroup content (NavigationSplitView)
├── Assets.xcassets/             # app icon (layered for visionOS), colors
├── Info.plist                   # (often synthesized; UISceneConfigurations etc.)
├── Preview Content/             # SwiftUI preview assets
└── Packages/ (SPM deps)         # optional OpenImmersiveLib; no Plex SDK required
```

That is genuinely the whole baseline. Xcode's "App" template for visionOS scaffolds `…App.swift` + a `ContentView.swift` (+ optionally a `ToggleImmersiveSpaceButton` and `ImmersiveView.swift` if you pick the "Volume"/"Full Space" initial scene). For this app, choose the **Window** initial scene.

---

## 2. Proposed Module Breakdown (YAGNI, well-bounded)

Implement as Swift Package targets (or at minimum folder-grouped Swift files) so dependencies stay one-directional. Each module is a small, testable unit.

| Module | One-line purpose | Depends on |
|---|---|---|
| **AppState** | Observable root app state: current server, selected library, navigation path, immersion style, playback queue. | (none — leaf) |
| **PlexAuth** | Plex.tv login flow (PIN/OAuth), stores & refreshes the auth token in Keychain, resolves the user's servers/connection URIs. | (Foundation, Keychain) |
| **PlexAPI** | Library browse (sections, items, metadata, artwork URLs) + the transcode/stream **decision** (direct play vs `start.m3u8`, building the playback URL). Thin hand-written `URLSession` REST layer; use `plexswift` only as an optional reference/model source. | PlexAuth, Foundation |
| **Player** | `AVPlayerViewController` wrapper (backed by `AVPlayer`) + a SwiftUI environment to launch playback from any view; handles play/pause/seek, progress reporting back to Plex (`/:/timeline`). | PlexAPI (for stream URLs), AppState |
| **DownloadManager** | Download selected items to the app sandbox for offline, track download state, vend local file URLs to Player. | PlexAPI (download URLs) |
| **LibraryUI** | SwiftUI browse views: server/library picker, grid/poster wall, detail view, "play" + "download" buttons. The `WindowGroup` content. | AppState, PlexAPI, Player, DownloadManager |

Design notes / boundaries:
- **AppState is a leaf** that everyone reads; injected via `.environment()`. Use Swift's `@Observable` (Observation framework).
- **Player accepts an `AVPlayerItem` source abstraction** (`.remote(URL)` or `.local(URL)`) so DownloadManager and PlexAPI both feed it without Player knowing about Plex.
- **PlexAPI owns the transcode decision** (resolution/bitrate caps, codec support) — that logic does NOT leak into the UI.
- Deliberately **omitted for v1 (YAGNI):** no official Mobile Sync engine, no multi-user, no analytics, no settings sync, no SharePlay, no immersive 180/360 module. Add an `ImmersivePlayer` module later only if you actually want surround video. Use Media Optimizer/direct-download for offline instead of implementing Plex Sync first.

---

## 3. Sideloading on a FREE / Personal Apple ID — The Hard Truth

This is the make-or-break section. **Confirmed current as of June 2026:**

### What works
- Xcode + the visionOS SDK are **free** with any Apple ID. You can build and run on a real Vision Pro using a **Personal Team** (free provisioning) — no $99/yr account required.
- Device pairing: **Window > Devices and Simulators**, find the Vision Pro (over Wi-Fi/developer mode), pair it, then run from Xcode onto the headset.

### The constraints (do not sugarcoat these)
1. **7-day expiry.** Free-team provisioning profiles are valid **7 days** from creation (paid teams get ~1 year). After 7 days the app **refuses to launch** ("could not be verified") until you **rebuild and redeploy from Xcode**. This is a hard weekly chore for the life of the app.
2. **3-app limit.** A free Apple ID can have at most **3 sideloaded apps** active at once per device. Fine for one Plex client, but it's a ceiling.
3. **No paid entitlements.** No push notifications, no associated domains, no CarPlay, no app groups across an org, certain background modes restricted. For a Plex client this mostly costs you: **no remote/push features** — irrelevant here. Background download behavior is allowed but constrained (see §4).
4. **Mac tether for every refresh.** Re-signing requires the **headset reachable by the Mac running Xcode** (wired isn't an option on Vision Pro — it's wireless dev mode). So roughly **once a week** you must: open Xcode, connect the headset, hit Run, wait for the build to install. If you forget, the app is dead until you do.

### Can AltStore / SideStore rescue this on visionOS? — **No (as of June 2026).**
- **visionOS has no third-party sideloading ecosystem.** AltStore and SideStore target **iOS/iPadOS only**; neither advertises or supports visionOS. The on-device "auto-refresh over Wi-Fi" trick (which is how SideStore dodges the weekly Mac tether on iPhone) **is not available for Vision Pro.**
- The iOS-side mitigations you may have read about — **LiveContainer** (run many apps inside one signed container to beat the 3-app limit) and **SideStore's background refresh** — **do not apply to visionOS.**
- The **only** supported path to a Vision Pro is Apple's official Xcode deployment. So on visionOS you are stuck with the **raw free-provisioning rules: 7-day expiry, manual Mac-tethered refresh.**

### Bottom line
The app will work great when freshly installed, but **you will re-sign it from Xcode about every 7 days, with the headset connected to your Mac, indefinitely.** There is no visionOS equivalent of AltStore to automate this. If that weekly friction is unacceptable, the alternatives are (a) pay the **$99/yr** Apple Developer Program (profiles last ~1 year → re-sign yearly, and unlocks TestFlight), or (b) just use the existing App Store Plex/Infuse clients. **For a personal project the free path is viable but the re-signing tax is real and permanent.**

---

## 4. Offline Downloads on visionOS

visionOS is iOS-derived, so AVFoundation/URLSession storage behavior carries over.

### Where to store files
- Put downloaded media in **`Application Support/`** (`FileManager.default.url(for: .applicationSupportDirectory, …)`) or a subfolder of `Documents/` — both are **inside the app sandbox** and **backed by the OS but excluded from iCloud if you set `isExcludedFromBackup`** (you want to exclude large media). Use **Caches/** only if you're OK with the system purging it under storage pressure (not ideal for "saved" downloads).
- Create a `Downloads/` subdirectory, store one file per item, and keep a small metadata index (JSON/SQLite) mapping Plex ratingKey → local URL + state.

### How to download
- For a **single progressive file** (Plex can serve the original `Part.key` file, or a finished Media Optimizer MP4 version): use **`URLSession` with a background configuration** (`URLSessionConfiguration.background(withIdentifier:)`) and a download task → move the temp file into Application Support on completion. Background sessions let the download continue/resume if the app is backgrounded.
- For **HLS** content you'd otherwise use `AVAssetDownloadTask`/`AVAggregateAssetDownloadTask` to persist an HLS asset for offline AVPlayer playback. **Do not point this at Plex's live-style universal transcode playlist.** Simpler for a personal app: ask Plex Media Optimizer to produce a finished downloadable MP4 version and store that — avoids the FairPlay/HLS-offline complexity entirely. Plex media is not DRM-protected, so plain file download is fine.

### Playing a local file
Identical to remote playback — build an `AVPlayerItem` from the local file URL:
```swift
let item = AVPlayerItem(url: localFileURL)   // file:// in Application Support
player.replaceCurrentItem(with: item)
```
The Player module's `.local(URL)` source case feeds straight into the same `AVPlayer`.

### visionOS-specific storage notes
- **No special hard cap** beyond the device's free space; the Vision Pro ships with substantial storage but it's **not user-expandable**, so a few movies adds up — surface used-space in the UI and let the user delete downloads.
- Background **execution time is limited** like iOS; very large downloads may need the background `URLSession` (which the system manages) rather than relying on foreground time.
- Set **`URLFileProtection`** appropriately and **exclude downloads from backup** (`var rv = URLResourceValues(); rv.isExcludedFromBackup = true`).

---

## 5. Toolchain: Xcode / SDK / Deployment Target / SPM

### Versions (current, June 2026)
- **Xcode 26.5** ships Swift 6.3 and the **visionOS 26.5 SDK**; requires **macOS Tahoe 26.2+** on the build Mac.
- **Recommended minimum deployment target: visionOS 2.0** for broad device coverage, **or visionOS 26.0** if you want to use the newest player/immersive APIs (RealityKit `VideoPlayerComponent`, progressive immersive mode, comfort mitigation). For a personal app where you control the OS on your one headset, **targeting the latest (visionOS 26) is fine and simplest.**
- Build with the current SDK (Apple now mandates building against recent SDKs); you can still set a lower deployment target than the SDK.

### Plex networking dependency choice
- **Recommended:** no Plex SDK dependency for v1. Implement a thin hand-written `PlexAPI` over `URLSession` for PIN auth, `/api/v2/resources`, library browsing, the official/legacy transcode decision/start calls, timeline reporting, Media Optimizer, and direct `Part.key?download=1`.
- **`plexswift` status:** `https://github.com/LukeHagar/plexswift` is MIT but archived/unmaintained, generated, iOS-only in its manifest/docs, and weak around HLS transcoding/bitrate parameters. Keep it as a reference/model source only unless a build spike proves it compiles cleanly for visionOS and covers the exact endpoint you want.
- **Reference libraries:** prefer `python-plexapi` (BSD-3) for portable behavior and `plex-for-kodi` only as a GPL-2.0 behavioral reference to re-implement, not copy.

---

## Sources
- [Apple — Provisioning profile updates](https://developer.apple.com/help/account/provisioning-profiles/provisioning-profile-updates/)
- [myByways — New limitations on free Apple Developer account (7-day / 3-app)](https://mybyways.com/blog/new-limitations-imposed-on-free-apple-developer-account)
- [silisko — iOS Sideloading Complete Guide 2026](https://silisko.com/ios-sideloading-complete-guide-2026/)
- [Ken Harris — Sideloading on Any Apple Product (visionOS)](https://kenhv.com/blog/sideloading-on-any-apple-product)
- [MacRumors — visionOS needs sideloading](https://forums.macrumors.com/threads/visionos-needs-sideloading.2393957/)
- [iDownloadBlog — SideStore (AltStore fork)](https://www.idownloadblog.com/2024/07/08/sidestore/)
- [Apple Developer Forums — Connecting Xcode to a real Vision Pro](https://developer.apple.com/forums/thread/746464)
- [AppleInsider — Getting started with Apple Vision Pro developer software](https://appleinsider.com/articles/23/06/22/getting-started-with-apple-vision-pro-developer-software)
- [Apple — Set the scene with SwiftUI in visionOS (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/290/)
- [Apple — Creating an immersive space in visionOS](https://developer.apple.com/documentation/visionOS/creating-immersive-spaces-in-visionos-with-swiftui)
- [SwiftAnytime — Exploring visionOS app development with SwiftUI](https://www.swiftanytime.com/blog/exploring-visionos-app-development-with-swiftui)
- [Apple — Support immersive video playback in visionOS (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/296/)
- [Apple — Destination Video sample](https://developer.apple.com/documentation/visionos/destination-video)
- [Apple — visionOS 26 Release Notes](https://developer.apple.com/documentation/visionos-release-notes/visionos-26-release-notes)
- [GitHub — LukeHagar/plexswift](https://github.com/LukeHagar/plexswift)
