# Issue #12 — RealityKit Theater First Slice

## Current truth after Wave 3

- Branch base for this slice: local `main` at `447b10e` (`Re-apply music redesign (#17/#22)
  onto the custom-player stack`). The branch was first reset to the requested Wave-3 base
  `dfed548`, then the uncommitted #12 edits were reapplied after local `main` advanced again.
- The shipping player is the app-owned custom player (`CustomPlayerView` / `CustomPlayerChrome`), not the deleted AVKit `AVPlayerViewController` path.
- `CustomCinemaMode.isUserVisible = false` hides the temporary custom-player Cinema button. That scaffold reused `AVPlayerLayer` inside a SwiftUI `ImmersiveSpace`; device testing showed it is not equivalent to Apple's system Cinema Environment and can pull the viewer out of a full Environment at 100% immersion.
- Therefore #12 must be a new RealityKit/immersive-theater path, not a quick re-enable of the hidden Wave-2 Cinema button.

## Mergeable slice implemented here

This slice creates a clean #12 boundary while keeping the product safe:

1. Add `RealityTheaterFeature` with a distinct immersive-space ID and a hard `isShippingEntryPointVisible = false` gate.
2. Add `RealityTheaterConfiguration` for screen width, distance, vertical offset, seat preset, and controls placement in meters.
3. Add `RealityTheaterSessionStore`, separate from `CustomCinemaSessionStore`, so future work can attach active playback and theater controls without coupling to Wave-2 player chrome.
4. Add `RealityTheaterPrototypeView`, a hidden `RealityView` scene with RealityKit screen, frame, controls, and seat anchors. It is a prototype layout scaffold only; it does not render video or expose a button.
5. Register the new hidden `ImmersiveSpace` in `PlexAVPApp` without adding any Settings toggle or player-chrome entry point.

## Explicit non-goals for this slice

- Do not flip `CustomCinemaMode.isUserVisible` back to `true`.
- Do not route `CustomPlayerChrome` to the new theater yet.
- Do not claim device-ready behavior from a simulator build.
- Do not reintroduce `AVPlayerViewController` / `AVExperienceController` to get system Cinema behavior.
- Do not add a public Settings toggle until device behavior is proven.

## Intended follow-up path

1. **Developer-only entry point:** add a local/test-only opener guarded by `RealityTheaterFeature.isDeveloperEntryPointEnabled` and prepare `RealityTheaterSessionStore` from the active `PlaybackController`.
2. **Video surface decision:** prove whether the custom player's `AVPlayer` can be safely presented on a RealityKit surface for normal 2D media, or whether #12 needs a separate playback presenter instead of sharing `AVPlayerLayer`.
3. **Controls:** bind screen width/distance/vertical offset/seat preset to a non-shipping control panel first; only promote controls once device ergonomics are acceptable.
4. **Device gates:** test from Windowed, Mixed, and 100% full Environment states; verify opening/closing does not strand an immersive space, pull the user unexpectedly, or regress normal custom-player playback.
5. **Shipping gate:** only after the above, consider a visible player-chrome affordance. Until then the current `CustomCinemaMode` button remains hidden.

## Manual device checks still required

- With a full Environment active at 100% immersion, opening the #12 prototype must not surprise-pull the viewer out of the chosen Environment without a deliberate design decision.
- Screen scale/distance must feel stable and comfortable across at least the front/center/back seat presets.
- Controls must be reachable without blocking the movie surface.
- Dismissal must return to the prior player state and leave no orphaned immersive space.
- Long playback, pause/resume, scrub, retry, and Close need real-device checks once video is wired into the RealityKit scene.

## Validation for this slice

- `xcodebuild -project PlexAVPApp.xcodeproj -scheme PlexAVPApp -destination 'generic/platform=visionOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO`
- `git diff --check`
- Confirm no visible player-chrome theater affordance was added and `CustomCinemaMode.isUserVisible` remains `false`.
## 2026-06-15 buildout update

- Added a DEBUG/developer-gated player chrome entry point (`Theater Lab`) behind
  `RealityTheaterFeature.developerDefaultsKey`; it remains hidden in normal/shipping UI.
- The entry point prepares `RealityTheaterSessionStore` from the active `PlaybackController`
  and opens the separate #12 immersive space.
- `RealityTheaterPrototypeView` now hosts a SwiftUI/AVPlayer attachment over the RealityKit
  screen placeholder, giving the next device pass a concrete video-surface proof path without
  re-enabling the old hidden `CustomCinemaMode` button.
- Validation: PMSKit tests, hygiene, and Vision Pro simulator build/run passed after rebasing
  on `origin/main` with downloads + URL-query hardening merged.


## 2026-06-15 Theater Lab tuning update

- Added an in-immersive DEBUG/developer Theater Lab panel for device testing:
  - screen width, distance, and vertical offset sliders in meters;
  - front/center/back seat presets;
  - below-screen vs seat-rail controls placement;
  - reset-to-defaults plus Apple-ish baseline buttons.
