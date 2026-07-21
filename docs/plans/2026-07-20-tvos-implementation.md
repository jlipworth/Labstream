# tvOS implementation plan

Status: **active research and implementation plan** for [GitHub issue #246](https://github.com/jlipworth/Labstream/issues/246). tvOS is not currently an implemented or supported Labstream platform; the phase checkboxes below are acceptance gates, not claims of shipped behavior.

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
- [ ] Add TV poster/card sizing, safe-area spacing, readable metadata, system focus effects, default focus, focus sections, and focus restoration across navigation, sheets, reloads, pagination, errors, and playback return. The first sizing/spacing/type pass covers authentication, shared video posters/grids, library cards, and music art; exhaustive focus-state and live-data review remains.
- [ ] Make Plex link code, Jellyfin Quick Connect, and Emby Connect PIN primary; keep remote-friendly manual URL/credential entry as fallback where needed. The initial three-backend TV layout and remote backend-selection fixture are implemented; live authentication, restore, error, and fallback flows remain.
- [ ] Validate local-network permission/ATS behavior, LAN and remote servers, Keychain restore, backend switching, signed-out/error states, dictation/iPhone Remote keyboard, and physical keyboard fallback.
- [ ] Make Settings TV-specific and focus-safe. Exclude download/storage/cellular controls, and replace unavailable diagnostics, feedback, discovery, or export surfaces with TV-native equivalents rather than silently dropping their user capability.

**Exit:** using only a Siri Remote, a user can sign in to each backend, browse/search, open details, recover from errors, return with focus restored, and sign out.

### Phase 2 — custom-player TV adaptation

- [ ] Keep the shared app-owned `CustomPlayerView`/`PlaybackController` as the only video player; do not restore the retired `AVPlayerViewController` path. The tvOS target now links AVKit explicitly so the shared player's `AVPlayerItem.externalMetadata` category call does not crash at launch, and live Plex playback has been proven in the simulator; the complete player-state audit remains open.
- [ ] Add tvOS focus ownership, chrome reveal/auto-hide, remote-command routing, focus restoration, and a remote-native scrubber interaction without duplicating canonical playback intent methods.
- [ ] Support exactly-once Play/Pause, Select, Menu/Back, clickpad/directional scrub and seek, Siri/system commands, buffering/retry, end-of-item, autoplay, and return-focus behavior.
- [ ] Expose quality, audio, subtitles, chapters, speed, skip intro/credits, and bounded diagnostics through TV-native player menus/actions.
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

- [ ] Add deterministic tvOS UI fixtures and `XCUIRemote` tests for directional focus, Select, Menu, Play/Pause, tab/rail boundaries, search, details, modals, player enter/exit, errors, backend switching, and destructive confirmations. Initial fixtures cover all three signed-out backend surfaces and Plex Home -> detail -> Menu/Back through the real app views.
- [ ] Assert the focused element after transitions; attach screenshots and accessibility hierarchies on failure.
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
