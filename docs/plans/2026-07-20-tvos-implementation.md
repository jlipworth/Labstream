# tvOS implementation plan

Status: **active research and implementation plan** for [GitHub issue #246](https://github.com/jlipworth/Labstream/issues/246). A tvOS target and substantial parity scaffolding now exist, but tvOS is not yet a supported or release-complete Labstream platform; the phase checkboxes below are acceptance gates, not claims of shipped behavior.

Research baseline: 2026-07-20 against repository commit `44839793`, with parity scope reconciled against `main` at `6d5851fb`, current Apple developer documentation, current Apple TV 4K specifications, and a live GitHub duplicate/dependency audit. Recheck SDK requirements, hardware specifications, issue state, and source line locations when implementation begins because these facts may drift.

This document is the durable repository plan. Keep its phase status synchronized with issue #246 during implementation, then promote proven behavior into the current architecture, development, testing, and platform documentation. Archive this note only after every required acceptance gate is complete or explicitly moved to a linked follow-up.

The per-screen visual and remote-interaction inventory lives in
[`2026-07-20-tvos-screen-audit.md`](2026-07-20-tvos-screen-audit.md). A phase item cannot be treated
as visually checked merely because it inherited shared metrics; the corresponding audit rows need
actual tvOS evidence.

Implementation checkpoint: commits `53ec96eb` and `5ef5bb6d` establish the tvOS compile,
test-host, and simulator-tooling foundation. The current Phase 1 slice adds a dedicated
ten-foot sign-in layout, deterministic signed-out fixtures for all three backends, synthetic browse
fixtures consumed by the real Home/Libraries/Detail views, and a remote-only Home -> detail -> Back
journey. On tvOS 27, the worktree-owned Apple TV 4K (third generation) simulator build installs with
a matching binary UUID and launches without an app fault. The applicable tvOS unit suite now omits
the approved download-only exception and completes with 82 passing tests; the separated tvOS UI
suite completes with four passing tests. Existing visionOS, mobile, Mac, and PMSKit checks passed at
the compile-foundation checkpoint; this slice reran the tvOS app/unit/UI lanes, tooling hygiene, and
strict documentation. Artwork fixtures, the remaining browse/search/settings surfaces, complete
focus semantics, player/music adaptation, physical-device validation, and release work remain open.
This checkpoint is an initial parity implementation slice, not a parity-complete app or Phase 1 exit.
The subsequent TV visual audit removes invented marketing copy, gives authentication controls and
panels ten-foot sizing without oversized empty containers, introduces tvOS-specific poster, grid,
library-card, music-art, type, and spacing metrics, and suppresses redundant Home/Libraries/Search/
Music/Settings navigation titles because the persistent tab bar already carries that information.

Implementation handoff at commit `ced35a36`: the Plex simulator can traverse the compact Libraries
section header, Sort/Filter/Jump/Collections rail, six-up poster grid, detail screen, and live video
launch without the earlier missing-AVKit selector crash. The audit remains intentionally open. In
particular, native system-keyboard Select does not insert letters in the current Xcode 27 beta 3 /
tvOS beta simulator, and the shared custom player's hidden chrome has no proven remote-input/focus
owner, so directional, Select, and Play/Pause input cannot reliably reveal it or reach its submenus.
These are unresolved defects, not permission to replace the system keyboard or the app-owned custom
player. `CustomPlayerView`, `CustomPlayerChrome`, the AVPlayerLayer presentation, and custom
scrubbing remain canonical across platforms; no `AVPlayerViewController` replacement is approved.

Implementation checkpoint (2026-07-21 session, commit `eb12403c` and prior): the hidden-chrome
remote-input blocker above is now resolved. Root cause was proven via window/focus instrumentation
(once chrome auto-hides the player subtree has no focusable item and every remote press bypasses
SwiftUI entirely); the fix is a nonvisual full-screen hidden-chrome focus owner plus a bounded retry
that verifies a racy `@FocusState` write actually stuck. Up from the transport cluster now reaches
the menu strip, open submenus are treated as modal so Menu can't fall through and exit playback, and
fixture `XCUIRemote` tests traverse and open/close every submenu (Subtitles/Audio/Chapters/Speed/
Stats) from a confirmed hidden state. A live-only follow-on gap then surfaced after that fixture work
passed — Down from the menu strip still couldn't reach the skip cluster because the timeline is a
non-interactive `ProgressView` with no focusable — fixed with a `.focusSection()` on the transport
row. Diagonal moves route through a guarded `onMoveCommand` fallback; live-captured evidence found
`onMoveCommand` fires on every dpad press (not only unresolved ones) with inconsistent ordering
against the focus engine's update (leading it by ~80-105ms on some presses, trailing it by ~5ms on
others), so the guard checks both an edge-item focus position and a 0.15s recent-focus-change
timestamp to avoid double-moving on a single press. Separately, a card-focus-indicator regression
(bare custom `ButtonStyle` cards drawing no focus platter, found live on the Libraries root) was
fixed with an owned focus ring across library, music, and episode cards, and a tab-bar directional-
entry bug (Down from the tab bar geometrically landing on card 2 regardless of intent — confirmed
live that `focusScope` + `prefersDefaultFocus` does not govern directional entry, only initial/
programmatic focus) was fixed with a `@FocusState`-tracked entry redirect on Home and the Libraries
root grid. The search-keyboard defect (TVUI-004) is not fixed: fixture testing now exonerates a bare
`TextField`, a styled field, a focus-binding replica, and a full generic TabView/NavigationStack
shell, narrowing the suspect surface to live-only layers (session-keyed `NavigationStack.id`,
environment injections, TabView-level `.onExitCommand`, `.task(id:)`, `MiniPlayerBar` safeAreaInset);
a decisive live repro test exists but has not been run to completion. See
`2026-07-20-tvos-screen-audit.md` (TVUI-004, TVUI-024 through TVUI-027) for full detail and evidence
status. This Xcode beta has no Simulator.app (DeviceHub.app is the sim GUI); a full simulator reboot
temporarily detaches DeviceHub's key input and self-recovers — do not mistake that for an app
regression.

