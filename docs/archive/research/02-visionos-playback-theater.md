# visionOS Video Playback: The Theater Experience for a Plex Client

> **Archived research snapshot:** retained as dated evidence, not current architecture, feature
> status, or implementation guidance. Verify any reusable detail against the active docs and
> current source; old `VisionPlay` names, issue links, branches, and paths below are historical.

Research date: June 2026. Target: Apple Vision Pro, visionOS 2.x and visionOS 26 era APIs.
Scope: play a standard HLS (`.m3u8`) stream from a Plex transcode session on a giant
virtual cinema screen, with minimal custom code. We do **not** need true 180/360/MV-HEVC
immersive playback — the library is flat 2D plus some frame-packed 3D (SBS/TAB).

## TL;DR

- **Flat 2D HLS on a giant cinema screen is essentially free.** Drop an
  `AVPlayerViewController` in, give its `AVPlayer` your `.m3u8` URL, present it fullscreen,
  and the system handles the big-screen "Expanded"/docked cinema presentation, scrubbing,
  AirPods spatial audio, subtitle/audio menus, and docking into Apple's system environments
  with zero rendering work.
- **3D side-by-side / top-and-bottom is the hard part.** There is **no system affordance**
  for frame-packed 3D. The stock player and RealityKit's stereo path both want **MV-HEVC**,
  not a single flat frame you split yourself. To show SBS/TAB you must do custom rendering:
  RealityKit + `ShaderGraphMaterial` (Camera Index Switch node) + a per-frame texture feed
  from `AVPlayerItemVideoOutput` into `TextureResource.DrawableQueue`. Medium difficulty,
  well-trodden by community examples, but it means you give up the stock player UI for 3D.

---

## 1. AVPlayerViewController on visionOS — the stock cinema player

Reference: Apple, **"Adopting the system player interface in visionOS"** (AVKit)
<https://developer.apple.com/documentation/avkit/adopting-the-system-player-interface-in-visionos>.

### What you get for free

On visionOS, `AVPlayerViewController` is the recommended ("system player interface") way to
play video. You set its `player` to an `AVPlayer` and present the view controller. When the
player view controller is the **exclusive root view** of its window scene, the system
presents it in a full-screen mode automatically. This gives you:

- A large, well-placed virtual screen with the standard visionOS transport controls
  (play/pause, scrubber, skip, volume), AirPods/spatial-audio handling, and the
  audio/subtitle selection menu — all stock, no custom UI.
- Automatic **docking** behavior: when the user opens an immersive environment while a
  full-window video is playing, the system **docks** the video screen at a fixed, comfortable
  location in that environment and presents streamlined playback controls that detach and
  float a little closer to the user for easier interaction. This is the "cinema" experience —
  the screen becomes the theater screen.

### Experiences and the controller API

