# tvOS exhaustive screen audit

Status: remaining open questions after the archived tvOS implementation plan
([`docs/archive/plans/2026-07-20-tvos-implementation.md`](../archive/plans/2026-07-20-tvos-implementation.md))
and [2026-07-21 session report](../archive/research/2026-07-21-tvos-session-report.md).
Historical rows below are a dated inventory; do not treat “Fix in progress” as current
instruction. The leftover product gates are physical Siri Remote / keyboard / HDMI / HDR,
not the simulator search-keyboard XCTest.

This is the visual and interaction inventory for the tvOS implementation. A shared metric or a
successful compile does not count as checking a screen. Each row requires an actual tvOS simulator
or physical-device presentation, remote-only traversal, focus proof, screenshot, and review for:

1. control, text, icon, artwork, and target sizing;
2. horizontal and vertical spacing;
3. control orientation and focus order;
4. redundant labels, titles, descriptions, and actions;
5. Select, Menu/Back, Play/Pause, keyboard/dictation, loading, empty, error, and retry behavior.

`Open` means it has not passed all five checks. Simulator screenshots cannot complete hardware-only
player, HDMI, HDR, audio-route, long-play, or accessibility acceptance.

## Current findings

| ID | Screen/state | Finding | Status |
| --- | --- | --- | --- |
| TVUI-001 | Plex/Jellyfin/Emby authentication actions | Shared 520pt full-width label frames, title-scale text, and glass styles compounded tvOS focus padding. Buttons were oversized and long Emby/Jellyfin labels wrapped. Replace with native bordered styles, intrinsic labels, body-scale type, and bounded widths; recheck every auth state. | Fix in progress |
| TVUI-002 | First-run Choose Libraries | iPad `Form` sheet collapsed into a narrow TV popover. Footer clipped, toolbar overflowed, and Not Now/Show All/Done were unclear. Replace with a TV-owned full-screen dialog and direct remote-toggle rows. | Fix in progress |
| TVUI-003 | Libraries root cards | Cards were oversized, produced a three-plus-one orphan grid, and truncated names. An unapproved follow-up then hid matching captions and made some libraries structurally different. Preserve the same title-plus-type-caption hierarchy for every library and use a four-up TV grid with enough title width. | Fix in progress |
| TVUI-004 | Search system keyboard | Earlier simulator sessions saw Select on a highlighted letter clear first responder without inserting a character. Fixture shells passed. The decisive live XCTest `testLiveSearchTabSystemKeyboardInsertsLetter` later **passed**: synthetic `XCUIRemote` input inserts the letter on the real Search tab. Remaining risk is the physical input path (real Siri Remote / DeviceHub key routing), not app view composition. Do not replace the system keyboard with a custom keyboard. | Simulator XCTest passed; physical remote/keyboard still open |
| TVUI-005 | Top-level titles | Home/Libraries/Search/Music/Settings repeated the selected persistent-tab label as a page title. | Fixed; regression proof pending |
| TVUI-006 | Authentication branding | Invented “Your media. Your screen.” copy was added during the port. | Removed |
| TVUI-007 | Leaf detail navigation/title | The iPad navigation title was rendered over the TV hero, duplicating the content title and colliding with the tagline/metadata. Hide TV navigation chrome while retaining Menu/Back navigation. | Fix in progress |
| TVUI-008 | Leaf detail artwork and page geometry | The shared 300pt tablet poster, 48pt page inset, and unbounded metadata column did not establish a TV-safe hero or readable measure. Use a TV-owned leading poster, 96pt safe inset, and bounded information column. | Fix in progress |
| TVUI-009 | Leaf detail identity and metadata | Large-title/tablet type, the oversized tagline, and a dense metadata row competed rather than forming a hierarchy. Use TV title/body scales and stable two-line behavior for long identity text. | Fix in progress |
| TVUI-010 | Leaf detail genres and credits | Cast/director/studio were inserted before the actions in tablet-style baseline rows; wrapped cast text drifted inward and overwhelmed the primary task. Move credits after the synopsis and use aligned label/value rows with bounded wrapping. | Fix in progress |
| TVUI-011 | Leaf detail actions | Resume/Play and watched controls inherited title-scale labels and oversized focus geometry. Use intrinsic native bordered controls at body scale, one horizontal remote-focus group, and no unavailable Download control. | Fix in progress |
| TVUI-012 | Leaf detail versions and technical facts | A borderless `Version: 4K · HEVC…` menu repeated the immediately following spec chips and did not read as a TV focus target. Use explicit compact edition/file chooser controls only when multiple choices exist; keep the selected technical facts in one badge row. | Fix in progress |
| TVUI-013 | Leaf detail synopsis | The synopsis inherited the remaining tablet column width and was crowded under the technical row. Bound its readable measure, preserve the full text through vertical scrolling, and keep it ahead of secondary credits. | Fix in progress |
| TVUI-014 | Leaf detail chapters | Chapter count appeared as an undersized, list-like afterthought beside technical chips. Keep it as non-actionable media metadata at TV callout scale; chapter selection remains in the player’s Chapters menu. | Fix in progress |
| TVUI-015 | Leaf detail secondary/error/related states | Playback resolving, disabled/watched variants, playback errors, multiple editions/files, missing metadata/art, long text, episodes, and Trailers & Extras have not yet been traversed after the TV composition change. | Open |
| TVUI-016 | Library section navigation chrome | Entering a library retained the tablet navigation title and toolbar, consuming roughly half the initial viewport before the first poster row. Replaced it with a compact two-row TV header. Back is now handled at the persistent TV shell (where focus actually lives) and was verified Collections → Movies → Libraries without escaping to tvOS Home. | Fixed; Plex simulator proof |
| TVUI-017 | Library alphabet navigation | The persistent phone/tablet A–Z edge index was tiny, visually noisy, and impractical for Siri Remote focus. Replaced it with the intentional visionOS-style Jump action, a spaced six-column TV focus grid, selection dismissal, a verified D jump, focus return to Jump, and Back-only modal dismissal. | Fixed; Plex simulator proof |
| TVUI-018 | Library Collections entry | Collections was placed alone in navigation-toolbar space, truncated while unfocused, and disconnected from the other browse actions. It now has a full intrinsic label at the trailing end of the Sort/Filter/Jump focus rail; three Right presses reach it from Sort, and navigation plus one-level Back restoration were traversed. | Fixed; Plex simulator proof |
| TVUI-019 | Library grid exterior spacing | The 80pt shared page inset plus navigation chrome pushed the first row far down and inward. The TV section now uses a 56pt inset and 16pt grid top boundary directly below the compact header. | Fixed; Plex simulator proof |
| TVUI-020 | Library grid interior spacing and card scale | Adaptive 220–260pt columns plus a 36pt gutter created excessive unused space while title-scale labels wrapped aggressively. The TV grid now uses 248pt posters, 24pt gutters, and smaller dense title/year typography; six complete posters fit across the first row. | Fixed; Plex simulator proof |
| TVUI-021 | Library section variants | Sort/filter states, Jump selection/dismissal/focus restoration, Collections navigation, loading/skeleton, empty/error, pagination, non-Plex libraries, non-portrait art, long titles, and return position require literal traversal after the composition change. | Open |
| TVUI-022 | Playback launch | Selecting Resume crashed the tvOS process with `NSInvalidArgumentException`: `AVPlayerItem.setExternalMetadata:` was unavailable because the tvOS target did not link AVKit, whose Objective-C category supplies that selector. Link AVKit explicitly and prove live playback instead of treating return to the tvOS Home screen as a player presentation failure. | Fixed; Plex simulator proof |
| TVUI-023 | Detail action transition into playback | Replacing the focused Play/Resume label with a bare spinner collapsed the button's intrinsic width; disabling it simultaneously moved focus to Mark Watched, making both controls visibly mutate before presentation. Preserve the full label's geometry behind the spinner and retain tvOS focus while the existing request guard rejects repeat presses. | Fixed; Plex simulator proof |
| TVUI-024 | Hidden player chrome remote input | After custom chrome auto-hide, directional, Select, and Play/Pause input did not reveal it, so Quality/Subtitles/Audio/Chapters/Speed/Stats could not be reached. Root cause proven via window/focus instrumentation: once chrome auto-hides, the player subtree has no focusable item, the focus engine reports `focusedItem == nil`, and every remote press reaches `UIWindow.sendEvent` but never a SwiftUI handler. Fix: a nonvisual full-screen `Button` rendered only while chrome is hidden owns focus (`TVPlayerFocus.hiddenSurface`); Select on it reveals chrome and hands focus to Play/Pause; a bounded retry verifies the `@FocusState` write actually stuck (a race could silently drop it). Once visible, Up from the transport cluster reaches the menu strip (header row is a focus section) and an open submenu is treated as modal (top chrome hidden, `onExitCommand` closes it) so Menu can't fall through and exit playback. A follow-on live-only gap surfaced after that fixture work passed: Down from the trailing menu strip (e.g. Quality) still couldn't reach the skip cluster because the timeline is a non-interactive `ProgressView` with no focusable, so the vertical beam had nothing to land on. Fixed the same way — `.focusSection()` on the transport row, mirroring the header row's. Diagonal transitions (Left+Down etc.) go through a guarded `onMoveCommand` fallback; live-captured evidence found `onMoveCommand` fires for every dpad press (not only unresolved ones) with inconsistent ordering against the focus engine's update — the focus update was seen preceding the command by ~80-105ms on some presses and trailing it by ~5ms on others — so the fallback guards on both an edge-item focus position and a recent-focus-change timestamp (0.15s window on `tvPlayerFocusChangedAt`); an earlier unguarded version double-moved on a single press. Chrome auto-hide now restarts its 5s countdown on every dpad press while visible so rapid navigation can't have chrome vanish mid-traversal and reset focus. Keep the shared app-owned `CustomPlayerView`/`CustomPlayerChrome` and custom scrubbing; do not substitute `AVPlayerViewController`. Layout update (`e02a4d07`, approved live): the transport-button row and skip buttons this entry references were later removed — the chrome is the header (title + menu strip) over a focusable full-width timeline that is the default chrome focus, and hidden-chrome side presses skip ±10s directly; the focus-section and traversal findings above now apply to the timeline row. | Fixed; fixture UI-test and live-session proof, regression screenshot/log evidence pending |
| TVUI-025 | Buffering and player chrome sizing | The buffering dialog and revealed player chrome showed tablet-derived proportions, wrapping, compressed time labels, and weak internal/exterior spacing at 1080p. Multiple sizing passes landed: clocks size to content (100pt floor) so `h:mm:ss` never truncates, skip/play-pause buttons trimmed to 40pt, status platter widened to 760pt for 1-2 line buffering guidance, popover spacing/clipping tightened, Stats popover grown to fill 820x700 without scrolling, chapter/poster cards moved to the native `.card` style, and the header platter widened to 1760pt with a 760pt title ceiling so episode/movie titles truncate far later. TVUI-024's fix unblocks deterministic reveal and submenu traversal, so the remaining gap is a full visual review pass (internal/exterior spacing, truncation, safe areas) rather than an input blocker. | Fix in progress; sizing refined across several passes, full visual review pending |
| TVUI-026 | Card focus indicators missing on bare button-style cards | Poster/still/chapter/View All rail cards, then library, music, and episode rows use a bare custom `ButtonStyle` (adopted because the system `.borderless`/`.card` styles were on the stack of a SwiftUI-internal `DynamicContainer` fatal crash on a Home row change, not reproduced under fixture scale and tracked as suspected tvOS 27 beta runtime behavior) that draws no system focus platter. Any card whose artwork doesn't carry an owned focus treatment is invisible when focused. Regression found live on the Libraries root. Fixed by adding an owned white-ring-plus-lift-plus-shadow treatment via `isFocused`: first to poster/still/chapter/View All cards, then to `LibrarySectionCard`, `SquareArtCell` (music), and `EpisodeRow`. | Fixed; live-session proof, regression screenshot/log evidence pending |
| TVUI-027 | Directional entry from the tab bar lands on the wrong card | Down from the tab bar always landed on card 2 on both Home and the Libraries root grid — pure geometry: the Home tab button sits over the second card's column. Key discovery, verified live: `focusScope` + `prefersDefaultFocus` does not influence directional (dpad) entry, only initial/programmatic focus resolution, so it could not fix this. Fix: Home and the Libraries root grid track per-card focus via `@FocusState`; a nil-to-card transition (focus entering from outside the grid) redirects to the remembered entry card or card 1, while in-grid moves and pop-back restores pass through untouched. Every horizontal media rail (HubRail, search hub/music rails, music library/browser rails) is now also a `.focusSection()` so vertical moves treat the whole rail as a target regardless of column overlap. | Fixed; live-session proof, regression screenshot/log evidence pending |

