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

- [ ] Rework custom player menus as true small popover/submenu surfaces instead of one giant player-options panel.
- [ ] Make Chapters a horizontally scrollable tile submenu, closer to the previous Apple-sized submenu behavior.
- [ ] Keep Quality/Subtitles/Audio/Speed/Stats similarly compact; they should not require the giant box.
- [ ] Extract reusable menu/picker views out of `PlayerControlSurface.swift` into separate shared control files before expanding reuse further.
- [ ] Continue tuning bottom menu pill sizing; the current width tweak is subtle and may still be too small in-headset.

## Reconnect/retry worklist

- [ ] Keep the reconnecting overlay compact and centered, not stretched across the screen.
- [ ] Revisit the final-target rebuild budget after the custom scrubber stabilizes; rapid repeated releases currently trip the safety guardrail rather than a server exception.
- [ ] Surface retry failures explicitly without hiding repeated reopen attempts in a silent loop.
