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
