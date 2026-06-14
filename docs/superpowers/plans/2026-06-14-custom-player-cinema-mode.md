# Custom Player Cinema Mode Plan

> **For agentic workers:** keep this aligned with GitHub issue #38 and the Jellyfin handoff. This is not a proxy/playlist/segment-interception project.

## Current truth

- The default AVKit player still gets Apple's Cinema Environment through `AVPlayerViewController.experienceController`.
- The experimental custom player is `AVPlayerLayer` + SwiftUI chrome. It does **not** yet have a working Cinema Mode.
- The branch now registers a first-pass `ImmersiveSpace` / `RealityView` shell at `custom-player-cinema` so the custom path can grow a native visionOS theater scene without reviving the old window -> fullscreen -> cinema animation hack.

## Direction

Use as many Apple parts as possible while keeping the playback backend neutral:

1. Keep `CustomPlayerView` UI-only and backend-neutral through `controllerFactory`.
2. Introduce a small shared custom playback session that owns the active `PlaybackController`, title, scrubber state, and on-close hooks.
3. Render the same active `AVPlayer` in the Cinema scene using visionOS scene primitives (`ImmersiveSpace`, `RealityView`, and a RealityKit video surface if the SDK path works cleanly).
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
- [ ] Surface retry failures explicitly without hiding repeated reopen attempts in a silent loop.
