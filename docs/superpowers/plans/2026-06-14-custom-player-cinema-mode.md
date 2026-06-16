# Custom Player Cinema Mode Plan

> **For agentic workers:** keep this aligned with GitHub issue #38 and the Jellyfin handoff. This is not a proxy/playlist/segment-interception project.

## Current truth

- The AVKit `AVPlayerViewController` path has been deleted; the custom player is now the only
  player (`AVPlayerLayer` + SwiftUI chrome).
- The temporary custom Cinema Mode path still exists as a scaffold: the active custom-player
  session publishes its title and `AVPlayer` into `CustomCinemaSessionStore`, and the registered
  `ImmersiveSpace` can render that same player on a theater-style surface.
- Device testing showed that scaffold is not equivalent to Apple's AVKit Cinema Environment, so
  `CustomCinemaMode.isUserVisible = false` hides the button from shipping chrome. Issue #12 now
  owns the proper RealityKit theater path; see `2026-06-15-issue12-realitykit-theater.md`.

## Direction

Use as many Apple parts as possible while keeping the playback backend neutral:

1. Keep `CustomPlayerView` UI-only and backend-neutral through `controllerFactory`.
2. Introduce a small shared custom playback session/store that exposes the active title and `AVPlayer` to the Cinema scene while `CustomPlayerView` still owns the backend-neutral controller factory.
3. Render the same active `AVPlayer` in the Cinema scene using visionOS scene primitives (`ImmersiveSpace`) and the app-owned `AVPlayerLayer` presenter. RealityKit video-surface work can be revisited later, but the testable path now uses the same player instance instead of a placeholder.
4. Keep scrub commits routed through `PlaybackController.performUserSeek(toMs:)`.
5. Keep Plex final-target rebuild behavior in the Plex controller implementation; Jellyfin will later provide a controller factory using `PlaybackInfo(StartTimeTicks)` / remote stream reopen.
6. Do not add a local proxy, playlist rewriting, or segment interception.

## UI worklist from simulator feedback

- [x] Rework custom player menus as true small popover/submenu surfaces instead of one giant player-options panel.
- [x] Make Chapters a horizontally scrollable tile submenu, closer to the previous Apple-sized submenu behavior.
- [x] Keep Quality/Subtitles/Audio/Speed/Stats similarly compact; they should not require the giant box.
- [x] Extract reusable menu/picker views out of `PlayerControlSurface.swift` into separate shared control files before expanding reuse further.
- [x] Continue tuning bottom menu pill sizing; menu buttons now use regular control sizing and larger labels/min widths.

## Reconnect/retry worklist

- [x] Keep the reconnecting overlay compact and centered, not stretched across the screen.
- [x] Revisit the final-target rebuild budget after the custom scrubber stabilizes; default final-target policy now allows five committed rebuilds per minute before escalating.
- [x] Surface retry failures explicitly without hiding repeated reopen attempts in a silent loop; Retry is explicit user intent, and failed retry/rebuild/stall paths return to `surfaceFailure(...)` / Retry+Close UI.


## Cinema follow-up note

Apple's polished Cinema Environment was available only through the old `AVPlayerViewController`
path. The custom player intentionally uses `AVPlayerLayer` so it can own chrome and scrubber
behavior; directly reusing `AVExperienceController` would mean re-entering the deleted AVKit
player path. The current custom Cinema scaffold therefore uses a visionOS `ImmersiveSpace` plus
the same active `AVPlayer` and custom scrubber/chrome, but it remains hidden because hardware
testing showed poor full-Environment behavior. Future visible theater work should happen through
the separate #12 RealityKit scaffold instead of re-exposing this button.