- The lab prints `[Theater Lab]` lines for open, close, preset, reset, and tuning changes so a device pass can correlate screenshots/notes with exact values.
- The active AVPlayer attachment path is preserved; tuning only moves/scales the RealityKit screen and markers around the existing SwiftUI `PlayerLayerView` attachment.
- Shipping gates remain unchanged: `RealityTheaterFeature.isShippingEntryPointVisible == false`, and `CustomCinemaMode.isUserVisible == false`.

## Practical Vision Pro device checklist for later today

1. **Enable only the developer entry point**
   - Launch a DEBUG build with `developerRealityKitTheaterEnabled=true` in app defaults.
   - Confirm the old Custom Cinema button is still absent and only the developer `Theater Lab` button appears.
2. **Open/close semantics**
   - Start normal custom-player playback, open Theater Lab, close with the in-lab `Close Lab` button, then reopen and close with `Exit Theater Lab` in chrome.
   - Verify playback continues after each open/close and no immersive space is orphaned.
3. **Environment/full-immersion comparison**
   - Repeat opening from Windowed, Mixed, and a 100% full Environment.
   - Record whether Theater Lab preserves, exits, or visually fights the current Environment; compare this behavior against Apple's AVKit Cinema default if available in a reference app.
4. **Apple-ish baseline comparison**
   - Test `Apple-ish default` first, then `Apple-ish large/back`, then manual width/distance/vertical tweaks.
   - For each comfortable value, capture the visible label and console `[Theater Lab]` line.
5. **Video surface playback notes**
   - While playing, pause/resume, scrub, skip ±10/30, and wait through at least one buffering/quality change if possible.
   - Watch for black frames, detached audio, or the attachment failing to resize with the screen.
6. **Controls reachability**
   - Compare `Below screen` vs `Seat rail` controls placement from front/center/back.
   - Record whether controls block subtitles, sit too low/high, or require uncomfortable reach.
7. **Reset instructions**
   - Press `Reset`; confirm values return to Apple-ish default (`4.8m`, `5.0m`, `0.25m`, center, below screen).
   - Close and reopen; confirm the reset/tuned values are understandable and no shipping-visible state changed.

## 2026-06-16 Vision Pro headset pass — black immersive custom-cinema findings

Context: this was tested on a physical Apple Vision Pro from the `issue/12-custom-realitykit-theater`
worktree after `main` had the Jellyfin merge. Testing used Plex playback, not Jellyfin. `devicectl`
can install/launch/capture console logs on this host/device pairing, but screenshot/screen-record
capabilities are not available, so visual feedback came from headset observation only.

### What worked / what is promising

- The cleanest visible direction so far is a **single active AVPlayer rendered as a RealityKit
  `VideoMaterial` plane in a full black `ImmersiveSpace`**. This avoids the worst artifact from
  earlier mixed-space attempts that placed a second black/window-like surface in front of the app.
- Explicitly dismissing the main SwiftUI `WindowGroup` after the immersive space opens removed the
  gray/windowed surface. Apple effectively requires another scene to be open before closing the
  current window, so the open-immersive-then-dismiss-window order is important.
- A large RealityKit video plane in a full black immersive scene is directionally acceptable to the
  product owner, even though it is not Apple's private/system AVKit Cinema Environment.
- Latest manually tested comfortable-ish direction: push the screen farther back and make it larger
  than the initial pass. The local WIP ended around `width=9.4m`, `distance=6.25m`; vertical offset
  was still being tuned upward because the viewer felt too high / looking down at the screen.

### What did not work / should not ship

- The old quick `CustomCinemaMode` button that only opened a SwiftUI/AVPlayerLayer immersive scene
  remains conceptually wrong; it does not reproduce Apple's AVKit Cinema default and can pull the
  viewer out of their current Environment.
- Reusing AVKit's actual Cinema Environment appears tied to `AVPlayerViewController`/system chrome;
  it is not viable for the current custom scrubber/menus without a separate system-player path.
- Rendering two concurrent player surfaces is a non-starter. Cinema must move ownership of the
  single active `AVPlayer`/renderer, not duplicate playback.
- The current experimental window-dismiss exit is **not final UX**. Because entering cinema dismisses
  the main app `WindowGroup`, reopening the window on exit can recreate the root UI and dump the user
  at Home. That is better than Crown-killing the app, but it is not acceptable as the product exit
  behavior.
- SwiftUI `RealityView` attachments for Exit controls were not reliably visible/reachable on device
  in the black immersive scene. Do not assume an attachment-based Exit affordance is sufficient until
  it is proven on hardware.

### Product requirements clarified during headset testing

- Entering Cinema should make the normal window disappear; no gray/content/detail/player window may
  remain in front of the theater surface.
- Exit Cinema should return to the same playback/detail context, not perform a full app reload and
  re-navigation from Home.