## Authentication and session lifecycle

- [ ] Secure-storage unavailable screen.
- [ ] Session-restoring screen and slow restore.
- [ ] Plex start, working, link-code, success handoff, cancellation, expired code, discovery
      failure, reconnect, and sign-in-again screens.
- [ ] Jellyfin server URL entry; Quick Connect vs credentials chooser; disabled states; Quick
      Connect working/code/expiry/error/fallback; username/password keyboard, validation, working,
      failure, and success screens.
- [ ] Emby Connect vs server URL chooser; Connect working/PIN/expiry/error/fallback; multi-server
      picker; manual server URL; username/password keyboard, validation, working, failure, and
      success screens.
- [ ] Backend switching confirmation, sign-out confirmation, signed-out return focus, restored
      session focus, local/remote server variants, and unreachable-server recovery.

## Persistent shell and top-level destinations

- [ ] Tab bar sizing, icons, focus movement, selected state, content handoff, restoration, and no
      repeated page titles for Home, Libraries, Search, Music, and Settings.
- [ ] Mini-player present/absent layouts and focus movement between content, tabs, and mini-player.
- [ ] Home loading skeleton, Plex hubs, Jellyfin/Emby rails, empty, error, retry/refresh, View All,
      horizontal boundaries, long titles, missing art, progress, episode, movie, show, and music cards.
