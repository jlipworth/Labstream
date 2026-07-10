# macOS #228 validation plan

> **Archived:** issue-era validation split. Current preview validation guidance lives in
> [`docs/MACOS.md`](../../MACOS.md) and [`docs/TESTING-STRATEGY.md`](../../TESTING-STRATEGY.md).

This document splits the #228 validation matrix into checks an agent can run without user interaction and checks that require a real signed-in Mac session, subjective UI review, or real media-server/download behavior.

## Agent-runnable validation

Run:

```sh
scripts/validate-macos-228.sh
```

This performs:

- `git diff --check`
- conflict-marker scan across source/docs/scripts/config
- Mac app icon asset slot/file/dimension validation
- Mac identity wiring static checks for bundle id, keychain service, background download session id, and diagnostic context
- `LabstreamMac` host Debug build
- `Labstream` visionOS simulator build using this worktree's visionOS simulator
- `LabstreamMobile` iOS simulator build using this worktree's iPhone simulator
- `PMSKit` diagnostic/redaction tests (`DiagnosticLoggingTests`)
- bounded native macOS host launch smoke via `scripts/smoke-macos-host.sh`

Logs are written to:

```text
build/validation/macos-228/
```

These checks prove the branch is syntactically clean, shared-code compile-safe, that the Mac app can be staged/launched under an isolated dev bundle id, that key Mac identity wiring is still present, and that the diagnostics report renderer/redaction coverage still passes its focused tests. They do **not** prove real auth, subjective UI quality, system media-key runtime behavior, or live download robustness.

## User/manual validation still required

### Auth/account

- Fresh Mac sign-in for Plex.
- Fresh Mac sign-in for Jellyfin.
- Fresh Mac sign-in for Emby.
- Relaunch restores session without repeated keychain prompts.
- Sign-out stays signed out after relaunch.
- Backend switching from Settings dismisses/focuses the main sign-in window correctly.

### Navigation/UI

- Home, Libraries, Search, Music, and Offline load in the Mac shell.
- Music page transition/render does not momentarily resize or kick the whole app shell left.
- Movie/show/season/music detail navigation works.
- Escape pops a content/detail submenu when no player/sheet owns Escape.
- Navigate > Back / `⌘[` pops the same submenu.
- Settings and Choose Libraries remain acceptable for v1.
- Sidebar/root toolbar do not appear in player mode.

### Playback

- Start playback from Home/detail/library.
- Player controls remain visually acceptable.
- Fullscreen button actuates reliably.
- Escape in fullscreen exits fullscreen first; a later Escape exits player.
- Left/Right seek 30 seconds; Shift+Left/Right seek 10 seconds.
- Quality/audio/subtitle changes preserve playhead and do not snap to `0:00`.
- Now Playing / media keys work for video.

### Music

- Artist/album grid sizing remains acceptable.
- Music playback works.
- Now Playing / media keys work for music.
- Music and video system media ownership do not conflict when switching between them.

### Downloads/offline

- Start a download on Mac.
- Restart the app during/after a download and verify state reconciles.
- Resume works after interruption/relaunch.
- Offline library updates.
- Offline playback works.
- Per-worktree dev bundle ID isolates offline state.

### Diagnostics/feedback

- Feedback UI opens on Mac.
- Diagnostic preview/export includes Mac build/platform/bundle/keychain/container/download/playback facts.
- Diagnostic preview/export does not leak tokens, hosts, paths, usernames, filenames, or media titles.

## Completion rule

#228 should not be considered done until the agent-runnable validation script passes and the manual checklist above has either been tested successfully or split into explicit follow-up issues with user approval.
