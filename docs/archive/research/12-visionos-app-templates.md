# 12 — visionOS App Templates & Reference Projects

> **Archived research snapshot:** retained as dated evidence, not current architecture, feature
> status, or implementation guidance. Verify any reusable detail against the active docs and
> current source; old `VisionPlay` names, issue links, branches, and paths below are historical.

**Purpose:** Find the best *real, runnable* reference projects to use as a structural template for our personal-use visionOS Plex client (SwiftUI + AVKit playback, a cinema/big-screen environment, a floating browse window).

**Date:** June 2026
**Method:** Web search + GitHub (raw README/LICENSE inspection) + Apple developer docs/WWDC.
**Scope of our app — 6 modules:** AppState / PlexAuth / PlexAPI / Player / DownloadManager / LibraryUI.

> Legend: **★ Directly templatable** = clone, strip, and reshape into our project. **○ Inspiration only** = read for patterns; don't fork wholesale.

---

## TL;DR ranking

| # | Reference | Type | License | Verdict |
|---|-----------|------|---------|---------|
| 1 | **Apple — Destination Video** | Official sample | Apple Sample Code License (permissive) | ★ Primary template |
| 2 | **Apple — Playing immersive media with AVKit** (visionOS 26) | Official sample | Apple Sample Code License | ★ Player-layer template |
| 3 | **Apple — Adopting the system player interface in visionOS** | Official doc + snippet | Apple Sample Code License | ★ Player baseline |
| 4 | **acuteimmersive/OpenImmersive** (+ openimmersivelib) | OSS app + SPM lib | MIT | ★ for player module / ○ for app shell |
| 5 | **Apple — Building an immersive media viewing experience** | Official sample | Apple Sample Code License | ○ Environment immersion |
| 6 | **jellyfin/Swiftfin** | OSS media client | MPL-2.0 | ○ Architecture only (no visionOS target) |
| 7 | Theater / Aurora / Plexi (Plex VP clients) | Closed-source apps | Proprietary | ✗ Not available — teardown only |

---

## 1. Apple's official samples (highest value)