- The screen should be farther back, large, and raised enough that the viewer is not looking down at
  it from a “high seat” perspective.
- Cinema can be a true black immersive environment if that is the only public-API path to a clean
  non-artifacty custom-player theater.
- Headset testing is required for every meaningful placement/control iteration; simulator is not
  enough for #12.

### Next architecture to implement before the next headset pass

1. Introduce a persistent app-level `CinemaPlaybackSession` / coordinator that owns:
   - active `PlaybackController` / `AVPlayer`;
   - source item/title and selected media index;
   - current playback time and whether normal player should be restored after cinema;
   - original navigation/detail context where practical.
2. Stop using “dismiss main window then reopen root window” as the normal exit mechanism. If the
   window must be dismissed to hide gray UI, persist enough context to restore the same title/player
   immediately on reopen.
3. Make Exit a proven in-scene control:
   - prefer a high-contrast RealityKit-native target or a very large attachment anchored directly on
     the visible screen plane;
   - log when the exit target is added and tapped;
   - verify it can be seen and tapped from the headset before considering placement final.
4. Keep the old hidden developer lab and the black custom-cinema path clearly separated in code until
   one path is proven. Avoid merging a confusing mix of lab/prototype/product affordances.
5. Once the exit/restore path is stable, reintroduce richer controls incrementally: pause/play first,
   then scrubber, then quality/subs/audio/chapters/speed/stats.

### Useful device commands / evidence from this pass

- Device install/build worked with:
  - destination id `00008142-001018591A09401C`
  - CoreDevice id `73122E1D-7B2D-5EFD-AF40-F179D1978B5C`
  - `DEVELOPMENT_TEAM=SUAJSL8UG9 CODE_SIGN_STYLE=Automatic`
- Console launch pattern:
  - `xcrun devicectl -t 3600 device process launch --device 73122E1D-7B2D-5EFD-AF40-F179D1978B5C --terminate-existing --console com.jlipworth.VisionPlex`
- Representative log line from the best black immersive pass:
  - `[Custom Cinema] black immersive opened: width 9.4m · distance 6.25m · vertical 1.65m; title=The Phoenician Scheme; hasPlayer=true`
- `devicectl` screenshot/screen-record capabilities were unsupported on this host/device pairing, so
  do not plan tomorrow's device pass around automated screenshots unless the tooling changes.

### Merge guidance

Do not merge the current local cinema WIP into `main` as-is. The useful outputs from tonight are the
hardware findings and direction above. Tomorrow's non-headset work should continue from `main` and
other worktrees; #12 should resume only when headset testing is available again or when implementing
context-preserving architecture that can be reviewed without visual headset tuning.

## 2026-06-16 follow-up pass — placement improved, controls remain open

After rebasing the branch onto current `main`, the branch was built, installed, and launched on the
physical Apple Vision Pro again. The ignored local `Signing.local.xcconfig` had to be copied into
this worktree so `DEVELOPMENT_TEAM=SUAJSL8UG9` was applied for device signing.

### Placement / immersion adjustments made

- The visible custom-cinema path is still `CustomCinemaMode`, not the hidden RealityKit lab path.
  Earlier tuning accidentally changed only the RealityKit lab defaults; the headset test was using
  the custom-cinema scaffold.
- The custom-cinema screen was lowered substantially and pushed farther back:
  - `screenDistanceMeters = 7.0`
  - `verticalOffsetMeters = 0.65`
- The owner confirmed this placement is "much better" than the previous high placement.
- Both immersive spaces now request:
  - full immersion,
  - replacement immersive environment behavior,
  - dark immersive content brightness,
  - hidden upper-limb visibility.

### Controls direction clarified

Do **not** add an always-visible floating Exit button just to solve escape. It makes the theater feel
less immersive and is not the desired product direction.

Instead, the next controls slice should focus on an immersive-mode control model:

1. Controls are hidden by default while the viewer is watching.
2. A deliberate interaction reveals them temporarily, likely gaze/pinch/tap on the screen plane or a
   large invisible/low-distraction hit region near the screen.
3. Revealed controls should auto-hide after a short idle timeout.
4. The first revealed control set should be small and reliable:
   - Play/Pause,
   - Exit Cinema,
   - optionally ±10s after the reveal behavior is proven.
5. Controls should be anchored below the screen or near a seat rail, but not permanently over the
   movie image.
6. Exit must be reliable from inside the immersive space and should return to the prior playback
   context, not reload the app from Home.

### Open headset observations

- The hands/upper-limb hiding request needs retesting after applying `.upperLimbVisibility(.hidden)`
  to both immersive spaces. If real hands are still visible, investigate whether the currently opened
  scene path supports upper-limb hiding on this OS/version, or whether another system overlay / mixed
  immersion path is still active.
- Controls are still the major blocker for #12. The current minimal controls are not the final
  interaction model and should be treated as a debug scaffold only.