- [ ] Libraries loading, first-run chooser, root cards, empty/error, visibility changes, every
      library kind, section grid, pagination, sort/filter menus, alphabet rail, Collections entry,
      long names, missing art, and focus restoration.
- [ ] Library section composition (TVUI-016 through TVUI-021): compact header height; title and
      Sort/Filter/Jump/Collections on one rail; no persistent A–Z sidebar; grid exterior/interior
      rhythm; poster/title sizing; initial visible row count; remote focus order; and every loading,
      empty, error, pagination, backend, artwork-shape, and return-position variant.
- [ ] Search idle, system keyboard, dictation hint, query editing, clear, loading, grouped video and
      music results, track actions, empty query/result, errors, pagination/View All, and return focus.
- [ ] Settings every section, picker, toggle, button, long value, disabled/loading state,
      confirmation dialog, backend/server switch, library editor, diagnostics, feedback, reset,
      sign-out, About/build identity, and TV exclusions.

## Browse hierarchy and details

- [ ] View All grid and pagination for each rail/query kind.
- [ ] Show, season, collection, playlist, and folder container screens.
- [ ] Episode rows, poster grids, empty/loading/error states, and deep Menu/Back restoration.
- [ ] Movie, show, season, episode, collection, playlist, and generic-video detail variants.
- [ ] Leaf detail subsection audit (TVUI-007 through TVUI-015): navigation/title chrome;
      poster/backdrop/page geometry; identity/tagline; year/runtime/certification/ratings/watched;
      genres; Play/Resume/Mark Watched; edition/file selection; technical badges/chapter count;
      synopsis; cast/director/studio; related shelves; focus order; scroll/return position; and every
      missing/long/loading/disabled/error variant.