Apple sample code ships under the **Apple Sample Code License** (https://developer.apple.com/support/downloads/terms/apple-sample-code/Apple-Sample-Code-License.pdf). It is permissive and MIT-like: you may *use, reproduce, modify, and redistribute in source and/or binary form, with or without modifications.* Two practical conditions: (a) retain the license notice if you redistribute the sample **unmodified and in its entirety**; (b) **do not use Apple's name/trademarks/logos** to endorse or promote derived products. For a personal app this is effectively unrestricted — you can lift architecture and code freely.

### 1a. ★ Destination Video — THE primary template
- **Docs:** https://developer.apple.com/documentation/visionos/destination-video
- **What it is:** Apple's flagship multiplatform (visionOS / iOS / tvOS) **media-streaming** sample. A library/browse UI on a 2D window, full-feature `AVPlayerViewController` playback, and docking into a custom immersive environment built in Reality Composer Pro.
- **Frameworks:** SwiftUI (`WindowGroup` + `ImmersiveSpace`), **AVKit** (`AVPlayerViewController` / `AVPlayer`), **RealityKit** + **Reality Composer Pro** for the Studio environment, GroupActivities (SharePlay).
- **What it teaches that maps 1:1 to us:**
  - **Player presentation (→ our Player module):** the canonical `AVPlayerViewController` wrapped for SwiftUI, full-window expansion, and the *dock-into-environment* flow (video fades out of expanded view, fades back in docked inside the custom studio).
  - **Custom cinema environment (→ our big-screen/theater env):** a **custom Docking Region** authored in Reality Composer Pro (2.4:1 bounding box that scales the video like a theater screen), **light spill** onto passthrough (`immersiveContentBrightness`, `surroundingsEffect`), a **Virtual Environment Probe** with two pre-baked Environment Resources and a blend factor for smooth dark↔light Studio transitions, and **media reflections** to ground the screen in the room.
  - **Browse / profile UI (→ our LibraryUI module):** a content-model-driven catalog window (video library, detail views, "up next") with an `@Observable` model object passed through the environment — exactly the shape our LibraryUI + AppState need.
  - **Scene structure (→ our AppState):** `WindowGroup` (browse) + `ImmersiveSpace` (cinema) coordinated through `openImmersiveSpace`/`dismissImmersiveSpace` and a shared observable app model.
- **WWDC backing:** "Enhance the immersion of media viewing in custom environments" (WWDC24, session 10115, https://developer.apple.com/videos/play/wwdc2024/10115/) walks through this exact sample's docking region, light spill, environment probe, and dark/light variants.
- **Gotchas / notes:**
  - It's multiplatform; you'll **strip the iOS/tvOS targets** and keep the visionOS app + RealityKitContent package.
  - The Studio environment is bespoke RCP content — reuse it as scaffolding, but our "cinema" look will need its own RCP scene (or reuse the docking-region pattern).
  - Its content model is hardcoded JSON (a curated catalog). We replace that data source with our **PlexAPI** module; the *view/model wiring* is what we keep, not the data.
  - Sample tracks the latest SDK — pull the current version (visionOS 2.x/26 era) so the environment/probe APIs match.

### 1b. ★ Playing immersive media with AVKit (visionOS 26)
- **Docs/sample:** https://developer.apple.com/documentation/avkit/playing-immersive-media-with-avkit
- **What it teaches:** the **`AVExperienceController`** API (new in visionOS 26) — defines the set of playback experiences a player view controller can switch between: **Expanded** and **Immersive**, with delegate methods and the option to disable automatic transitions and explicitly drive the immersive transition.
- **Maps to us:** if we ever play spatial/immersive content from Plex, this is the transition controller. For ordinary 2D movies it's optional, but it's the right home for "expand to cinema" semantics.
- **WWDC backing:** "Support immersive video playback in visionOS apps" (WWDC25, session 296, https://developer.apple.com/videos/play/wwdc2025/296/).
- **Gotcha:** visionOS 26+ only. Don't make it a hard dependency for baseline 2D playback.

### 1c. ★ Adopting the system player interface in visionOS
- **Docs:** https://developer.apple.com/documentation/avkit/adopting-the-system-player-interface-in-visionos
- **What it teaches:** the minimal, correct way to present `AVPlayerViewController` on visionOS so you inherit the native transport UI, scrubbing, audio/subtitle pickers, 3D/spatial handling, and (per the multiview doc) multiview — for free.
- **Maps to us:** the **baseline Player module.** Start here, then layer Destination Video's docking on top. Strongly prefer this over a hand-rolled RealityKit `VideoMaterial` player for standard movies/TV — you get the system chrome and accessibility automatically.
- **Related:** "Creating a multiview video playback experience in visionOS" (https://developer.apple.com/documentation/avkit/creating-a-multiview-video-playback-experience-in-visionos) and WWDC23 "Create a great spatial playback experience" (https://developer.apple.com/videos/play/wwdc2023/10070/).

### 1d. ○ Building an immersive media viewing experience
- **Docs:** https://developer.apple.com/documentation/visionOS/building-an-immersive-media-viewing-experience
- **What it teaches:** adding immersion to playback via RealityKit/Reality Composer Pro, and the **`.immersiveEnvironmentPicker`** SwiftUI modifier — lets the audience pick a custom environment from the player's dock menu (declared with title/thumbnail metadata).
- **Maps to us:** the picker is how we'd offer "Cinema / Theater / Default" environment choices from inside the player. Inspiration-grade; overlaps heavily with Destination Video.

---

## 2. Open-source visionOS video / media apps

### 2a. ★/○ OpenImmersive — `acuteimmersive/openimmersive`
- **App repo:** https://github.com/acuteimmersive/openimmersive
- **Library repo (SPM):** https://github.com/acuteimmersive/openimmersivelib
- **License:** **MIT** (confirmed in repo `LICENSE`, "Copyright (c) 2024 Acute").
- **Maintained:** yes — actively developed (1.5+ releases), on the visionOS App Store, requires **Xcode 26 / visionOS 26**. Derived from Mike Swanson's open-source Spatial Player (https://github.com/mikeswanson/SpatialPlayer).
- **What it is:** a complete, deliberately *concise* immersive/spatial video player. Two pieces: **OpenImmersiveApp** (the visionOS app shell) and **OpenImmersiveLib** (a drop-in Swift package: player view, playback controls, HLS + local loading, resolution/audio-track selection, custom UI panels).
- **What to borrow:**
  - **Player module (★):** real, readable code for an auto-dismissing control panel, an interactable scrubber, ±15s buttons, HLS bandwidth/resolution selection, and audio-track switching — all of which we need on top of (or instead of) the system player for transcoded Plex HLS streams. The lib is literally `import OpenImmersive` and go.
  - **App shell (○):** loading a video from multiple sources (gallery/files/URL/drag) is a clean reference for our "play this Plex item" entry points.
- **Gotchas:**
  - Its core strength is **MV-HEVC / spatial / immersive** formats (SBS, Over-Under, AIVU). Our primary case is *flat* movies/TV via Plex HLS — so we use it for the *control/streaming plumbing*, not the spatial-format machinery.
  - No auth, no library browser, no download manager — it's a player, not an app framework. Pair it with Destination Video's app/browse structure.
  - Desired-but-missing per their README: subtitles, SharePlay — note these gaps for our own roadmap.

### 2b. Plex visionOS clients — **all closed-source (confirmed)**
Prior research said no OSS Plex VP client exists; **confirmed June 2026:**
- **Theater** (Sandwich Vision, App Store, launched June 2024) — proprietary.
- **Aurora for Plex** (cleanplate.studio, https://apps.apple.com/us/app/aurora-for-plex/id6547867554) — proprietary.
- **Plexi** (OPE Byte Sized Engineering, https://apps.apple.com/us/app/plexi/id6544807707) — proprietary.
None publish source. These are **competitive-teardown / UX references only** (see research file 04), not templates.

### 2c. Jellyfin / Emby clients
- **Swiftfin** — https://github.com/jellyfin/Swiftfin — **MPL-2.0**. **iOS 16+ and tvOS 17+ only; no visionOS target** (confirmed; issue #1532 is cosmetic "circular design," not a native target). It *can* run on Vision Pro via **"Designed for iPad" compatibility mode**, but that yields an iPad-in-a-window, not a native spatial app — useless as a structural template for our cinema/immersive goals. Value: ○ **architecture inspiration only** — large, mature SwiftUI media client (libraries, server auth, VLCKit direct-play, settings). Note MPL-2.0 is file-level copyleft: copying whole Swiftfin *files* into our app obligates us to keep those files under MPL-2.0 — fine for personal use, but prefer learning over lifting.
- No open-source **native visionOS** Jellyfin/Emby client found.

---

## 3. General visionOS architecture templates

- **vinothvino42/visionOS-Projects** — https://github.com/vinothvino42/visionOS-Projects — curated SwiftUI + RealityKit + ARKit sample collection; good for window/immersive-space idioms. ○
- **tomkrikorian/awesome-visionOS** — https://github.com/tomkrikorian/awesome-visionOS — the index to start from for any visionOS resource. ○
- **tracyhenry-visionOS/GenerativeDoodleArt_VisionOS** — https://github.com/tracyhenry-visionOS/GenerativeDoodleArt_VisionOS — compact app that cleanly demonstrates `WindowGroup` + `ImmersiveSpace` scene declaration and an `@Observable` view model injected via `@State`/environment — the exact modern pattern for our AppState. ○
- **Pattern consensus (maps to our 6 modules):**
  - **AppState** → root `@Observable` model created with `@State` at the `App` level, injected via `.environment()`; owns scene phase + which immersive space is open.
  - **PlexAuth / PlexAPI / DownloadManager** → plain `@Observable` services injected the same way (no third-party DI needed; skip Swiftfin's Stinsen-style coordinators).
  - **Player** → `AVPlayerViewController` (system interface) wrapped via `UIViewControllerRepresentable`, optionally swapped for OpenImmersiveLib's player.
  - **LibraryUI** → `WindowGroup` browse window + detail views bound to PlexAPI; cinema playback lives in a separate `ImmersiveSpace`.

---

## 4. What our Xcode project borrows from the top references

### From **Destination Video** (skeleton — ★ primary)
```
Borrow the whole project shape:
  App entry      → WindowGroup(browse) + ImmersiveSpace(cinema) + @Observable app model in environment
  LibraryUI      → catalog grid / detail / "up next" view structure (re-point data source to PlexAPI)
  Player module  → AVPlayerViewController wrapper + dock-into-environment fade flow
  Cinema env     → RealityKitContent package: custom Docking Region (2.4:1), env probe, light spill,
                   reflections  → reskin into our "theater" instead of Apple's Studio
Discard: iOS/tvOS targets, hardcoded JSON catalog, SharePlay (optional later)
```

### From **OpenImmersiveLib** (player internals — ★)
```
Add as SPM dependency OR copy the control-panel/scrubber/HLS code:
  Player module  → auto-dismiss controls, scrubber, ±15s, HLS resolution+bandwidth picker,
                   audio-track switcher  → drive these against Plex transcode/HLS URLs
Discard: spatial-format (MV-HEVC/SBS/OU) machinery unless we add spatial content later
```

### From **"Adopting the system player interface" + "Playing immersive media with AVKit"** (player baseline — ★)
```
Player module  → start from system AVPlayerViewController (free transport UI, subtitles, multiview)
               → add AVExperienceController (visionOS 26+) for Expanded↔Immersive "expand to cinema"
               → gate AVExperienceController behind availability; keep 2D playback as the baseline
```

### From **Swiftfin** (architecture cross-check — ○)
```
Read for: server connection/auth state machine, library pagination, settings model,
          direct-play vs transcode decisioning.  Learn, don't lift (MPL-2.0 file-level copyleft).
```

---

## Sources
- Destination Video — https://developer.apple.com/documentation/visionos/destination-video
- WWDC24 10115 (custom environments / Destination Video) — https://developer.apple.com/videos/play/wwdc2024/10115/
- Adopting the system player interface in visionOS — https://developer.apple.com/documentation/avkit/adopting-the-system-player-interface-in-visionos
- Playing immersive media with AVKit — https://developer.apple.com/documentation/avkit/playing-immersive-media-with-avkit
- WWDC25 296 (immersive video playback) — https://developer.apple.com/videos/play/wwdc2025/296/
- Building an immersive media viewing experience — https://developer.apple.com/documentation/visionOS/building-an-immersive-media-viewing-experience
- Creating a multiview video playback experience — https://developer.apple.com/documentation/avkit/creating-a-multiview-video-playback-experience-in-visionos
- WWDC23 10070 (spatial playback) — https://developer.apple.com/videos/play/wwdc2023/10070/
- Apple Sample Code License — https://developer.apple.com/support/downloads/terms/apple-sample-code/Apple-Sample-Code-License.pdf
- OpenImmersive (app) — https://github.com/acuteimmersive/openimmersive
- OpenImmersiveLib (SPM, MIT) — https://github.com/acuteimmersive/openimmersivelib
- Spatial Player (origin) — https://github.com/mikeswanson/SpatialPlayer
- Swiftfin (MPL-2.0, iOS/tvOS only) — https://github.com/jellyfin/Swiftfin
- Making your app compatible with visionOS (Designed for iPad) — https://developer.apple.com/documentation/visionos/making-your-app-compatible-with-visionos/
- awesome-visionOS — https://github.com/tomkrikorian/awesome-visionOS
- visionOS-Projects — https://github.com/vinothvino42/visionOS-Projects
- GenerativeDoodleArt_VisionOS — https://github.com/tracyhenry-visionOS/GenerativeDoodleArt_VisionOS
- Aurora for Plex (proprietary) — https://apps.apple.com/us/app/aurora-for-plex/id6547867554
- Plexi (proprietary) — https://apps.apple.com/us/app/plexi/id6544807707
