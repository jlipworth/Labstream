# tvOS implementation plan

Status: **active research and implementation plan** for [GitHub issue #246](https://github.com/jlipworth/Labstream/issues/246). tvOS is not currently an implemented or supported Labstream platform; the phase checkboxes below are acceptance gates, not claims of shipped behavior.

Research baseline: 2026-07-20 against repository commit `44839793`, current Apple developer documentation, current Apple TV 4K specifications, and a live GitHub duplicate/dependency audit. Recheck SDK requirements, hardware specifications, issue state, and source line locations when implementation begins because these facts may drift.

This document is the durable repository plan. Keep its phase status synchronized with issue #246 during implementation, then promote proven behavior into the current architecture, development, testing, and platform documentation. Archive this note only after every required acceptance gate is complete or explicitly moved to a linked follow-up.

## Goal

Create a first-class native tvOS version of Labstream for Apple TV, sharing the existing Plex/Jellyfin/Emby networking and playback policy while giving Apple TV its own 10-foot UI, focus model, Siri Remote behavior, player integration, testing lane, and release train.

A new Apple TV hardware refresh is [credible but still unannounced](https://www.macrumors.com/2026/07/08/apple-tv-4k-latest-rumors/), and an AV1-capable chip is plausible. That is motivation to establish the platform now, **not** an assumption in the design: the MVP must work against today's A15 Apple TV 4K and its [officially documented formats](https://www.apple.com/apple-tv-4k/specs/). Any wider codec support must be enabled only after Apple announces hardware and Labstream verifies it on that physical device.

## Research summary

- The repo currently has `Labstream` (visionOS), `LabstreamMobile` (iPhone/iPad), and `LabstreamMac`, all sharing the file-system-synchronized `Labstream/` source root and PMSKit. The completed macOS port in #228 is the closest process precedent.
- PMSKit has no third-party package dependencies and is a good shared core, but `PMSKit/Package.swift` does not declare tvOS yet.
- This cannot be a platform-setting-only port. There is no tvOS target, scheme, `@main`, identity, resource set, test host, or simulator/device workflow. `RootView` also routes an unknown platform into visionOS-only content, and shared source contains APIs that need tvOS availability gates (including Spotlight, MetricKit, pasteboard/file export, and the current embedded web-auth presentation path).
- Existing code-based sign-in is a strong TV foundation: Plex link code, Jellyfin Quick Connect, and Emby Connect PIN should be the primary living-room flows.
- The shared `PlaybackController`/`AVPlayer` ownership and server progress/cleanup logic should remain canonical. For tvOS, start with an `AVPlayerViewController` adapter unless a short spike proves the custom chrome can match all standard remote, scrub, subtitle/audio, Siri, Now Playing, and PiP behavior without duplicating the system player. Apple recommends the system player for the familiar tvOS experience: [playback customization](https://developer.apple.com/documentation/avkit/customizing-the-tvos-playback-experience), [remote interactions](https://developer.apple.com/documentation/AVFoundation/supporting-remote-interactions-in-tvos).
- tvOS is focus-first, not touch/pointer-first. Every core flow needs deterministic initial focus, directional reachability, focus restoration, and correct Menu/Back behavior using system focus primitives: [focus and selection](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection/), [remotes](https://developer.apple.com/design/human-interface-guidelines/remotes).
- Apple TV local storage is purgeable outside very small settings data. The first release should be streaming-first and omit the current offline library/download promises until a separate physical-device storage, eviction, quota, sleep/relaunch, and recovery design is proven: [tvOS storage guidance](https://developer.apple.com/library/archive/documentation/General/Conceptual/AppleTV_PG/), [current file-system guidance](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively).
- Simulator tests can prove compile, navigation, and focus behavior. Physical Apple TV is mandatory for codec, HDR/Dolby Vision, HDMI/audio output, Siri Remote, PiP/background, performance, and long-play acceptance.

## Product scope

### MVP

- Native `LabstreamTV` app target and TV-specific app identity/assets.
- Plex, Jellyfin, and Emby secure sign-in, saved-session restore, backend switching, and sign-out.
- Home, Libraries, Search, TV/movie/episode detail, TV-relevant Settings, and video playback.
- Watched/resume state, Up Next/autoplay, quality, audio, subtitles, chapters/skip actions, progress reporting, retry/error handling, and transcode teardown.
- A ten-foot layout and complete Siri Remote/focus/accessibility path; no core task may require touch, pointer, or hardware keyboard input.
- Conservative per-platform/device playback capabilities with server Direct Play/Direct Stream/transcode fallback.
- tvOS simulator automation, physical-device validation, internal/external TestFlight, and tvOS App Store assets/reviewer flow.

### Explicitly deferred until the streaming MVP is healthy

- Persistent offline downloads and an Offline destination.
- visionOS Cinema/Reality Theater and visionOS-only SharePlay surfaces.
- Dynamic personalized Top Shelf content (static artwork is sufficient initially).
- Spotlight/App Intents parity, text-heavy diagnostics export, and other non-TV system integrations.
- Advanced music UI/queue parity and Apple TV multiuser mapping. Assess these after video MVP rather than letting them block it.

## Implementation plan

### Phase 0 — target and compile foundation

- [ ] Add `.tvOS(...)` to `PMSKit/Package.swift` and run PMSKit tests for the declared platform.
- [ ] Add `LabstreamTV`, `LabstreamTVTests`, and `LabstreamTVUITests` targets/products/shared schemes with tvOS deployment settings, signing, generated plist, package linkage, test plans, and layered TV app icon assets.
- [ ] Add a tvOS-only `LabstreamTV.swift` entry point and explicit Apple TV/tvOS values in `PlatformClientIdentity`.
- [ ] Add an explicit `tvRootContent` path instead of allowing `RootView` to fall through to visionOS-only content.
- [ ] Audit the shared source root for `canImport(UIKit)` and availability fallthroughs; gate or adapt MetricKit, Spotlight, pasteboard/share/export, embedded web auth, iOS orientation/PiP, and visionOS scenes.
- [ ] Introduce a central platform feature policy so tvOS can omit downloads/offline, Spotlight, unsupported sharing, and irrelevant Settings without forking backend policy.
- [ ] Update project-hygiene allowlists, `scripts/worktree-sim.sh`, compile audit, Apple-platform CI, and developer docs with a concrete tvOS simulator identity and never target a generic `booted` simulator.

**Exit:** a clean tvOS simulator build launches deterministically into fixture login/browse state; existing visionOS, mobile, Mac, and PMSKit lanes still build/test.

### Phase 1 — TV shell, authentication, and focus

- [ ] Build a dedicated tvOS sidebar/tab shell for Home, Libraries, Search, optional Music, and Settings; do not show an empty Offline destination.
- [ ] Add TV poster/card sizing, safe-area spacing, readable metadata, system focus effects, default focus, focus sections, and focus restoration across navigation, sheets, reloads, pagination, errors, and playback return.
- [ ] Make Plex link code, Jellyfin Quick Connect, and Emby Connect PIN primary; keep remote-friendly manual URL/credential entry as fallback where needed.
- [ ] Validate local-network permission/ATS behavior, LAN and remote servers, Keychain restore, backend switching, signed-out/error states, dictation/iPhone Remote keyboard, and physical keyboard fallback.
- [ ] Make Settings TV-specific and focus-safe, excluding download/storage/cellular, Spotlight, and file-export controls.

**Exit:** using only a Siri Remote, a user can sign in to each backend, browse/search, open details, recover from errors, return with focus restored, and sign out.

### Phase 2 — native TV playback

- [ ] Spike an `AVPlayerViewController` adapter around the canonical `PlaybackController`/`AVPlayer`; record the decision before extending the existing custom chrome.
- [ ] Support exactly-once Play/Pause, Select, Menu/Back, clickpad/directional scrub and seek, Siri/system commands, buffering/retry, end-of-item, autoplay, and return-focus behavior.
- [ ] Expose quality, audio, subtitles, chapters, speed, skip intro/credits, and bounded diagnostics through TV-native player menus/actions.
- [ ] Add/generalize the tvOS media-session coordinator for audio session, interruptions/routes, Now Playing metadata/commands, background behavior, and PiP evaluation.
- [ ] Preserve load-bearing startup/stall/seek/restart/cleanup invariants and backend progress/transcode teardown from `docs/PLAYBACK-ARCHITECTURE.md`.

**Exit:** deterministic fixtures and live servers prove stable remote control, track selection, reporting, cleanup, failure recovery, and focus restoration.

### Phase 3 — capability-driven codec negotiation

- [ ] Refactor the current generic Apple server profiles into an injected backend-neutral platform/device capability profile; keep the tvOS default at the existing conservative proven intersection.
- [ ] Record source container/codecs, server decision, runtime AVPlayer format, HDR state, output route, and observed result for Plex/Jellyfin/Emby.
- [ ] Validate H.264 and HEVC Main/Main10; SDR, HDR10, HLG, and supported Dolby Vision profiles; AAC, AC-3, E-AC-3/Atmos; text/image subtitles; Direct Play, remux, audio transcode, video transcode, and subtitle burn.
- [ ] Keep AV1, DTS/DTS-HD, TrueHD, additional Dolby Vision profiles, passthrough claims, and any newly announced codec disabled/unadvertised until official support **and** physical-device playback evidence exist.
- [ ] When new Apple TV hardware ships, add it to the matrix and widen server advertisements only for verified rows. Do not infer app-level Direct Play from a chip or protocol bullet alone.

**Exit:** a checked-in/test-linked matrix explains each backend decision without false capability advertising, and unsupported media reliably falls back to server transcode.

### Phase 4 — automation, accessibility, and physical hardware

- [ ] Add deterministic tvOS UI fixtures and `XCUIRemote` tests for directional focus, Select, Menu, Play/Pause, tab/rail boundaries, search, details, modals, player enter/exit, errors, backend switching, and destructive confirmations.
- [ ] Assert the focused element after transitions; attach screenshots and accessibility hierarchies on failure.
- [ ] Complete VoiceOver/Switch Control tasks for sign-in, browse, search, playback, audio/subtitles, and sign-out; verify Increase Contrast, Reduce Motion, Bold Text, captions, and audio descriptions.
- [ ] Validate on the oldest supported Apple TV and the current Apple TV 4K, plus any future model after release; include real Siri Remote generations where available.
- [ ] Cover Ethernet/Wi-Fi, display range/frame-rate matching, HDMI/receiver routes, sleep/wake, background/foreground, PiP, interruptions, network loss/recovery, memory pressure, rapid commands, and multi-hour playback.

**Exit:** simulator focus automation is repeatable and a signed physical-device matrix has no unresolved core focus, control, playback, lifecycle, or capability failures.

### Phase 5 — productization and release

- [ ] Add TV icon/parallax and static Top Shelf artwork, screenshots, privacy text/labels, signing/provisioning, export-compliance answer, version/build release train, and deploy/test docs.
- [ ] Provide App Review with an internet-accessible seeded demo account/server and precise reviewer instructions for the supported backends.
- [ ] Run internal TestFlight, then a small external cohort spanning Apple TV generations, remotes, receivers/displays, networks, and Plex/Jellyfin/Emby.
- [ ] Add the tvOS platform to README status only at its actual validation level; do not advertise support before physical-device/TestFlight proof.

**Exit:** the declared MVP is distributable through TestFlight/App Store and documented without aspirational platform or codec claims.

## Definition of done

- [ ] Native tvOS target ships the declared Plex/Jellyfin/Emby streaming MVP.
- [ ] All existing platform build/test lanes remain healthy.
- [ ] No core flow requires touch, pointer, or a hardware keyboard; focus and Back/Menu behavior are deterministic.
- [ ] Physical Apple TV evidence covers playback, codecs/HDR/audio, Siri Remote, lifecycle, accessibility, and long-play behavior.
- [ ] Codec/server advertisements match tested runtime/device truth, including conservative transcode fallback.
- [ ] TestFlight/App Review assets, demo access, privacy metadata, signing, and release documentation are complete.
- [ ] Offline downloads remain disabled unless a separate purge/recovery design and physical-device acceptance pass.
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