## Video player

- [ ] Initial loading, playing, paused, buffering, stalled, retrying, failed, ended, and autoplay
      countdown states.
- [ ] Hidden/revealed chrome, initial/default focus, Play/Pause, Menu/Back, timeline, elapsed/remaining
      time, remote seeking/scrubbing, chapter marks, trick-play, skip intro/credits, and Up Next.
- [ ] Quality, speed, chapters, subtitles, audio tracks/streams, and Stats tabs including long lists,
      selected/disabled states, empty/unavailable states, popover sizing, focus boundaries, selection,
      dismissal, and restoration.
- [ ] Stats for Nerds, route picker, PiP entry/return if retained, lifecycle overlays, playback error
      messages, and teardown/return-to-detail focus.

## Music

- [ ] Plex and Jellyfin/Emby music loading/empty/error states and multi-library picker.
- [ ] Home/Artists/Albums/Playlists pivot sizing and remote switching.
- [ ] Music rails and grids; artist, album, playlist, and track rows; long/missing metadata/art;
      pagination, alphabet rail, and context/queue actions.
- [ ] Mini-player, Now Playing, queue, transport, progress, shuffle/repeat, track menu, errors,
      background/foreground restoration, and switch between music and video ownership.

## System, modal, and accessibility states

- [ ] Every alert, confirmation dialog, sheet/full-screen cover, popover, context menu, progress
      overlay, empty state, error message, and retry action reachable on tvOS.