Merge checkpoint (2026-07-21): the implemented tvOS foundation and simulator-verified interaction
slice is ready to join `main`, but this plan remains active because physical Apple TV, complete
backend/parity, accessibility, system-integration, and release gates are still open. The branch was
rebased onto local `main` without changing its final tree. Post-rebase validation passed 1,638
PMSKit tests, 85 applicable tvOS unit tests, a clean tvOS simulator build, and all 16 tvOS UI tests.
The UI suite itself completed with zero failures, but Xcode 27 beta again hung after XCTest reported
the final passing summary; the stuck `xcodebuild` was terminated after 30 seconds of no further
output rather than being allowed to hang indefinitely. Repository hygiene passed 50 tooling tests,
the strict documentation build, and Mermaid validation. The exact clean product was installed with
a matching binary UUID, launched successfully on the worktree-owned Apple TV 4K (third generation)
simulator, and produced a healthy signed-out ten-foot UI screenshot. Expected simulator keyboard
analytics and an unreachable stale server-restoration attempt were present in unified logging; no
crash or app fatal signal was observed.

## Goal

Create a first-class native tvOS version of Labstream for Apple TV with functional parity to the shared iPad/Mac product surface across Plex, Jellyfin, and Emby. The implementation may advance through internal checkpoints, but no reduced video-only or single-backend edition is a release target. tvOS gets its own 10-foot UI, focus model, Siri Remote behavior, system integration, testing lane, and release train while retaining the complete shared product behavior that applies to a television.