`AVPlayerViewController` exposes an **`experienceController`** of type
**`AVExperienceController`** (an AVKit class that "defines the set of possible video playback
experiences that its parent player view controller can switch between"). Key experiences:

- **Embedded** — video appears inline alongside your other app content (in a window).
- **Expanded** — the video screen appears alone, consuming the whole window scene. This is
  the full-screen cinema state and the one that participates in docking.
- **Docked** — the screen pinned into an immersive environment.
- (Plus multiview and spatial-video experiences in visionOS 2.)

You constrain available experiences via **`allowedExperiences`**, e.g.

```swift
controller.experienceController.allowedExperiences = .recommended(excluding: [.expanded])
```

Adding multiview as an allowed experience automatically surfaces a multiview button in the
player UI. To opt **out** of docking, simply keep the video in the **embedded** state.

### Version note (visionOS 26 / 2.6)

In the visionOS 26 era (WWDC25 session 296, below), the **Expanded** experience became
**configurable to drive an immersive/cinema presentation** — i.e., the same
`AVExperienceController` API is leveraged to transition the full-screen player into the
immersive environment. So the basic "make it big and cinematic" path is more turnkey than it
was at launch. Flag: `allowedExperiences` / immersive-expanded configurability are
visionOS-2+/26 APIs; guard with availability checks if you also target visionOS 1.

**Bottom line:** for flat 2D Plex content, AVPlayerViewController fullscreen + the system's
automatic docking IS the cinema experience, with effectively no custom code.

---

## 2. Cinema Environments and registering your own

visionOS ships roughly a dozen system **Environments** (the immersive backdrops in Control
Center / the Environments picker — Mount Hood, Joshua Tree, White Sands, the Moon, Haleakalā,
etc.), plus media-specific cinema spaces like the **Apple TV app's Cinema environment** and
the **IMAX app's auditorium**. When a full-window video is playing and the user enters one of
these, the system **docks** the screen into a sensible spot in that environment.

### How a video docks into an environment

References: WWDC24 **"Enhance the immersion of media viewing in custom environments"**
(session 10115) <https://developer.apple.com/videos/play/wwdc2024/10115/> and WWDC24
"Create custom environments for your immersive apps in visionOS" (session 10087).

A media app builds its viewing space as an **`ImmersiveSpace`** scene and uses AVKit's
player inside it. To control where the screen lands, you author a **Docking Region** in
**Reality Composer Pro**:

- **Custom Docking Region Component** — placed on an entity in your environment; defines a
  bounding region for the video with a **2.4:1** max aspect ratio. Properties include width
  (height auto-follows to keep aspect), position, and rotation. Videos wider than the max are
  scaled to fit. Recommendation: float it slightly above the ground like a real theater
  screen, and test scale/viewing angle on device to avoid neck strain.

You can further dress the room for immersion:

- **Media reflections** via Reality Composer Pro ShaderGraph nodes:
  **`Reflection_Specular`** (glossy surfaces; RealityKit computes the reflection from the
  docking-region location + ground texture coords) and **`Reflection_Diffuse`** (softer, for
  matte surfaces). These cast the moving image onto your floor/walls.
- **`VirtualEnvironmentProbeComponent`** — drives illumination/color variation in the room
  and can blend two pre-baked environment resources for progressive immersion.
- Passthrough/lighting controls: **`immersiveContentBrightness`** (tint the user's hands to
  match the room when "the lights dim") and **`surroundingsEffect`** (soften the edge between
  passthrough and the media space).
- **Reverb Component** (Reality Composer Pro) — presets like *Medium Room (Treated)*,
  *Outdoor*, *Very Large Room*; spatializes both authored and system sounds. Recommended even
  if you ship no custom audio.

### Registering your OWN environment in the system picker

To make your custom theater appear alongside Apple's environments in the **Immersive
Environment Picker** (the list users get when they go to dock), you **declare it with
metadata** and attach it to your video views with the SwiftUI **`.immersiveEnvironmentPicker`**
modifier. Required metadata per environment: a **title**, a **thumbnail image**, and the
**immersive space id** to open. Example shape from session 10115:

```swift
ContentView()
    .immersiveEnvironmentPicker {
        ForEach(viewModel.environmentItems) { item in
            Button(item.title, image: item.thumbnail) {
                Task { await openImmersiveSpace(id: item.id) }
            }
        }
    }
```

For SharePlay-synced environments there's **`AVGroupExperienceCoordinator`** /
`groupExperienceCoordinator` plus `playbackCoordinator` (out of scope for a personal client,
but noted).

### visionOS 26 follow-up

WWDC25 **"Support immersive video playback in visionOS apps"** (session 296)
<https://developer.apple.com/videos/play/wwdc2025/296/> extends AVKit/RealityKit/Quick Look to
the new immersive **profiles** (Apple Projected Media Profile — 180/360/wide-FOV — and Apple
Immersive Video) and makes the **Expanded** player experience configurable for immersive
playback. For our flat + frame-packed-3D library this is mostly informational; the custom
**environment + docking** authoring workflow from WWDC24 is the load-bearing part.

**Difficulty:** Using Apple's stock environments = free. Authoring one custom cinema
environment (Reality Composer Pro: a room model + Docking Region + optional reflections/reverb)
+ registering it with `.immersiveEnvironmentPicker` = a moderate, mostly-Reality-Composer-Pro
task, no real graphics programming.

---

## 3. Playing the Plex HLS (`.m3u8`) URL

References: AVFoundation Media Selection (subtitles/audio), Plex URL commands
<https://support.plex.tv/articles/201638786-plex-media-server-url-commands/>, Apple Developer
Forums on AVURLAsset headers <https://developer.apple.com/forums/thread/671139>.

### Straightforward? Mostly yes.

HLS is AVFoundation's native streaming format. A Plex transcode session hands you a
`start.m3u8` → `index.m3u8` → `.ts`/fMP4 segment chain. Playing it is the canonical case:

```swift
let player = AVPlayer(url: URL(string: "https://server:32400/.../start.m3u8?X-Plex-Token=...")!)
controller.player = player
```

### Gotchas

- **Auth — prefer the query string.** Plex authenticates with **`X-Plex-Token`**, which it
  accepts as a **URL query parameter**. This is the path of least resistance: bake the token
  into the `.m3u8` URL and AVPlayer carries it through to playlist and segment requests with
  no special handling. **Avoid custom HTTP auth headers.** The header-injection option key
  (`AVURLAssetHTTPHeaderFieldsKey`) is **undocumented/unsupported**, may draw App Store
  rejection, and — critically — does **not reliably propagate to HLS media-segment requests**.
  The only robust header-based approaches are an `AVAssetResourceLoaderDelegate` (which can
  intercept playlists but struggles to add auth headers to segments) or an on-device reverse
  proxy — both far more work than just using the token query param. For a personal client,
  use the token in the query string. (Plex also lets you allow-list a LAN IP to skip auth on
  the local network.)
- **HTTPS / ATS.** App Transport Security wants HTTPS. Plex servers commonly use a
  `*.plex.direct` hostname with a valid cert specifically to satisfy this; point at that
  rather than a bare `http://ip:32400` to avoid ATS exceptions.
- **Subtitles & audio tracks** come for free *if Plex muxes them into the HLS master
  playlist*. AVKit renders the stock language/subtitle menu automatically from
  `AVMediaSelectionGroup` / `AVMediaSelectionOption`. To drive selection in code, query the
  asset for groups via the **`.legible`** (subtitles, `AVMediaCharacteristicLegible`) and
  **`.audible`** (audio, `AVMediaCharacteristicAudible`) characteristics and call
  `AVPlayerItem.select(_:in:)` (`-selectMediaOption:inMediaSelectionGroup:`). Caveat: if Plex
  is doing the transcode it often **burns in** or pre-selects a single subtitle/audio track,
  so the in-stream choices may be limited — track selection is then a Plex-server request
  decision (you ask Plex to start a session with a given audio/subtitle stream), not an
  AVPlayer-side switch. Decide track selection by re-requesting the transcode when feasible.
- **Seeking** in a live transcode works but depends on Plex's transcode/segment availability;
  standard `AVPlayer.seek` applies.

---

## 4. 3D movies: Side-by-Side (SBS) and Top-and-Bottom (TAB)

This is the genuinely hard requirement. SBS/TAB files are **standard-codec** (H.264/HEVC)
where each decoded frame contains both eyes packed left/right or top/bottom; the client must
split each frame and route halves to the correct eye.

### Is there a system affordance? No.

- **`AVPlayerViewController` / AVPlayer has no SBS or TAB mode.** It treats the file as one
  flat 2D video and would display the squashed double-image on the screen. There is no system
  picker option to say "this is side-by-side, please un-pack it."
- **RealityKit's stereo path wants MV-HEVC, not frame-packed.** `VideoPlayerComponent`
  (and `VideoMaterial`) support stereo via `desiredViewingMode` / `viewingMode` `.stereo`
  vs `.mono`, and visionOS 26 adds 180/360/wide-FOV/Apple Immersive modes (portal /
  progressive / full). **But the stereo input it expects is MV-HEVC** (or spatial video), where
  the two eyes are carried as separate encoded layers. Pointing the stereo viewing mode at a
  **frame-packed SBS/TAB** asset does **not** produce a stereo effect — Apple's own guidance is
  to **convert frame-packed material to MV-HEVC** instead. (Ref: RealityKit "Rendering
  stereoscopic video with RealityKit"; Apple Developer Forums thread 760761.)

So you have two viable strategies:

**Option A — Transcode/convert to MV-HEVC, then use the system path.** If you (or a tool on
the Plex side) re-encode SBS/TAB into MV-HEVC, then `VideoPlayerComponent` with `.stereo`
renders it natively, and you could even ride the stock immersive/spatial pipeline. Downside:
MV-HEVC re-encoding of an arbitrary library is heavy/offline; not something AVPlayer does live.
For a personal client this is a "pre-process the few 3D titles" play, not a runtime one.

**Option B — Render SBS/TAB yourself in RealityKit (runtime split).** Keep using `AVPlayer`
just as a decoder/clock, but draw the video onto your own screen entity with a custom shader
that crops each eye. This is the established community technique (e.g. KhaosT's
`RealityKitSideBySideRenderExample`, halmueller's `ShaderGraphStereo`). Concretely:

1. Create an `AVPlayer` + **`AVPlayerItemVideoOutput`** to pull decoded `CVPixelBuffer`s
   per frame.
2. Push those frames into a **`TextureResource.DrawableQueue`** so RealityKit gets a live
   updating texture.
3. Apply a **`ShaderGraphMaterial`** authored in Reality Composer Pro that uses the
   **Camera Index Switch** ShaderGraph node: it samples the **left half** of the texture for
   the left-eye camera and the **right half** for the right-eye camera (for TAB, sample
   top/bottom instead — i.e. adjust the UV crop). This routes the correct half to each eye.
4. Put that material on a large quad/plane entity sized like a cinema screen, inside your
   `ImmersiveSpace` / `RealityView`.

### Difficulty assessment

- **Medium.** It's not research-grade, but it's real graphics plumbing: a per-frame
  pixel-buffer pump, a DrawableQueue, a hand-authored ShaderGraph, and UV math for
  SBS-vs-TAB-vs-full/half-width variants. Reference implementations exist and can be adapted.
- **You lose the stock player UI in 3D mode.** Once you're drawing into a RealityKit entity,
  the nice AVPlayerViewController transport bar, subtitle menu, and automatic docking are
  gone — you must build your own controls (or overlay a SwiftUI control panel) and place the
  screen yourself. You *can* still author the surrounding cinema environment + reflections the
  same way.
- **Aspect/packing detection is on you.** Plex/your metadata must tell the app "this title is
  half-SBS / full-SBS / half-TAB" so you pick the right crop and horizontal-stretch factor.

**Recommendation for this project:** Two code paths. Flat 2D → `AVPlayerViewController`
(free, great). 3D SBS/TAB → custom `RealityView` + `ShaderGraphMaterial` Camera-Index-Switch
renderer (Option B) as a self-contained "3D player" mode; optionally pre-convert the handful
of 3D titles to MV-HEVC (Option A) if you'd rather keep them on the system stereo path.

---

## 5. Free vs custom — the dividing line

| Capability | Stock `AVPlayerViewController` (free) | Needs custom RealityKit / shader work |
|---|---|---|
| Play flat 2D HLS `.m3u8` | Yes | — |
| Giant cinema screen + transport UI | Yes (Expanded/full-screen) | — |
| Dock into Apple system environments | Yes (automatic) | — |
| Subtitle / audio track menu | Yes (from `AVMediaSelectionGroup`) | — |
| Spatial audio, scrubbing, AirPods | Yes | — |
| Use a **custom** cinema environment | Reality Composer Pro authoring + `.immersiveEnvironmentPicker` (no graphics code) | — |
| MV-HEVC / spatial / 180-360 stereo | `VideoPlayerComponent` `.stereo` (visionOS 26) | — |
| **Frame-packed SBS / TAB 3D** | **No** | **Yes** — `AVPlayerItemVideoOutput` → `TextureResource.DrawableQueue` → `ShaderGraphMaterial` (Camera Index Switch), custom controls |
| Custom screen placement/geometry beyond docking region | — | Yes (RealityKit entity) |

We explicitly do **not** need true 180/360/MV-HEVC immersive playback, so the only thing
pushing us off the free path is **frame-packed 3D SBS/TAB**.

---

## Sources

- [Adopting the system player interface in visionOS — Apple AVKit docs](https://developer.apple.com/documentation/avkit/adopting-the-system-player-interface-in-visionos)
- [AVExperienceController — Apple AVKit docs](https://developer.apple.com/documentation/avkit/avexperiencecontroller)
- [AVPlayerViewController — Apple AVKit docs](https://developer.apple.com/documentation/avkit/avplayerviewcontroller)
- [WWDC24 Session 10115 — Enhance the immersion of media viewing in custom environments](https://developer.apple.com/videos/play/wwdc2024/10115/)
- [WWDCNotes — Session 10115 notes](https://wwdcnotes.com/documentation/wwdcnotes/wwdc24-10115-enhance-the-immersion-of-media-viewing-in-custom-environments/)
- [WWDC24 Session 10087 — Create custom environments for your immersive apps in visionOS](https://developer.apple.com/videos/play/wwdc2024/10087/)
- [WWDC25 Session 296 — Support immersive video playback in visionOS apps](https://developer.apple.com/videos/play/wwdc2025/296/)
- [VideoPlayerComponent — Apple RealityKit docs](https://developer.apple.com/documentation/realitykit/videoplayercomponent)
- [Rendering stereoscopic video with RealityKit — Apple docs](https://developer.apple.com/documentation/realitykit/rendering-stereoscopic-video-with-realitykit)
- [KhaosT/RealityKitSideBySideRenderExample (GitHub)](https://github.com/KhaosT/RealityKitSideBySideRenderExample)
- [halmueller/ShaderGraphStereo — Camera Index Switch ShaderGraphNode (GitHub)](https://github.com/halmueller/ShaderGraphStereo)
- [Apple Developer Forums — VideoMaterial to display SBS Stereo (thread 760761)](https://developer.apple.com/forums/thread/760761)
- [Apple Developer Forums — Adding HTTP headers to an AVURLAsset (thread 671139)](https://developer.apple.com/forums/thread/671139)
- [Plex Media Server URL Commands / X-Plex-Token — Plex Support](https://support.plex.tv/articles/201638786-plex-media-server-url-commands/)