- [ ] VoiceOver reading/order, Switch Control, Reduce Motion, Increase Contrast, Bold Text, captions,
      audio descriptions, and no hardware-keyboard-only action.
- [ ] Overscan/safe areas, 1080p/4K rendering, light/dark or system appearance where applicable,
      network loss, sleep/wake, memory pressure, and physical Siri Remote behavior.

## Environment and tooling notes

- This Xcode beta has no Simulator.app; DeviceHub.app is the sim GUI. A full simulator reboot
  temporarily detaches DeviceHub's key input (zero press events reach the app) and self-recovers;
  do not mistake this for an app-level input regression.
- UI-test runs leave the simulator on the tvOS home screen with placeholder test-runner icons; the
  app must be relaunched afterward before further live traversal.

## Evidence rule

For each completed row, record backend, fixture/live source, simulator or hardware identity, build
commit, screenshot/result path, remote path, and any approved platform exception. Do not mark a row
complete merely because a shared view was checked on iPad, Mac, visionOS, or a different backend.

## Recorded evidence

- TVUI-016/019/020 — live Plex Movies library, simulator
  `1BB9E7C3-3700-48E1-8B2A-DF6A6AD29457`, dirty build based on `5f8d4e32`, installed binary UUID
  `B573D4BD-53C9-309B-A736-73A06B8185AC`, remote path Libraries → Movies, screenshot
  `/tmp/labstream-tvos-library-section-final.png`.
- TVUI-017 — same simulator/build, remote path Movies → Jump; verified readable separated cells
  and Back dismissing only the picker in `/tmp/labstream-tvos-library-jump-final.png` and
  `/tmp/labstream-tvos-library-jump-back-final.png`. Earlier traversal also selected D, moved the
  grid to D, and restored focus to Jump (`/tmp/labstream-tvos-library-jump-result.png`).
- TVUI-018 — same simulator/build, remote path Movies → Right ×3 → Collections → Back → Movies →
  Back → Libraries. Full-label focus and both one-level returns are shown in
  `/tmp/labstream-tvos-collections-focus-final.png`,
  `/tmp/labstream-tvos-back-collections-to-movies-final.png`, and
  `/tmp/labstream-tvos-back-movies-to-libraries-final.png`.
- TVUI-022/023 — live Plex episode `<episode title scrubbed>`, same simulator, dirty build
  based on `5f8d4e32`, installed debug-dylib UUID
  `19192CD2-4EDD-3972-89E2-153FA0DFD896`. The original 19:04 crash is recorded in
  `~/Library/Logs/DiagnosticReports/<crash-report>.ips` with
  `PlaybackController.attachExternalMetadata` at `PlaybackController.swift:3187`. The replacement
  binary explicitly links AVKit; remote path detail → Resume reached live decoded video while PID
  15966 remained alive and no exception, abort, or fatal event appeared. Playback and return proof:
  `/tmp/tvos-playback-after-fix.png` and `/tmp/tvos-detail-after-playback-fix.png`. The captured
  transition sequence `/tmp/tvos-play-transition-fix-contact.png` retains the same Resume and Mark
  Watched geometry/focus until player presentation.