A new Apple TV hardware refresh is [credible but still unannounced](https://www.macrumors.com/2026/07/08/apple-tv-4k-latest-rumors/), and an AV1-capable chip is plausible. That is motivation to establish the platform now, **not** an assumption in the design. The supported hardware baseline is the latest shipping Apple TV 4K (third generation, A15) and, after release and validation, its expected successor; older Apple TV generations are not a support target. Any wider codec support must be enabled only after Apple announces hardware and Labstream verifies it on that physical device against the [officially documented formats](https://www.apple.com/apple-tv-4k/specs/).

## Research summary

- The repo currently has `Labstream` (visionOS), `LabstreamMobile` (iPhone/iPad), and `LabstreamMac`, all sharing the file-system-synchronized `Labstream/` source root and PMSKit. The completed macOS port in #228 is the closest process precedent.
- PMSKit has no third-party package dependencies and is a good shared core, but `PMSKit/Package.swift` does not declare tvOS yet.
- This cannot be a platform-setting-only port. There is no tvOS target, scheme, `@main`, identity, resource set, test host, or simulator/device workflow. `RootView` also routes an unknown platform into visionOS-only content, and shared source contains APIs that need tvOS availability gates (including Spotlight, MetricKit, pasteboard/file export, and the current embedded web-auth presentation path).
- Existing code-based sign-in is a strong TV foundation: Plex link code, Jellyfin Quick Connect, and Emby Connect PIN should be the primary living-room flows.
- The app-owned custom player is the sole video player and remains canonical on tvOS. Labstream deliberately retired its `AVPlayerViewController` path after the system surface could not expose or reliably control the complete player feature set. tvOS must adapt the shared custom chrome for focus and Siri Remote input, then add the necessary Now Playing, PiP, audio-session, and lifecycle coordinators without reintroducing a second player stack. Apple's [remote-interaction guidance](https://developer.apple.com/documentation/AVFoundation/supporting-remote-interactions-in-tvos) remains an input and acceptance reference, not a reason to replace the app-owned player.
- tvOS is focus-first, not touch/pointer-first. Every core flow needs deterministic initial focus, directional reachability, focus restoration, and correct Menu/Back behavior using system focus primitives: [focus and selection](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection/), [remotes](https://developer.apple.com/design/human-interface-guidelines/remotes).
- The current Apple TV has 64 GB or 128 GB of physical capacity, but tvOS treats downloaded app data as purgeable outside very small settings data. Labstream will therefore not expose downloads or an Offline destination on tvOS. This is an approved platform exception, not permission to omit other product areas: [tvOS storage guidance](https://developer.apple.com/library/archive/documentation/General/Conceptual/AppleTV_PG/), [current file-system guidance](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively).
- Simulator tests can prove compile, navigation, and focus behavior. Physical Apple TV is mandatory for codec, HDR/Dolby Vision, HDMI/audio output, Siri Remote, PiP/background, performance, and long-play acceptance.

## Parity scope

### Required for release

- Native `LabstreamTV` app target and TV-specific app identity/assets.
- Plex, Jellyfin, and Emby secure sign-in, saved-session restore, backend switching, and sign-out.
- Home, Libraries, Search, TV/movie/episode detail, TV-relevant Settings, diagnostics/feedback, and video playback.
- Music browsing, artists/albums/tracks, playback, queue/miniplayer behavior, progress/state, and applicable system-media integration.
- Watched/resume state, Up Next/autoplay, quality, audio, subtitles, chapters/skip actions, progress reporting, retry/error handling, and transcode teardown.
- A ten-foot layout and complete Siri Remote/focus/accessibility path; no core task may require touch, pointer, or hardware keyboard input.
- Conservative per-platform/device playback capabilities with server Direct Play/Direct Stream/transcode fallback.
- tvOS-native equivalents for applicable system integrations where the iPad/Mac API or presentation is unavailable.
- tvOS simulator automation, physical-device validation, internal/external TestFlight, and tvOS App Store assets/reviewer flow.

### Approved platform exceptions and scope boundaries

- Downloads, offline playback, download storage controls, and an Offline destination are excluded because tvOS cannot promise durable downloaded media.
- visionOS-only spatial presentation such as Cinema/Reality Theater is not copied literally; all underlying player functionality still applies.
- Unfinished enhancements in open issues are not absorbed into this project. tvOS targets the implemented behavior on `main`; shared enhancements flow into tvOS when they land independently.
- A platform API that does not exist on tvOS may be replaced with a TV-native equivalent. Any further omission requires an explicit, documented, user-approved platform exception before release.

### Release parity matrix

Every row is required across Plex, Jellyfin, and Emby wherever that row is implemented for the backend on iPad/Mac. Internal builds may exercise incomplete rows while development proceeds, but external TestFlight and App Store rollout remain blocked until the matrix passes or a platform exception is approved above.

| Product area | Required tvOS outcome |
| --- | --- |
| Identity and connectivity | Pairing/manual sign-in, local and remote servers, secure credential storage, session restore, server/backend switching, and sign-out. |
| Browse and discovery | Home, libraries, pagination, search, TV hierarchy, artwork, metadata, details, loading/empty/error/retry states, and deep navigation restoration. |
| Video | The sole custom player with quality, audio, subtitles, chapters/trick-play, speed, stats, skip actions, resume, watched state, Up Next/autoplay, retry/recovery, progress reporting, and encoder teardown. |
| Music | Library/discovery surfaces, artists/albums/tracks, playback, queue management, miniplayer/full player, metadata, progress/state, and background/system-media behavior. |
| Settings and support | Every applicable playback/account/privacy setting plus diagnostics, redacted feedback, About/build identity, destructive confirmations, and recovery actions through TV-native presentation. |
| System integration | Siri Remote, focus restoration, Now Playing, media commands, audio routes/interruptions, background behavior, PiP where compatible with the custom player, deep links, and an appropriate Top Shelf experience. |
| Accessibility | VoiceOver, Switch Control, Reduce Motion, Increase Contrast, captions/audio descriptions, complete focus traversal, and no required touch/pointer/hardware-keyboard path. |
| Downloads/offline | Explicit approved exception: no downloads, offline library/playback, or storage-management UI on tvOS. |
| Release quality | Deterministic tests, physical latest-generation Apple TV evidence, backend/codec matrix, TestFlight, reviewer access, assets, privacy metadata, and accurate platform documentation. |

## Implementation plan

### Phase 0 — target and compile foundation

- [x] Add `.tvOS(...)` to `PMSKit/Package.swift` and run PMSKit tests for the declared platform.
- [x] Add `LabstreamTV`, `LabstreamTVTests`, and `LabstreamTVUITests` targets/products/shared schemes with tvOS deployment settings, generated plist, package linkage, and test plans.
- [ ] Add layered TV app icon assets and validate real signing/provisioning when an Apple TV or TestFlight lane is available.
- [x] Add a tvOS-only `LabstreamTV.swift` entry point and explicit Apple TV/tvOS values in `PlatformClientIdentity`.
- [x] Add an explicit `tvRootContent` path instead of allowing `RootView` to fall through to visionOS-only content.
- [x] Audit the shared source root for `canImport(UIKit)` and availability fallthroughs; gate or adapt MetricKit, Spotlight, pasteboard/share/export, embedded web auth, iOS orientation/PiP, and visionOS scenes.
- [x] Introduce a central platform feature policy so tvOS can omit the approved downloads/offline exception and adapt unavailable system APIs without forking backend or product policy.
- [x] Update project-hygiene allowlists, `scripts/worktree-sim.sh`, compile audit, and developer docs with a worktree-owned concrete tvOS simulator identity; never target a generic `booted` simulator.
- [x] Prove a concrete worktree-owned simulator build, install/binary-identity guard, launch, bounded fault scan, screenshot, and initial UI launch test on an installed tvOS runtime.
- [x] Separate the applicable tvOS unit and UI suites so both finalize reliably on the installed runtime; omit download-only app tests from the tvOS target while retaining shared product-policy coverage.
- [ ] Add the tvOS build/test lane to the eventual Apple-platform CI work.

**Exit:** a clean tvOS simulator build launches deterministically into fixture login/browse state; existing visionOS, mobile, Mac, and PMSKit lanes still build/test.

### Phase 1 — TV shell, authentication, and focus

- [ ] Complete the initial dedicated tvOS tab shell for Home, Libraries, Search, Music, and Settings as a ten-foot, focus-safe surface; do not show an empty Offline destination. The persistent tab shell is implemented and no longer repeats its labels as top-level page titles; per-surface completion remains open.
- [ ] Add TV poster/card sizing, safe-area spacing, readable metadata, system focus effects, default focus, focus sections, and focus restoration across navigation, sheets, reloads, pagination, errors, and playback return. The first sizing/spacing/type pass covers authentication, shared video posters/grids, library cards, and music art. This session added owned focus rings to bare-`ButtonStyle` cards (poster/still/chapter/View All rows, then library/music/episode rows) after a live regression showed them focus-invisible, fixed a tab-bar directional-entry bug where Down always landed on card 2 regardless of intent (`focusScope`/`prefersDefaultFocus` does not govern directional entry — only a `@FocusState` entry redirect does), and made every horizontal media rail a `.focusSection()`. Exhaustive focus-state and live-data review still remains.
- [ ] Make Plex link code, Jellyfin Quick Connect, and Emby Connect PIN primary; keep remote-friendly manual URL/credential entry as fallback where needed. The initial three-backend TV layout and remote backend-selection fixture are implemented; live authentication, restore, error, and fallback flows remain.
- [ ] Validate local-network permission/ATS behavior, LAN and remote servers, Keychain restore, backend switching, signed-out/error states, dictation/iPhone Remote keyboard, and physical keyboard fallback.
- [ ] Resolve or conclusively classify native tvOS search-keyboard Select behavior. It reproduces with both the original `.searchable` field and an explicit native SwiftUI `TextField` on the current beta simulator: the field becomes first responder, then Select clears first responder without inserting a letter (UIKit reloads input views with `responder:(nil)` and tears down the SwiftUI text-field delegate; no character reaches the binding). Fixture testing has since exonerated a bare `TextField`, a styled field, a focus-binding replica, and a full generic TabView/NavigationStack/results-scroll shell — all insert letters correctly — narrowing the suspect surface to live-only layers (session-keyed `NavigationStack.id`, environment injections, TabView `.onExitCommand`, `.task(id:)`, `MiniPlayerBar` safeAreaInset). A decisive `XCUIRemote` test against the live Search tab exists (`testLiveSearchTabSystemKeyboardInsertsLetter`) but has not been run to completion. `.searchable` showed the identical defect earlier, which is evidence (not proof) the root cause may be Apple's beta runtime. Keep the system keyboard rather than inventing an app keyboard; simulator Capture Keyboard/direct typing remains diagnostic only, not acceptance proof.
- [ ] Make Settings TV-specific and focus-safe. Exclude download/storage/cellular controls, and replace unavailable diagnostics, feedback, discovery, or export surfaces with TV-native equivalents rather than silently dropping their user capability.

**Exit:** using only a Siri Remote, a user can sign in to each backend, browse/search, open details, recover from errors, return with focus restored, and sign out.

### Phase 2 — custom-player TV adaptation

- [ ] Keep the shared app-owned `CustomPlayerView`/`PlaybackController` as the only video player; do not restore the retired `AVPlayerViewController` path. The tvOS target now links AVKit explicitly so the shared player's `AVPlayerItem.externalMetadata` category call does not crash at launch, and live Plex playback has been proven in the simulator; the complete player-state audit remains open.
- [ ] Add tvOS focus ownership, chrome reveal/auto-hide, remote-command routing, focus restoration, and a remote-native scrubber interaction without duplicating canonical playback intent methods. The prior blocker — after chrome auto-hide, no proven focus/input owner received directional, Select, or Play/Pause input — is resolved: a nonvisual full-screen hidden-chrome focus owner reveals chrome on Select and hands focus to Play/Pause, with a bounded retry guarding a racy `@FocusState` write. Up from the transport cluster reaches the menu strip, submenus are treated as modal (Menu can't fall through and exit playback), and fixture `XCUIRemote` tests traverse/open/close every submenu from a confirmed hidden state. A live-only follow-on gap (Down from the menu strip couldn't reach the skip cluster; the timeline had no focusable) was fixed with `.focusSection()` on the transport row, and diagonal moves route through a guarded `onMoveCommand` fallback (guarded on edge-item focus position plus a 0.15s recent-focus-change timestamp, because `onMoveCommand` fires on every dpad press with inconsistent ordering against the focus engine). Auto-hide now restarts its 5s countdown on every dpad press while visible. Chrome layout update (`e02a4d07`, approved live): the on-screen transport-button row referenced above was subsequently removed — the chrome is now the title/menu-strip header over a focusable full-width timeline scrubber, which is the default chrome focus (Left/Right scrubs with streak acceleration, Select commits, moving focus away abandons), and a side press while chrome is hidden performs an instant ±10s skip (`tvRemoteSkipSeconds`) with a brief reveal; mentions of the transport cluster, skip buttons, and Play/Pause default focus are historical. Remaining work is the exhaustive live/physical-device visual and traversal sweep, not the input-ownership defect itself.
- [ ] Support exactly-once Play/Pause, Select, Menu/Back, clickpad/directional scrub and seek, Siri/system commands, buffering/retry, end-of-item, autoplay, and return-focus behavior.
- [ ] Expose quality, audio, subtitles, chapters, speed, skip intro/credits, and bounded diagnostics through TV-native player menus/actions. Prove every submenu is reachable, selectable, dismissible, and restores focus to its originating button; current live testing could not reach these menus after chrome auto-hide.
- [ ] Complete the player visual pass at 1920×1080: buffering overlay, revealed chrome, timeline, elapsed/remaining labels, transport controls, menu buttons, focus geometry, internal/exterior spacing, truncation, safe areas, and every submenu/list state. The buffering-layout adjustment and compact TV composition are provisional until deterministic reveal and traversal are available.
- [ ] Add/generalize the tvOS media-session coordinator for audio session, interruptions/routes, Now Playing metadata/commands, background behavior, and PiP evaluation.
- [ ] Preserve load-bearing startup/stall/seek/restart/cleanup invariants and backend progress/transcode teardown from `docs/PLAYBACK-ARCHITECTURE.md`.

**Exit:** deterministic fixtures and live servers prove stable remote control, track selection, reporting, cleanup, failure recovery, and focus restoration.

### Phase 3 — music and TV system integration

- [ ] Adapt the complete shared music surface: discovery, library navigation, artists/albums/tracks, playback, queue editing, miniplayer/full-player behavior, errors, and backend switching.
- [ ] Add tvOS focus and Siri Remote interactions for music without creating a second music state machine or queue policy.
- [ ] Integrate applicable Now Playing metadata, remote commands, audio-session/background behavior, interruptions, and route changes for both music and video.
- [ ] Provide TV-native diagnostics, privacy, feedback, deep-link/discovery, and Top Shelf behavior where tvOS has a different system surface from iPad/Mac.

**Exit:** video and music parity passes for Plex, Jellyfin, and Emby, including queue/state restoration and applicable system integration.

### Phase 4 — capability-driven codec negotiation

- [ ] Refactor the current generic Apple server profiles into an injected backend-neutral platform/device capability profile; keep the tvOS default at the existing conservative proven intersection.
- [ ] Record source container/codecs, server decision, runtime AVPlayer format, HDR state, output route, and observed result for Plex/Jellyfin/Emby.
- [ ] Validate H.264 and HEVC Main/Main10; SDR, HDR10, HLG, and supported Dolby Vision profiles; AAC, AC-3, E-AC-3/Atmos; text/image subtitles; Direct Play, remux, audio transcode, video transcode, and subtitle burn.
- [ ] Keep AV1, DTS/DTS-HD, TrueHD, additional Dolby Vision profiles, passthrough claims, and any newly announced codec disabled/unadvertised until official support **and** physical-device playback evidence exist.
- [ ] When new Apple TV hardware ships, add it to the matrix and widen server advertisements only for verified rows. Do not infer app-level Direct Play from a chip or protocol bullet alone.

**Exit:** a checked-in/test-linked matrix explains each backend decision without false capability advertising, and unsupported media reliably falls back to server transcode.

### Phase 5 — automation, accessibility, and physical hardware

- [ ] Add deterministic tvOS UI fixtures and `XCUIRemote` tests for directional focus, Select, Menu, Play/Pause, tab/rail boundaries, search, details, modals, player enter/exit, errors, backend switching, and destructive confirmations. Initial fixtures cover all three signed-out backend surfaces and Plex Home -> detail -> Menu/Back through the real app views. Next fixtures must isolate a minimal native search field plus player chrome visible, hidden, buffering, and each submenu state.
- [ ] Assert the focused element after transitions; attach screenshots and accessibility hierarchies on failure.
- [ ] Turn every open row in `2026-07-20-tvos-screen-audit.md` into a literal simulator or physical-device traversal. Record backend/fixture, simulator or hardware identity, build commit, remote path, screenshot/log evidence, loading/empty/error/long-content variants, and focus restoration; a green compile or shared-platform screenshot does not close a row.
- [ ] Complete VoiceOver/Switch Control tasks for sign-in, browse, search, playback, audio/subtitles, and sign-out; verify Increase Contrast, Reduce Motion, Bold Text, captions, and audio descriptions.
- [ ] Validate on Apple TV 4K (third generation), the sole initial hardware target, plus its successor only after that model ships and becomes available; do not claim older-generation support.
- [ ] Cover Ethernet/Wi-Fi, display range/frame-rate matching, HDMI/receiver routes, sleep/wake, background/foreground, PiP, interruptions, network loss/recovery, memory pressure, rapid commands, and multi-hour playback.

**Exit:** simulator focus automation is repeatable and a signed physical-device matrix has no unresolved core focus, control, playback, lifecycle, or capability failures.

### Phase 6 — productization and release

- [ ] Add TV icon/parallax and static Top Shelf artwork, screenshots, privacy text/labels, signing/provisioning, export-compliance answer, version/build release train, and deploy/test docs.
- [ ] Provide App Review with an internet-accessible seeded demo account/server and precise reviewer instructions for the supported backends.
- [ ] Run internal TestFlight, then a small external cohort spanning the supported latest-generation hardware (and its successor after release), remotes, receivers/displays, networks, and Plex/Jellyfin/Emby.
- [ ] Add the tvOS platform to README status only at its actual validation level; do not advertise support before physical-device/TestFlight proof.

**Exit:** the parity release is distributable through TestFlight/App Store and documented without aspirational platform or codec claims.

## Resume order and remaining validation

After this checkpoint merges, continue from current `main` in a fresh issue-specific worktree rather
than recreating or depending on the closed `issue-246-tvos` lane. Provision that worktree's own tvOS
simulator with the repository tooling and never target a generic `booted` simulator. Before editing,
confirm the worktree and installed-runtime truth because Xcode beta and simulator behavior may have
changed.

1. **Player input/focus root cause — resolved, needs live/regression proof recorded:** the hidden-chrome
   focus owner, submenu modal treatment, menu-strip-to-skip-cluster vertical reach, and the guarded
   diagonal `onMoveCommand` fallback are implemented and fixture/live-verified this session (see
   TVUI-024 in the screen audit). Remaining work is recording formal screenshot/log evidence and
   sweeping the full submenu/state matrix, not further root-causing.
2. **Directional-entry and focus-indicator regressions — resolved, needs live/regression proof
   recorded:** the tab-bar Down-lands-on-card-2 bug (TVUI-027) and the bare-`ButtonStyle` missing-
   focus-ring regression (TVUI-026) are fixed; record simulator evidence for both.
3. **Search input classification — still open, narrowed:** fixture testing has exonerated a bare
   `TextField`, styled field, focus-binding replica, and a full generic TabView/NavigationStack shell,
   pointing at live-only layers (session-keyed `NavigationStack.id`, environment injections, TabView
   `.onExitCommand`, `.task(id:)`, `MiniPlayerBar` safeAreaInset). Run the existing
   `testLiveSearchTabSystemKeyboardInsertsLetter` test to completion against the real Search tab; fix
   an app-owned focus/responder defect if proven, otherwise record an Apple beta/runtime blocker with
   reproducible evidence. Do not accept direct Mac typing as the remote-input gate.
4. **Exhaustive surface audit:** continue the four explicit passes—size, spacing, control orientation/
   focus order, and redundant information—across authentication, session restore/errors, Home,
   Libraries and every library state/backend, Search/results, all detail/container variants, Settings,
   Music, player states/submenus, alerts, sheets, and accessibility variants.
5. **Automated regression:** expand deterministic fixtures and `XCUIRemote` journeys; assert focus after
   every modal/navigation transition and save screenshots plus accessibility hierarchies on failure.
   Run the tvOS app/unit/UI lanes, PMSKit tests, tooling hygiene, strict documentation, and unchanged
   visionOS/mobile/Mac build or test lanes appropriate to the touched shared code.
6. **Physical-device gate:** when hardware is available, validate real Siri Remote behavior, codec/HDR/
   audio/HDMI routes, PiP/background/lifecycle, accessibility, performance, and multi-hour playback on
   the latest supported Apple TV. Simulator evidence cannot close these rows.

Do not interpret the committed simulator fixes as parity completion. Phase 1, the complete custom
player adaptation, Music, system integration, codec negotiation, accessibility, physical hardware,
TestFlight, App Review, and productization all remain open until their stated exit gates pass.

## Definition of done

- [ ] Native tvOS target has functional parity with the implemented iPad/Mac product surface across Plex, Jellyfin, and Emby, including video, music, browse/search/details, settings, diagnostics/privacy, progress/state, and applicable system integration.
- [ ] All existing platform build/test lanes remain healthy.
- [ ] No core flow requires touch, pointer, or a hardware keyboard; focus and Back/Menu behavior are deterministic.
- [ ] Physical Apple TV evidence covers playback, codecs/HDR/audio, Siri Remote, lifecycle, accessibility, and long-play behavior.
- [ ] Codec/server advertisements match tested runtime/device truth, including conservative transcode fallback.
- [ ] TestFlight/App Review assets, demo access, privacy metadata, signing, and release documentation are complete.
- [x] Downloads, offline playback, storage controls, and the Offline destination remain absent as the approved tvOS storage exception.
- [ ] No unfinished enhancement from an open issue is made a hidden dependency of tvOS parity; the release baseline is implemented behavior on `main`.
- [ ] The issue remains open until physical Apple TV and TestFlight acceptance are complete; simulator success alone is not sufficient.

## Related work

- #228 — first-class macOS target precedent
- #197 — canonical video Now Playing/remote-command work
- #238 — Emby BIF/ThumbnailSet trick-play for seek previews
- #202 — shared subtitle/audio preference policy
- #203 — “Why is this transcoding?” capability/reason model (currently visionOS-scoped)
- #204 — reusable codec/HDR/Dolby/AV1 badge models (currently Vision Pro-scoped)
- #243 — shared artwork-led detail screen requiring a TV adaptation
- #226 — shared accessibility semantics; tvOS owns its focus/remote acceptance
- #115 — future Mac-runner Apple-platform CI integration
- #92 — App Store/reviewer/privacy precedent (currently visionOS-scoped)

## Duplicate check

Searched current issue titles, bodies, comments, and PRs for `tvOS`, `Apple TV`, `AV1`, `VP9`, `HEVC`, `Dolby`, `HDR`, `codec`, and platform expansion. No existing issue or PR tracks a first-class tvOS target; related tickets cover shared capabilities or other platform ports only.
