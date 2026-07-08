# macOS #228 remaining work plan

This document captures the agreed scope and sequence for finishing the first native macOS Labstream implementation in GitHub issue #228.

## Current branch state

- Worktree: `/Users/jlipworth/labstream-228-macos`
- Branch: `issue-228-macos`
- Baseline commit: `4088d32 Implement native macOS app pass`
- Quality-switch follow-up commit: `57d001a Fix quality reload playhead snapshots`
- Follow-up redesign issue: #232, `Mac shell/sidebar redesign pass`

## Scope decisions

1. **Quality-switch playhead race**
   - In scope / mandatory.
   - Root playback fix has landed as `57d001a`.
   - Validate on Mac and existing platforms.
   - Candidate cherry-pick to `main` if real testing confirms it.

2. **Escape/back navigation outside player**
   - In scope.
   - Pressing Escape in a content/detail submenu should navigate back to the previous screen when no higher-priority surface is active.
   - Player fullscreen/close behavior takes priority while player is active.
   - Sheets/dialogs should keep normal dismiss behavior.

3. **Downloads/offline on Mac**
   - In scope for basic parity.
   - Use app-container storage for v1.
   - Do not add external folders/security-scoped bookmark support in #228.
   - Validate start, restart, resume/reconcile, offline library update, and offline playback.

4. **Mac player/system integration**
   - Full Now Playing + media keys parity is in scope.
   - Do not leave Mac system media integration as no-op placeholders.
   - Video player keyboard/fullscreen behavior remains part of this pass.

5. **Diagnostics/feedback parity**
   - Full diagnostics parity is in scope.
   - Include Mac-specific bundle ID, per-worktree dev identity, sandbox/container paths, storage/download facts, playback/quality-switch diagnostics, and redaction safety.

6. **Music/system integration**
   - Full music system/media parity is in scope.
   - No major music UI redesign unless obvious Mac layout bugs appear.

7. **Release/versioning/App Store mechanics**
   - Minimal scaffolding/docs in #228.
   - Defer final App Store Connect/TestFlight/universal-purchase plan.

8. **Mac shell/menu/sidebar polish**
   - Polish current shell enough for v1.
   - No major redesign in #228.
   - Larger redesign tracked by #232.

9. **App icon**
   - Current technically valid icon is acceptable for #228 unless actively broken.
   - Final brand/icon art can be follow-up.

10. **End-to-end validation matrix**
    - Required before #228 is considered done.
    - User does not need to perform every item manually.
    - Agents/lead should cover build checks, static checks, non-auth automated checks, deterministic runtime smoke, logs, and documentation.
    - User covers real-auth, subjective UI feel, and real-server playback/download cases where local interaction is needed.

## Recommended implementation sequence

1. **Review/validate `57d001a` quality-switch fix**
   - Inspect patch for correctness.
   - Re-run relevant builds/checks if needed.
   - Ask for focused retest of quality switching.

2. **Implement Escape-to-back for content/detail screens**
   - Small clean follow-up commit.
   - Prefer Mac-specific command handling unless a shared implementation is clearly safe.

3. **System media integration**
   - Implement/replace Mac Now Playing and remote command placeholders.
   - Cover video and music.
   - Validate media keys and metadata/artwork behavior where possible.

4. **Downloads/offline parity**
   - Validate Mac app-container download lifecycle.
   - Fix Mac-specific storage/resume/reconcile/offline playback gaps.

5. **Diagnostics/feedback parity**
   - Add Mac-specific diagnostic fields and feedback/export coverage.
   - Verify redaction.

6. **Shell/menu/sidebar v1 polish**
   - Back navigation, menu coverage, root/player chrome separation, status/account/settings placement.
   - Keep larger IA redesign in #232.

7. **Release scaffolding/docs**
   - Document Mac build/deploy/versioning/release caveats.
   - No full App Store Connect plan in this ticket.

8. **Validation matrix sweep**
   - Automated/static/build checks by agents/lead.
   - Focused user testing for real auth/playback/download/UI feel.

## Validation matrix draft

### Build/static

- `git diff --check`
- Conflict-marker scan.
- `LabstreamMac` host Debug build.
- `Labstream` visionOS simulator build for shared-code regressions.
- `LabstreamMobile` iOS simulator build for shared-code regressions.

### Auth/account

- Fresh Mac install/sign-in for Plex.
- Fresh Mac install/sign-in for Jellyfin.
- Fresh Mac install/sign-in for Emby.
- Relaunch restores session without repeated keychain prompts.
- Sign-out stays signed out after relaunch.
- Backend switching from Settings dismisses/focuses correctly.

### Navigation/UI

- Home, Libraries, Search, Music, Offline load.
- Detail/content navigation works.
- Escape goes back from content/detail submenu.
- Settings is idiomatic enough for v1.
- Choose Libraries dialog remains usable.
- Sidebar/root toolbar do not appear in player mode.

### Playback

- Start playback from Home/detail/library.
- Custom controls usable and visually acceptable.
- Fullscreen button actuates reliably.
- Escape in fullscreen exits fullscreen first.
- Escape when windowed exits player.
- Left/Right seek 30 seconds.
- Shift+Left/Right seek 10 seconds.
- Quality changes preserve playhead and do not snap to `0:00`.
- Audio/subtitle changes preserve playhead.
- Now Playing/media keys work for video.

### Music

- Artist/album grid sizing acceptable.
- Music playback works.
- Now Playing/media keys work for music.
- Music and video media command ownership do not conflict.

### Downloads/offline

- Start a download on Mac.
- App restart during/after download reconciles state.
- Resume works after interruption/relaunch.
- Offline library updates.
- Offline playback works.
- Per-worktree dev bundle ID isolates offline state.

### Diagnostics/feedback

- Feedback UI works on Mac.
- Diagnostics include Mac build/platform/container/download/playback facts.
- Diagnostics redact tokens/server-sensitive values.
- Logs include useful quality-switch/download breadcrumbs without excessive noise.

### Docs/release scaffolding

- Mac host deploy docs current.
- Per-worktree dev identity caveats documented.
- Minimal release/versioning caveats documented.
